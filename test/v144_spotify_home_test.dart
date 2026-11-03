@Timeout(Duration(seconds: 90))
library;

// Byte © 2026 Apurba Laskar
import 'dart:convert';

import 'package:byte/core/models.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/data/spotify_account.dart';
import 'package:byte/data/spotify_sync.dart';
import 'package:byte/data/spotify_web.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/screens/home_screen.dart';
import 'package:byte/ui/service_rows.dart';
import 'package:byte/ui/sync_help.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 1.4.4 (Apurba, Nov 3: "Spotify se import kiya hua home page pe show
// hona chahiye"): a logged-in account's playlists are on Home, Liked Songs
// first, imported or not; a sync failure never empties them.

/// A music account that answers from memory (no network).
class FakeAccount extends SpotifyAccount {
  FakeAccount(super.net);
  bool on = true;
  bool failLists = false;
  final failRead = <String>{};
  int reads = 0;
  List<SpotifyPlaylistInfo> ls = const [SpotifyPlaylistInfo('pl_gym', 'Gym Bangers', null, -1, 'Apurba'), SpotifyPlaylistInfo('liked', 'Liked Songs', null, -1, 'Apurba')];
  Map<String, List<ExtTrack>> tracks = {
    'liked': [const ExtTrack('Kesariya', 'Arijit Singh'), const ExtTrack('Tum Hi Ho', 'Arijit Singh')],
    'pl_gym': [const ExtTrack('Zinda', 'Siddharth Mahadevan'), const ExtTrack('Sultan', 'Sukhwinder Singh'), const ExtTrack('Dangal', 'Daler Mehndi')],
  };
  @override
  bool get connected => on;
  @override
  String get userName => 'Apurba';
  @override
  Future<List<SpotifyPlaylistInfo>> playlists() async {
    if (failLists) throw Exception('The music service answered 403 (Client/request not allowed)');
    return ls;
  }

  @override
  Future<ExtList> read(SpotifyPlaylistInfo p, {void Function(String)? onStatus}) async {
    reads++;
    if (failRead.contains(p.id)) throw Exception('read failed for ${p.id}');
    final ts = tracks[p.id]!;
    onStatus?.call('Reading songs… ${ts.length} of ${ts.length}');
    return ExtList(p.name, p.cover, ts, MusicService.spotify, 'spotify:${p.id}', total: ts.length);
  }
}

void main() {
  late Services sv;
  late FakeAccount acc;
  var matched = 0;

  Future<List<Item?>> matcher(List<ExtTrack> ts, void Function(int, int) progress) async {
    matched += ts.length;
    return [
      for (final t in ts) Item(kind: ItemKind.song, id: 'yt_${t.title.toLowerCase().replaceAll(' ', '_')}', title: t.title, artists: [ArtistRef(t.artists)]),
    ];
  }

  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    SpotifySync.retryDelays = const [];
  });

  setUp(() async {
    for (final p in sv.library.playlists) {
      await sv.library.deletePlaylist(p.id);
    }
    for (final l in sv.library.likes) {
      await sv.library.setLiked(l, false);
    }
    acc = FakeAccount(sv.net);
    sv.spotify = acc;
    final sy = SpotifySync(account: acc, library: sv.library, matcher: matcher);
    await sy.open();
    await sy.forget();
    sv.spotifySync = sy;
    matched = 0;
    resetSpotifyHomeRowForTest();
  });

  test('the list is kept on the phone, Liked Songs first', () async {
    final ls = await sv.spotifySync.refreshLists();
    expect(ls.length, 2);
    expect(sv.spotifySync.lists.map((p) => p.id).toList(), ['liked', 'pl_gym']);
    expect(sv.spotifySync.lists[1].name, 'Gym Bangers');
  });

  test('sync failure keeps the cached list (and says why, quietly)', () async {
    await sv.spotifySync.refreshLists();
    acc.failLists = true;
    acc.failRead.addAll(['liked', 'pl_gym']);
    final r = await sv.spotifySync.syncNow();
    expect(r, isNull);
    expect(sv.spotifySync.lastError, isNotNull);
    expect(sv.spotifySync.lastErrorDetail, contains('read failed'));
    expect(sv.spotifySync.lists.length, 2, reason: 'Home keeps the last list');
    await sv.spotifySync.refreshLists();
    expect(sv.spotifySync.lists.length, 2);
  });

  test('one playlist failing never stops the others', () async {
    acc.failRead.add('liked');
    final r = await sv.spotifySync.syncNow();
    expect(r, isNotNull);
    expect(r!.playlists, 1);
    expect(sv.library.playlistBySource('spotify:pl_gym')!.items.length, 3);
    expect(sv.spotifySync.lastError, contains('1 of 2'));
  });

  test('importOne brings one playlist in; a second sync only looks up new songs', () async {
    final items = await sv.spotifySync.importOne(acc.ls.first);
    expect(items.map((i) => i.title), ['Zinda', 'Sultan', 'Dangal']);
    expect(sv.spotifySync.imported(acc.ls.first)!.items.length, 3);
    expect(matched, 3);
    await sv.spotifySync.syncNow();
    expect(matched, 5, reason: 'only the 2 liked songs were new');
    expect(sv.spotifySync.likedImported, isTrue);
    expect(sv.library.isLiked('yt_kesariya'), isTrue);
  });

  test('the web reader asks like a browser (the 403 that caused "Couldn\'t sync")', () async {
    final net = FakeNet((r, body) {
      if (r.url.host == 'api-partner.spotify.com') {
        if (!(r.headers['User-Agent'] ?? '').startsWith('Mozilla/5.0')) {
          return jsonRes({
            'error': {'status': 403, 'message': 'Client/request not allowed'},
          }, 403);
        }
        final op = (jsonDecode(body) as Map)['operationName'];
        if (op == 'fetchPlaylist') {
          return jsonRes({
            'data': {
              'playlistV2': {
                'content': {
                  'totalCount': 1,
                  'items': [
                    {
                      'itemV2': {
                        'data': {
                          '__typename': 'Track',
                          'name': 'Loser',
                          'artists': {
                            'items': [
                              {
                                'profile': {'name': 'Tame Impala'},
                              },
                            ],
                          },
                          'albumOfTrack': {'name': 'Deadbeat'},
                          'trackDuration': {'totalMilliseconds': 223069},
                        },
                      },
                    },
                  ],
                },
              },
            },
          });
        }
      }
      return null;
    });
    final api = SpotifyWebApi(net, () async => 'tok_${'x' * 60}');
    final ts = await api.playlistTracks('spotify:playlist:abc');
    expect(ts.single.title, 'Loser');
    expect(ts.single.artists, 'Tame Impala');
    final pf = net.log.firstWhere((r) => r.url.host == 'api-partner.spotify.com');
    expect(pf.headers['User-Agent'], SpotifyWebApi.desktopUa);
    expect(pf.headers['Origin'], 'https://open.spotify.com');
  });

  test('the older public API: playlist songs also come from its newer "items" address', () async {
    final net = FakeNet((r, body) {
      if (r.url.host == 'api-partner.spotify.com') return jsonRes({'error': 'x'}, 400);
      if (r.url.path.endsWith('/tracks')) return jsonRes({'error': 'gone'}, 404);
      if (r.url.path.endsWith('/items')) {
        return jsonRes({
          'items': [
            {
              'item': {
                'name': 'Raabta',
                'artists': [
                  {'name': 'Arijit Singh'},
                ],
              },
            },
          ],
          'next': null,
        });
      }
      return null;
    });
    final ts = await SpotifyWebApi(net, () async => 't' * 60).playlistTracks('spotify:playlist:abc');
    expect(ts.single.title, 'Raabta');
  });

  testWidgets('Home after a failed sync still shows the last list; logged out → no row', (tester) async {
    await tester.runAsync(() => sv.spotifySync.refreshLists());
    acc.failLists = true;
    acc.failRead.addAll(['liked', 'pl_gym']);
    await tester.runAsync(() => sv.spotifySync.syncNow());
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: MusicServiceRows())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('From Spotify'), findsOneWidget);
    expect(find.text('Gym Bangers'), findsOneWidget);
    expect(find.text('Liked Songs'), findsOneWidget);

    acc.on = false;
    sv.spotifySync.notifyListeners();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('From Spotify'), findsNothing);
    expect(find.byKey(const ValueKey('home-spotify')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('logged in, never read, service refusing: Liked Songs still shows', (tester) async {
    acc.failLists = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: MusicServiceRows())),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('From Spotify'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-spotify-liked')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"How sync works" says what the code does', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SyncHelpSheet(service: 'Spotify', automatic: true)),
      ),
    );
    expect(find.text('How sync works'), findsOneWidget);
    expect(find.textContaining('every 3 hours'), findsOneWidget);
    expect(find.textContaining('more than 6 hours ago'), findsOneWidget);
    expect(find.textContaining('one way, from Spotify into Byte'), findsOneWidget);
    expect(find.textContaining('log in again, then tap Sync now'), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SyncHelpSheet(service: 'JioSaavn', automatic: false)),
      ),
    );
    expect(find.textContaining('No automatic sync yet'), findsOneWidget);
    expect(find.textContaining('From JioSaavn'), findsOneWidget);
  });
  testWidgets('Home: logged in + 2 playlists → "From Spotify" row, Liked first; tap an unimported one → brought in + plays; again → opens at once', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() => sv.spotifySync.refreshLists());
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: HomeScreen())));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('From Spotify'), findsOneWidget);
    final liked = find.byKey(const ValueKey('home-spotify-liked'));
    final gym = find.byKey(const ValueKey('home-spotify-pl_gym'));
    expect(liked, findsOneWidget);
    expect(gym, findsOneWidget);
    expect(tester.getTopLeft(liked).dx, lessThan(tester.getTopLeft(gym).dx), reason: 'Liked Songs first');
    final row = tester.getTopLeft(find.byKey(const ValueKey('home-spotify'))).dy;
    for (final other in ['Top Picks for You', 'Recents', 'Quick picks']) {
      final f = find.text(other);
      if (f.evaluate().isNotEmpty) expect(tester.getTopLeft(f.first).dy, greaterThan(row), reason: other);
    }
    expect(sv.spotifySync.imported(acc.ls.first), isNull);

    await tester.tap(gym);
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(acc.reads, 1);
    expect(sv.spotifySync.imported(acc.ls.first)!.items.length, 3);
    expect(sv.player.current.value?.title, 'Zinda');
    expect(find.byKey(const ValueKey('bringing-in')), findsNothing);
    await tester.runAsync(() => sv.player.stop());

    // back on Home: now it shows its count and opens without reading again
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: HomeScreen())));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('3 songs'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-spotify-pl_gym')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(acc.reads, 1, reason: 'imported: opens instantly');
    expect(sv.player.current.value?.title, 'Zinda');
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  });
}
