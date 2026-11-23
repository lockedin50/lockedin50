-- =====================================================================
-- Locked In 50 · database setup (version 2: accounts, multiple crews,
-- daily trackers, crew-vs-crew board)
--
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Works on a fresh project, upgrades a version 1 database in place
-- (keeping everyone's progress and logins), and is safe to run again.
--
-- How access works: every table is locked (row level security on, no
-- policies), so the public app key cannot read or change them directly.
-- The app can only call the functions below. Each checks a sign-in
-- token, and crew data is only returned to members of that crew.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- core tables ----------
create table if not exists crews (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);
alter table crews add column if not exists captain_id uuid;

create table if not exists accounts (
  id uuid primary key default gen_random_uuid(),
  username text not null,
  pin_hash text not null,
  token uuid not null default gen_random_uuid(),
  color text,
  photo text,
  start_date date not null,
  items jsonb not null,
  failed_pins int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists crew_members (
  crew_id uuid not null references crews(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (crew_id, account_id)
);

-- ---------- upgrade from version 1 (one crew per person) ----------
do $$
declare t text;
begin
  if to_regclass('public.members') is not null then
    -- usernames can't have spaces and must be unique across the app
    insert into accounts (id, username, pin_hash, token, color, photo, start_date, items, failed_pins, locked_until, created_at)
    select m.id,
           case when row_number() over (partition by lower(regexp_replace(m.name, '[^A-Za-z0-9_.]', '_', 'g')) order by m.created_at) = 1
                then left(regexp_replace(m.name, '[^A-Za-z0-9_.]', '_', 'g'), 20)
                else left(regexp_replace(m.name, '[^A-Za-z0-9_.]', '_', 'g'), 17) || (row_number() over (partition by lower(regexp_replace(m.name, '[^A-Za-z0-9_.]', '_', 'g')) order by m.created_at))::text end,
           m.pin_hash, m.token, m.color, m.photo, m.start_date, m.items, m.failed_pins, m.locked_until, m.created_at
    from members m
    on conflict (id) do nothing;
    insert into crew_members (crew_id, account_id, joined_at)
    select crew_id, id, created_at from members on conflict do nothing;
    update crews c set captain_id = (select id from members m where m.crew_id = c.id order by created_at limit 1)
    where captain_id is null;

    drop table members cascade;  -- also drops the old links from the tables below

    foreach t in array array['goals', 'days', 'posts', 'likes', 'comments'] loop
      if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = t and column_name = 'member_id') then
        execute format('alter table %I rename column member_id to account_id', t);
        execute format('alter table %I add foreign key (account_id) references accounts(id) on delete cascade', t);
      end if;
    end loop;
    drop index if exists posts_auto;
  end if;
end $$;

create unique index if not exists accounts_username on accounts (lower(username));
create unique index if not exists accounts_token on accounts (token);

-- ---------- activity tables ----------
create table if not exists goals (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  label text not null,
  unit text not null default '',
  start_val numeric not null,
  target_val numeric not null,
  shared boolean not null default false,
  sort int not null default 0
);
alter table goals add column if not exists kind text not null default 'number';  -- 'number' or 'time' (stored in seconds)

create table if not exists goal_logs (
  goal_id uuid not null references goals(id) on delete cascade,
  log_date date not null,
  value numeric not null,
  primary key (goal_id, log_date)
);

create table if not exists days (
  account_id uuid not null references accounts(id) on delete cascade,
  day date not null,
  done jsonb not null default '[]'::jsonb,
  primary key (account_id, day)
);

-- Private daily numbers (calories, water…). Never shown to anyone else.
create table if not exists trackers (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  label text not null,
  unit text not null default '',
  daily_target numeric,
  sort int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists tracker_logs (
  tracker_id uuid not null references trackers(id) on delete cascade,
  log_date date not null,
  value numeric not null,
  primary key (tracker_id, log_date)
);

create table if not exists posts (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references crews(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete cascade,
  body text not null,
  kind text not null default 'post',
  ref_key text,
  created_at timestamptz not null default now()
);
create unique index if not exists posts_auto2 on posts (crew_id, account_id, kind, ref_key) where ref_key is not null;
create index if not exists posts_crew_time on posts (crew_id, created_at desc);

create table if not exists likes (
  post_id uuid not null references posts(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete cascade,
  primary key (post_id, account_id)
);

create table if not exists comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id) on delete cascade,
  account_id uuid not null references accounts(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);

-- Lock every table: no direct access with the public key.
alter table crews        enable row level security;
alter table accounts     enable row level security;
alter table crew_members enable row level security;
alter table goals        enable row level security;
alter table goal_logs    enable row level security;
alter table days         enable row level security;
alter table trackers     enable row level security;
alter table tracker_logs enable row level security;
alter table posts        enable row level security;
alter table likes        enable row level security;
alter table comments     enable row level security;
revoke all on crews, accounts, crew_members, goals, goal_logs, days, trackers, tracker_logs, posts, likes, comments from anon, authenticated;

-- ---------- remove version 1 functions ----------
drop function if exists crew_members(text);
drop function if exists join_crew(text, text, text, text, text, date, jsonb, jsonb);
drop function if exists sign_in(text, uuid, text);
drop function if exists get_crew(uuid);
drop function if exists set_day(uuid, date, jsonb, boolean, integer);
drop function if exists log_goal(uuid, uuid, date, numeric);
drop function if exists add_post(uuid, text);
drop function if exists toggle_like(uuid, uuid);
drop function if exists add_comment(uuid, uuid, text);
drop function if exists set_photo(uuid, text);
drop function if exists li_member(uuid);

-- ---------- helpers (not callable from the app) ----------
create or replace function li_account(p_token uuid) returns accounts
language plpgsql stable security definer set search_path = public as $$
declare a accounts;
begin
  select * into a from accounts where token = p_token;
  if a.id is null then raise exception 'bad_token'; end if;
  return a;
end $$;

create or replace function li_today() returns date
language sql stable as $$ select (now() at time zone 'Australia/Sydney')::date $$;

-- Names people choose must be clean: crew names show on the public board.
create or replace function li_clean(p text) returns boolean
language sql immutable as $$
  select lower(regexp_replace(p, '[^A-Za-z]', '', 'g')) !~ '(fuck|shit|cunt|bitch|dick|cock|pussy|nigg|fag|slut|whore|rape|nazi|retard|porn|wank|twat|bastard|penis|vagina|boob|tits|hitler|kkk|cum)'
$$;

create or replace function li_goal_pct(p_goal uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when g.target_val = g.start_val then 100
    else round((coalesce((select value from goal_logs where goal_id = g.id order by log_date desc limit 1), g.start_val) - g.start_val)
               / (g.target_val - g.start_val) * 100)::int end
  from goals g where g.id = p_goal
$$;

-- One person's score (0–100) for one day: weighted share of their list ticked.
create or replace function li_score(p_account uuid, p_day date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(round(100.0 *
    coalesce(sum(case when d.done ? (it->>'id') then (it->>'weight')::numeric else 0 end), 0)
    / nullif(sum((it->>'weight')::numeric), 0)), 0)
  from accounts a
  cross join lateral jsonb_array_elements(a.items) it
  left join days d on d.account_id = a.id and d.day = p_day
  where a.id = p_account
$$;

-- Average daily score over the days that count (past days, plus today once something is ticked).
-- p_last_days limits it to the most recent days (7 for the weekly board); null = whole challenge.
create or replace function li_avg(p_account uuid, p_last_days int) returns numeric
language sql stable security definer set search_path = public as $$
  with a as (select id, start_date from accounts where id = p_account),
  ds as (
    select gs::date as day from a, generate_series(a.start_date, least(a.start_date + 49, li_today()), interval '1 day') gs
  ),
  counted as (
    select ds.day from ds
    where ds.day < li_today()
       or exists (select 1 from days d where d.account_id = p_account and d.day = ds.day and jsonb_array_length(d.done) > 0)
  ),
  recent as (
    select day from counted
    where p_last_days is null or day > li_today() - p_last_days
  )
  select round(avg(li_score(p_account, day)), 1) from recent
$$;

revoke execute on function li_account(uuid), li_goal_pct(uuid), li_score(uuid, date), li_avg(uuid, int) from public, anon, authenticated;

-- ---------- accounts ----------
create or replace function check_username(p_username text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('available', not exists (select 1 from accounts where lower(username) = lower(trim(p_username))))
$$;

-- Who a crew is, from its code (for invite links), without needing to sign in.
create or replace function crew_preview(p_code text) returns json
language plpgsql stable security definer set search_path = public as $$
declare c crews;
begin
  select * into c from crews where code = upper(trim(p_code));
  if c.id is null then raise exception 'bad_code'; end if;
  return json_build_object('name', c.name, 'code', c.code, 'members', (select count(*) from crew_members where crew_id = c.id));
end $$;

create or replace function li_make_code() returns text
language plpgsql volatile as $$
declare chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := 'LI50-';
    for i in 1..5 loop c := c || substr(chars, 1 + floor(random() * length(chars))::int, 1); end loop;
    exit when not exists (select 1 from crews where code = c);
  end loop;
  return c;
end $$;

create or replace function li_join(p_account uuid, p_crew uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from crew_members where crew_id = p_crew and account_id = p_account) then return; end if;
  if (select count(*) from crew_members where account_id = p_account) >= 10 then raise exception 'too_many_crews'; end if;
  if (select count(*) from crew_members where crew_id = p_crew) >= 50 then raise exception 'crew_full'; end if;
  insert into crew_members (crew_id, account_id) values (p_crew, p_account);
  insert into posts (crew_id, account_id, body, kind) values (p_crew, p_account, 'Joined the crew 👋', 'join');
end $$;

create or replace function li_new_crew(p_account uuid, p_name text) returns crews
language plpgsql security definer set search_path = public as $$
declare c crews;
begin
  p_name := trim(p_name);
  if length(p_name) < 2 or length(p_name) > 30 then raise exception 'bad_crew_name'; end if;
  if not li_clean(p_name) then raise exception 'name_not_allowed'; end if;
  if (select count(*) from crews where captain_id = p_account) >= 10 then raise exception 'too_many_crews'; end if;
  insert into crews (code, name, captain_id) values (li_make_code(), p_name, p_account) returning * into c;
  insert into crew_members (crew_id, account_id) values (c.id, p_account);
  insert into posts (crew_id, account_id, body, kind) values (c.id, p_account, 'Started the crew 🔒 Let''s go.', 'join');
  return c;
end $$;

revoke execute on function li_join(uuid, uuid), li_new_crew(uuid, text) from public, anon, authenticated;

-- Create an account and lock in a 50-day list, goals and trackers.
-- Optionally join a crew (p_join_code) or start one (p_new_crew).
create or replace function create_account(p_username text, p_pin text, p_color text, p_photo text, p_start date,
    p_items jsonb, p_goals jsonb, p_trackers jsonb, p_join_code text, p_new_crew text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a accounts; g jsonb; t jsonb; i int := 0; gid uuid; c crews; v_code text;
begin
  p_username := trim(p_username);
  if p_username !~ '^[A-Za-z0-9_.]{3,20}$' then raise exception 'bad_username'; end if;
  if not li_clean(p_username) then raise exception 'name_not_allowed'; end if;
  if exists (select 1 from accounts where lower(username) = lower(p_username)) then raise exception 'username_taken'; end if;
  if p_pin !~ '^\d{6}$' then raise exception 'bad_pin_format'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 5 or jsonb_array_length(p_items) > 12 then raise exception 'bad_items'; end if;
  if jsonb_typeof(p_goals) <> 'array' or jsonb_array_length(p_goals) > 3 then raise exception 'bad_goals'; end if;
  if jsonb_typeof(p_trackers) <> 'array' or jsonb_array_length(p_trackers) > 4 then raise exception 'bad_trackers'; end if;
  if p_photo is not null and length(p_photo) > 200000 then raise exception 'photo_too_big'; end if;
  if p_start < li_today() - 1 or p_start > li_today() + 2 then raise exception 'bad_start'; end if;
  if nullif(trim(p_join_code), '') is not null then
    select * into c from crews where code = upper(trim(p_join_code));
    if c.id is null then raise exception 'bad_code'; end if;
  end if;

  insert into accounts (username, pin_hash, color, photo, start_date, items)
  values (p_username, crypt(p_pin, gen_salt('bf')), p_color, p_photo, p_start, p_items)
  returning * into a;

  for g in select * from jsonb_array_elements(p_goals) loop
    insert into goals (account_id, label, unit, kind, start_val, target_val, shared, sort)
    values (a.id, left(g->>'label', 40), left(coalesce(g->>'unit', ''), 12),
            case when g->>'kind' = 'time' then 'time' else 'number' end,
            (g->>'start')::numeric, (g->>'target')::numeric, coalesce((g->>'shared')::boolean, false), i)
    returning id into gid;
    i := i + 1;
  end loop;

  i := 0;
  for t in select * from jsonb_array_elements(p_trackers) loop
    insert into trackers (account_id, label, unit, daily_target, sort)
    values (a.id, left(t->>'label', 30), left(coalesce(t->>'unit', ''), 12), nullif(t->>'target', '')::numeric, i);
    i := i + 1;
  end loop;

  if c.id is not null then
    perform li_join(a.id, c.id); v_code := c.code;
  elsif nullif(trim(p_new_crew), '') is not null then
    c := li_new_crew(a.id, p_new_crew); v_code := c.code;
  end if;

  return json_build_object('token', a.token, 'id', a.id, 'crew_id', c.id, 'crew_code', v_code);
end $$;

-- Sign in with username + PIN. 5 wrong tries locks that account for 15 minutes.
create or replace function sign_in(p_username text, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare a accounts;
begin
  select * into a from accounts where lower(username) = lower(trim(p_username));
  if a.id is null then return json_build_object('error', 'no_account'); end if;
  if a.locked_until is not null and a.locked_until > now() then return json_build_object('error', 'locked'); end if;
  if crypt(p_pin, a.pin_hash) = a.pin_hash then
    update accounts set failed_pins = 0, locked_until = null where id = a.id;
    return json_build_object('token', a.token, 'id', a.id);
  end if;
  update accounts set failed_pins = case when failed_pins >= 4 then 0 else failed_pins + 1 end,
                      locked_until = case when failed_pins >= 4 then now() + interval '15 minutes' else null end
  where id = a.id;
  return json_build_object('error', 'bad_pin');
end $$;

-- Everything about the signed-in person: their list, days, goals with full history, trackers, crews.
create or replace function get_me(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  return json_build_object(
    'id', a.id, 'username', a.username, 'color', a.color, 'photo', a.photo, 'startDate', a.start_date, 'items', a.items,
    'days', coalesce((select json_object_agg(d.day::text, d.done) from days d where d.account_id = a.id), '{}'::json),
    'goals', coalesce((select json_agg(json_build_object('id', g.id, 'label', g.label, 'unit', g.unit, 'kind', g.kind, 'shared', g.shared,
        'start', g.start_val, 'target', g.target_val,
        'logs', coalesce((select json_agg(json_build_object('date', l.log_date, 'value', l.value) order by l.log_date) from goal_logs l where l.goal_id = g.id), '[]'::json))
        order by g.sort) from goals g where g.account_id = a.id), '[]'::json),
    'trackers', coalesce((select json_agg(json_build_object('id', t.id, 'label', t.label, 'unit', t.unit, 'target', t.daily_target,
        'logs', coalesce((select json_object_agg(l.log_date::text, l.value) from tracker_logs l where l.tracker_id = t.id), '{}'::json))
        order by t.sort, t.created_at) from trackers t where t.account_id = a.id), '[]'::json),
    'crews', coalesce((select json_agg(json_build_object('id', c.id, 'name', c.name, 'code', c.code, 'captain', c.captain_id = a.id,
        'members', (select count(*) from crew_members x where x.crew_id = c.id)) order by cm.joined_at)
        from crew_members cm join crews c on c.id = cm.crew_id where cm.account_id = a.id), '[]'::json)
  );
end $$;

-- One crew: its members (shared goals as % only) and feed. Members only.
create or replace function get_crew(p_token uuid, p_crew uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare a accounts; c crews;
begin
  a := li_account(p_token);
  select * into c from crews where id = p_crew;
  if c.id is null or not exists (select 1 from crew_members where crew_id = c.id and account_id = a.id) then raise exception 'not_in_crew'; end if;
  return json_build_object(
    'id', c.id, 'name', c.name, 'code', c.code, 'captainId', c.captain_id,
    'members', coalesce((select json_agg(json_build_object(
        'id', x.id, 'name', x.username, 'color', x.color, 'photo', x.photo, 'startDate', x.start_date, 'items', x.items,
        'days', coalesce((select json_object_agg(d.day::text, d.done) from days d where d.account_id = x.id), '{}'::json),
        'goals', coalesce((select json_agg(json_build_object('id', g.id, 'label', g.label, 'shared', true, 'pct', li_goal_pct(g.id)) order by g.sort)
          from goals g where g.account_id = x.id and g.shared), '[]'::json)
      ) order by cm.joined_at) from crew_members cm join accounts x on x.id = cm.account_id where cm.crew_id = c.id), '[]'::json),
    'feed', coalesce((select json_agg(f order by f.ts desc) from (
        select p.id, p.account_id as "userId", p.body as text, (extract(epoch from p.created_at) * 1000)::bigint as ts,
          coalesce((select json_agg(l.account_id) from likes l where l.post_id = p.id), '[]'::json) as likes,
          coalesce((select json_agg(json_build_object('userId', cm2.account_id, 'text', cm2.body, 'ts', (extract(epoch from cm2.created_at) * 1000)::bigint) order by cm2.created_at)
                    from comments cm2 where cm2.post_id = p.id), '[]'::json) as comments
        from posts p where p.crew_id = c.id order by p.created_at desc limit 60) f), '[]'::json)
  );
end $$;

-- The public crew-vs-crew board: crew name, active members and score only.
-- A crew needs 3+ people who are in their 50 days (or finished within the last week) to be ranked.
create or replace function get_board(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  return coalesce((select json_agg(b order by b.ranked desc, b.week desc nulls last, b.name) from (
    select c.id, c.name,
      count(x.id) as active,
      round(avg(li_avg(x.id, 7)), 1) as week,
      round(avg(li_avg(x.id, null)), 1) as overall,
      exists (select 1 from crew_members m where m.crew_id = c.id and m.account_id = a.id) as mine,
      count(x.id) >= 3 as ranked
    from crews c
    join crew_members cm on cm.crew_id = c.id
    join accounts x on x.id = cm.account_id
      and x.start_date <= li_today() and x.start_date + 49 >= li_today() - 6
    group by c.id
    having count(x.id) >= 3 or exists (select 1 from crew_members m where m.crew_id = c.id and m.account_id = a.id)
  ) b), '[]'::json);
end $$;

-- ---------- crews ----------
create or replace function create_crew(p_token uuid, p_name text) returns json
language plpgsql security definer set search_path = public as $$
declare a accounts; c crews;
begin
  a := li_account(p_token);
  c := li_new_crew(a.id, p_name);
  return json_build_object('id', c.id, 'code', c.code, 'name', c.name);
end $$;

create or replace function join_crew(p_token uuid, p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare a accounts; c crews;
begin
  a := li_account(p_token);
  select * into c from crews where code = upper(trim(p_code));
  if c.id is null then raise exception 'bad_code'; end if;
  perform li_join(a.id, c.id);
  return json_build_object('id', c.id, 'name', c.name);
end $$;

create or replace function leave_crew(p_token uuid, p_crew uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts; c crews; nxt uuid;
begin
  a := li_account(p_token);
  delete from crew_members where crew_id = p_crew and account_id = a.id;
  select * into c from crews where id = p_crew;
  if c.captain_id = a.id then
    select account_id into nxt from crew_members where crew_id = p_crew order by joined_at limit 1;
    if nxt is null then delete from crews where id = p_crew;          -- last one out: crew closes
    else update crews set captain_id = nxt where id = p_crew; end if; -- captaincy passes on
  end if;
end $$;

create or replace function li_captain(p_token uuid, p_crew uuid) returns crews
language plpgsql stable security definer set search_path = public as $$
declare a accounts; c crews;
begin
  a := li_account(p_token);
  select * into c from crews where id = p_crew;
  if c.id is null or c.captain_id is distinct from a.id then raise exception 'not_captain'; end if;
  return c;
end $$;
revoke execute on function li_captain(uuid, uuid) from public, anon, authenticated;

create or replace function rename_crew(p_token uuid, p_crew uuid, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform li_captain(p_token, p_crew);
  p_name := trim(p_name);
  if length(p_name) < 2 or length(p_name) > 30 then raise exception 'bad_crew_name'; end if;
  if not li_clean(p_name) then raise exception 'name_not_allowed'; end if;
  update crews set name = p_name where id = p_crew;
end $$;

create or replace function new_crew_code(p_token uuid, p_crew uuid) returns json
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  perform li_captain(p_token, p_crew);
  v := li_make_code();
  update crews set code = v where id = p_crew;
  return json_build_object('code', v);
end $$;

create or replace function remove_member(p_token uuid, p_crew uuid, p_account uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c crews;
begin
  c := li_captain(p_token, p_crew);
  if p_account = c.captain_id then raise exception 'cannot_remove_captain'; end if;
  delete from crew_members where crew_id = p_crew and account_id = p_account;
end $$;

-- ---------- daily activity ----------
-- Save ticks (today or yesterday only, within your 50 days). A perfect day posts to all your crews.
create or replace function set_day(p_token uuid, p_day date, p_done jsonb, p_perfect boolean, p_day_num int) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  if p_day < a.start_date or p_day > a.start_date + 49 then raise exception 'outside_challenge'; end if;
  if p_day < li_today() - 1 or p_day > li_today() + 1 then raise exception 'day_closed'; end if;
  if jsonb_typeof(p_done) <> 'array' then raise exception 'bad_done'; end if;
  insert into days (account_id, day, done) values (a.id, p_day, p_done)
  on conflict (account_id, day) do update set done = excluded.done;
  if p_perfect then
    insert into posts (crew_id, account_id, body, kind, ref_key)
    select cm.crew_id, a.id, 'Day ' || p_day_num || ' done. 100% 💯', 'perfect', p_day::text
    from crew_members cm where cm.account_id = a.id
    on conflict do nothing;
  end if;
end $$;

-- Log a goal number (time goals in seconds). Returns whether it's a personal best.
create or replace function log_goal(p_token uuid, p_goal uuid, p_day date, p_value numeric) returns json
language plpgsql security definer set search_path = public as $$
declare a accounts; g goals; best numeric; pb boolean := false;
begin
  a := li_account(p_token);
  select * into g from goals where id = p_goal and account_id = a.id;
  if g.id is null then raise exception 'not_your_goal'; end if;
  if p_day > li_today() + 1 or p_day < a.start_date - 1 then raise exception 'bad_day'; end if;
  -- a PB beats the starting number and every other day's entry
  if g.target_val < g.start_val then
    select min(value) into best from goal_logs where goal_id = g.id and log_date <> p_day;
    pb := p_value < least(coalesce(best, g.start_val), g.start_val);
  else
    select max(value) into best from goal_logs where goal_id = g.id and log_date <> p_day;
    pb := p_value > greatest(coalesce(best, g.start_val), g.start_val);
  end if;
  insert into goal_logs (goal_id, log_date, value) values (g.id, p_day, p_value)
  on conflict (goal_id, log_date) do update set value = excluded.value;
  if g.shared and pb then
    insert into posts (crew_id, account_id, body, kind, ref_key)
    select cm.crew_id, a.id,
      case when li_goal_pct(g.id) >= 100 then 'Hit my goal: ' || g.label || ' 🎯' else 'New PB: ' || g.label || ' 🎉' end,
      case when li_goal_pct(g.id) >= 100 then 'goal' else 'pb' end,
      case when li_goal_pct(g.id) >= 100 then g.id::text else g.id::text || ':' || p_day::text end
    from crew_members cm where cm.account_id = a.id
    on conflict do nothing;
  end if;
  return json_build_object('pb', pb, 'pct', li_goal_pct(g.id));
end $$;

create or replace function delete_goal_log(p_token uuid, p_goal uuid, p_day date) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  delete from goal_logs l using goals g where l.goal_id = g.id and g.id = p_goal and g.account_id = a.id and l.log_date = p_day;
end $$;

create or replace function add_tracker(p_token uuid, p_label text, p_unit text, p_target numeric) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  if (select count(*) from trackers where account_id = a.id) >= 4 then raise exception 'too_many_trackers'; end if;
  if length(trim(p_label)) < 1 then raise exception 'bad_label'; end if;
  insert into trackers (account_id, label, unit, daily_target, sort)
  values (a.id, left(trim(p_label), 30), left(coalesce(trim(p_unit), ''), 12), p_target,
          coalesce((select max(sort) + 1 from trackers where account_id = a.id), 0));
end $$;

create or replace function remove_tracker(p_token uuid, p_tracker uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  delete from trackers where id = p_tracker and account_id = a.id;
end $$;

create or replace function log_tracker(p_token uuid, p_tracker uuid, p_day date, p_value numeric) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  if not exists (select 1 from trackers where id = p_tracker and account_id = a.id) then raise exception 'not_your_tracker'; end if;
  if p_day > li_today() + 1 or p_day < li_today() - 7 then raise exception 'bad_day'; end if;
  if p_value is null then
    delete from tracker_logs where tracker_id = p_tracker and log_date = p_day;
  else
    insert into tracker_logs (tracker_id, log_date, value) values (p_tracker, p_day, p_value)
    on conflict (tracker_id, log_date) do update set value = excluded.value;
  end if;
end $$;

-- ---------- crew feed ----------
create or replace function add_post(p_token uuid, p_crew uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  if not exists (select 1 from crew_members where crew_id = p_crew and account_id = a.id) then raise exception 'not_in_crew'; end if;
  p_text := trim(p_text);
  if length(p_text) < 1 or length(p_text) > 280 then raise exception 'bad_text'; end if;
  insert into posts (crew_id, account_id, body) values (p_crew, a.id, p_text);
end $$;

create or replace function toggle_like(p_token uuid, p_post uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  if not exists (select 1 from posts p join crew_members cm on cm.crew_id = p.crew_id and cm.account_id = a.id where p.id = p_post) then raise exception 'not_found'; end if;
  if exists (select 1 from likes where post_id = p_post and account_id = a.id) then
    delete from likes where post_id = p_post and account_id = a.id;
  else
    insert into likes (post_id, account_id) values (p_post, a.id);
  end if;
end $$;

create or replace function add_comment(p_token uuid, p_post uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  p_text := trim(p_text);
  if length(p_text) < 1 or length(p_text) > 200 then raise exception 'bad_text'; end if;
  if not exists (select 1 from posts p join crew_members cm on cm.crew_id = p.crew_id and cm.account_id = a.id where p.id = p_post) then raise exception 'not_found'; end if;
  insert into comments (post_id, account_id, body) values (p_post, a.id, p_text);
end $$;

create or replace function set_photo(p_token uuid, p_photo text) returns void
language plpgsql security definer set search_path = public as $$
declare a accounts;
begin
  a := li_account(p_token);
  if p_photo is not null and length(p_photo) > 200000 then raise exception 'photo_too_big'; end if;
  update accounts set photo = p_photo where id = a.id;
end $$;

-- Helper functions are internal only.
revoke execute on function li_make_code(), li_clean(text), li_today() from public, anon, authenticated;
