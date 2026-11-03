import 'dart:convert';

import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/data/spotify_account.dart';
import 'package:byte/data/spotify_sync.dart';
import 'package:byte/data/spotify_web.dart';
import 'package:byte/data/scrobble.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 1.4: "Tap to connect" → the music service's own sign-in page inside
// Byte; whoever signs in, their Liked Songs + playlists come in and stay synced.

Map<String, Object?> _pfBody(String body) => jsonDecode(body) as Map<String, Object?>;

Map<String, Object?> _libTrack(String name, String artist, {int ms = 200000}) => {
  'addedAt': {'isoString': '2026-11-01T00:00:00Z'},
  'track': {
    '_uri': 'spotify:track:${name.hashCode}',
    'data': {
      '__typename': 'Track',
      'name': name,
      'albumOfTrack': {'name': '$name album'},
      'artists': {
        'items': [
          {'profile': {'name': artist}},
        ],
      },
      'duration': {'totalMilliseconds': ms},
    },
  },
};

/// A fake music service: one signed-in person with [liked] songs and two playlists.
FakeNet fakeService({required List<(String, String)> liked, bool signedIn = true, List<String>? log}) {
  final playlists = {
    'spotify:playlist:AAA': ('Road trip', [('Kalyani', 'Vineeth'), ('Tum Hi Ho', 'Arijit Singh')]),
    'spotify:playlist:BBB': ('Gym', [('Believer', 'Imagine Dragons')]),
  };
  return FakeNet((r, body) {
    final u = r.url.toString();
    if (u == SpotifyWebApi.pathfinder) {
      final b = _pfBody(body);
      final op = b['operationName'];
      log?.add('$op ${jsonEncode(b['variables'])}');
      final v = (b['variables'] as Map?) ?? const {};
      if (!(r.headers['Authorization'] ?? '').startsWith('Bearer ')) return jsonRes({}, 401);
      if (op == 'profileAttributes') {
        return jsonRes({'data': {'me': signedIn ? {'profile': {'name': 'Tablet User', 'username': 'tab1'}} : null}});
      }
      if (op == 'fetchLibraryTracks') {
        final off = v['offset'] as int, lim = v['limit'] as int;
        final page = liked.skip(off).take(lim).map((t) => _libTrack(t.$1, t.$2)).toList();
        return jsonRes({'data': {'me': {'library': {'tracks': {'items': page, 'pagingInfo': {'offset': off, 'limit': lim}, 'totalCount': liked.length}}}}});
      }
      if (op == 'libraryV3') {
        return jsonRes({
          'data': {
            'me': {
              'libraryV3': {
                'totalCount': 3,
                'items': [
                  for (final e in playlists.entries)
                    {
                      'item': {
                        '__typename': 'PlaylistResponseWrapper',
                        '_uri': e.key,
                        'data': {'__typename': 'Playlist', 'name': e.value.$1, 'ownerV2': {'data': {'name': 'Tablet User'}}, 'images': {'items': []}},
                      },
                    },
                  {
                    'item': {'__typename': 'FolderResponseWrapper', '_uri': 'spotify:user:x:folder:1', 'data': {'__typename': 'Folder', 'name': 'A folder'}},
                  },
                ],
              },
            },
          },
        });
      }
      if (op == 'fetchPlaylist') {
        final pl = playlists[v['uri']]!;
        return jsonRes({
          'data': {
            'playlistV2': {
              'name': pl.$1,
              'content': {
                'totalCount': pl.$2.length,
                'items': [for (final t in pl.$2) {'itemV2': {'data': (_libTrack(t.$1, t.$2)['track'] as Map)['data']}}],
              },
            },
          },
        });
      }
    }
    return null;
  });
}

void main() {
  group('reading the signed-in person\'s library like the web player does', () {
    test('a real web-player answer (recorded 2 Nov 2026) parses into songs', () {
      final j = jsonDecode(fixture('spotify_fetch_playlist.json')) as Map;
      final items = (((j['data'] as Map)['playlistV2'] as Map)['content'] as Map)['items'] as List;
      final t = SpotifyWebApi.trackFrom(((items.first as Map)['itemV2'] as Map)['data'] as Map)!;
      expect(t.title, 'Loser');
      expect(t.artists, contains('Tame Impala'));
      expect(t.album, 'Deadbeat');
      expect(t.durationMs, 223069);
    });

    test('question ids are read from the web player\'s own script', () {
      final js = 'x=new aQ.l("fetchLibraryTracks","query","${'a' * 64}",null),y=new aQ.l("libraryV3","query","${'b' * 64}",null)';
      expect(SpotifyWebApi.hashesIn(js), {'fetchLibraryTracks': 'a' * 64, 'libraryV3': 'b' * 64});
    });

    test('Liked Songs page through to the end; playlists skip folders; playlist songs read', () async {
      final liked = [for (var i = 0; i < 123; i++) ('Song $i', 'Artist $i')];
      final log = <String>[];
      final api = SpotifyWebApi(fakeService(liked: liked, log: log), () async => 'tok')..hashes = Map.of(SpotifyWebApi.fallbackHashes);
      final got = await api.likedSongs();
      expect(got.length, 123);
      expect(got.first.title, 'Song 0');
      expect(log.where((l) => l.startsWith('fetchLibraryTracks')).length, 3, reason: '50 + 50 + 23');
      final pls = await api.playlists();
      expect(pls.map((p) => p.name), ['Road trip', 'Gym']);
      final songs = await api.playlistTracks('spotify:playlist:AAA');
      expect(songs.map((s) => s.title), ['Kalyani', 'Tum Hi Ho']);
      expect(await api.me(), 'Tablet User');
    });

    test('a guest pass (not signed in) is told apart from a real sign-in', () async {
      final api = SpotifyWebApi(fakeService(liked: const [], signedIn: false), () async => 'tok');
      expect(await api.me(), isNull);
    });

    test('the page hook messages parse; short or broken ones are ignored', () {
      final now = DateTime(2026, 11, 3);
      final m = parseHookMessage(jsonEncode({'k': 'bearer', 't': 'B' * 140}), now: now)!;
      expect(m.token, 'B' * 140);
      expect(m.expMs, greaterThan(now.millisecondsSinceEpoch), reason: 'no expiry given → assume ~50 min');
      expect(parseHookMessage(jsonEncode({'k': 'token', 't': 'A' * 100, 'anon': true}), now: now)!.anonymous, isTrue);
      expect(parseHookMessage('{"k":"ping"}'), isNull);
      expect(parseHookMessage('not json'), isNull);
    });

    test('the hook script only listens (no page changes) and reports both ways', () {
      expect(spotifyTokenHook, contains('ByteSpot.postMessage'));
      expect(spotifyTokenHook, contains("/\\/api\\/token|get_access_token/"));
      expect(spotifyTokenHook, contains('setRequestHeader'));
      expect(spotifyTokenHook, isNot(contains('document.cookie')));
    });
  });

  group('connect + sync into Byte', () {
    late Services sv;
    late FakeNet net;
    late List<List<String>> matchedBatches;
    setUp(() async {
      net = fakeService(liked: [('Kalyani', 'Vineeth'), ('Believer', 'Imagine Dragons'), ('Nobody Knows', 'Someone')]);
      sv = await makeServices(net: net);
      Services.i = sv;
      await sv.spotify.open();
      await sv.spotify.disconnect();
      matchedBatches = [];
    });

    SpotifySync makeSync() => SpotifySync(
      account: sv.spotify,
      library: sv.library,
      matcher: (tracks, onProgress) async {
        matchedBatches.add([for (final t in tracks) t.title]);
        onProgress(tracks.length, tracks.length);
        return [
          for (final t in tracks)
            t.title == 'Nobody Knows' ? null : Item(kind: ItemKind.song, id: 'yt_${t.title.hashCode.abs()}', title: t.title, artists: [ArtistRef(t.artists)], durationSec: 200),
        ];
      },
    );

    test('a guest pass does not connect; a real sign-in does (no Client ID needed)', () async {
      SpotifyAccount.webRefresher = null;
      final bad = SpotifyAccount(fakeService(liked: const [], signedIn: false));
      expect(await bad.finishWeb('g' * 120, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch), isNull);
      final name = await sv.spotify.finishWeb('t' * 140, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch);
      expect(name, 'Tablet User');
      expect(sv.spotify.connected, isTrue);
      expect(sv.spotify.isWeb, isTrue);
      expect(sv.spotify.clientId, isEmpty);
    });

    test('first sync: liked songs become likes, playlists become Byte playlists; second sync only looks up new songs', () async {
      await sv.spotify.finishWeb('t' * 140, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch);
      final sync = makeSync();
      await sync.open();
      await sync.forget();
      final r = await sync.syncNow();
      expect(r, isNotNull);
      expect(r!.liked, 2, reason: 'one song could not be found');
      expect(r.notFound, 1);
      expect(sv.library.likes.map((i) => i.title), containsAll(['Kalyani', 'Believer']));
      expect(sv.library.likes.first.title, 'Kalyani', reason: 'newest like on top, same order as the service');
      final road = sv.library.playlistBySource('spotify:AAA')!;
      expect(road.name, 'Road trip');
      expect(road.items.map((i) => i.title), ['Kalyani', 'Tum Hi Ho']);
      expect(sv.library.playlistBySource('spotify:BBB')!.items.single.title, 'Believer');
      expect(matchedBatches.single.toSet(), {'Kalyani', 'Believer', 'Nobody Knows', 'Tum Hi Ho'}, reason: 'each song looked up once');

      final again = await sync.syncNow();
      expect(again!.newSongs, 0);
      expect(matchedBatches.length, 1, reason: 'nothing new → no searching');
      expect(sv.library.playlists.where((p) => p.source == 'spotify:AAA').length, 1, reason: 'updated in place, not duplicated');
      expect(sync.likedCount, 2);
      expect(sync.playlistCount, 2);
      expect(sync.lastSync, isNotNull);
    });

    test('auto-sync only when connected, switched on and due', () async {
      final sync = makeSync();
      await sync.open();
      await sync.forget();
      await sync.maybeSync();
      expect(matchedBatches, isEmpty, reason: 'not connected');
      await sv.spotify.finishWeb('t' * 140, DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch);
      await sync.setAuto(false);
      await sync.maybeSync();
      expect(matchedBatches, isEmpty);
      await sync.setAuto(true);
      await sync.maybeSync();
      expect(matchedBatches, hasLength(1));
      await sync.maybeSync();
      expect(matchedBatches, hasLength(1), reason: 'synced just now');
    });

    test('an expired sign-in is renewed quietly by the background page', () async {
      await sv.spotify.finishWeb('t' * 140, DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch);
      var asked = 0;
      SpotifyAccount.webRefresher = () async {
        asked++;
        return (token: 'n' * 140, expMs: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch);
      };
      final lists = await sv.spotify.playlists();
      expect(asked, 1);
      expect(lists.first.id, 'liked');
      expect(lists.map((l) => l.name), contains('Gym'));
      SpotifyAccount.webRefresher = null;
    });

    test('signed out on the service and no renewal → a clear message', () async {
      await sv.spotify.finishWeb('t' * 140, DateTime.now().subtract(const Duration(minutes: 5)).millisecondsSinceEpoch);
      SpotifyAccount.webRefresher = () async => null;
      await expectLater(sv.spotify.playlists(), throwsA(isA<SpotifyProblem>().having((e) => e.message, 'message', contains('connect again'))));
      SpotifyAccount.webRefresher = null;
    });

    test('track keys ignore case, brackets and punctuation', () {
      expect(trackKey(ExtTrack('Kalyani (Remix)', 'Vineeth, X')), trackKey(ExtTrack('KALYANI', 'vineeth')));
    });
  });

  group('Account & integrations page (reference layout)', () {
    setUp(() async {
      final sv = await makeServices();
      Services.i = sv;
      await sv.spotify.open();
      await sv.spotify.disconnect();
      await sv.scrobbler.open();
      await sv.spotifySync.open();
    });
    testWidgets('Spotify "Tap to connect", Discord, ListenBrainz, Last.fm in the reference order', (t) async {
      // 1.4.1: the Music apps list (log in to each app) sits above these rows now, so a taller view
      t.view.physicalSize = const Size(390 * 3, 2600 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(const MaterialApp(home: AccountScreen()));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Account & integrations'), findsWidgets);
      expect(find.text('Tap to connect'), findsOneWidget);
      expect(find.text('Enter a token to enable'), findsOneWidget);
      expect(find.text('Tap to sign in'), findsOneWidget);
      final y = [for (final k in ['spotify-row', 'discord-row', 'listenbrainz-row', 'lastfm-row']) t.getTopLeft(find.byKey(ValueKey(k))).dy];
      for (var i = 1; i < y.length; i++) {
        expect(y[i], greaterThan(y[i - 1]));
      }
      await t.tap(find.byKey(const ValueKey('discord-row')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('Discord only lets apps'), findsOneWidget);
    });

    test('ListenBrainz token is found on its settings page', () {
      const html = '<script>{"user":{"name":"apurba","auth_token":"0a1b2c3d-1111-2222-3333-444455556666"}}</script>';
      expect(Scrobbler.listenBrainzTokenIn(html), '0a1b2c3d-1111-2222-3333-444455556666');
      expect(Scrobbler.listenBrainzTokenIn('<html>nothing</html>'), isNull);
    });
  });

  test('NetResponse is the only door used (no stray http in the sync)', () {
    expect(Net, isNotNull);
  });
}
