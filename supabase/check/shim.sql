-- A bare Postgres made to look like Supabase (roles, auth.uid/jwt) for checking the setup file.

create role anon nologin; create role authenticated nologin;
create schema auth; create schema extensions;
create extension pgcrypto with schema extensions;
create table auth.users (id uuid primary key, email text);
create function auth.jwt() returns jsonb language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb $$;
create function auth.uid() returns uuid language sql stable as $$ select nullif(auth.jwt() ->> 'sub', '')::uuid $$;
grant usage on schema auth, extensions, public to anon, authenticated;
grant execute on all functions in schema auth to anon, authenticated;
create publication supabase_realtime;
