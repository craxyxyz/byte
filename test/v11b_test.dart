import 'dart:async';
import 'dart:convert';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/streams.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/data/scrobble.dart';
import 'package:byte/data/webdav.dart';
import 'package:byte/data/spotify_account.dart';
import 'package:byte/ui/screens/integrations_pages.dart';
import 'package:byte/data/settings.dart';
import 'package:byte/player/equalizer.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:byte/ui/theme.dart';
import 'package:byte/services.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'helpers.dart';

/// Byte 1.1 additions: scrobbling, your own WebDAV server, steadier matching.
void main() {
  setUpAll(() async {
    await makeServices();
  });

  group('scrobbling', () {
    late FakeNet net;
    late Scrobbler sc;
    var offline = false;
    setUp(() async {
      offline = false;
      net = FakeNet((r, body) {
        if (offline) throw Exception('SocketException: no route');
        final u = r.url.toString();
        if (u.endsWith('/1/validate-token')) {
          return r.headers['Authorization'] == 'Token good' ? jsonRes({'valid': true, 'user_name': 'apurba'}) : jsonRes({'valid': false}, 200);
        }
        if (u.endsWith('/1/submit-listens')) return jsonRes({'status': 'ok'});
        if (u.startsWith(Scrobbler.lfmApi)) {
          final p = Uri.splitQueryString(body);
          if (p['method'] == 'auth.getMobileSession') {
            return p['password'] == 'pw' ? jsonRes({'session': {'name': 'apurba_lfm', 'key': 'SK1'}}) : jsonRes({'error': 4, 'message': 'Invalid username or password'});
          }
          if (p['method'] == 'track.scrobble') return jsonRes({'scrobbles': {'@attr': {'accepted': 1}}});
          return jsonRes({'nowplaying': {}});
        }
        return null;
      });
      await Hive.deleteBoxFromDisk('scrobble_private');
      sc = Scrobbler(net);
      await sc.open();
    });

    test('Last.fm signature: sorted keys + secret, md5 (format left out)', () {
      final sig = Scrobbler.lastFmSignature({'method': 'track.scrobble', 'api_key': 'K', 'format': 'json', 'artist[0]': 'A'}, 'S');
      expect(sig, md5.convert(utf8.encode('api_keyKartist[0]Amethodtrack.scrobbleS')).toString());
    });

    test('ListenBrainz: bad token is refused, good token connects', () async {
      await expectLater(sc.connectListenBrainz('bad'), throwsA(isA<ScrobbleProblem>()));
      expect(sc.lbOn, isFalse);
      expect(await sc.connectListenBrainz(' good '), 'apurba');
      expect(sc.lbOn, isTrue);
    });

    test('Last.fm: wrong password is refused, right one keeps only the session key', () async {
      await expectLater(sc.connectLastFm(apiKey: 'K', secret: 'S', user: 'a', password: 'nope'), throwsA(isA<ScrobbleProblem>()));
      expect(await sc.connectLastFm(apiKey: 'K', secret: 'S', user: 'a', password: 'pw'), 'apurba_lfm');
      expect(sc.lfmOn, isTrue);
      final login = net.log.lastWhere((r) => utf8.decode(r.body ?? []).contains('getMobileSession'));
      final p = Uri.splitQueryString(utf8.decode(login.body!));
      expect(p['api_sig'], Scrobbler.lastFmSignature({'method': 'auth.getMobileSession', 'username': 'a', 'password': 'pw', 'api_key': 'K'}, 'S'));
      final box = await Hive.openBox('scrobble_private');
      expect(box.values.contains('pw'), isFalse, reason: 'password never stored');
    });

    test('a song counts after half of it (max 4 min), once; now playing after 5 s; nothing for short clips', () async {
      await sc.connectListenBrainz('good');
      await sc.connectLastFm(apiKey: 'K', secret: 'S', user: 'a', password: 'pw');
      net.log.clear();
      const song = Item(kind: ItemKind.song, id: 'abc', title: 'तुम ही हो', artists: [ArtistRef('अरिजीत सिंह')], album: 'Aashiqui 2', durationSec: 262);
      final t0 = DateTime(2026, 11, 2, 1, 0);
      for (var i = 0; i < 140; i++) {
        sc.tick(song, 1000, 'abc#1', t0.add(Duration(seconds: i)));
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final bodies = net.log.map((r) => utf8.decode(r.body ?? [])).toList();
      expect(bodies.where((b) => b.contains('playing_now')).length, 1);
      expect(bodies.where((b) => b.contains('updateNowPlaying')).length, 1);
      final lb = bodies.where((b) => b.contains('"listen_type":"single"')).toList();
      expect(lb.length, 1);
      final j = jsonDecode(lb.single) as Map;
      final listen = (j['payload'] as List).single as Map;
      expect(listen['listened_at'], t0.millisecondsSinceEpoch ~/ 1000);
      expect(listen['track_metadata']['track_name'], 'तुम ही हो');
      expect(listen['track_metadata']['artist_name'], 'अरिजीत सिंह');
      expect(listen['track_metadata']['additional_info']['duration_ms'], 262000);
      expect(bodies.where((b) => b.contains('track.scrobble')).length, 1);
      expect(sc.queue, isEmpty);
      // A 20-second clip never counts.
      net.log.clear();
      const clip = Item(kind: ItemKind.song, id: 'clip', title: 'Intro', artists: [ArtistRef('X')], durationSec: 20);
      for (var i = 0; i < 25; i++) {
        sc.tick(clip, 1000, 'clip#1', t0);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(net.log.where((r) => utf8.decode(r.body ?? []).contains('scrobble') || utf8.decode(r.body ?? []).contains('single')), isEmpty);
      expect(Scrobbler.thresholdMs(600), 240000);
      expect(Scrobbler.thresholdMs(null), 120000);
    });

    test('offline listens wait in the queue and go out in one batch later', () async {
      await sc.connectListenBrainz('good');
      offline = true;
      for (var i = 0; i < 3; i++) {
        await sc.add(Listen('Song $i', 'Artist', 1000 + i));
      }
      expect(sc.queue.length, 3);
      offline = false;
      net.log.clear();
      await sc.flush();
      expect(sc.queue, isEmpty);
      final b = net.log.map((r) => utf8.decode(r.body ?? [])).where((b) => b.contains('"listen_type":"import"')).single;
      expect(((jsonDecode(b) as Map)['payload'] as List).length, 3);
    });

    test('with nothing connected, nothing is sent and nothing is lost', () async {
      const song = Item(kind: ItemKind.song, id: 'q', title: 'A', artists: [ArtistRef('B')], durationSec: 100);
      for (var i = 0; i < 80; i++) {
        sc.tick(song, 1000, 'q#1', DateTime(2026));
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(net.log, isEmpty);
    });
  });

  group('your own server (WebDAV)', () {
    test('folder listing: folders first, audio files only, the folder itself left out, names decoded', () {
      final list = WebDav.parseMultistatus(davListing(Uri.parse('https://nas.local/music/')), Uri.parse('https://nas.local/music/'));
      expect(list.where((e) => e.folder).map((e) => e.name), ['Bollywood', 'Rabindrasangeet — রবীন্দ্রসঙ্গীত']);
      expect(list.where((e) => e.isAudio).length, 3);
      expect(list.any((e) => e.name == 'notes.txt' && !e.isAudio), isTrue);
      expect(list.any((e) => e.url.path == '/music/' || e.url.path == '/music'), isFalse);
    });

    test('file names become songs; the player gets your login header', () async {
      final it = WebDav.itemFor(DavEntry('01 - Arijit Singh - Tum Hi Ho.mp3', Uri.parse('https://nas.local/music/01%20-%20Arijit%20Singh%20-%20Tum%20Hi%20Ho.mp3'), false), folderName: 'Bollywood');
      expect(it.title, 'Tum Hi Ho');
      expect(it.artistLine, 'Arijit Singh');
      expect(it.isDav && it.isLocal && it.isPlayable, isTrue);
      final s = await makeServices();
      await s.webdav.connect('nas.local/music', 'me', 'secret');
      expect(s.webdav.url, 'https://nas.local/music/');
      expect(WebDav.headersFor!(Uri.parse('https://nas.local/music/x.mp3'))['Authorization'], 'Basic ${base64.encode(utf8.encode('me:secret'))}');
      expect(WebDav.headersFor!(Uri.parse('https://evil.example/x.mp3')), isEmpty, reason: 'login only goes to your own server');
    });

    test('wrong password / not WebDAV give clear messages', () async {
      final d = WebDav(FakeNet((r, b) => NetResponse(401, const {}, utf8.encode(''))));
      await d.open();
      await expectLater(d.connect('https://x/', 'a', 'b'), throwsA(isA<DavProblem>().having((e) => e.message, 'm', contains('password'))));
      final d2 = WebDav(FakeNet((r, b) => NetResponse(207, const {}, utf8.encode('<html>nope'))));
      await d2.open();
      await expectLater(d2.connect('https://x/', '', ''), throwsA(isA<DavProblem>()));
    });
  });

  group('matching', () {
    test('short search: no "(From …)" tag, only the main artist', () {
      const t = ExtTrack('Beedi (From "Omkara")', 'Sunidhi Chauhan, Sukhwinder Singh, Nachiketa Chakravorty');
      expect(t.shortQuery, 'Beedi Sunidhi Chauhan');
      expect(const ExtTrack('Kal Ho Naa Ho - Remastered 2003', 'Sonu Nigam & Shankar').shortQuery, 'Kal Ho Naa Ho Sonu Nigam');
    });

    test('Hindi / Bengali script lists match Latin titles (and not unrelated songs)', () {
      expect(romanizeIndic('तेरे बिना'), 'tere binaa');
      const hi = ExtTrack('तेरे बिना', 'ए आर रहमान');
      const right = Item(kind: ItemKind.song, id: 'a', title: 'Tere Bina', artists: [ArtistRef('A.R. Rahman'), ArtistRef('Chinmayi')], durationSec: 310);
      const wrong = Item(kind: ItemKind.song, id: 'b', title: 'Kal Ho Naa Ho', artists: [ArtistRef('Sonu Nigam')], durationSec: 321);
      expect(matchScore(hi, right), greaterThan(PlaylistMatcher.minScore));
      expect(matchScore(hi, wrong), lessThan(PlaylistMatcher.minScore));
      const bn = ExtTrack('আমার পরান যাহা চায়', 'রবীন্দ্রনাথ ঠাকুর');
      const bnRight = Item(kind: ItemKind.song, id: 'c', title: 'Amaro Porano Jaha Chay', artists: [ArtistRef('Rabindranath Tagore')]);
      expect(matchScore(bn, bnRight), greaterThan(PlaylistMatcher.minScore));
      expect(matchScore(bn, wrong), lessThan(PlaylistMatcher.minScore));
    });

    test('YouTube says "slow down" (429/403): the matcher waits and tries again instead of giving up', () async {
      var calls = 0;
      final waits = <Duration>[];
      final net = FakeNet((r, body) {
        if (r.url.path.contains('/search')) {
          calls++;
          if (calls <= 2) return NetResponse(calls == 1 ? 429 : 403, const {}, utf8.encode('Sorry'));
        }
        return catalogue(r, body);
      });
      final m = PlaylistMatcher(InnerTube(net), sleep: (d) async => waits.add(d));
      final r = await m.matchAll([const ExtTrack('Tum Hi Ho', 'Arijit Singh')]);
      expect(waits.length, greaterThanOrEqualTo(2));
      expect(r.single.failed, isFalse);
      expect(r.single.searched, isTrue);
    });

    test('offline: songs are marked "couldn\'t check" (not "not found") so they can be retried', () async {
      final net = FakeNet((r, body) => throw Exception('SocketException: Failed host lookup'));
      final m = PlaylistMatcher(InnerTube(net), sleep: (d) async {});
      final r = await m.matchAll([const ExtTrack('Tum Hi Ho', 'Arijit Singh'), const ExtTrack('Kesariya', 'Arijit Singh')]);
      expect(r.every((x) => x.failed && !x.matched), isTrue);
    });
  });

  group('iPhone equalizer', () {
    test('10 bands; presets and band moves are sent to the iPhone player', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('byte/eq'), (c) async {
        calls.add(c);
        return true;
      });
      final st = Settings();
      await st.open();
      final eq = ByteEqualizer(st, ios: true);
      expect(eq.bands.length, 10);
      await eq.setEnabled(true);
      await eq.setPreset('Bass boost');
      final last = calls.last.arguments as Map;
      expect(last['enabled'], true);
      expect((last['freqs'] as List).length, 10);
      final g = (last['gains'] as List).cast<double>();
      expect(g.first, closeTo(6, 0.01));
      expect(g.last, closeTo(0, 0.01));
      await eq.setBand(9, 5);
      expect(((calls.last.arguments as Map)['gains'] as List).last, 5.0);
      expect(st.eqPreset, 'Manual');
      await eq.setPreset('Flat');
      await eq.setEnabled(false);
      expect((calls.last.arguments as Map)['enabled'], false);
    });

    for (final w in [360.0, 390.0, 820.0]) {
      for (final dark in [false, true]) {
        testWidgets('equalizer screen with 10 bands, ${w.toInt()}px ${dark ? 'dark' : 'light'}', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(w, 800);
          addTearDown(tester.view.reset);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('byte/eq'), (c) async => true);
          await tester.runAsync(() async {
            final base = await makeServices();
            await makeServices(equalizer: ByteEqualizer(base.settings, ios: true));
          });
          Services.i.settings.eqEnabled = true;
          await tester.pumpWidget(MaterialApp(theme: ByteTheme.build(dark ? Brightness.dark : Brightness.light), home: const EqualizerScreen()));
          await tester.pump(const Duration(milliseconds: 500));
          expect(find.text('16k'), findsOneWidget);
          expect(find.text('32'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 5));
        });
      }
    }
  });

  group('Spotify login (own Client ID, PKCE)', () {
    FutureOr<NetResponse?> spotifyApi(NetRequest r, String body) {
      final u = r.url.toString();
      if (u == 'https://accounts.spotify.com/api/token') {
        final p = Uri.splitQueryString(body);
        if (p['grant_type'] == 'authorization_code' && p['code'] == 'CODE1' && (p['code_verifier'] ?? '').length >= 43) {
          return jsonRes({'access_token': 'AT1', 'refresh_token': 'RT1', 'expires_in': 3600});
        }
        if (p['grant_type'] == 'refresh_token' && p['refresh_token'] == 'RT1') return jsonRes({'access_token': 'AT2', 'expires_in': 3600});
        return jsonRes({'error': 'invalid_grant', 'error_description': 'Invalid authorization code'}, 400);
      }
      if (!u.startsWith(SpotifyAccount.api)) return catalogue(r, body);
      if (!(r.headers['Authorization'] ?? '').startsWith('Bearer AT')) return jsonRes({'error': {'status': 401}}, 401);
      if (u.endsWith('/me')) return jsonRes({'id': 'apurba', 'display_name': 'Apurba Laskar'});
      if (u.contains('/me/tracks?limit=1')) return jsonRes({'total': 3, 'items': []});
      if (u.contains('/me/tracks')) {
        return jsonRes({
          'items': [
            {'track': {'name': 'Tum Hi Ho', 'duration_ms': 262000, 'artists': [{'name': 'Arijit Singh'}], 'album': {'name': 'Aashiqui 2'}}},
            {'track': {'name': 'Kesariya', 'duration_ms': 268000, 'artists': [{'name': 'Arijit Singh'}, {'name': 'Pritam'}], 'album': {'name': 'Brahmastra'}}},
            {'track': {'name': 'An episode', 'type': 'episode'}},
          ],
          'next': null,
        });
      }
      if (u.contains('/me/playlists?limit=50')) {
        return jsonRes({
          'items': [{'id': 'P1', 'name': 'গাড়ির গান — ড্রাইভ', 'images': [], 'tracks': {'total': 150}, 'owner': {'display_name': 'Apurba Laskar'}}],
          'next': '${SpotifyAccount.api}/me/playlists?offset=50&limit=50',
        });
      }
      if (u.contains('/me/playlists?offset=50')) {
        return jsonRes({'items': [{'id': 'P2', 'name': 'Private mix', 'images': [{'url': 'https://i.scdn.co/x.jpg'}], 'tracks': {'total': 2}, 'owner': {'display_name': 'Apurba Laskar'}}], 'next': null});
      }
      if (u.contains('/playlists/P1/tracks')) {
        final off = int.tryParse(r.url.queryParameters['offset'] ?? '0') ?? 0;
        return jsonRes({
          'items': [for (var i = off; i < (off + 100).clamp(0, 150); i++) {'track': {'name': 'Song $i', 'artists': [{'name': 'A$i'}], 'duration_ms': 200000}}],
          'next': off + 100 < 150 ? '${SpotifyAccount.api}/playlists/P1/tracks?offset=${off + 100}&limit=100' : null,
        });
      }
      if (u.contains('/playlists/P2/tracks')) return jsonRes({'error': {'status': 404}}, 404);
      if (u.contains('/playlists/P2/items')) return jsonRes({'items': [{'item': {'name': 'X', 'artists': [{'name': 'Y'}]}}, {'item': {'name': 'Z', 'artists': []}}], 'next': null});
      return jsonRes({}, 404);
    }

    test('sign-in link carries a matching S256 challenge; code → tokens → your name', () async {
      await Hive.deleteBoxFromDisk('spotify_private');
      final sp = SpotifyAccount(FakeNet(spotifyApi));
      await sp.open();
      final url = sp.authorizeUrl('0123456789abcdef0123456789abcdef');
      expect(url.host, 'accounts.spotify.com');
      expect(url.queryParameters['redirect_uri'], SpotifyAccount.redirectUri);
      expect(url.queryParameters['scope'], contains('playlist-read-private'));
      final v = sp.pendingVerifier!;
      expect(url.queryParameters['code_challenge'], base64Url.encode(sha256.convert(ascii.encode(v)).bytes).replaceAll('=', ''));
      await expectLater(sp.finish(Uri.parse('byte://spotify-callback?error=access_denied')), throwsA(isA<SpotifyProblem>()));
      await sp.finish(Uri.parse('byte://spotify-callback?code=CODE1'));
      expect(sp.connected, isTrue);
      expect(sp.userName, 'Apurba Laskar');
    });

    test('Liked Songs + all playlists (paged); songs read across pages; new "items" name works too; tokens refresh', () async {
      final net = FakeNet(spotifyApi);
      final sp = SpotifyAccount(net);
      await sp.open();
      final ls = await sp.playlists();
      expect(ls.map((p) => p.name), ['Liked Songs', 'গাড়ির গান — ড্রাইভ', 'Private mix']);
      expect(ls.first.count, 3);
      final liked = await sp.read(ls.first);
      expect(liked.tracks.map((t) => t.title), ['Tum Hi Ho', 'Kesariya'], reason: 'episodes skipped');
      expect(liked.tracks[1].artists, 'Arijit Singh, Pritam');
      final big = await sp.read(ls[1]);
      expect(big.tracks.length, 150);
      expect(big.partial, isFalse);
      final p2 = await sp.read(ls[2]);
      expect(p2.tracks.length, 2);
      // Expired access token → refreshed with the refresh token.
      final box = await Hive.openBox('spotify_private');
      await box.put('exp', DateTime(2000).toIso8601String());
      await sp.playlists();
      expect(net.log.any((r) => r.url.toString().endsWith('/api/token') && utf8.decode(r.body!).contains('refresh_token')), isTrue);
      expect(net.log.last.headers['Authorization'], 'Bearer AT2');
    });

    for (final w in [360.0, 820.0]) {
      testWidgets('logged-in Spotify screen lists your playlists, ${w.toInt()}px', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(w, 800);
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          await makeServices(net: FakeNet(spotifyApi));
        });
        expect(Services.i.spotify.connected, isTrue);
        await tester.pumpWidget(MaterialApp(theme: ByteTheme.build(Brightness.light), home: const SpotifyAccountScreen()));
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(find.text('Liked Songs'), findsOneWidget);
        expect(find.text('Private mix'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 5));
      });
    }
  });

  group('stream resolver', () {
    test('a network hiccup on the first client is retried (no fall-back to a stream that stops after 1 MB)', () async {
      var playerCalls = 0;
      final net = FakeNet((r, body) {
        if (r.url.path.contains('/player')) {
          playerCalls++;
          if (playerCalls == 1) throw Exception('SocketException: Connection reset');
        }
        return catalogue(r, body);
      });
      final s = await StreamResolver(InnerTube(net), retryPause: Duration.zero).resolve('abc12345678', AudioQuality.high, probe: false);
      expect(s.client, playerClients.first.name);
      expect(playerCalls, 2);
    });

    test('an Opus stream cached for Android is not handed to the iPhone player', () async {
      final r = StreamResolver(InnerTube(FakeNet(catalogue)), retryPause: Duration.zero);
      final a = await r.resolve('abc12345678', AudioQuality.high, probe: false);
      expect(a.isOpus, isTrue);
      final i = await r.resolve('abc12345678', AudioQuality.high, preferMp4: true, probe: false);
      expect(i.isMp4, isTrue);
    });
  });
}
