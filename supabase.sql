-- PSL Rater: онлайн-батлы 1 на 1 и магазин за Рету. Выполните целиком: Supabase -> SQL Editor -> New query -> вставить -> Run.
-- Можно запускать повторно и поверх прошлой версии: лишнее удаляется, нужное создаётся.
--
-- Как идёт бой:
--   1) игрок нажимает «Найти соперника», его ставят в очередь; пара собирается из игроков ОДНОГО пола и ОДНОГО ранга
--      (если ждать дольше 10 секунд, разрешён соседний ранг, но не дальше: Рекрут никогда не встретит Титана);
--   2) у каждого своё окно: игрок ставит своё лицо и жмёт «Определить рейт»; соперник видит маленькую копию лица;
--   3) когда оба определили рейт, побеждает тот, у кого PSL выше (хоть на 0,1); равный PSL это ничья;
--   4) победа +100 очков, поражение -50 (ниже нуля не падает), ничья 0; 500 очков = 1 ранг, всего 8 рангов.
--   Если соперник за 3 минуты не определил рейт или ушёл, побеждает тот, кто успел (неявка), второй получает поражение.
-- Рета (местная валюта): +100 за каждую победу в онлайн-бое. В магазине за неё покупают анимации победы (могга) и косметику профиля.
--   Цены лежат в таблице shop_items ниже: поменяйте число и снова нажмите Run. Баланс и покупки меняются только функциями сервера.
-- Фото: маленькая копия лица (до 60 КБ) лежит только на время боя и стирается через 5 минут после его конца.
-- Ограничение: PSL считается в браузере игрока, сервер ему верит.

create table if not exists public.players (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 30),
  picture text check (picture is null or char_length(picture) <= 500),
  points integer not null default 0 check (points >= 0),
  wins integer not null default 0,
  losses integer not null default 0,
  draws integer not null default 0,
  sex text check (sex in ('m', 'f')),
  created_at timestamptz not null default now()
);
alter table public.players add column if not exists reta integer not null default 0 check (reta >= 0);
alter table public.players add column if not exists equipped jsonb not null default '{}'::jsonb;

-- остатки прошлой версии (бои с «претендентом» без соперника онлайн)
drop function if exists public.fight();
drop function if exists public.set_fighter(text, numeric);
drop index if exists public.players_pool;
alter table public.players drop column if exists psl;
alter table public.players drop column if exists psl_set_at;
alter table public.players drop column if exists last_fight_at;

create table if not exists public.battles (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  player_id uuid not null references public.players (id) on delete cascade,
  opp_id uuid references public.players (id) on delete set null,
  opp_name text not null,
  my_psl numeric(3, 1),
  opp_psl numeric(3, 1),
  result text not null check (result in ('win', 'loss', 'draw')),
  delta integer not null
);
alter table public.battles alter column my_psl drop not null;
alter table public.battles alter column opp_psl drop not null;
alter table public.battles add column if not exists note text;
alter table public.battles add column if not exists reta integer not null default 0;

create table if not exists public.queue (
  player_id uuid primary key references public.players (id) on delete cascade,
  sex text not null check (sex in ('m', 'f')),
  rank integer not null,
  since timestamptz not null default now(),
  seen timestamptz not null default now()
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  status text not null default 'live' check (status in ('live', 'done', 'void')),
  result text check (result in ('a', 'b', 'draw', 'void')),
  note text,
  a uuid references public.players (id) on delete set null,
  b uuid references public.players (id) on delete set null,
  a_name text not null, b_name text not null,
  a_pic text, b_pic text,
  a_rank integer not null, b_rank integer not null,
  a_photo text check (a_photo is null or char_length(a_photo) <= 60000),
  b_photo text check (b_photo is null or char_length(b_photo) <= 60000),
  a_psl numeric(3, 1), b_psl numeric(3, 1),
  a_delta integer, b_delta integer
);
alter table public.matches add column if not exists a_eq jsonb not null default '{}'::jsonb;   -- что было надето у игроков в начале боя
alter table public.matches add column if not exists b_eq jsonb not null default '{}'::jsonb;
alter table public.matches add column if not exists a_reta integer not null default 0;
alter table public.matches add column if not exists b_reta integer not null default 0;
create index if not exists matches_a on public.matches (a) where status = 'live';
create index if not exists matches_b on public.matches (b) where status = 'live';

create table if not exists public.reports (   -- жалобы на фото: смотрите их в Table Editor
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  reporter uuid references public.players (id) on delete set null,
  reported uuid references public.players (id) on delete set null,
  match_id uuid,
  photo text
);

create table if not exists public.shop_items (
  id text primary key,
  kind text not null check (kind in ('mogg', 'frame', 'title', 'nick', 'banner')),
  name text not null,
  price integer not null check (price >= 0),
  sort integer not null default 0
);
create table if not exists public.purchases (
  player_id uuid not null references public.players (id) on delete cascade,
  item_id text not null references public.shop_items (id) on delete cascade,
  at timestamptz not null default now(),
  primary key (player_id, item_id)
);

-- каталог и цены (id должны совпадать с теми, что знает сайт)
insert into public.shop_items (id, kind, name, price, sort) values
  ('mogg_bolt', 'mogg', 'Молния', 300, 1), ('mogg_glitch', 'mogg', 'Глитч', 400, 2), ('mogg_fire', 'mogg', 'Пламя', 500, 3),
  ('mogg_crack', 'mogg', 'Трещины', 600, 4), ('mogg_crown', 'mogg', 'Корона', 800, 5), ('mogg_meteor', 'mogg', 'Метеорит', 1000, 6),
  ('frame_gold', 'frame', 'Золотая рамка', 200, 1), ('frame_neon', 'frame', 'Неон', 300, 2), ('frame_fire', 'frame', 'Огонь', 500, 3), ('frame_ice', 'frame', 'Лёд', 500, 4),
  ('title_moger', 'title', 'Могер', 150, 1), ('title_reta', 'title', 'Ретаголик', 250, 2), ('title_king', 'title', '175см со стельками', 500, 3), ('title_eye', 'title', 'Король лтнов', 700, 4),
  ('nick_gold', 'nick', 'Золотой ник', 200, 1), ('nick_aurora', 'nick', 'Северное сияние', 350, 2), ('nick_glow', 'nick', 'Неоновое свечение', 500, 3),
  ('banner_aurora', 'banner', 'Аврора', 300, 1), ('banner_matrix', 'banner', 'Матрица', 400, 2), ('banner_sunset', 'banner', 'Закат', 400, 3)
on conflict (id) do update set kind = excluded.kind, name = excluded.name, price = excluded.price, sort = excluded.sort;

create index if not exists battles_player_at on public.battles (player_id, at desc);
create index if not exists players_points on public.players (points desc);

-- права: ладдер и свою историю читать можно, всё остальное только через функции ниже
alter table public.players enable row level security;
alter table public.battles enable row level security;
alter table public.queue enable row level security;
alter table public.matches enable row level security;
alter table public.reports enable row level security;
alter table public.shop_items enable row level security;
alter table public.purchases enable row level security;
drop policy if exists players_read on public.players;
create policy players_read on public.players for select to authenticated using (true);
drop policy if exists battles_read on public.battles;
create policy battles_read on public.battles for select to authenticated using (player_id = auth.uid());
drop policy if exists shop_read on public.shop_items;
create policy shop_read on public.shop_items for select to authenticated using (true);
drop policy if exists purchases_read on public.purchases;
create policy purchases_read on public.purchases for select to authenticated using (player_id = auth.uid());
revoke all on public.players, public.battles, public.queue, public.matches, public.reports, public.shop_items, public.purchases from anon, authenticated;
-- баланс Реты (колонка reta) другим игрокам не показывается: свой профиль приходит через my_profile()
grant select (id, name, picture, points, wins, losses, draws, sex, created_at, equipped) on public.players to authenticated;
grant select on public.battles, public.shop_items, public.purchases to authenticated;

-- ---------- внутренние помощники (клиентам недоступны) ----------

-- итог боя: очки, счётчики, история
create or replace function public._finish_match(p_id uuid, p_result text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  m matches;
  pa players; pb players;
  da int := 0; db int := 0; ra int := 0; rb int := 0;
begin
  select * into m from matches where id = p_id for update;
  if not found or m.status <> 'live' then return; end if;
  if p_result = 'void' then
    update matches set status = 'void', result = 'void', finished_at = now(), note = p_note where id = p_id;
    return;
  end if;
  select * into pa from players where id = m.a for update;
  select * into pb from players where id = m.b for update;
  if p_result = 'a' then da := 100; ra := 100; db := -least(50, coalesce(pb.points, 0));
  elsif p_result = 'b' then db := 100; rb := 100; da := -least(50, coalesce(pa.points, 0)); end if;
  if pa.id is not null then
    update players set points = points + da, reta = reta + ra, wins = wins + (p_result = 'a')::int, losses = losses + (p_result = 'b')::int, draws = draws + (p_result = 'draw')::int where id = pa.id;
    insert into battles (player_id, opp_id, opp_name, my_psl, opp_psl, result, delta, note, reta)
    values (pa.id, m.b, m.b_name, m.a_psl, m.b_psl, case p_result when 'a' then 'win' when 'b' then 'loss' else 'draw' end, da, p_note, ra);
  end if;
  if pb.id is not null then
    update players set points = points + db, reta = reta + rb, wins = wins + (p_result = 'b')::int, losses = losses + (p_result = 'a')::int, draws = draws + (p_result = 'draw')::int where id = pb.id;
    insert into battles (player_id, opp_id, opp_name, my_psl, opp_psl, result, delta, note, reta)
    values (pb.id, m.a, m.a_name, m.b_psl, m.a_psl, case p_result when 'b' then 'win' when 'a' then 'loss' else 'draw' end, db, p_note, rb);
  end if;
  update matches set status = 'done', result = p_result, finished_at = now(), a_delta = da, b_delta = db, a_reta = ra, b_reta = rb, note = p_note where id = p_id;
end $$;

-- решает бой, если пора: оба определили рейт, либо вышло время (3 минуты)
create or replace function public._settle_match(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare m matches;
begin
  select * into m from matches where id = p_id for update;
  if not found or m.status <> 'live' then return; end if;
  if m.a_psl is not null and m.b_psl is not null then
    perform _finish_match(p_id, case when m.a_psl > m.b_psl then 'a' when m.a_psl < m.b_psl then 'b' else 'draw' end);
  elsif m.created_at < now() - interval '3 minutes' then
    if m.a_psl is not null then perform _finish_match(p_id, 'a', 'walkover');
    elsif m.b_psl is not null then perform _finish_match(p_id, 'b', 'walkover');
    else perform _finish_match(p_id, 'void', 'timeout'); end if;
  end if;
end $$;

create or replace function public._cleanup()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  delete from queue where seen < now() - interval '30 seconds';
  for r in select id from matches where status = 'live' and created_at < now() - interval '3 minutes' loop
    perform _settle_match(r.id);
  end loop;
  update matches set a_photo = null, b_photo = null
  where status <> 'live' and finished_at < now() - interval '5 minutes' and (a_photo is not null or b_photo is not null);
  delete from matches where status <> 'live' and finished_at < now() - interval '1 hour';
  delete from reports where at < now() - interval '30 days';
end $$;

-- что видит игрок: соперника и его PSL видно только когда бой закончен
create or replace function public._view(p_id uuid, p_uid uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m matches; me_a boolean; res text; pts int; bal int;
begin
  select * into m from matches where id = p_id;
  if not found then return null; end if;
  me_a := m.a = p_uid;
  select points, reta into pts, bal from players where id = p_uid;
  res := case when m.status = 'live' then null when m.result = 'void' then 'void' when m.result = 'draw' then 'draw'
              when (m.result = 'a') = me_a then 'win' else 'loss' end;
  return jsonb_build_object(
    'id', m.id, 'status', m.status, 'result', res, 'note', m.note,
    'left_s', greatest(0, 180 - extract(epoch from now() - m.created_at))::int,
    'me', jsonb_build_object('name', case when me_a then m.a_name else m.b_name end, 'picture', case when me_a then m.a_pic else m.b_pic end,
          'rank', case when me_a then m.a_rank else m.b_rank end, 'photo', case when me_a then m.a_photo else m.b_photo end,
          'rated', (case when me_a then m.a_psl else m.b_psl end) is not null,
          'eq', case when me_a then m.a_eq else m.b_eq end),
    'opp', jsonb_build_object('name', case when me_a then m.b_name else m.a_name end, 'picture', case when me_a then m.b_pic else m.a_pic end,
          'rank', case when me_a then m.b_rank else m.a_rank end, 'photo', case when me_a then m.b_photo else m.a_photo end,
          'rated', (case when me_a then m.b_psl else m.a_psl end) is not null,
          'eq', case when me_a then m.b_eq else m.a_eq end),
    'my_psl', case when m.status = 'done' then case when me_a then m.a_psl else m.b_psl end end,
    'opp_psl', case when m.status = 'done' then case when me_a then m.b_psl else m.a_psl end end,
    'delta', case when m.status = 'done' then case when me_a then m.a_delta else m.b_delta end end,
    'points', pts, 'rank_after', least(coalesce(pts, 0) / 500, 7),
    'reta', bal, 'reta_delta', case when m.status = 'done' then case when me_a then m.a_reta else m.b_reta end end,
    'fx', case when m.status = 'done' then case m.result when 'a' then m.a_eq ->> 'mogg' when 'b' then m.b_eq ->> 'mogg' end end);
end $$;

-- ---------- функции для сайта ----------

-- создать профиль (ник) или сменить ник (аватар берётся из аккаунта Google, а не от пользователя)
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

-- поиск соперника; вызывать каждые пару секунд, пока идёт поиск (это и есть «я ещё здесь»)
create or replace function public.queue_join(p_sex text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_me players;
  v_rank int;
  v_m matches;
  v_since timestamptz;
  v_q queue;
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_sex is null or p_sex not in ('m', 'f') then raise exception 'bad_sex'; end if;
  select * into v_me from players where id = v_uid;
  if not found then raise exception 'not_joined'; end if;
  perform pg_advisory_xact_lock(hashtext('psl-queue'));
  perform _cleanup();
  select * into v_m from matches where status = 'live' and (a = v_uid or b = v_uid) limit 1;
  if found then return jsonb_build_object('state', 'match', 'match', _view(v_m.id, v_uid)); end if;

  v_rank := least(v_me.points / 500, 7);
  update players set sex = p_sex where id = v_uid;
  insert into queue (player_id, sex, rank) values (v_uid, p_sex, v_rank)
  on conflict (player_id) do update set seen = now(), rank = excluded.rank,
    since = case when queue.sex = excluded.sex then queue.since else now() end, sex = excluded.sex;
  select since into v_since from queue where player_id = v_uid;

  select q.* into v_q from queue q
  where q.player_id <> v_uid and q.sex = p_sex and q.seen > now() - interval '15 seconds'
    and (q.rank = v_rank or (abs(q.rank - v_rank) = 1 and (q.since < now() - interval '10 seconds' or v_since < now() - interval '10 seconds')))
  order by abs(q.rank - v_rank), q.since
  limit 1;
  if not found then
    return jsonb_build_object('state', 'searching', 'waited', extract(epoch from now() - v_since)::int);
  end if;

  insert into matches (a, b, a_name, b_name, a_pic, b_pic, a_rank, b_rank, a_eq, b_eq)
  select v_q.player_id, v_uid, pa.name, v_me.name, pa.picture, v_me.picture, v_q.rank, v_rank, pa.equipped, v_me.equipped
  from players pa where pa.id = v_q.player_id
  returning id into v_id;
  delete from queue where player_id in (v_uid, v_q.player_id);
  return jsonb_build_object('state', 'match', 'match', _view(v_id, v_uid));
end $$;

create or replace function public.queue_leave()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  delete from queue where player_id = auth.uid();
end $$;

-- текущее состояние: идёт ли бой (для опроса и для возврата на страницу)
create or replace function public.match_state()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_m matches;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  perform pg_advisory_xact_lock(hashtext('psl-queue'));
  perform _cleanup();
  select * into v_m from matches where (a = v_uid or b = v_uid) order by created_at desc limit 1;
  if found and (v_m.status = 'live' or v_m.finished_at > now() - interval '2 minutes') then
    return jsonb_build_object('state', 'match', 'match', _view(v_m.id, v_uid));
  end if;
  if exists (select 1 from queue where player_id = v_uid) then return jsonb_build_object('state', 'searching'); end if;
  return jsonb_build_object('state', 'idle');
end $$;

-- поставить своё лицо (маленькая копия, JPEG)
create or replace function public.match_photo(p_match uuid, p_photo text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m matches;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_photo is null or char_length(p_photo) > 60000 or p_photo !~ '^data:image/jpeg;base64,[A-Za-z0-9+/=]+$' then raise exception 'bad_photo'; end if;
  select * into m from matches where id = p_match and (a = v_uid or b = v_uid) for update;
  if not found then raise exception 'no_match'; end if;
  perform _settle_match(p_match);
  select * into m from matches where id = p_match;
  if m.status <> 'live' then return _view(p_match, v_uid); end if;
  if (m.a = v_uid and m.a_psl is not null) or (m.b = v_uid and m.b_psl is not null) then raise exception 'already_rated'; end if;
  if m.a = v_uid then update matches set a_photo = p_photo where id = p_match; else update matches set b_photo = p_photo where id = p_match; end if;
  return _view(p_match, v_uid);
end $$;

-- определить рейт: присылает PSL; когда оба прислали, бой решается
create or replace function public.match_rate(p_match uuid, p_psl numeric)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m matches; v_psl numeric(3, 1);
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_psl is null or p_psl < 1 or p_psl > 9 then raise exception 'bad_psl'; end if;
  v_psl := round(p_psl, 1);
  select * into m from matches where id = p_match and (a = v_uid or b = v_uid) for update;
  if not found then raise exception 'no_match'; end if;
  perform _settle_match(p_match);
  select * into m from matches where id = p_match;
  if m.status <> 'live' then return _view(p_match, v_uid); end if;
  if (m.a = v_uid and m.a_photo is null) or (m.b = v_uid and m.b_photo is null) then raise exception 'no_photo'; end if;
  if (m.a = v_uid and m.a_psl is not null) or (m.b = v_uid and m.b_psl is not null) then raise exception 'already_rated'; end if;
  if m.a = v_uid then update matches set a_psl = v_psl where id = p_match; else update matches set b_psl = v_psl where id = p_match; end if;
  perform _settle_match(p_match);
  return _view(p_match, v_uid);
end $$;

-- выйти из боя: если соперник уже поставил лицо, это поражение (неявка), иначе бой отменяется без последствий
create or replace function public.match_leave(p_match uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m matches;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into m from matches where id = p_match and (a = v_uid or b = v_uid) for update;
  if not found then raise exception 'no_match'; end if;
  if m.status = 'live' then
    if m.a = v_uid then perform _finish_match(p_match, case when m.b_photo is not null then 'b' else 'void' end, case when m.b_photo is not null then 'walkover' else 'left' end);
    else perform _finish_match(p_match, case when m.a_photo is not null then 'a' else 'void' end, case when m.a_photo is not null then 'walkover' else 'left' end); end if;
  end if;
  return _view(p_match, v_uid);
end $$;

-- пожаловаться на фото соперника (до 10 жалоб в час)
create or replace function public.report_opponent(p_match uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); m matches; v_opp uuid; v_photo text;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into m from matches where id = p_match and (a = v_uid or b = v_uid);
  if not found then raise exception 'no_match'; end if;
  if (select count(*) from reports where reporter = v_uid and at > now() - interval '1 hour') >= 10 then raise exception 'too_fast'; end if;
  v_opp := case when m.a = v_uid then m.b else m.a end;
  v_photo := case when m.a = v_uid then m.b_photo else m.a_photo end;
  insert into reports (reporter, reported, match_id, photo) values (v_uid, v_opp, p_match, v_photo);
end $$;

-- свой профиль целиком (с балансом Реты)
create or replace function public.my_profile()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  return (select to_jsonb(p) from players p where p.id = auth.uid());
end $$;

-- купить предмет за Рету
create or replace function public.buy_item(p_item text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_item shop_items; v_me players;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_item from shop_items where id = p_item;
  if not found then raise exception 'no_item'; end if;
  select * into v_me from players where id = v_uid for update;
  if not found then raise exception 'not_joined'; end if;
  if exists (select 1 from purchases where player_id = v_uid and item_id = p_item) then raise exception 'owned'; end if;
  if v_me.reta < v_item.price then raise exception 'poor'; end if;
  update players set reta = reta - v_item.price where id = v_uid;
  insert into purchases (player_id, item_id) values (v_uid, p_item);
  return jsonb_build_object('reta', v_me.reta - v_item.price, 'item', p_item);
end $$;

-- надеть купленное (p_item = null снимает предмет из этой ячейки)
create or replace function public.equip_item(p_slot text, p_item text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_eq jsonb;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_slot is null or p_slot not in ('mogg', 'frame', 'title', 'nick', 'banner') then raise exception 'bad_slot'; end if;
  perform 1 from players where id = v_uid for update;
  if not found then raise exception 'not_joined'; end if;
  if p_item is null then
    update players set equipped = equipped - p_slot where id = v_uid returning equipped into v_eq;
  else
    if not exists (select 1 from shop_items i join purchases b on b.item_id = i.id where i.id = p_item and i.kind = p_slot and b.player_id = v_uid) then raise exception 'not_owned'; end if;
    update players set equipped = jsonb_set(equipped, array[p_slot], to_jsonb(p_item)) where id = v_uid returning equipped into v_eq;
  end if;
  return v_eq;
end $$;

-- удалить свой профиль, очки и историю боёв
create or replace function public.leave_ladder()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  delete from players where id = auth.uid();
end $$;

revoke all on function public._finish_match(uuid, text, text), public._settle_match(uuid), public._cleanup(), public._view(uuid, uuid) from public, anon, authenticated;
revoke all on function public.join_ladder(text), public.queue_join(text), public.queue_leave(), public.match_state(),
  public.match_photo(uuid, text), public.match_rate(uuid, numeric), public.match_leave(uuid), public.report_opponent(uuid), public.leave_ladder(), public.my_profile(), public.buy_item(text), public.equip_item(text, text) from public, anon;
grant execute on function public.join_ladder(text), public.queue_join(text), public.queue_leave(), public.match_state(),
  public.match_photo(uuid, text), public.match_rate(uuid, numeric), public.match_leave(uuid), public.report_opponent(uuid), public.leave_ladder(), public.my_profile(), public.buy_item(text), public.equip_item(text, text) to authenticated;
