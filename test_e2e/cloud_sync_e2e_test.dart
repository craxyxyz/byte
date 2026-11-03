// End to end: two "devices" sign in with the same email and sync through a
// real Supabase stack (auth + PostgREST + Realtime) with Byte-v1.3-sync.sql.
//   . supabase-local/env.sh && flutter test test_e2e/cloud_sync_e2e_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:byte/core/models.dart';
import 'package:byte/data/cloud_sync.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:supabase/supabase.dart';

import '../test/helpers.dart' show MemSecureStorage;

final env = Platform.environment;
final url = env['SUPA_URL'] ?? 'http://127.0.0.1:54321';
final key = env['SUPA_ANON_KEY'] ?? '';
final mailLog = env['SUPA_MAIL_LOG'] ?? '';

/// The newest sign-in link mailed to [to] (as the person would copy it).
Future<String> linkFor(String to, {int after = 0}) async {
  for (var i = 0; i < 50; i++) {
    final raw = File(mailLog).readAsStringSync();
    final mails = raw.split('=== MAIL').skip(1).where((m) => m.contains('to=<$to>')).toList();
    if (mails.length > after) {
      final body = mails.last.replaceAll('=\n', '').replaceAll('=3D', '=').replaceAll('&amp;', '&');
      final m = RegExp(r'https?://[^"\s<]+/auth/v1/verify\?[^"\s<]+').firstMatch(body);
      if (m != null) return m.group(0)!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  throw StateError('no mail for $to');
}

int mailsTo(String to) => File(mailLog).readAsStringSync().split('=== MAIL').where((m) => m.contains('to=<$to>')).length;

String liked(String id) => jsonEncode({'item': Item(kind: ItemKind.song, id: id, title: 'Song $id').toJson(), 'at': 1});

Future<void> until(bool Function() ok, {int ms = 8000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() => Hive.init(Directory.systemTemp.createTempSync('byte_e2e_').path));

  test('same Gmail on two devices = same Byte (email link sign-in, live updates, own rows only)', () async {
    expect(key, isNotEmpty, reason: 'source supabase-local/env.sh first');
    final email = 'byte.e2e.${DateTime.now().millisecondsSinceEpoch}@gmail.com';
    final storeA = MemSecureStorage();

    // ── device A: sign in with a link mailed to the Gmail ──
    final a = CloudAccount(CloudAccount.makeClient(url, key), secure: storeA);
    await a.restore();
    var before = mailsTo(email);
    await a.sendCode(email);
    await a.verifyLink(await linkFor(email, after: before));
    expect(a.signedIn, isTrue);
    expect(a.email, email);
    final syncA = CloudSync(backendFor: () => SupabaseSyncBackend(a.client), deviceId: 'devA', deviceName: () => 'Pixel', boxPrefix: 'A_', debounce: const Duration(milliseconds: 200));
    await syncA.open();
    await Hive.box('A_likes').put('song1', liked('song1'));
    await Hive.box('A_settings').put('theme', 2);
    await Hive.box('A_library_misc').put('searches', ['arijit']);
    await syncA.start(a.uid!);
    expect(syncA.state, SyncState.synced, reason: '${syncA.message}');

    // ── device B: same Gmail ──
    final b = CloudAccount(CloudAccount.makeClient(url, key), secure: MemSecureStorage());
    await b.restore();
    before = mailsTo(email);
    // the server allows one email per address every so often (as hosted)
    for (var i = 0;; i++) {
      try {
        await b.sendCode(email);
        break;
      } on AuthException catch (e) {
        if (e.statusCode != '429' || i > 70) rethrow;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    await b.verifyLink(await linkFor(email, after: before));
    expect(b.uid, a.uid);
    final syncB = CloudSync(backendFor: () => SupabaseSyncBackend(b.client), deviceId: 'devB', deviceName: () => 'Tablet', boxPrefix: 'B_', debounce: const Duration(milliseconds: 200));
    await syncB.open();
    await Hive.box('B_likes').put('fromTablet', liked('fromTablet'));
    await syncB.start(b.uid!);
    expect(syncB.state, SyncState.synced, reason: '${syncB.message}');
    expect(Hive.box('B_likes').keys.toSet(), {'song1', 'fromTablet'});
    expect(Hive.box('B_settings').get('theme'), 2);
    expect(Hive.box('B_library_misc').get('searches'), ['arijit']);

    // ── live: a like on A shows up on B by itself ──
    await syncA.syncNow();
    expect(Hive.box('A_likes').containsKey('fromTablet'), isTrue);
    await Hive.box('A_likes').put('live1', liked('live1'));
    await until(() => Hive.box('B_likes').containsKey('live1'));
    expect(Hive.box('B_likes').containsKey('live1'), isTrue, reason: 'realtime ping → pull');
    // unlike on B → gone on A
    await Hive.box('B_likes').delete('song1');
    await until(() => !Hive.box('A_likes').containsKey('song1'));
    expect(Hive.box('A_likes').containsKey('song1'), isFalse);

    // ── what's playing ──
    await syncA.notePlaying([const Item(kind: ItemKind.song, id: 'p1', title: 'Kesariya')], 0, const Duration(seconds: 42), playing: false);
    await until(() => syncB.remoteNow.value != null);
    expect(syncB.remoteNow.value?.item?.title, 'Kesariya');
    expect(syncB.remoteNow.value?.deviceName, 'Pixel');

    // ── another Gmail (password sign-in) sees none of it ──
    final c = CloudAccount(CloudAccount.makeClient(url, key), secure: MemSecureStorage());
    await c.withPassword('other.${DateTime.now().millisecondsSinceEpoch}@gmail.com', 'correct horse 42', create: true);
    expect(c.signedIn, isTrue);
    expect(await SupabaseSyncBackend(c.client).pull(0), isEmpty);
    // and cannot write into A's rows: its push lands in its own account
    await SupabaseSyncBackend(c.client).push([const SyncRow(collection: 'likes', id: 'intruder', payload: {'v': 'x'}, updatedAt: 99999999999999)]);
    expect((await SupabaseSyncBackend(a.client).pull(0)).where((r) => r.id == 'intruder'), isEmpty);
    // wrong password: a clear error
    final d = CloudAccount(CloudAccount.makeClient(url, key), secure: MemSecureStorage());
    await expectLater(d.withPassword(c.email!, 'wrong password'), throwsA(isA<AuthException>()));

    // ── app restart: still signed in ──
    final a2 = CloudAccount(CloudAccount.makeClient(url, key), secure: storeA as FlutterSecureStorage);
    await a2.restore();
    expect(a2.email, email);

    await syncA.stop();
    await syncB.stop();
  }, timeout: const Timeout(Duration(minutes: 4)));
}
