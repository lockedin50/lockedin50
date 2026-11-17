-- =====================================================================
-- Locked In 50 · database setup
-- Paste this whole file into Supabase → SQL Editor → New query → Run.
-- Safe to run more than once.
--
-- How access works: the tables are locked (row level security on, no
-- policies), so the public app key cannot read or change them directly.
-- The app can only call the functions below, and each one checks a
-- crew code or a member's sign-in token before doing anything.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists crews (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists members (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references crews(id) on delete cascade,
  name text not null,
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
create unique index if not exists members_crew_name on members (crew_id, lower(name));
create unique index if not exists members_token on members (token);

create table if not exists goals (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references members(id) on delete cascade,
  label text not null,
  unit text not null default '',
  start_val numeric not null,
  target_val numeric not null,
  shared boolean not null default false,
  sort int not null default 0
);

create table if not exists goal_logs (
  goal_id uuid not null references goals(id) on delete cascade,
  log_date date not null,
  value numeric not null,
  primary key (goal_id, log_date)
);

create table if not exists days (
  member_id uuid not null references members(id) on delete cascade,
  day date not null,
  done jsonb not null default '[]'::jsonb,
  primary key (member_id, day)
);

create table if not exists posts (
  id uuid primary key default gen_random_uuid(),
  crew_id uuid not null references crews(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  body text not null,
  kind text not null default 'post',
  ref_key text,
  created_at timestamptz not null default now()
);
create unique index if not exists posts_auto on posts (member_id, kind, ref_key) where ref_key is not null;
create index if not exists posts_crew_time on posts (crew_id, created_at desc);

create table if not exists likes (
  post_id uuid not null references posts(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  primary key (post_id, member_id)
);

create table if not exists comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references posts(id) on delete cascade,
  member_id uuid not null references members(id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);

-- Lock every table: no direct access with the public key.
alter table crews     enable row level security;
alter table members   enable row level security;
alter table goals     enable row level security;
alter table goal_logs enable row level security;
alter table days      enable row level security;
alter table posts     enable row level security;
alter table likes     enable row level security;
alter table comments  enable row level security;
revoke all on crews, members, goals, goal_logs, days, posts, likes, comments from anon, authenticated;

-- ---------- helpers (not callable from the app) ----------
create or replace function li_member(p_token uuid) returns members
language plpgsql stable security definer set search_path = public as $$
declare m members;
begin
  select * into m from members where token = p_token;
  if m.id is null then raise exception 'bad_token'; end if;
  return m;
end $$;

create or replace function li_today() returns date
language sql stable as $$ select (now() at time zone 'Australia/Sydney')::date $$;

create or replace function li_goal_pct(p_goal uuid) returns int
language sql stable security definer set search_path = public as $$
  select case when g.target_val = g.start_val then 100
    else round((coalesce((select value from goal_logs where goal_id = g.id order by log_date desc limit 1), g.start_val) - g.start_val)
               / (g.target_val - g.start_val) * 100)::int end
  from goals g where g.id = p_goal
$$;

revoke execute on function li_member(uuid), li_goal_pct(uuid) from public, anon, authenticated;

-- ---------- functions the app calls ----------

-- Who's in a crew (for joining and the sign-in screen). Needs the crew code.
create or replace function crew_members(p_code text) returns json
language plpgsql stable security definer set search_path = public as $$
declare c crews;
begin
  select * into c from crews where code = upper(trim(p_code));
  if c.id is null then raise exception 'bad_code'; end if;
  return json_build_object('name', c.name, 'members', coalesce((
    select json_agg(json_build_object('id', m.id, 'name', m.name, 'color', m.color, 'photo', m.photo, 'startDate', m.start_date) order by m.created_at)
    from members m where m.crew_id = c.id), '[]'::json));
end $$;

-- Join a crew and lock in a list and goals. Returns a sign-in token.
create or replace function join_crew(p_code text, p_name text, p_pin text, p_color text, p_photo text,
                                     p_start date, p_items jsonb, p_goals jsonb) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare c crews; m members; g jsonb; i int := 0; gid uuid;
begin
  select * into c from crews where code = upper(trim(p_code));
  if c.id is null then raise exception 'bad_code'; end if;
  p_name := trim(p_name);
  if length(p_name) < 1 or length(p_name) > 20 then raise exception 'bad_name'; end if;
  if p_pin !~ '^\d{4}$' then raise exception 'bad_pin_format'; end if;
  if exists (select 1 from members where crew_id = c.id and lower(name) = lower(p_name)) then raise exception 'name_taken'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) < 5 or jsonb_array_length(p_items) > 12 then raise exception 'bad_items'; end if;
  if jsonb_typeof(p_goals) <> 'array' or jsonb_array_length(p_goals) > 3 then raise exception 'bad_goals'; end if;
  if p_photo is not null and length(p_photo) > 200000 then raise exception 'photo_too_big'; end if;
  if p_start < li_today() - 1 or p_start > li_today() + 2 then raise exception 'bad_start'; end if;

  insert into members (crew_id, name, pin_hash, color, photo, start_date, items)
  values (c.id, p_name, crypt(p_pin, gen_salt('bf')), p_color, p_photo, p_start, p_items)
  returning * into m;

  for g in select * from jsonb_array_elements(p_goals) loop
    insert into goals (member_id, label, unit, start_val, target_val, shared, sort)
    values (m.id, left(g->>'label', 40), left(coalesce(g->>'unit', ''), 12), (g->>'start')::numeric, (g->>'target')::numeric,
            coalesce((g->>'shared')::boolean, false), i)
    returning id into gid;
    insert into goal_logs (goal_id, log_date, value) values (gid, p_start, (g->>'start')::numeric);
    i := i + 1;
  end loop;

  insert into posts (crew_id, member_id, body, kind)
  values (c.id, m.id, 'Locked in for 50 days 🔒 Starting ' || case when p_start = li_today() then 'today.' else to_char(p_start, 'FMDay') || '.' end, 'join');

  return json_build_object('token', m.token, 'id', m.id);
end $$;

-- Sign in with a PIN. 5 wrong tries locks that person out for 15 minutes.
create or replace function sign_in(p_code text, p_member uuid, p_pin text) returns json
language plpgsql security definer set search_path = public, extensions as $$
declare m members;
begin
  select m2.* into m from members m2 join crews c on c.id = m2.crew_id where m2.id = p_member and c.code = upper(trim(p_code));
  if m.id is null then return json_build_object('error', 'not_found'); end if;
  if m.locked_until is not null and m.locked_until > now() then return json_build_object('error', 'locked'); end if;
  if crypt(p_pin, m.pin_hash) = m.pin_hash then
    update members set failed_pins = 0, locked_until = null where id = m.id;
    return json_build_object('token', m.token, 'id', m.id);
  end if;
  update members set failed_pins = case when failed_pins >= 4 then 0 else failed_pins + 1 end,
                     locked_until = case when failed_pins >= 4 then now() + interval '15 minutes' else null end
  where id = m.id;
  return json_build_object('error', 'bad_pin');
end $$;

-- Everything the app shows for a crew. Other people's goals come back as % only.
create or replace function get_crew(p_token uuid) returns json
language plpgsql stable security definer set search_path = public as $$
declare m members; r json;
begin
  m := li_member(p_token);
  select json_build_object(
    'crew', (select json_build_object('name', c.name, 'code', c.code) from crews c where c.id = m.crew_id),
    'me', m.id,
    'members', coalesce((select json_agg(json_build_object(
        'id', x.id, 'name', x.name, 'color', x.color, 'photo', x.photo, 'startDate', x.start_date, 'items', x.items,
        'days', coalesce((select json_object_agg(d.day::text, d.done) from days d where d.member_id = x.id), '{}'::json),
        'goals', coalesce((select json_agg(case when x.id = m.id then json_build_object(
              'id', g.id, 'label', g.label, 'unit', g.unit, 'shared', g.shared, 'start', g.start_val, 'target', g.target_val,
              'logs', coalesce((select json_agg(json_build_object('date', l.log_date, 'value', l.value) order by l.log_date)
                                from goal_logs l where l.goal_id = g.id), '[]'::json))
            else json_build_object('id', g.id, 'label', g.label, 'shared', true, 'pct', li_goal_pct(g.id)) end order by g.sort)
          from goals g where g.member_id = x.id and (x.id = m.id or g.shared)), '[]'::json)
      ) order by x.created_at) from members x where x.crew_id = m.crew_id), '[]'::json),
    'feed', coalesce((select json_agg(f order by f.ts desc) from (
        select p.id, p.member_id as "userId", p.body as text, (extract(epoch from p.created_at) * 1000)::bigint as ts,
          coalesce((select json_agg(l.member_id) from likes l where l.post_id = p.id), '[]'::json) as likes,
          coalesce((select json_agg(json_build_object('userId', c.member_id, 'text', c.body, 'ts', (extract(epoch from c.created_at) * 1000)::bigint) order by c.created_at)
                    from comments c where c.post_id = p.id), '[]'::json) as comments
        from posts p where p.crew_id = m.crew_id order by p.created_at desc limit 60) f), '[]'::json)
  ) into r;
  return r;
end $$;

-- Save today's ticks (today or yesterday only, within your 50 days).
create or replace function set_day(p_token uuid, p_day date, p_done jsonb, p_perfect boolean, p_day_num int) returns void
language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := li_member(p_token);
  if p_day < m.start_date or p_day > m.start_date + 49 then raise exception 'outside_challenge'; end if;
  if p_day < li_today() - 1 or p_day > li_today() + 1 then raise exception 'day_closed'; end if;
  if jsonb_typeof(p_done) <> 'array' then raise exception 'bad_done'; end if;
  insert into days (member_id, day, done) values (m.id, p_day, p_done)
  on conflict (member_id, day) do update set done = excluded.done;
  if p_perfect then
    insert into posts (crew_id, member_id, body, kind, ref_key)
    values (m.crew_id, m.id, 'Day ' || p_day_num || ' done. 100% 💯', 'perfect', p_day::text)
    on conflict do nothing;
  end if;
end $$;

-- Log a goal number for a day.
create or replace function log_goal(p_token uuid, p_goal uuid, p_day date, p_value numeric) returns void
language plpgsql security definer set search_path = public as $$
declare m members; g goals;
begin
  m := li_member(p_token);
  select * into g from goals where id = p_goal and member_id = m.id;
  if g.id is null then raise exception 'not_your_goal'; end if;
  insert into goal_logs (goal_id, log_date, value) values (g.id, p_day, p_value)
  on conflict (goal_id, log_date) do update set value = excluded.value;
  if g.shared and li_goal_pct(g.id) >= 100 then
    insert into posts (crew_id, member_id, body, kind, ref_key)
    values (m.crew_id, m.id, 'Hit my goal: ' || g.label || ' 🎯', 'goal', g.id::text)
    on conflict do nothing;
  end if;
end $$;

create or replace function add_post(p_token uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := li_member(p_token);
  p_text := trim(p_text);
  if length(p_text) < 1 or length(p_text) > 280 then raise exception 'bad_text'; end if;
  insert into posts (crew_id, member_id, body) values (m.crew_id, m.id, p_text);
end $$;

create or replace function toggle_like(p_token uuid, p_post uuid) returns void
language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := li_member(p_token);
  if not exists (select 1 from posts where id = p_post and crew_id = m.crew_id) then raise exception 'not_found'; end if;
  if exists (select 1 from likes where post_id = p_post and member_id = m.id) then
    delete from likes where post_id = p_post and member_id = m.id;
  else
    insert into likes (post_id, member_id) values (p_post, m.id);
  end if;
end $$;

create or replace function add_comment(p_token uuid, p_post uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := li_member(p_token);
  p_text := trim(p_text);
  if length(p_text) < 1 or length(p_text) > 200 then raise exception 'bad_text'; end if;
  if not exists (select 1 from posts where id = p_post and crew_id = m.crew_id) then raise exception 'not_found'; end if;
  insert into comments (post_id, member_id, body) values (p_post, m.id, p_text);
end $$;

create or replace function set_photo(p_token uuid, p_photo text) returns void
language plpgsql security definer set search_path = public as $$
declare m members;
begin
  m := li_member(p_token);
  if p_photo is not null and length(p_photo) > 200000 then raise exception 'photo_too_big'; end if;
  update members set photo = p_photo where id = m.id;
end $$;

-- ---------- the first crew ----------
-- Change the name or code here if you like (codes are matched in capitals).
insert into crews (code, name) values ('LI50-PS65S', 'Carter''s Crew')
on conflict (code) do nothing;
