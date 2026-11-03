-- ============================================================================
-- BYTE 1.3.1 — server setup, ek hi file (rooms + Gmail sync + admin)
-- © 2026 Apurba Laskar
-- Supabase → SQL Editor → New query → ye POORI file paste karo → Run.
-- Dobara chalana safe hai: sirf byte_* cheezein banti/update hoti hain.
-- Neeche "Success. No rows returned" dikhega = ho gaya.
-- ============================================================================

-- ============================================================================
-- 1) LISTEN TOGETHER rooms (party code, host, now playing)
--    (Rooms work even without this, over the live channel; this adds the saved
--    state so people who join late start at the right place.)
-- ============================================================================
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.byte_listen_rooms (
  code         text primary key check (code ~ '^[A-Z0-9]{6}$'),
  host_name    text not null default '' check (char_length(host_name) <= 60),
  secret_hash  text not null,
  state        jsonb not null default '{}'::jsonb check (pg_column_size(state) < 32000),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  closed       boolean not null default false
);

alter table public.byte_listen_rooms enable row level security;
alter table public.byte_listen_rooms force row level security;

-- Clients may only READ open rooms, and never the secret hash.
revoke all on table public.byte_listen_rooms from anon, authenticated;
grant select (code, host_name, state, created_at, updated_at, closed)
  on table public.byte_listen_rooms to anon, authenticated;

drop policy if exists "byte_rooms_read_open" on public.byte_listen_rooms;
create policy "byte_rooms_read_open" on public.byte_listen_rooms
  for select to anon, authenticated
  using (not closed and updated_at > now() - interval '12 hours');
-- (no insert/update/delete policies: writes only through the functions below)

-- Host opens (or re-opens) a room. Returns false if the code is taken by someone else.
create or replace function public.byte_lt_open(p_code text, p_secret text, p_host_name text, p_state jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  h text;
begin
  if p_code is null or p_code !~ '^[A-Z0-9]{6}$' or p_secret is null or char_length(p_secret) < 16 then
    raise exception 'bad request';
  end if;
  h := encode(digest(p_secret, 'sha256'), 'hex');
  delete from public.byte_listen_rooms where updated_at < now() - interval '2 days';
  insert into public.byte_listen_rooms as r (code, host_name, secret_hash, state)
  values (p_code, left(coalesce(p_host_name, ''), 60), h, coalesce(p_state, '{}'::jsonb))
  on conflict (code) do update
    set host_name = excluded.host_name, secret_hash = excluded.secret_hash,
        state = excluded.state, updated_at = now(), closed = false
    where r.secret_hash = excluded.secret_hash or r.closed or r.updated_at < now() - interval '12 hours';
  return found;
end;
$$;

-- Host saves what is playing (so people who join late start at the right place).
create or replace function public.byte_lt_update(p_code text, p_secret text, p_state jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.byte_listen_rooms
     set state = coalesce(p_state, '{}'::jsonb), updated_at = now()
   where code = p_code and not closed
     and secret_hash = encode(digest(coalesce(p_secret, ''), 'sha256'), 'hex');
  return found;
end;
$$;

-- Host ends the room.
create or replace function public.byte_lt_close(p_code text, p_secret text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.byte_listen_rooms
     set closed = true, updated_at = now()
   where code = p_code
     and secret_hash = encode(digest(coalesce(p_secret, ''), 'sha256'), 'hex');
  return found;
end;
$$;

revoke all on function public.byte_lt_open(text, text, text, jsonb) from public;
revoke all on function public.byte_lt_update(text, text, jsonb) from public;
revoke all on function public.byte_lt_close(text, text) from public;
grant execute on function public.byte_lt_open(text, text, text, jsonb) to anon, authenticated;
grant execute on function public.byte_lt_update(text, text, jsonb) to anon, authenticated;
grant execute on function public.byte_lt_close(text, text) to anon, authenticated;


-- ============================================================================
-- 2) GMAIL SYNC — same likes, playlists, history, settings on every device
-- ============================================================================
-- 2a) One table for everything Byte syncs. Each row = (user, collection, id) + JSON.
--    collections: likes, playlists, history, library, settings, downloads,
--    stats (per device), playlog (per device), now (what is playing).
create sequence if not exists public.byte_records_seq;

create table if not exists public.byte_records (
  user_id     uuid        not null default auth.uid() references auth.users (id) on delete cascade,
  collection  text        not null,
  id          text        not null,
  payload     jsonb,                                   -- null when deleted
  updated_at  bigint      not null,                    -- time of the edit on the device (ms); newest wins
  deleted     boolean     not null default false,      -- deletes are kept so other devices learn about them
  device      text,                                    -- which device made the edit
  seq         bigint      not null default nextval('public.byte_records_seq'),
  server_at   timestamptz not null default now(),
  primary key (user_id, collection, id)
);

create index if not exists byte_records_user_seq on public.byte_records (user_id, seq);

-- 2b) Row Level Security: every account sees and changes ONLY its own rows.
alter table public.byte_records enable row level security;

drop policy if exists "byte own rows select" on public.byte_records;
drop policy if exists "byte own rows insert" on public.byte_records;
drop policy if exists "byte own rows update" on public.byte_records;
drop policy if exists "byte own rows delete" on public.byte_records;

create policy "byte own rows select" on public.byte_records
  for select to authenticated using (auth.uid() = user_id);
create policy "byte own rows insert" on public.byte_records
  for insert to authenticated with check (auth.uid() = user_id);
create policy "byte own rows update" on public.byte_records
  for update to authenticated using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "byte own rows delete" on public.byte_records
  for delete to authenticated using (auth.uid() = user_id);

revoke all on public.byte_records from anon;
grant select, insert, update, delete on public.byte_records to authenticated;
grant usage, select on sequence public.byte_records_seq to authenticated;

-- 2c) Push: saves a batch; an older edit never overwrites a newer one.
create or replace function public.byte_push(rows jsonb)
returns integer
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  n integer;
begin
  if uid is null then
    raise exception 'not signed in' using errcode = '28000';
  end if;
  insert into public.byte_records as t (user_id, collection, id, payload, updated_at, deleted, device)
  select uid, r.collection, r.id,
         case when coalesce(r.deleted, false) then null else r.payload end,
         r.updated_at, coalesce(r.deleted, false), r.device
  from jsonb_to_recordset(rows) as r(collection text, id text, payload jsonb, updated_at bigint, deleted boolean, device text)
  where r.collection is not null and r.id is not null and r.updated_at is not null
  on conflict (user_id, collection, id) do update
     set payload    = excluded.payload,
         updated_at = excluded.updated_at,
         deleted    = excluded.deleted,
         device     = excluded.device,
         seq        = nextval('public.byte_records_seq'),
         server_at  = now()
   where excluded.updated_at > t.updated_at;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.byte_push(jsonb) from public, anon;
grant execute on function public.byte_push(jsonb) to authenticated;

-- 2d) Live: other devices get a ping the moment one device saves.
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'byte_records'
  ) then
    alter publication supabase_realtime add table public.byte_records;
  end if;
end $$;


-- ============================================================================
-- 3) USAGE + ADMIN (Byte 1.3.1) — sirf Apurba (justapurbapoco1@gmail.com) dekh sakta hai.
--    Each phone reports: model, Android/iOS version, Byte version, last used,
--    songs played (title, artist, seconds). No passwords, no location.
--    Phones write ONLY through byte_ping / byte_play (a per-phone secret);
--    nobody can read these tables directly; only byte_admin_overview reads
--    them, and it checks on the server that the caller is the owner AND
--    signed in with an email code/link (so nobody can fake his Gmail).
-- ============================================================================

create table if not exists public.byte_devices (
  device_id    text primary key check (char_length(device_id) between 8 and 80),
  secret_hash  text not null,
  user_id      uuid references auth.users (id) on delete set null,
  email        text,
  name         text,
  device_model text,
  platform     text,
  os_version   text,
  app_version  text,
  first_seen   timestamptz not null default now(),
  last_active  timestamptz not null default now(),
  plays        bigint not null default 0,
  seconds      bigint not null default 0
);

create table if not exists public.byte_plays (
  id         bigserial primary key,
  device_id  text not null references public.byte_devices (device_id) on delete cascade,
  user_id    uuid,
  song_id    text,
  title      text,
  artist     text,
  seconds    integer not null default 0,
  played_at  timestamptz not null default now()
);
create index if not exists byte_plays_at on public.byte_plays (played_at);
create index if not exists byte_plays_device on public.byte_plays (device_id);

create table if not exists public.byte_active_days (
  device_id  text not null references public.byte_devices (device_id) on delete cascade,
  day        date not null,
  primary key (device_id, day)
);

alter table public.byte_devices enable row level security;
alter table public.byte_plays enable row level security;
alter table public.byte_active_days enable row level security;
revoke all on public.byte_devices, public.byte_plays, public.byte_active_days from anon, authenticated;
-- (no policies at all: reads and writes only through the functions below)

create or replace function public.byte_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(lower(auth.jwt() ->> 'email'), '') = 'justapurbapoco1@gmail.com';
$$;

-- this session proved the email: signed in with an email code or link
create or replace function public.byte_email_proven()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) a
    where a ->> 'method' in ('otp', 'magiclink', 'email/signup', 'recovery', 'invite', 'email_change')
  );
$$;

create or replace function public.byte_ping(p_device text, p_secret text, p_info jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  h text;
  uid uuid := auth.uid();
begin
  if p_device is null or char_length(p_device) not between 8 and 80 or p_secret is null or char_length(p_secret) < 16 then
    raise exception 'bad request';
  end if;
  h := encode(digest(p_secret, 'sha256'), 'hex');
  insert into public.byte_devices as d (device_id, secret_hash, user_id, email, name, device_model, platform, os_version, app_version)
  values (p_device, h, uid, lower(auth.jwt() ->> 'email'),
          left(coalesce(auth.jwt() -> 'user_metadata' ->> 'name', p_info ->> 'name'), 80),
          left(p_info ->> 'device_model', 80), left(p_info ->> 'platform', 20),
          left(p_info ->> 'os_version', 20), left(p_info ->> 'app_version', 20))
  on conflict (device_id) do update
     set user_id      = coalesce(excluded.user_id, d.user_id),
         email        = coalesce(excluded.email, d.email),
         name         = coalesce(excluded.name, d.name),
         device_model = coalesce(excluded.device_model, d.device_model),
         platform     = coalesce(excluded.platform, d.platform),
         os_version   = coalesce(excluded.os_version, d.os_version),
         app_version  = coalesce(excluded.app_version, d.app_version),
         last_active  = now()
   where d.secret_hash = excluded.secret_hash;
  if not found then return false; end if;
  insert into public.byte_active_days (device_id, day) values (p_device, (now() at time zone 'Asia/Kolkata')::date)
  on conflict do nothing;
  return true;
end;
$$;

create or replace function public.byte_play(p_device text, p_secret text, p_song jsonb)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  s integer := least(greatest(coalesce((p_song ->> 'seconds')::integer, 0), 0), 7200);
begin
  update public.byte_devices
     set plays = plays + 1, seconds = seconds + s, last_active = now()
   where device_id = p_device and secret_hash = encode(digest(coalesce(p_secret, ''), 'sha256'), 'hex');
  if not found then return false; end if;
  insert into public.byte_plays (device_id, user_id, song_id, title, artist, seconds)
  values (p_device, auth.uid(), left(p_song ->> 'song_id', 80), left(p_song ->> 'title', 200), left(p_song ->> 'artist', 200), s);
  insert into public.byte_active_days (device_id, day) values (p_device, (now() at time zone 'Asia/Kolkata')::date)
  on conflict do nothing;
  return true;
end;
$$;

create or replace function public.byte_admin_overview(p_days integer default 30)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  d integer := least(greatest(coalesce(p_days, 30), 1), 365);
  today date := (now() at time zone 'Asia/Kolkata')::date;
begin
  if not public.byte_is_admin() then
    raise exception 'not admin' using errcode = '42501';
  end if;
  if not public.byte_email_proven() then
    raise exception 'verify email: sign in with an email code' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'totals', jsonb_build_object(
      'devices', (select count(*) from public.byte_devices),
      'accounts', (select count(distinct user_id) from public.byte_devices where user_id is not null),
      'active_today', (select count(*) from public.byte_active_days where day = today),
      'active_7d', (select count(distinct device_id) from public.byte_active_days where day > today - 7),
      'plays_7d', (select count(*) from public.byte_plays where played_at > now() - interval '7 days'),
      'plays_total', (select coalesce(sum(plays), 0) from public.byte_devices)
    ),
    'daily', coalesce((
      select jsonb_agg(jsonb_build_object('day', to_char(g.day, 'YYYY-MM-DD'), 'users', coalesce(a.n, 0)) order by g.day)
      from generate_series(today - (d - 1), today, interval '1 day') as g(day)
      left join (select day, count(*) n from public.byte_active_days group by day) a on a.day = g.day::date
    ), '[]'::jsonb),
    'top_songs', coalesce((
      select jsonb_agg(t) from (
        select title, artist, count(*) as plays from public.byte_plays
        where played_at > now() - make_interval(days => d) and title is not null
        group by title, artist order by count(*) desc limit 25) t
    ), '[]'::jsonb),
    'top_artists', coalesce((
      select jsonb_agg(t) from (
        select artist, count(*) as plays from public.byte_plays
        where played_at > now() - make_interval(days => d) and coalesce(artist, '') <> ''
        group by artist order by count(*) desc limit 25) t
    ), '[]'::jsonb),
    'users', coalesce((
      select jsonb_agg(t) from (
        select name, email, device_model, platform, os_version, app_version,
               first_seen, last_active, plays, (seconds / 60) as minutes
        from public.byte_devices order by last_active desc limit 300) t
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.byte_is_admin() from public;
revoke all on function public.byte_email_proven() from public;
revoke all on function public.byte_ping(text, text, jsonb) from public;
revoke all on function public.byte_play(text, text, jsonb) from public;
revoke all on function public.byte_admin_overview(integer) from public;
grant execute on function public.byte_ping(text, text, jsonb) to anon, authenticated;
grant execute on function public.byte_play(text, text, jsonb) to anon, authenticated;
grant execute on function public.byte_admin_overview(integer) to authenticated;
grant execute on function public.byte_is_admin() to authenticated;
grant execute on function public.byte_email_proven() to authenticated;

-- Let the app see the new tables/functions right away.
notify pgrst, 'reload schema';

-- Done. Neeche "Success. No rows returned" dikhega.
