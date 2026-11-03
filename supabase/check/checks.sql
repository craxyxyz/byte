-- Security + behaviour checks (run after shim.sql and the setup file, as postgres).

\set ON_ERROR_STOP 1
insert into auth.users values ('11111111-1111-1111-1111-111111111111','justapurbapoco1@gmail.com'),('22222222-2222-2222-2222-222222222222','friend@gmail.com');
-- anon phone pings + plays
set role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', false);
select 'ping_new', public.byte_ping('phone-aaaa-1111', 'secretsecretsecret1', '{"device_model":"Redmi Note 13","platform":"Android","os_version":"14"}');
select 'ping_wrong_secret', public.byte_ping('phone-aaaa-1111', 'WRONGWRONGWRONGWRONG', '{"device_model":"HACK"}');
select 'play', public.byte_play('phone-aaaa-1111', 'secretsecretsecret1', '{"song_id":"x1","title":"Kesariya","artist":"Arijit Singh","seconds":240}');
select 'play2', public.byte_play('phone-aaaa-1111', 'secretsecretsecret1', '{"song_id":"x2","title":"KALYANI (Remix)","artist":"ARJN","seconds":269}');
select 'play_bad', public.byte_play('phone-aaaa-1111', 'nope-nope-nope-nope', '{"title":"spam"}');
-- anon cannot read tables
do $$ begin perform * from public.byte_devices; raise exception 'LEAK devices'; exception when insufficient_privilege then raise notice 'ok: anon cannot read byte_devices'; end $$;
do $$ begin perform * from public.byte_plays; raise exception 'LEAK plays'; exception when insufficient_privilege then raise notice 'ok: anon cannot read byte_plays'; end $$;
-- anon cannot call admin
do $$ begin perform public.byte_admin_overview(30); raise exception 'LEAK admin anon'; exception when insufficient_privilege then raise notice 'ok: anon cannot call admin'; end $$;
reset role;
-- friend signed in (password) pings with account
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"22222222-2222-2222-2222-222222222222","email":"friend@gmail.com","role":"authenticated","user_metadata":{"name":"Rahul"},"amr":[{"method":"password"}]}', false);
select 'friend_ping', public.byte_ping('phone-bbbb-2222', 'secretsecretsecret2', '{"device_model":"Galaxy A15","platform":"Android","os_version":"15"}');
select 'friend_play', public.byte_play('phone-bbbb-2222', 'secretsecretsecret2', '{"song_id":"x1","title":"Kesariya","artist":"Arijit Singh","seconds":200}');
do $$ begin perform public.byte_admin_overview(30); raise exception 'LEAK admin friend'; exception when insufficient_privilege then raise notice 'ok: friend gets 42501 not admin'; end $$;
-- sync table: friend sees only own rows
select 'push', public.byte_push('[{"collection":"likes","id":"x1","payload":{"t":1},"updated_at":10,"device":"p"}]');
select 'friend_rows', count(*) from public.byte_records;
reset role;
-- someone registers with the owner's email but only a password (autoconfirm): refused
set role authenticated;
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","email":"justapurbapoco1@gmail.com","role":"authenticated","amr":[{"method":"password"}]}', false);
do $$ begin perform public.byte_admin_overview(30); raise exception 'LEAK admin password-only'; exception when insufficient_privilege then raise notice 'ok: owner email with password only must prove email (42501)'; end $$;
select 'owner_rows_of_friend', count(*) from public.byte_records;
-- the owner, signed in with an email code
select set_config('request.jwt.claims', '{"sub":"11111111-1111-1111-1111-111111111111","email":"justapurbapoco1@gmail.com","role":"authenticated","amr":[{"method":"otp","timestamp":1}]}', false);
select 'overview', jsonb_pretty(public.byte_admin_overview(7));
reset role;
-- rooms
set role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', false);
select 'room_open', public.byte_lt_open('ABC234', 'roomsecretroomsecret', 'Apurba', '{"v":1}');
select 'room_steal', public.byte_lt_open('ABC234', 'otherotherotherother', 'X', '{"v":9}');
select 'room_read', code, host_name, state from public.byte_listen_rooms;
reset role;
