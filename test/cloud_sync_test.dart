import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:byte/data/cloud_sync.dart';
import 'package:byte/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase/supabase.dart';

/// The server, as Byte-v1.3-sync.sql makes it: rows per account (row level
/// security), newest edit wins, a change counter devices pull from.
class MemServer {
  final Map<String, Map<String, SyncRow>> byUser = {};
  int seq = 0;
  bool offline = false;
  bool notReady = false;
  final _ping = StreamController<String>.broadcast();

  void push(String uid, List<SyncRow> rows) {
    final m = byUser.putIfAbsent(uid, () => {});
    for (final r in rows) {
      final k = '${r.collection}|${r.id}';
      final cur = m[k];
      if (cur != null && r.updatedAt <= cur.updatedAt) continue; // older edit: ignored
      m[k] = SyncRow(collection: r.collection, id: r.id, payload: r.deleted ? null : r.payload, updatedAt: r.updatedAt, deleted: r.deleted, device: r.device, seq: ++seq);
    }
    _ping.add(uid);
  }

  List<SyncRow> pull(String uid, int after, int limit) {
    final l = (byUser[uid]?.values ?? const <SyncRow>[]).where((r) => r.seq > after).toList()..sort((a, b) => a.seq.compareTo(b.seq));
    return l.take(limit).toList();
  }
}

class MemBackend implements SyncBackend {
  final MemServer server;
  final String uid;
  MemBackend(this.server, this.uid);
  void _check() {
    if (server.notReady) throw const SyncNotReady('relation "public.byte_records" does not exist');
    if (server.offline) throw const SocketException('offline');
  }

  @override
  Future<void> push(List<SyncRow> rows) async {
    _check();
    // through JSON, like the wire
    server.push(uid, [for (final r in rows) SyncRow.fromJson(jsonDecode(jsonEncode({...r.toJson(), 'seq': 0})) as Map)]);
  }

  @override
  Future<List<SyncRow>> pull(int afterSeq, {int limit = 500}) async {
    _check();
    return server.pull(uid, afterSeq, limit);
  }

  @override
  Stream<void> changes() => server._ping.stream.where((u) => u == uid).map((_) {});
  @override
  Future<void> close() async {}
}

class Device {
  final String name;
  final CloudSync sync;
  int applied = 0;
  Device._(this.name, this.sync);
  static Future<Device> make(MemServer server, String name, {String uid = 'user-1', int Function()? clock}) async {
    late Device d;
    final s = CloudSync(
      backendFor: () => MemBackend(server, d._uid),
      deviceId: 'dev-$name',
      deviceName: () => '$name phone',
      onApplied: () => d.applied++,
      debounce: const Duration(hours: 1), // tests call syncNow themselves
      lazyEvery: const Duration(hours: 1),
      clock: clock,
      boxPrefix: '${name}_',
    );
    d = Device._(name, s);
    d._uid = uid;
    await s.open();
    return d;
  }

  String _uid = 'user-1';
  Box box(String n) => Hive.box('${name}_$n');
  Future<void> signIn([String? uid]) async {
    if (uid != null) _uid = uid;
    await sync.start(_uid);
  }

  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sync.syncNow();
  }
}

String liked(String id) => jsonEncode({'item': Item(kind: ItemKind.song, id: id, title: 'Song $id').toJson(), 'at': 1});

void main() {
  var n = 0;
  late MemServer server;
  var t = 1000000;
  int clock() => t += 1000;

  setUpAll(() {
    Hive.init(Directory.systemTemp.createTempSync('byte_sync_').path);
  });
  setUp(() => server = MemServer());

  Future<(Device, Device)> two() async {
    n++;
    return (await Device.make(server, 'a$n', clock: clock), await Device.make(server, 'b$n', clock: clock));
  }

  test('likes, playlists, library lists and settings reach the other device', () async {
    final (a, b) = await two();
    await a.signIn();
    await a.box('likes').put('song1', liked('song1'));
    await a.box('playlists').put('pl1', jsonEncode({'id': 'pl1', 'n': 'Gym', 'i': [], 'c': 1, 'u': 1}));
    await a.box('library_misc').put('pinned_playlists', ['pl1']);
    await a.box('settings').put('theme', 2);
    await a.box('settings').put('qMobile', 2);
    await a.box('history').put('song1', liked('song1'));
    await a.box('downloads').put('song1', jsonEncode({'i': Item(kind: ItemKind.song, id: 'song1', title: 'Song song1').toJson(), 'p': '/x', 'b': 1, 'm': 'audio/webm', 'a': 1}));
    await a.settle();
    expect(a.sync.state, SyncState.synced);
    expect(a.sync.pending, 0);
    await b.signIn();
    expect(b.box('likes').containsKey('song1'), isTrue);
    expect(jsonDecode(b.box('playlists').get('pl1') as String)['n'], 'Gym');
    expect(b.box('library_misc').get('pinned_playlists'), ['pl1']);
    expect(b.box('settings').get('theme'), 2);
    expect(b.box('history').containsKey('song1'), isTrue);
    expect(b.applied, greaterThan(0));
    // a download is a list entry on the other phone (files stay where they are)
    expect(b.box('downloads').containsKey('song1'), isFalse);
    expect(b.sync.otherDownloads.keys, ['song1']);
  });

  test("this phone's own settings (its id, its hardware) never travel", () async {
    final (a, b) = await two();
    await a.box('settings').put('deviceId', 'AAAA');
    await a.box('settings').put('usbDac', true);
    await b.box('settings').put('deviceId', 'BBBB');
    await a.signIn();
    await b.signIn();
    expect(b.box('settings').get('deviceId'), 'BBBB');
    expect(b.box('settings').get('usbDac'), isNull);
    expect((server.byUser['user-1']?.keys ?? const <String>[]).where((k) => k.contains('deviceId') || k.contains('usbDac')), isEmpty);
  });

  test('deletes travel too (unlike on one phone = unliked on the other)', () async {
    final (a, b) = await two();
    await a.signIn();
    await a.box('likes').put('song2', liked('song2'));
    await a.settle();
    await b.signIn();
    expect(b.box('likes').containsKey('song2'), isTrue);
    await a.box('likes').delete('song2');
    await a.settle();
    await b.settle();
    expect(b.box('likes').containsKey('song2'), isFalse);
  });

  test('conflict: the newer edit wins, whichever phone syncs last', () async {
    final (a, b) = await two();
    await a.signIn();
    await b.signIn();
    server.offline = true;
    await a.box('settings').put('theme', 1); // earlier
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.box('settings').put('theme', 2); // later
    await Future<void>.delayed(const Duration(milliseconds: 5));
    server.offline = false;
    await b.sync.syncNow(); // the newer one goes up first…
    await a.sync.syncNow(); // …the older one comes after and loses
    await b.sync.syncNow();
    expect(a.box('settings').get('theme'), 2);
    expect(b.box('settings').get('theme'), 2);
    expect((server.byUser['user-1']!['settings|theme']!.payload as Map)['v'], 2);
  });

  test('offline: changes wait on the phone and go up when the connection is back', () async {
    final (a, b) = await two();
    await a.signIn();
    server.offline = true;
    await a.box('likes').put('s1', liked('s1'));
    await a.box('likes').put('s2', liked('s2'));
    await a.settle();
    expect(a.sync.state, SyncState.offline);
    expect(a.sync.pending, 2);
    expect(a.sync.message, contains('2 changes'));
    // the queue survives the app closing
    final again = await Device.make(server, a.name, clock: clock);
    expect(again.sync.pending, 2);
    server.offline = false;
    await a.sync.syncNow();
    expect(a.sync.pending, 0);
    await b.signIn();
    expect(b.box('likes').keys.toSet(), {'s1', 's2'});
  });

  test('first sign-in merges what was on the phone: nothing is lost', () async {
    final (a, b) = await two();
    await a.box('likes').put('fromA', liked('fromA'));
    await a.box('library_misc').put('searches', ['arijit', 'kesariya']);
    await a.box('settings').put('theme', 1);
    await a.signIn();
    // B was used before signing in
    await b.box('likes').put('fromB', liked('fromB'));
    await b.box('library_misc').put('searches', ['tum hi ho', 'arijit']);
    await b.box('settings').put('theme', 2);
    await b.signIn();
    await a.settle();
    for (final d in [a, b]) {
      expect(d.box('likes').keys.toSet(), {'fromA', 'fromB'}, reason: d.name);
      expect((d.box('library_misc').get('searches') as List).toSet(), {'arijit', 'kesariya', 'tum hi ho'}, reason: d.name);
    }
    // a setting already in the account wins over the new phone's old one
    expect(b.box('settings').get('theme'), 1);
  });

  test('listening stats: each phone adds its own, shown together', () async {
    final (a, b) = await two();
    Map stat(int ms, int p) => {'song1': {'i': Item(kind: ItemKind.song, id: 'song1', title: 'x').toJson(), 'ms': ms, 'p': p}};
    await a.box('stats').put('y2026', stat(60000, 2));
    await b.box('stats').put('y2026', stat(30000, 1));
    await a.signIn();
    await b.signIn();
    await a.settle();
    expect(b.box('stats').get('y2026'), stat(30000, 1)); // its own stays its own
    expect(b.box('stats').get('r:dev-${a.name}:y2026'), stat(60000, 2));
    expect(a.box('stats').get('r:dev-${b.name}:y2026'), stat(30000, 1));
  });

  test("what's playing: the other phone can carry on from the same moment", () async {
    final (a, b) = await two();
    await a.signIn();
    await b.signIn();
    final songs = [for (var i = 0; i < 3; i++) Item(kind: ItemKind.song, id: 'q$i', title: 'Q$i')];
    await a.sync.notePlaying(songs, 1, const Duration(seconds: 83), playing: false);
    await a.settle();
    await b.settle();
    final now = b.sync.remoteNow.value!;
    expect(now.item!.id, 'q1');
    expect(now.position, const Duration(seconds: 83));
    expect(now.deviceName, '${a.name} phone');
    expect(a.sync.remoteNow.value, isNull); // not offered to itself
    // B plays something newer: A's old song is not offered back
    await b.sync.notePlaying(songs, 2, Duration.zero, playing: true);
    await b.sync.syncNow();
    await a.settle();
    expect(a.sync.remoteNow.value!.item!.id, 'q2');
  });

  test('server not set up yet: says so, everything stays on the phone and waits', () async {
    final (a, _) = await two();
    server.notReady = true;
    await a.box('likes').put('s9', liked('s9'));
    await a.signIn();
    expect(a.sync.state, SyncState.notReady);
    expect(a.sync.message, contains('not switched on'));
    expect(a.box('likes').containsKey('s9'), isTrue);
    expect(a.sync.pending, greaterThan(0));
    server.notReady = false;
    await a.sync.syncNow();
    expect(a.sync.state, SyncState.synced);
    expect(server.byUser['user-1']!.containsKey('likes|s9'), isTrue);
  });

  test("another Gmail sees none of it (each account's own rows)", () async {
    final (a, b) = await two();
    await a.signIn('user-1');
    await a.box('likes').put('private', liked('private'));
    await a.settle();
    await b.signIn('user-2');
    expect(b.box('likes').containsKey('private'), isFalse);
    expect(server.byUser['user-2'], anyOf(isNull, isNot(contains('likes|private'))));
  });

  test('sign-out stops syncing; the data stays on the phone', () async {
    final (a, _) = await two();
    await a.signIn();
    await a.box('likes').put('keep', liked('keep'));
    await a.settle();
    await a.sync.stop();
    expect(a.sync.state, SyncState.signedOut);
    expect(a.box('likes').containsKey('keep'), isTrue);
    await a.box('likes').put('later', liked('later'));
    await a.sync.syncNow();
    expect(server.byUser['user-1']!.containsKey('likes|later'), isFalse);
  });

  group('the real server client (requests checked, no network)', () {
    final seen = <http.Request>[];
    SupabaseClient client(http.Response Function(http.Request) answer) => SupabaseClient(
      'https://example.supabase.co',
      'publishable-key',
      httpClient: MockClient((r) async {
        seen.add(r);
        final res = answer(r);
        return http.Response(res.body, res.statusCode, headers: res.headers, request: r);
      }),
    );
    setUp(seen.clear);

    test('pull: own rows only (server rule), newer than the last one seen, in order', () async {
      final b = SupabaseSyncBackend(client((_) => http.Response(jsonEncode([{'collection': 'likes', 'id': 'x', 'payload': {'v': 'a'}, 'updated_at': 5, 'deleted': false, 'device': 'd', 'seq': 8}]), 200, headers: {'content-type': 'application/json'})));
      final rows = await b.pull(7);
      expect(rows.single.seq, 8);
      final u = seen.single.url;
      expect(u.path, '/rest/v1/byte_records');
      expect(u.queryParameters['seq'], 'gt.7');
      expect(u.queryParameters['order'], startsWith('seq.asc'));
      expect(u.queryParameters['limit'], '500');
      expect(u.queryParameters.containsKey('user_id'), isFalse); // the server's row rule picks the account, not the app
    });

    test('push: one call with the batch; newest-wins is done by the server', () async {
      final b = SupabaseSyncBackend(client((_) => http.Response('1', 200, headers: {'content-type': 'application/json'})));
      await b.push([const SyncRow(collection: 'settings', id: 'theme', payload: {'v': 2}, updatedAt: 9, device: 'd')]);
      expect(seen.single.url.path, '/rest/v1/rpc/byte_push');
      final body = jsonDecode(seen.single.body) as Map;
      expect((body['rows'] as List).single, {'collection': 'settings', 'id': 'theme', 'payload': {'v': 2}, 'updated_at': 9, 'deleted': false, 'device': 'd'});
    });

    test('table not made yet → "not set up" (not a crash)', () async {
      final b = SupabaseSyncBackend(client((_) => http.Response(jsonEncode({'code': 'PGRST205', 'message': "Could not find the table 'public.byte_records' in the schema cache"}), 404, headers: {'content-type': 'application/json'})));
      expect(() => b.pull(0), throwsA(isA<SyncNotReady>()));
    });
  });
}
