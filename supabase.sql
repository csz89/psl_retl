-- PSL Rater: онлайн-батлы. Выполните один раз: Supabase -> SQL Editor -> New query -> вставить -> Run.
-- Можно запускать повторно: уже созданное не пересоздаётся.
-- Фото в базу не попадают. Хранятся ник, ссылка на аватар Google, пол, число PSL и очки.
--
-- Правила (меняются здесь же, потом нужно снова нажать Run):
--   ранг = очки / 500 (всего 8 рангов: Рекрут ... Титан), победа +100, поражение -50, ничья 0, ниже 0 очки не падают;
--   соперник берётся из своего ранга, если никого нет, то из соседнего (+-1). Рекрут никогда не встретит Титана;
--   сравнение по PSL с точностью до 0,1: у кого выше, тот победил. Соперник тот же пол, очки соперника не меняются.

create table if not exists public.players (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 30),
  picture text check (picture is null or char_length(picture) <= 500),
  points integer not null default 0 check (points >= 0),
  wins integer not null default 0,
  losses integer not null default 0,
  draws integer not null default 0,
  sex text check (sex in ('m', 'f')),
  psl numeric(3, 1) check (psl between 1 and 9),
  psl_set_at timestamptz,
  last_fight_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.battles (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  player_id uuid not null references public.players (id) on delete cascade,
  opp_id uuid references public.players (id) on delete set null,
  opp_name text not null,
  my_psl numeric(3, 1) not null,
  opp_psl numeric(3, 1) not null,
  result text not null check (result in ('win', 'loss', 'draw')),
  delta integer not null
);

create index if not exists battles_player_at on public.battles (player_id, at desc);
create index if not exists players_points on public.players (points desc);
create index if not exists players_pool on public.players (sex, points) where psl is not null;

-- права: читать можно, писать напрямую нельзя (только через функции ниже)
alter table public.players enable row level security;
alter table public.battles enable row level security;
drop policy if exists players_read on public.players;
create policy players_read on public.players for select to authenticated using (true);
drop policy if exists battles_read on public.battles;
create policy battles_read on public.battles for select to authenticated using (player_id = auth.uid());
revoke all on public.players, public.battles from anon, authenticated;
grant select on public.players, public.battles to authenticated;

-- создать профиль бойца или сменить ник (аватар берётся из аккаунта Google, а не от пользователя)
create or replace function public.join_ladder(p_name text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_name text;
  v_pic text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  v_name := left(regexp_replace(btrim(coalesce(p_name, '')), '[[:cntrl:]]', '', 'g'), 30);
  if p_name is not null and char_length(v_name) < 2 then raise exception 'bad_name'; end if;
  select u.raw_user_meta_data ->> 'picture' into v_pic from auth.users u where u.id = v_uid;
  if v_pic is not null and v_pic !~ '^https://[a-z0-9.-]+\.googleusercontent\.com/' then v_pic := null; end if;
  if p_name is null then
    if not exists (select 1 from players where id = v_uid) then raise exception 'bad_name'; end if;
    update players set picture = v_pic where id = v_uid;
  else
    insert into players (id, name, picture) values (v_uid, v_name, v_pic)
    on conflict (id) do update set name = excluded.name, picture = excluded.picture;
  end if;
end $$;

-- выставить бойца: пол и PSL последней оценки (раз в 10 секунд)
create or replace function public.set_fighter(p_sex text, p_psl numeric)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_psl numeric(3, 1);
  v_at timestamptz;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_sex is null or p_sex not in ('m', 'f') then raise exception 'bad_sex'; end if;
  if p_psl is null or p_psl < 1 or p_psl > 9 then raise exception 'bad_psl'; end if;
  v_psl := round(p_psl, 1);
  select psl_set_at into v_at from players where id = v_uid for update;
  if not found then raise exception 'not_joined'; end if;
  if v_at is not null and v_at > now() - interval '10 seconds' then raise exception 'too_fast'; end if;
  update players set sex = p_sex, psl = v_psl, psl_set_at = now() where id = v_uid;
end $$;

-- бой: подбирает соперника по рангу, сравнивает PSL, начисляет очки
create or replace function public.fight()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me players;
  v_opp players;
  v_rank int;
  v_res text;
  v_old int;
  v_new int;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  select * into v_me from players where id = auth.uid() for update;
  if not found then raise exception 'not_joined'; end if;
  if v_me.psl is null then raise exception 'no_fighter'; end if;
  if v_me.last_fight_at is not null and v_me.last_fight_at > now() - interval '3 seconds' then raise exception 'too_fast'; end if;

  v_rank := least(v_me.points / 500, 7);
  select o.* into v_opp from players o
  where o.id <> v_me.id and o.sex = v_me.sex and o.psl is not null
    and abs(least(o.points / 500, 7) - v_rank) <= 1
  order by abs(least(o.points / 500, 7) - v_rank),
           exists (select 1 from battles b where b.player_id = v_me.id and b.opp_id = o.id and b.at > now() - interval '1 hour'),
           random()
  limit 1;
  if not found then raise exception 'no_opponent'; end if;

  v_old := v_me.points;
  if v_me.psl > v_opp.psl then v_res := 'win'; v_new := v_old + 100;
  elsif v_me.psl < v_opp.psl then v_res := 'loss'; v_new := greatest(0, v_old - 50);
  else v_res := 'draw'; v_new := v_old; end if;

  update players set points = v_new, last_fight_at = now(),
    wins = wins + (v_res = 'win')::int, losses = losses + (v_res = 'loss')::int, draws = draws + (v_res = 'draw')::int
  where id = v_me.id;
  insert into battles (player_id, opp_id, opp_name, my_psl, opp_psl, result, delta)
  values (v_me.id, v_opp.id, v_opp.name, v_me.psl, v_opp.psl, v_res, v_new - v_old);

  return jsonb_build_object(
    'result', v_res, 'delta', v_new - v_old, 'points', v_new,
    'rank_before', v_rank, 'rank_after', least(v_new / 500, 7),
    'me', jsonb_build_object('psl', v_me.psl),
    'opp', jsonb_build_object('name', v_opp.name, 'picture', v_opp.picture, 'psl', v_opp.psl, 'points', v_opp.points));
end $$;

-- удалить свой профиль бойца и историю боёв
create or replace function public.leave_ladder()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  delete from players where id = auth.uid();
end $$;

revoke all on function public.join_ladder(text), public.set_fighter(text, numeric), public.fight(), public.leave_ladder() from public, anon;
grant execute on function public.join_ladder(text), public.set_fighter(text, numeric), public.fight(), public.leave_ladder() to authenticated;
