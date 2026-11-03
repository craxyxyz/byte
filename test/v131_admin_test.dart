// 1.3.1: Byte account (create / log in), the owner's Admin screen and usage reporting.
import 'dart:convert';

import 'package:byte/core/models.dart';
import 'package:byte/data/usage.dart';
import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/admin_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase/supabase.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

// What the real byte_admin_overview returned on a test database (Postgres 15).
const sample = r"""{"daily": [{"day": "2026-10-31", "users": 0}, {"day": "2026-11-01", "users": 0}, {"day": "2026-11-02", "users": 2}], "users": [{"name": "Rahul", "email": "friend@gmail.com", "plays": 2, "minutes": 6, "platform": "Android", "first_seen": "2026-11-02T17:15:59.454867+00:00", "os_version": "15", "app_version": null, "last_active": "2026-11-02T17:16:10.159302+00:00", "device_model": "Galaxy A15"}, {"name": null, "email": null, "plays": 4, "minutes": 16, "platform": "Android", "first_seen": "2026-11-02T17:15:59.444451+00:00", "os_version": "14", "app_version": null, "last_active": "2026-11-02T17:16:10.157239+00:00", "device_model": "Redmi Note 13"}], "totals": {"devices": 2, "accounts": 1, "plays_7d": 6, "active_7d": 2, "plays_total": 6, "active_today": 2}, "top_songs": [{"plays": 4, "title": "Kesariya", "artist": "Arijit Singh"}, {"plays": 2, "title": "KALYANI (Remix)", "artist": "ARJN"}], "top_artists": [{"plays": 4, "artist": "Arijit Singh"}, {"plays": 2, "artist": "ARJN"}]}""";

void main() {
  test('overview from the server is read correctly (nulls are blanks)', () {
    final o = AdminOverview.fromJson(jsonDecode(sample) as Map);
    expect(o.devices, 2);
    expect(o.accounts, 1);
    expect(o.activeToday, 2);
    expect(o.daily.length, 3);
    expect(o.daily.last.$2, 2);
    expect(o.topSongs.first.$1, 'Kesariya');
    expect(o.topSongs.first.$3, greaterThanOrEqualTo(2));
    expect(o.topArtists.first.$1, 'Arijit Singh');
    final rahul = o.users.firstWhere((u) => u.name == 'Rahul');
    expect(rahul.email, 'friend@gmail.com');
    expect(rahul.device, 'Galaxy A15');
    expect(rahul.platform, 'Android 15');
    expect(o.users.any((u) => u.email.isEmpty && u.name.isEmpty), isTrue); // a phone with no account
  });

  test('only the owner\'s Gmail counts as the owner', () {
    expect(AdminApi.isOwner('justapurbapoco1@gmail.com'), isTrue);
    expect(AdminApi.isOwner(' JustApurbaPoco1@Gmail.com '), isTrue);
    expect(AdminApi.isOwner('friend@gmail.com'), isFalse);
    expect(AdminApi.isOwner(null), isFalse);
  });

  group('usage reporting', () {
    const song = Item(kind: ItemKind.song, id: 'abc', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')]);
    late List<String> calls;
    late bool on;
    final secrets = <String, String>{};
    UsageReporter make({Object? fail}) => UsageReporter(
      client: () => SupabaseClient('https://example.supabase.co', 'k'),
      deviceId: 'device-12345678',
      enabled: () => on,
      deviceInfo: () => {'device_model': 'Redmi Note 13', 'platform': 'Android', 'os_version': '14'},
      readSecret: (k) async => secrets[k],
      writeSecret: (k, v) async => secrets[k] = v,
      rpcForTest: (fn, p) async {
        if (fail != null) throw fail;
        calls.add('$fn ${p['p_song'] is Map ? (p['p_song'] as Map)['title'] : (p['p_info'] as Map)['device_model']} ${(p['p_secret'] as String).length}');
        return true;
      },
    );
    setUp(() {
      calls = [];
      on = true;
    });

    test('a ping, then songs heard 30 s or more (not skips)', () async {
      final u = make();
      await u.ping();
      await u.ping(); // within 10 min: no second ping
      await u.played(song, const Duration(seconds: 12)); // a skip
      await u.played(song, const Duration(seconds: 95));
      expect(calls, ['byte_ping Redmi Note 13 32', 'byte_play Tum Hi Ho 32']);
      expect(secrets['byte_usage_secret'], hasLength(32)); // same secret every time
    });

    test('"Share usage" off: nothing is sent', () async {
      on = false;
      final u = make();
      await u.ping(force: true);
      await u.played(song, const Duration(seconds: 200));
      expect(calls, isEmpty);
    });

    test('server not set up yet: goes quiet, no crash', () async {
      final u = make(fail: const PostgrestException(message: 'Could not find the function public.byte_ping', code: 'PGRST202'));
      await u.ping(force: true);
      expect(u.serverMissing, isTrue);
      await u.played(song, const Duration(seconds: 200));
    });
  });

  group('screens', () {
    setUpAll(() async {
      await makeServices();
    });

    testWidgets('Admin shows the numbers, top songs and people', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 1600);
      addTearDown(t.view.reset);
      await t.pumpWidget(const ByteApp());
      await settle(t);
      pushInCurrentTab!(AdminScreen(load: () async => AdminOverview.fromJson(jsonDecode(sample) as Map)));
      await settle(t);
      expect(find.text('Admin'), findsWidgets);
      expect(find.text('Phones'), findsOneWidget);
      expect(find.text('Byte accounts'), findsOneWidget);
      expect(find.text('1. Kesariya'), findsOneWidget);
      expect(find.text('Rahul'), findsOneWidget);
      expect(find.textContaining('Galaxy A15 · Android 15'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('Admin explains a password-only sign-in and offers the email code', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(400, 900);
      addTearDown(t.view.reset);
      await t.pumpWidget(const ByteApp());
      await settle(t);
      pushInCurrentTab!(AdminScreen(load: () async => throw const AdminProblem('To open Admin, sign in to your Byte account with an email code once (it proves the email is really yours).')));
      await settle(t);
      expect(find.byKey(const ValueKey('admin-error')), findsOneWidget);
      expect(find.text('Sign in with an email code'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    test('Services wires usage to the settings switch', () {
      final s = Services.i;
      s.settings.shareUsage = false;
      expect(s.usage.enabled(), isFalse);
      s.settings.shareUsage = true;
      expect(s.usage.enabled(), isTrue);
    });
  });
}
