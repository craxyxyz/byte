
// Byte 1.4.1: playlist links, proven against responses captured on 3 Nov 2026
// from an Indian (Airtel, Mumbai) connection, plus share-link redirects.
import 'dart:convert';
import 'dart:typed_data';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/net.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

NetResponse _text(String s, [int status = 200, Map<String, String> h = const {}]) => NetResponse(status, h, Uint8List.fromList(utf8.encode(s)));

void main() {
  group('share links', () {
    test('every app\'s short link is recognised', () {
      for (final u in [
        'https://spotify.link/boGUtmjd1Ib',
        'https://link.deezer.com/s/34aWwWnrKRjRvnSHaDyQF',
        'https://on.soundcloud.com/7hPsww4UXmlszc9gNT',
        'https://amzn.in/d/abc',
        'https://apple.co/3xyz',
        'https://deezer.page.link/abc',
      ]) {
        expect(isShortLink(Uri.parse(u)), isTrue, reason: u);
      }
      expect(isShortLink(Uri.parse('https://www.deezer.com/en/playlist/5714603022')), isFalse);
      expect(isShortLink(Uri.parse('https://open.spotify.com/playlist/37i9dQZEVXbLZ52XmnySJg')), isFalse);
      expect(detectService('https://amzn.in/d/abc'), MusicService.amazon);
      expect(detectService('https://apple.co/3xyz'), MusicService.apple);
    });

    test('a Deezer share link is followed through its redirects (real chain shape)', () async {
      final net = FakeNet((r, _) {
        expect(r.followRedirects, isFalse);
        final u = r.url.toString();
        if (u == 'https://link.deezer.com/s/34aWwWnrKRjRvnSHaDyQF') {
          return _text('', 301, {
            'location':
                'https://link.deezer.com/?awf=x&dest=https%3A%2F%2Fwww.deezer.com%2Falbum%2F1053813382%3Fhost%3D6701046381%26utm_campaign%3Dclipboard-generic',
          });
        }
        return _text('', 404);
      });
      final out = await PlaylistReader(net, InnerTube(net)).resolveShortLink('https://link.deezer.com/s/34aWwWnrKRjRvnSHaDyQF');
      expect(out, startsWith('https://www.deezer.com/album/1053813382'));
    });

    test('a page that forwards by script gives its real link', () async {
      final net = FakeNet((r, _) => _text('<html><script>location.replace("https:\\/\\/open.spotify.com\\/playlist\\/4VxLLwRnF6c7sY6FrKWFgK?si=1")</script>'));
      final out = await PlaylistReader(net, InnerTube(net)).resolveShortLink('https://spotify.link/x');
      expect(out, 'https://open.spotify.com/playlist/4VxLLwRnF6c7sY6FrKWFgK?si=1');
    });

    test('trailing full stop of a shared sentence is not part of the link', () async {
      String? asked;
      final net = FakeNet((r, _) {
        asked = r.url.toString();
        return null;
      });
      try {
        await PlaylistReader(net, InnerTube(net)).read('Listen https://www.jiosaavn.com/s/playlist/x/best/XnX4xmatqpsGSw2I1RxdhQ__.');
      } catch (_) {}
      expect(asked, contains('token=XnX4xmatqpsGSw2I1RxdhQ__&'));
    });
  });

  group('responses captured from an Indian connection', () {
    test('Spotify embed (Top 50 India): 50 songs', () async {
      final net = FakeNet((r, _) => r.url.host == 'open.spotify.com' ? _text(fixture('india/spotify_embed.txt')) : null);
      final l = await PlaylistReader(net, InnerTube(net)).read('https://open.spotify.com/playlist/37i9dQZEVXbLZ52XmnySJg?si=abc');
      expect(l.tracks.length, 50);
      expect(l.name, 'Top 50 - India');
      expect(l.tracks.first.title, isNotEmpty);
      expect(l.tracks.first.artists, isNotEmpty);
    });

    test('JioSaavn (Trending Today): 50 songs with artists', () async {
      final net = FakeNet((r, _) => r.url.path == '/api.php' && r.url.queryParameters['p'] == '1' ? _text(fixture('india/saavn_api.txt')) : null);
      final l = await PlaylistReader(net, InnerTube(net)).read('https://www.jiosaavn.com/featured/trending-today/I3kvhipIy73uCJW60TJk1Q__');
      expect(l.tracks.length, 50);
      expect(l.tracks.every((t) => t.title.isNotEmpty && t.artists.isNotEmpty), isTrue);
    });

    test('Gaana (Hindi Top 50): 50 songs', () async {
      final net = FakeNet((r, _) => r.url.path == '/apiv2' ? _text(fixture('india/gaana_api.txt')) : null);
      final l = await PlaylistReader(net, InnerTube(net)).read('https://gaana.com/playlist/gaana-dj-hindi-top-50-1');
      expect(l.tracks.length, 50);
      expect(l.name, 'Hindi Top 50');
    });

    test('Amazon Music user playlist: 23 songs', () async {
      final net = FakeNet((r, _) => r.url.host == 'music.amazon.in' ? _text(fixture('india/amazon_user.txt')) : null);
      final l = await PlaylistReader(net, InnerTube(net)).read('https://music.amazon.in/user-playlists/6b90e13c16a7465e8cb325ccbcf26b8bi8n0?ref=dm_sh_x');
      expect(l.tracks.length, 23);
      expect(l.tracks.first.title, 'Blinding Lights');
    });
  });

  test('a stale YouTube Music sign-in falls back to a guest request', () async {
    var calls = 0;
    final net = FakeNet((r, _) {
      calls++;
      if (r.headers.containsKey('Cookie')) return jsonRes({'error': 'auth'}, 401);
      return jsonRes({'contents': {}});
    });
    final yt = InnerTube(net, session: YtSession('SAPISID=abc; __Secure-3PAPISID=abc'));
    await yt.call('search', {'query': 'x'});
    expect(calls, 2);
    expect(yt.authFailed, isTrue);
  });
}
