// Listen together end-to-end against a running Supabase (the local stand-in
// by default): two "phones" — a host and a guest — each with its own client.
//   SUPA_URL / SUPA_ANON_KEY from supabase-local/env.sh
//   flutter test test_e2e/listen_together_e2e_test.dart
import 'dart:io';

import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

class FakeSync implements SyncPlayer {
  final String name;
  FakeSync(this.name);
  @override
  Item? item;
  bool playing = false;
  int _posMs = 0;
  int _at = DateTime.now().millisecondsSinceEpoch;
  final ValueNotifier<int> _changes = ValueNotifier(0);
  final List<String> log = [];
  @override
  Listenable get changes => _changes;
  @override
  bool get isPlaying => playing;
  @override
  Duration get position => Duration(milliseconds: playing ? _posMs + DateTime.now().millisecondsSinceEpoch - _at : _posMs);
  void _mark(int pos) {
    _posMs = pos;
    _at = DateTime.now().millisecondsSinceEpoch;
  }

  // local user actions (host side)
  void userPlay(Item it) {
    item = it;
    playing = true;
    _mark(0);
    _changes.value++;
  }

  void userPause() {
    _mark(position.inMilliseconds);
    playing = false;
    _changes.value++;
  }

  void userResume() {
    _mark(position.inMilliseconds);
    playing = true;
    _changes.value++;
  }

  void userSeek(int ms) {
    _mark(ms);
    _changes.value++;
  }

  // driven by ListenTogether (guest side)
  @override
  Future<void> load(Item it, Duration at, {required bool play}) async {
    log.add('load ${it.id} ${at.inMilliseconds} $play');
    item = it;
    playing = play;
    _mark(at.inMilliseconds);
  }

  @override
  Future<void> seekTo(Duration d) async {
    log.add('seek ${d.inMilliseconds}');
    _mark(d.inMilliseconds);
  }

  @override
  Future<void> setPlaying(bool play) async {
    log.add('play $play');
    _mark(position.inMilliseconds);
    playing = play;
  }
}

Future<void> waitFor(bool Function() ok, {Duration max = const Duration(seconds: 8), String what = ''}) async {
  final end = DateTime.now().add(max);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) throw TestFailure('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  final url = Platform.environment['SUPA_URL'] ?? 'http://127.0.0.1:54321';
  final key = Platform.environment['SUPA_ANON_KEY'] ?? '';
  const song1 = Item(kind: ItemKind.song, id: 'abc123', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')]);
  const song2 = Item(kind: ItemKind.song, id: 'def456', title: 'আমি তোমার — বাংলা গান', artists: [ArtistRef('শিল্পী')]);

  test('host + guest stay in sync (play, pause, seek, next song, late join, leave)', () async {
    final hp = FakeSync('host'), gp = FakeSync('guest');
    final host = ListenTogether(player: hp, deviceId: 'host-dev', displayName: () => 'Apurba', client: () => SupabaseClient(url, key));
    final guest = ListenTogether(player: gp, deviceId: 'guest-dev', displayName: () => 'Friend', client: () => SupabaseClient(url, key));

    hp.userPlay(song1);
    expect(await host.host(), isTrue, reason: host.error);
    final code = host.code!;
    expect(RegExp(r'^[A-Z0-9]{6}$').hasMatch(code), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 600));

    // Guest joins late: starts the same song near the host's position.
    expect(await guest.join(code.toLowerCase()), isTrue, reason: guest.error);
    await waitFor(() => gp.item?.id == 'abc123' && gp.playing, what: 'guest loads song 1');
    await waitFor(() => (gp.position - hp.position).inMilliseconds.abs() < 800, what: 'guest position close to host');
    await waitFor(() => host.people.length == 2 && guest.people.length == 2, what: 'presence shows both');
    expect(guest.people.first.host, isTrue);
    expect(guest.hostName, 'Apurba');

    // Pause on host → guest pauses.
    hp.userPause();
    await waitFor(() => !gp.playing, what: 'guest pauses');
    // Seek on host (paused) → guest seeks.
    hp.userSeek(90000);
    await waitFor(() => (gp.position.inMilliseconds - 90000).abs() < 800, what: 'guest seeks');
    // Resume → guest resumes from there.
    hp.userResume();
    await waitFor(() => gp.playing, what: 'guest resumes');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect((gp.position - hp.position).inMilliseconds.abs(), lessThan(900));
    // Next song (Bengali title) → guest follows.
    hp.userPlay(song2);
    await waitFor(() => gp.item?.id == 'def456', what: 'guest follows next song');
    expect(gp.item!.title, song2.title);

    // Guest drifting (e.g. buffering) gets pulled back by the heartbeat.
    await gp.seekTo(Duration.zero);
    gp.playing = true;
    hp.userSeek(60000);
    await waitFor(() => (gp.position - hp.position).inMilliseconds.abs() < 900, what: 'drift corrected');

    // Anyone can control the music: the guest pauses → the host pauses too.
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    gp.playing = true;
    gp.userPause();
    await waitFor(() => !hp.playing, what: 'host follows guest pause');
    expect(host.activity.any((a) => a.who == 'Friend' && a.what == 'Paused'), isTrue);
    gp.userResume();
    await waitFor(() => hp.playing, what: 'host follows guest play');

    // "Only I control the music": guest pausing stays local.
    await host.setHostOnly(true);
    await waitFor(() => guest.hostOnly, what: 'guest learns host-only');
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    gp.userPause();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(hp.playing, isTrue, reason: 'host keeps playing');
    expect(gp.playing, isFalse, reason: 'guest stays paused on their own phone');
    hp.userPlay(song1);
    await waitFor(() => gp.item?.id == 'abc123' && gp.playing, what: 'host change still reaches guest');

    // Party size: host sets 2 → a third person is turned away.
    await host.setCapacity(2);
    await waitFor(() => guest.capacity == 2, what: 'capacity synced');
    final g3 = ListenTogether(player: FakeSync('g3'), deviceId: 'g3-dev', displayName: () => 'Third', client: () => SupabaseClient(url, key));
    await Future<void>.delayed(const Duration(milliseconds: 3500)); // let the host save the room
    expect(await g3.join(code), isFalse);
    expect(g3.error, contains('full'));

    // A third client can read the open room, but never its secret.
    final anon = SupabaseClient(url, key);
    final rows = await anon.from('byte_listen_rooms').select('code, host_name').eq('code', code);
    expect(rows.length, 1);
    Object? err;
    try {
      await anon.from('byte_listen_rooms').select('secret_hash').eq('code', code);
    } catch (e) {
      err = e;
    }
    expect(err, isNotNull, reason: 'secret_hash must not be readable');
    // Nobody but the host can change the room.
    final hijack = await anon.rpc('byte_lt_update', params: {'p_code': code, 'p_secret': 'x' * 32, 'p_state': {}});
    expect(hijack, isFalse);
    Object? insErr;
    try {
      await anon.from('byte_listen_rooms').insert({'code': 'ZZZZZZ', 'secret_hash': 'x'});
    } catch (e) {
      insErr = e;
    }
    expect(insErr, isNotNull, reason: 'direct insert must be refused');

    // Wrong code → friendly error.
    final g2 = ListenTogether(player: FakeSync('g2'), deviceId: 'g2', displayName: () => 'X', client: () => SupabaseClient(url, key));
    expect(await g2.join('ZZZZZ9'), isFalse);
    expect(g2.error, contains('No party'));
    expect(await g2.join('abc'), isFalse);

    // Codes: typed "oh"/"eye" become zero/one, spaces and case don't matter.
    expect(ListenTogether.normaliseCode('ab c-d o i'), 'ABCD01');

    // Host removes the guest.
    final g4p = FakeSync('g4');
    await host.setCapacity(5);
    final g4 = ListenTogether(player: g4p, deviceId: 'g4-dev', displayName: () => 'Fourth', client: () => SupabaseClient(url, key));
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    expect(await g4.join(code), isTrue, reason: g4.error);
    await waitFor(() => host.people.any((p) => p.id == 'g4-dev'), what: 'host sees g4');
    await host.remove('g4-dev');
    await waitFor(() => g4.role == RoomRole.none, what: 'g4 removed');
    expect(g4.error, contains('removed'));
    await waitFor(() => !host.people.any((p) => p.id == 'g4-dev'), what: 'g4 gone from list');
    expect(host.activity.any((a) => a.what == 'Left'), isTrue);

    // Host ends → guest is told, room is closed for newcomers.
    await host.leave();
    await waitFor(() => guest.role == RoomRole.none, what: 'guest sees room ended');
    expect(guest.error, contains('ended'));
    final after = await anon.from('byte_listen_rooms').select('code').eq('code', code);
    expect(after, isEmpty);
    await guest.leave();
    await g2.leave();
    await g3.leave();
    await g4.leave();
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('server drop: both phones reconnect by themselves and catch up; host drops out and comes back', () async {
    final D = Platform.environment['SUPA_DIR'] ?? '/home/user/tab/files/supabase-local';
    final hp = FakeSync('host'), gp = FakeSync('guest');
    late SupabaseClient hostClient;
    final host = ListenTogether(player: hp, deviceId: 'host-r', displayName: () => 'Apurba', client: () => hostClient = SupabaseClient(url, key));
    final guest = ListenTogether(player: gp, deviceId: 'guest-r', displayName: () => 'Friend', client: () => SupabaseClient(url, key));
    hp.userPlay(song1);
    expect(await host.host(), isTrue, reason: host.error);
    expect(await guest.join(host.code!), isTrue, reason: guest.error);
    await waitFor(() => gp.item?.id == 'abc123', what: 'guest loads song 1');

    // 1. The realtime server goes away (like the net dropping on both phones).
    final pid = File('$D/run/realtime.pid').readAsStringSync().trim();
    await Process.run('kill', [pid]);
    await waitFor(() => !host.connected && !guest.connected, max: const Duration(seconds: 20), what: 'both notice the drop');
    expect(guest.activity.any((a) => a.what.startsWith('Connection lost')), isTrue);
    // The host changes the song while everyone is offline.
    hp.userPlay(song2);
    await Future<void>.delayed(const Duration(seconds: 2));
    final r = await Process.run('bash', ['$D/start.sh']);
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
    await waitFor(() => host.connected && guest.connected, max: const Duration(seconds: 40), what: 'both reconnect');
    await waitFor(() => gp.item?.id == 'def456', max: const Duration(seconds: 15), what: 'guest catches up with the song changed offline');
    expect(guest.activity.any((a) => a.what == 'Reconnected'), isTrue);
    await waitFor(() => (gp.position - hp.position).inMilliseconds.abs() < 900, what: 'positions line up again');

    // 2. The host's phone drops out on its own (app killed / no signal) without ending the party.
    await waitFor(() => guest.people.length == 2, what: 'presence back to 2');
    await hostClient.realtime.disconnect();
    await waitFor(() => guest.hostAway, max: const Duration(seconds: 20), what: 'guest sees the host dropped out');
    expect(guest.role, RoomRole.guest, reason: 'the guest stays in the party');
    // Host keeps playing locally, moves on, then comes back by itself.
    hp.userSeek(60000);
    await waitFor(() => host.connected && !guest.hostAway, max: const Duration(seconds: 40), what: 'host comes back');
    await waitFor(() => (gp.position.inMilliseconds - hp.position.inMilliseconds).abs() < 900, max: const Duration(seconds: 15), what: 'guest follows the host again');
    expect(guest.activity.any((a) => a.what == 'Is back'), isTrue);

    await host.leave();
    await waitFor(() => guest.role == RoomRole.none, what: 'guest sees room ended');
    await guest.leave();
  }, timeout: const Timeout(Duration(seconds: 180)));
}
