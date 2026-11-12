-- PSL Rater: онлайн-батлы 1 на 1, магазин за Рету, рейты и игры, задания и донат. Выполните целиком: Supabase -> SQL Editor -> New query -> вставить -> Run.
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
-- Рейты и игры (расходуемые попытки): новому игроку 10 рейтов и 10 игр, каждый день можно забрать +5 рейтов и +10 игр.
--   Один рейт тратится на оценку одного фото (в режиме «Сравнение» на каждое из двух фото), одна игра на онлайн-бой
--   (если бой отменён и никто не определил рейт, игра возвращается). Пакеты рейтов и игр продаются за деньги (таблицы packs и pack_prices).
-- Недельные задания (quest_defs): за выполнение дают Рету, прогресс считает сервер, неделя сбрасывается в понедельник по UTC.
-- Оплата: платёж подтверждает только сервер платёжной системы (Vercel-функции в папке api/), которая вызывает credit_order.
--   Ключ service_role нужен только им и хранится в переменных окружения Vercel, на сайт он не попадает.
-- Администраторы (таблица admins): аккаунт с подтверждённым Google-адресом из списка получает безлимит рейтов, игр и Реты (ничего не списывается,
--   покупать и надевать можно всё) и страницу «Админ»: поиск игроков, выдача им Реты, рейтов, игр и украшений. Каждое действие пишется в admin_log.
--   Проверку делает сервер по адресу, который подтвердил Google; чтобы добавить администратора, впишите его почту в insert в блоке admins ниже и нажмите Run.
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
alter table public.players add column if not exists rates integer not null default 10 check (rates >= 0);   -- рейты: попытки оценить фото
alter table public.players add column if not exists games integer not null default 10 check (games >= 0);   -- игры: попытки онлайн-боя
alter table public.players add column if not exists daily_on date;   -- день (UTC) последнего ежедневного бонуса

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
alter table public.shop_items add column if not exists case_only boolean not null default false;   -- выпадает только из кейса
create table if not exists public.quest_defs (
  id text primary key,
  title text not null,
  event text not null check (event in ('win', 'battle', 'rate', 'compare', 'daily', 'shop')),
  goal integer not null check (goal > 0),
  reta integer not null check (reta > 0),
  sort integer not null default 0
);
create table if not exists public.quest_progress (
  player_id uuid not null references public.players (id) on delete cascade,
  week date not null,
  quest_id text not null references public.quest_defs (id) on delete cascade,
  progress integer not null default 0,
  claimed boolean not null default false,
  primary key (player_id, week, quest_id)
);
create table if not exists public.packs (
  id text primary key,
  kind text not null check (kind in ('rates', 'games')),
  amount integer not null check (amount > 0),
  sort integer not null default 0
);
create table if not exists public.pack_prices (
  pack_id text not null references public.packs (id) on delete cascade,
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  amount_minor integer not null check (amount_minor > 0),   -- в копейках, центах и т. п.
  primary key (pack_id, currency)
);
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  player_id uuid references public.players (id) on delete set null,
  pack_id text not null references public.packs (id),
  currency text not null,
  amount_minor integer not null,
  provider text not null check (provider in ('stripe', 'liqpay')),
  provider_ref text,
  status text not null default 'pending' check (status in ('pending', 'paid', 'failed')),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);
create unique index if not exists orders_provider_ref on public.orders (provider, provider_ref) where provider_ref is not null;
create index if not exists orders_player on public.orders (player_id, created_at desc);

-- задания (меняйте цифры и снова нажимайте Run)
insert into public.quest_defs (id, title, event, goal, reta, sort) values
  ('q_win', 'Выиграй мог-батл', 'win', 1, 200, 1),
  ('q_win5', 'Выиграй 5 мог-батлов', 'win', 5, 400, 2),
  ('q_play3', 'Сыграй 3 мог-батла', 'battle', 3, 150, 3),
  ('q_rate', 'Сделай рейт', 'rate', 1, 50, 4),
  ('q_rate5', 'Сделай 5 рейтов', 'rate', 5, 150, 5),
  ('q_cmp', 'Сравни два лица', 'compare', 2, 80, 6),
  ('q_daily', 'Забери ежедневный бонус 5 раз', 'daily', 5, 100, 7),
  ('q_shop', 'Купи что-нибудь в магазине', 'shop', 1, 50, 8)
on conflict (id) do update set title = excluded.title, event = excluded.event, goal = excluded.goal, reta = excluded.reta, sort = excluded.sort;

-- пакеты и цены. Региональные цены подбирайте сами: сумма в минимальных единицах (12000 = 120,00)
insert into public.packs (id, kind, amount, sort) values
  ('rates_20', 'rates', 20, 1), ('rates_60', 'rates', 60, 2), ('rates_150', 'rates', 150, 3), ('rates_400', 'rates', 400, 4),
  ('games_20', 'games', 20, 5), ('games_60', 'games', 60, 6), ('games_150', 'games', 150, 7)
on conflict (id) do update set kind = excluded.kind, amount = excluded.amount, sort = excluded.sort;
insert into public.pack_prices (pack_id, currency, amount_minor) values
  ('rates_20', 'USD', 120), ('rates_60', 'USD', 330), ('rates_150', 'USD', 750), ('rates_400', 'USD', 1800), ('games_20', 'USD', 150), ('games_60', 'USD', 400), ('games_150', 'USD', 900),
  ('rates_20', 'EUR', 110), ('rates_60', 'EUR', 300), ('rates_150', 'EUR', 690), ('rates_400', 'EUR', 1650), ('games_20', 'EUR', 140), ('games_60', 'EUR', 370), ('games_150', 'EUR', 830),
  ('rates_20', 'UAH', 4500), ('rates_60', 'UAH', 11900), ('rates_150', 'UAH', 26900), ('rates_400', 'UAH', 64900), ('games_20', 'UAH', 5500), ('games_60', 'UAH', 14900), ('games_150', 'UAH', 32900),
  ('rates_20', 'RUB', 9900), ('rates_60', 'RUB', 26900), ('rates_150', 'RUB', 59900), ('rates_400', 'RUB', 149000), ('games_20', 'RUB', 12900), ('games_60', 'RUB', 34900), ('games_150', 'RUB', 74900),
  ('rates_20', 'PLN', 499), ('rates_60', 'PLN', 1399), ('rates_150', 'PLN', 2999), ('rates_400', 'PLN', 6999), ('games_20', 'PLN', 599), ('games_60', 'PLN', 1599), ('games_150', 'PLN', 3499),
  ('rates_20', 'KZT', 59000), ('rates_60', 'KZT', 159000), ('rates_150', 'KZT', 349000), ('rates_400', 'KZT', 849000), ('games_20', 'KZT', 69000), ('games_60', 'KZT', 189000), ('games_150', 'KZT', 419000)
on conflict (pack_id, currency) do update set amount_minor = excluded.amount_minor;

create table if not exists public.admins (email text primary key check (email = lower(email)));
insert into public.admins (email) values ('renkonkop@gmail.com') on conflict do nothing;
create table if not exists public.admin_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  admin_id uuid,
  target_id uuid,
  action text not null,
  detail jsonb
);

create table if not exists public.purchases (
  player_id uuid not null references public.players (id) on delete cascade,
  item_id text not null references public.shop_items (id) on delete cascade,
  at timestamptz not null default now(),
  primary key (player_id, item_id)
);

-- кейсы: цена в Рете, что внутри и вес каждого предмета (шанс = вес / сумма весов); refund: сколько Реты вернуть, если такой предмет уже есть
create table if not exists public.cases (
  id text primary key,
  name text not null,
  price integer not null check (price >= 0),
  sort integer not null default 0
);
create table if not exists public.case_items (
  case_id text not null references public.cases (id) on delete cascade,
  item_id text not null references public.shop_items (id) on delete cascade,
  weight integer not null check (weight > 0),
  refund integer not null default 0 check (refund >= 0),
  primary key (case_id, item_id)
);
create table if not exists public.case_opens (
  id bigint generated always as identity primary key,
  player_id uuid not null references public.players (id) on delete cascade,
  case_id text not null,
  item_id text not null,
  dup boolean not null,
  refund integer not null,
  at timestamptz not null default now()
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

-- предметы из кейсов (в магазине не продаются)
insert into public.shop_items (id, kind, name, price, sort, case_only) values
  ('frame_bw', 'frame', 'Чёрно-белая рамка', 0, 10, true),
  ('title_larp', 'title', 'Ларп', 0, 10, true), ('title_net', 'title', 'Нет', 0, 11, true), ('title_foid', 'title', 'Foid Slayer', 0, 12, true),
  ('nick_black', 'nick', 'Чёрное свечение', 0, 10, true),
  ('banner_apples', 'banner', 'Девять яблок', 0, 10, true),
  ('mogg_holyiq', 'mogg', 'Holy IQ', 0, 10, true)
on conflict (id) do update set kind = excluded.kind, name = excluded.name, price = excluded.price, sort = excluded.sort, case_only = excluded.case_only;

-- кейс «Holy IQ»: цену и шансы можно менять здесь и снова нажимать Run (сумма весов 100, значит вес = шанс в процентах)
insert into public.cases (id, name, price, sort) values ('holy_iq', 'Holy IQ', 500, 1)
on conflict (id) do update set name = excluded.name, price = excluded.price, sort = excluded.sort;
insert into public.case_items (case_id, item_id, weight, refund) values
  ('holy_iq', 'frame_bw', 40, 40),
  ('holy_iq', 'title_larp', 22, 100), ('holy_iq', 'title_net', 22, 100),
  ('holy_iq', 'title_foid', 7, 250),
  ('holy_iq', 'nick_black', 5, 300),
  ('holy_iq', 'banner_apples', 3, 600),
  ('holy_iq', 'mogg_holyiq', 1, 1500)
on conflict (case_id, item_id) do update set weight = excluded.weight, refund = excluded.refund;

-- кейс «ТикТок философия»: Сизиф, Штирнер, уроборос и «Превращение» Кафки
insert into public.shop_items (id, kind, name, price, sort, case_only) values
  ('title_sisyphus', 'title', 'Нескончаемый', 0, 20, true), ('title_stirner', 'title', 'Нет', 0, 21, true), ('title_samsa', 'title', 'Бездарный', 0, 22, true),
  ('frame_uroboros', 'frame', 'Уроборос', 0, 20, true),
  ('nick_stirner', 'nick', 'Штирнер', 0, 20, true),
  ('banner_sisyphus', 'banner', 'Вечный подъём', 0, 20, true),
  ('mogg_samsa', 'mogg', 'Превращение', 0, 20, true)
on conflict (id) do update set kind = excluded.kind, name = excluded.name, price = excluded.price, sort = excluded.sort, case_only = excluded.case_only;
insert into public.cases (id, name, price, sort) values ('tt_philosophy', 'ТикТок философия', 500, 2)
on conflict (id) do update set name = excluded.name, price = excluded.price, sort = excluded.sort;
insert into public.case_items (case_id, item_id, weight, refund) values
  ('tt_philosophy', 'title_sisyphus', 30, 50), ('tt_philosophy', 'title_stirner', 28, 50),
  ('tt_philosophy', 'title_samsa', 14, 120), ('tt_philosophy', 'frame_uroboros', 14, 120),
  ('tt_philosophy', 'nick_stirner', 8, 300),
  ('tt_philosophy', 'banner_sisyphus', 5, 700),
  ('tt_philosophy', 'mogg_samsa', 1, 1800)
on conflict (case_id, item_id) do update set weight = excluded.weight, refund = excluded.refund;

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
alter table public.admins enable row level security;
alter table public.admin_log enable row level security;
alter table public.quest_defs enable row level security;
alter table public.quest_progress enable row level security;
alter table public.packs enable row level security;
alter table public.pack_prices enable row level security;
alter table public.orders enable row level security;
alter table public.cases enable row level security;
alter table public.case_items enable row level security;
alter table public.case_opens enable row level security;
drop policy if exists players_read on public.players;
create policy players_read on public.players for select to authenticated using (true);
drop policy if exists battles_read on public.battles;
create policy battles_read on public.battles for select to authenticated using (player_id = auth.uid());
drop policy if exists shop_read on public.shop_items;
create policy shop_read on public.shop_items for select to authenticated using (true);
drop policy if exists purchases_read on public.purchases;
create policy purchases_read on public.purchases for select to authenticated using (player_id = auth.uid());
revoke all on public.admins, public.admin_log from anon, authenticated;
revoke all on public.players, public.battles, public.queue, public.matches, public.reports, public.shop_items, public.purchases, public.quest_defs, public.quest_progress, public.packs, public.pack_prices, public.orders from anon, authenticated;
-- баланс Реты (колонка reta) другим игрокам не показывается: свой профиль приходит через my_profile()
grant select (id, name, picture, points, wins, losses, draws, sex, created_at, equipped) on public.players to authenticated;
grant select on public.battles, public.shop_items, public.purchases, public.packs, public.pack_prices to authenticated;
revoke all on public.cases, public.case_items, public.case_opens from anon, authenticated;
grant select on public.cases, public.case_items, public.case_opens to authenticated;
drop policy if exists cases_read on public.cases;
create policy cases_read on public.cases for select to authenticated using (true);
drop policy if exists case_items_read on public.case_items;
create policy case_items_read on public.case_items for select to authenticated using (true);
drop policy if exists case_opens_read on public.case_opens;
create policy case_opens_read on public.case_opens for select to authenticated using (player_id = auth.uid());
drop policy if exists packs_read on public.packs;
create policy packs_read on public.packs for select to authenticated using (true);
drop policy if exists pack_prices_read on public.pack_prices;
create policy pack_prices_read on public.pack_prices for select to authenticated using (true);
-- свои заказы можно смотреть (без номеров платёжной системы)
grant select (id, pack_id, currency, amount_minor, provider, status, created_at, paid_at) on public.orders to authenticated;
drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select to authenticated using (player_id = auth.uid());

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
    update players set games = games + 1 where id in (m.a, m.b);   -- бой не состоялся: игра возвращается
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
  if pa.id is not null then perform _quest_progress(pa.id, 'battle', 1); if p_result = 'a' then perform _quest_progress(pa.id, 'win', 1); end if; end if;
  if pb.id is not null then perform _quest_progress(pb.id, 'battle', 1); if p_result = 'b' then perform _quest_progress(pb.id, 'win', 1); end if; end if;
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

  select * into v_me from players where id = v_uid;
  if v_me.games < 1 and not _is_admin(v_uid) then raise exception 'no_games'; end if;
  v_rank := least(v_me.points / 500, 7);
  update players set sex = p_sex where id = v_uid;
  insert into queue (player_id, sex, rank) values (v_uid, p_sex, v_rank)
  on conflict (player_id) do update set seen = now(), rank = excluded.rank,
    since = case when queue.sex = excluded.sex then queue.since else now() end, sex = excluded.sex;
  select since into v_since from queue where player_id = v_uid;

  select q.* into v_q from queue q join players pq on pq.id = q.player_id and (pq.games >= 1 or _is_admin(pq.id))
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
  update players set games = games - 1 where id in (v_uid, v_q.player_id) and not _is_admin(id);   -- каждый платит одну игру, кроме администратора
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

-- администратор ли игрок: его Google-аккаунт (identity google с подтверждённой почтой) есть в списке admins
create or replace function public._is_admin(p_uid uuid default auth.uid())
returns boolean language plpgsql stable security definer set search_path = public as $$
begin
  if p_uid is null then return false; end if;
  return exists (select 1 from admins a join auth.identities i on i.provider = 'google' and lower(i.identity_data ->> 'email') = a.email where i.user_id = p_uid);
end $$;

-- прогресс заданий: вызывается самим сервером при событиях (бой, рейт, покупка...)
create or replace function public._quest_progress(p_uid uuid, p_event text, p_n integer)
returns void language plpgsql security definer set search_path = public as $$
declare v_week date := date_trunc('week', now() at time zone 'utc')::date;
begin
  insert into quest_progress (player_id, week, quest_id, progress)
  select p_uid, v_week, d.id, least(d.goal, p_n) from quest_defs d where d.event = p_event
  on conflict (player_id, week, quest_id) do update
    set progress = least((select goal from quest_defs where id = quest_progress.quest_id), quest_progress.progress + excluded.progress)
    where not quest_progress.claimed;
end $$;

-- задания этой недели с прогрессом
create or replace function public.my_quests()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_week date := date_trunc('week', now() at time zone 'utc')::date;
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  return jsonb_build_object(
    'reset_s', extract(epoch from (v_week + 7)::timestamp - (now() at time zone 'utc'))::int,
    'quests', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'goal', d.goal, 'reta', d.reta,
        'progress', coalesce(p.progress, 0), 'claimed', coalesce(p.claimed, false)) order by d.sort)
      from quest_defs d left join quest_progress p on p.quest_id = d.id and p.player_id = auth.uid() and p.week = v_week), '[]'::jsonb));
end $$;

-- забрать награду за выполненное задание
create or replace function public.claim_quest(p_quest text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_week date := date_trunc('week', now() at time zone 'utc')::date; d quest_defs; pr quest_progress;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into d from quest_defs where id = p_quest;
  if not found then raise exception 'no_quest'; end if;
  perform 1 from players where id = v_uid for update;
  if not found then raise exception 'not_joined'; end if;
  select * into pr from quest_progress where player_id = v_uid and week = v_week and quest_id = p_quest for update;
  if not found or pr.progress < d.goal then raise exception 'quest_not_done'; end if;
  if pr.claimed then raise exception 'quest_claimed'; end if;
  update quest_progress set claimed = true where player_id = v_uid and week = v_week and quest_id = p_quest;
  update players set reta = reta + d.reta where id = v_uid;
  return my_profile();
end $$;

-- ежедневный бонус: +5 рейтов и +10 игр раз в сутки (по UTC)
create or replace function public.daily_claim()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_today date := (now() at time zone 'utc')::date; v_me players;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_me from players where id = v_uid for update;
  if not found then raise exception 'not_joined'; end if;
  if v_me.daily_on = v_today then raise exception 'claimed'; end if;
  update players set rates = rates + 5, games = games + 10, daily_on = v_today where id = v_uid;
  perform _quest_progress(v_uid, 'daily', 1);
  return my_profile();
end $$;

-- потратить один рейт ('rate': оценка одного фото, 'cmp': одно фото в режиме «Сравнение»)
create or replace function public.spend_credit(p_kind text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_me players;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if p_kind is null or p_kind not in ('rate', 'cmp') then raise exception 'bad_kind'; end if;
  select * into v_me from players where id = v_uid for update;
  if not found then raise exception 'not_joined'; end if;
  if not _is_admin(v_uid) then   -- у администратора рейты безлимитные
    if v_me.rates < 1 then raise exception 'no_rates'; end if;
    update players set rates = rates - 1 where id = v_uid;
  end if;
  perform _quest_progress(v_uid, case p_kind when 'rate' then 'rate' else 'compare' end, 1);
  return my_profile();
end $$;

-- ---------- платежи (вызываются только сервером оплаты с ключом service_role) ----------
create or replace function public.create_order(p_player uuid, p_pack text, p_currency text, p_provider text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_pack packs; v_price pack_prices; v_id uuid;
begin
  if not exists (select 1 from players where id = p_player) then raise exception 'not_joined'; end if;
  select * into v_pack from packs where id = p_pack;
  if not found then raise exception 'no_pack'; end if;
  select * into v_price from pack_prices where pack_id = p_pack and currency = p_currency;
  if not found then raise exception 'no_price'; end if;
  insert into orders (player_id, pack_id, currency, amount_minor, provider) values (p_player, p_pack, p_currency, v_price.amount_minor, p_provider) returning id into v_id;
  return jsonb_build_object('id', v_id, 'amount_minor', v_price.amount_minor, 'currency', p_currency, 'kind', v_pack.kind, 'amount', v_pack.amount, 'pack', p_pack);
end $$;

-- платёж подтверждён: выдать пакет (один раз, сумма и валюта должны совпасть с заказом)
create or replace function public.credit_order(p_order uuid, p_provider text, p_ref text, p_amount_minor integer, p_currency text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o orders; v_pack packs;
begin
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'no_order'; end if;
  if o.status = 'paid' then return jsonb_build_object('status', 'already'); end if;
  if o.provider <> p_provider or o.amount_minor <> p_amount_minor or o.currency <> p_currency then
    update orders set status = 'failed' where id = p_order;
    return jsonb_build_object('status', 'mismatch');
  end if;
  select * into v_pack from packs where id = o.pack_id;
  update orders set status = 'paid', provider_ref = p_ref, paid_at = now() where id = p_order;
  if o.player_id is not null then
    if v_pack.kind = 'rates' then update players set rates = rates + v_pack.amount where id = o.player_id;
    else update players set games = games + v_pack.amount where id = o.player_id; end if;
  end if;
  return jsonb_build_object('status', 'paid', 'kind', v_pack.kind, 'amount', v_pack.amount);
end $$;

-- свой профиль целиком (с балансом Реты)
create or replace function public.my_profile()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  return (select to_jsonb(p) || jsonb_build_object('is_admin', _is_admin(p.id), 'daily_ready', p.daily_on is distinct from (now() at time zone 'utc')::date,
    'next_daily_s', extract(epoch from (date_trunc('day', now() at time zone 'utc') + interval '1 day') - (now() at time zone 'utc'))::int)
    from players p where p.id = auth.uid());
end $$;

-- купить предмет за Рету
create or replace function public.buy_item(p_item text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_item shop_items; v_me players;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_item from shop_items where id = p_item;
  if not found then raise exception 'no_item'; end if;
  if v_item.case_only then raise exception 'case_only'; end if;
  select * into v_me from players where id = v_uid for update;
  if not found then raise exception 'not_joined'; end if;
  if exists (select 1 from purchases where player_id = v_uid and item_id = p_item) then raise exception 'owned'; end if;
  if not _is_admin(v_uid) then
    if v_me.reta < v_item.price then raise exception 'poor'; end if;
    update players set reta = reta - v_item.price where id = v_uid;
    v_me.reta := v_me.reta - v_item.price;
  end if;
  insert into purchases (player_id, item_id) values (v_uid, p_item);
  perform _quest_progress(v_uid, 'shop', 1);
  return jsonb_build_object('reta', v_me.reta, 'item', p_item);
end $$;

-- открыть кейс: списывает цену, по весам выбирает предмет на сервере; если предмет уже есть, возвращает часть Реты (refund)
create or replace function public.open_case(p_case text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_case cases; v_me players; v_admin boolean; v_total integer; v_roll numeric; v_pick case_items; r case_items; v_dup boolean; v_refund integer := 0;
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  select * into v_case from cases where id = p_case;
  if not found then raise exception 'no_case'; end if;
  select * into v_me from players where id = v_uid for update;
  if not found then raise exception 'not_joined'; end if;
  v_admin := _is_admin(v_uid);
  if not v_admin and v_me.reta < v_case.price then raise exception 'poor'; end if;
  select coalesce(sum(weight), 0) into v_total from case_items where case_id = p_case;
  if v_total = 0 then raise exception 'no_case'; end if;
  v_roll := random() * v_total;
  for r in select * from case_items where case_id = p_case order by weight desc, item_id loop
    v_roll := v_roll - r.weight;
    if v_roll < 0 then v_pick := r; exit; end if;
  end loop;
  if v_pick.item_id is null then select * into v_pick from case_items where case_id = p_case order by weight desc, item_id limit 1; end if;
  v_dup := exists (select 1 from purchases where player_id = v_uid and item_id = v_pick.item_id);
  if not v_admin then v_me.reta := v_me.reta - v_case.price; end if;
  if v_dup then
    if not v_admin then v_refund := v_pick.refund; v_me.reta := v_me.reta + v_refund; end if;
  else
    insert into purchases (player_id, item_id) values (v_uid, v_pick.item_id);
  end if;
  update players set reta = v_me.reta where id = v_uid;
  insert into case_opens (player_id, case_id, item_id, dup, refund) values (v_uid, p_case, v_pick.item_id, v_dup, v_refund);
  perform _quest_progress(v_uid, 'shop', 1);
  return jsonb_build_object('case', p_case, 'item', v_pick.item_id, 'dup', v_dup, 'refund', v_refund, 'reta', v_me.reta);
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
    if not exists (select 1 from shop_items where id = p_item and kind = p_slot) then raise exception 'not_owned'; end if;
    if not _is_admin(v_uid) and not exists (select 1 from purchases where player_id = v_uid and item_id = p_item) then raise exception 'not_owned'; end if;
    update players set equipped = jsonb_set(equipped, array[p_slot], to_jsonb(p_item)) where id = v_uid returning equipped into v_eq;
  end if;
  return v_eq;
end $$;

-- ---------- админ-панель ----------
create or replace function public.admin_search(p_q text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_q text := btrim(coalesce(p_q, ''));
begin
  if not _is_admin() then raise exception 'not_admin'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r)) from (
    select p.id, p.name, u.email, p.points, p.reta, p.rates, p.games, p.created_at
    from players p join auth.users u on u.id = p.id
    where v_q = '' or p.name ilike '%' || replace(replace(v_q, '%', '\%'), '_', '\_') || '%' or u.email ilike '%' || replace(replace(v_q, '%', '\%'), '_', '\_') || '%' or p.id::text = v_q
    order by p.created_at desc limit 20) r), '[]'::jsonb);
end $$;

create or replace function public.admin_player(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if not _is_admin() then raise exception 'not_admin'; end if;
  select to_jsonb(p) || jsonb_build_object('email', u.email,
      'items', coalesce((select jsonb_agg(b.item_id order by b.at) from purchases b where b.player_id = p.id), '[]'::jsonb),
      'orders', coalesce((select jsonb_agg(jsonb_build_object('pack_id', o.pack_id, 'currency', o.currency, 'amount_minor', o.amount_minor, 'status', o.status, 'created_at', o.created_at) order by o.created_at desc)
                          from (select * from orders where player_id = p.id order by created_at desc limit 5) o), '[]'::jsonb))
    into v from players p join auth.users u on u.id = p.id where p.id = p_id;
  if v is null then raise exception 'no_player'; end if;
  return v;
end $$;

-- выдать (или забрать, если число отрицательное) Рету, рейты и игры; ниже нуля не уходит
create or replace function public.admin_grant(p_player uuid, p_reta integer default 0, p_rates integer default 0, p_games integer default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin() then raise exception 'not_admin'; end if;
  if abs(coalesce(p_reta, 0)) > 1000000 or abs(coalesce(p_rates, 0)) > 1000000 or abs(coalesce(p_games, 0)) > 1000000 then raise exception 'bad_amount'; end if;
  perform 1 from players where id = p_player for update;
  if not found then raise exception 'no_player'; end if;
  update players set reta = greatest(0, reta + coalesce(p_reta, 0)), rates = greatest(0, rates + coalesce(p_rates, 0)), games = greatest(0, games + coalesce(p_games, 0)) where id = p_player;
  insert into admin_log (admin_id, target_id, action, detail) values (auth.uid(), p_player, 'grant', jsonb_build_object('reta', p_reta, 'rates', p_rates, 'games', p_games));
  return admin_player(p_player);
end $$;

-- выдать украшение или анимацию (p_give = true) либо забрать (false)
create or replace function public.admin_item(p_player uuid, p_item text, p_give boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_item shop_items;
begin
  if not _is_admin() then raise exception 'not_admin'; end if;
  select * into v_item from shop_items where id = p_item;
  if not found then raise exception 'no_item'; end if;
  perform 1 from players where id = p_player for update;
  if not found then raise exception 'no_player'; end if;
  if p_give then
    insert into purchases (player_id, item_id) values (p_player, p_item) on conflict do nothing;
  else
    delete from purchases where player_id = p_player and item_id = p_item;
    update players set equipped = equipped - v_item.kind where id = p_player and equipped ->> v_item.kind = p_item;
  end if;
  insert into admin_log (admin_id, target_id, action, detail) values (auth.uid(), p_player, case when p_give then 'give_item' else 'take_item' end, jsonb_build_object('item', p_item));
  return admin_player(p_player);
end $$;

create or replace function public.admin_recent()
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin() then raise exception 'not_admin'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r)) from (
    select l.at, l.action, l.detail, coalesce(p.name, '(удалён)') as target from admin_log l left join players p on p.id = l.target_id order by l.at desc limit 10) r), '[]'::jsonb);
end $$;

-- удалить свой профиль, очки и историю боёв
create or replace function public.leave_ladder()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  delete from players where id = auth.uid();
end $$;

revoke all on function public._finish_match(uuid, text, text), public._settle_match(uuid), public._cleanup(), public._view(uuid, uuid), public._quest_progress(uuid, text, integer), public._is_admin(uuid) from public, anon, authenticated;
revoke all on function public.create_order(uuid, text, text, text), public.credit_order(uuid, text, text, integer, text) from public, anon, authenticated;
grant execute on function public.create_order(uuid, text, text, text), public.credit_order(uuid, text, text, integer, text) to service_role;
revoke all on function public.join_ladder(text), public.queue_join(text), public.queue_leave(), public.match_state(),
  public.match_photo(uuid, text), public.match_rate(uuid, numeric), public.match_leave(uuid), public.report_opponent(uuid), public.leave_ladder(), public.my_profile(), public.buy_item(text), public.open_case(text), public.equip_item(text, text), public.my_quests(), public.claim_quest(text), public.daily_claim(), public.spend_credit(text),
  public.admin_search(text), public.admin_player(uuid), public.admin_grant(uuid, integer, integer, integer), public.admin_item(uuid, text, boolean), public.admin_recent() from public, anon;
grant execute on function public.join_ladder(text), public.queue_join(text), public.queue_leave(), public.match_state(),
  public.match_photo(uuid, text), public.match_rate(uuid, numeric), public.match_leave(uuid), public.report_opponent(uuid), public.leave_ladder(), public.my_profile(), public.buy_item(text), public.open_case(text), public.equip_item(text, text), public.my_quests(), public.claim_quest(text), public.daily_claim(), public.spend_credit(text),
  public.admin_search(text), public.admin_player(uuid), public.admin_grant(uuid, integer, integer, integer), public.admin_item(uuid, text, boolean), public.admin_recent() to authenticated;
