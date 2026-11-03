
// Byte 1.4.1: logging in to each music app. The readers below were run
// against the real sites on 3 Nov 2026 (in Chromium with Byte's phone user
// agent, reading a PUBLIC list in place of "me", since there is no account
// to sign in with); these tests parse exactly what they handed back.
import 'dart:convert';
import 'dart:io';

import 'package:byte/core/models.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/data/service_library.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Map _out(String n) => jsonDecode(File('test/fixtures/readers/$n.out.json').readAsStringSync()) as Map;

void main() {
  test('every music app has a login entry with its own sign-in page', () {
    final all = libServices(region: 'IN');
    expect(all.map((s) => s.name), ['Spotify', 'YouTube Music', 'Amazon Music', 'Apple Music', 'JioSaavn', 'Gaana', 'SoundCloud', 'Deezer']);
    expect(libSpec(LibService.amazon, region: 'IN').loginUrl, startsWith('https://www.amazon.in/ap/signin'));
    expect(libSpec(LibService.amazon, region: 'IN').loginUrl, contains(Uri.encodeComponent('https://music.amazon.in/my/playlists')));
    expect(libSpec(LibService.amazon, region: 'US').readUrl, 'https://music.amazon.com/my/playlists');
    for (final s in all) {
      expect(Uri.parse(s.loginUrl).scheme, 'https');
      expect(s.note, isNotEmpty);
      if (s.mode == LibReadMode.api) {
        final js = libraryReaderScript(s.service);
        expect(js, contains('ByteLib.postMessage'));
        expect(signedInProbe(s.service), isNotNull);
      }
    }
  });

  test('Apple Music reader answer → 100 songs with artists', () {
    final snap = parseLibraryMessage(LibService.apple, _out('apple'));
    expect(snap.liked.length, 100);
    expect(snap.liked.first.title, 'Raabta');
    expect(snap.liked.first.artists, contains('Pritam'));
    expect(snap.liked.first.durationMs, greaterThan(60000));
  });

  test('Deezer reader answer → 105 songs', () {
    final snap = parseLibraryMessage(LibService.deezer, _out('deezer'));
    expect(snap.liked.length, 105);
    expect(snap.liked.every((t) => t.title.isNotEmpty && t.artists.isNotEmpty), isTrue);
  });

  test('JioSaavn reader answer → playlist with its songs', () {
    final snap = parseLibraryMessage(LibService.jiosaavn, _out('jiosaavn'));
    expect(snap.playlists.single.name, 'Trending Today');
    expect(snap.playlists.single.tracks.length, 46);
    expect(snap.playlists.single.tracks.first.artists, isNotEmpty);
  });

  test('SoundCloud reader answer → liked tracks + playlists with id-only songs filled in', () {
    final snap = parseLibraryMessage(LibService.soundcloud, _out('soundcloud'));
    expect(snap.liked.length, 199);
    expect(snap.playlists.length, 3);
    expect(snap.playlists[0].tracks.length, greaterThanOrEqualTo(45)); // of 50
    expect(snap.playlists[2].tracks.length, greaterThanOrEqualTo(300)); // of 337
  });

  test('Amazon Music page rows (read off the live page by scrolling) → 84 songs', () {
    final html = File('test/fixtures/readers/amazon_dom_rows.html').readAsStringSync();
    final snap = parseLibraryMessage(LibService.amazon, {
      'ok': true,
      'user': 'me',
      'liked': {'pages': []},
      'playlists': [
        {'id': 'p1', 'name': 'A Long Playlist', 'pages': [html]},
      ],
    });
    expect(snap.playlists.single.tracks.length, 84);
    expect(snap.playlists.single.tracks.first.title, 'Just the Way You Are');
    expect(snap.playlists.single.tracks.first.artists, 'Bruno Mars');
  });

  test('a reader that found no sign-in says so', () {
    expect(() => parseLibraryMessage(LibService.gaana, {'ok': false, 'error': 'Log in to Gaana first', 'needLogin': true}), throwsA(isA<LibProblem>().having((e) => e.needLogin, 'needLogin', isTrue)));
  });

  test('Gaana / JioSaavn shapes found anywhere in an answer', () {
    final g = gaanaTracks(jsonDecode(fixture('india/gaana_api.txt')));
    expect(g.length, 50);
    final s = saavnTracks(jsonDecode(fixture('saavn_playlist_getdetails.json')));
    expect(s.length, 46);
  });

  test('import: liked → likes, playlists → playlists, re-sync updates in place and looks up only new songs', () async {
    final env = await makeServices();
    var looked = 0;
    final sync = LibrarySync(
      library: env.library,
      matcher: (ts, p) async {
        looked += ts.length;
        return [for (final t in ts) Item(kind: ItemKind.song, id: 'yt_${t.title.hashCode}', title: t.title, artists: [ArtistRef(t.artists)])];
      },
    );
    await sync.open();
    final snap = LibSnapshot('me', const [ExtTrack('Raabta', 'Pritam'), ExtTrack('Kesariya', 'Arijit Singh')], const [
      LibPlaylist('p1', 'Road trip', [ExtTrack('Kesariya', 'Arijit Singh'), ExtTrack('Ilahi', 'Arijit Singh')]),
    ]);
    final r = await sync.importSnapshot(LibService.amazon, snap);
    expect(r.liked, 2);
    expect(looked, 3);
    expect(env.library.isLiked('yt_${'Raabta'.hashCode}'), isTrue);
    final pl = env.library.playlistBySource('amazon:p1')!;
    expect(pl.items.length, 2);
    expect(sync.connected(LibService.amazon), isTrue);
    // second sync: one new song in the playlist; only it is looked up
    await sync.importSnapshot(LibService.amazon, LibSnapshot('me', snap.liked, const [
      LibPlaylist('p1', 'Road trip', [ExtTrack('Kesariya', 'Arijit Singh'), ExtTrack('Ilahi', 'Arijit Singh'), ExtTrack('Tum Hi Ho', 'Arijit Singh')]),
    ]));
    expect(looked, 4);
    expect(env.library.playlistBySource('amazon:p1')!.items.length, 3);
    expect(env.library.playlists.where((p) => p.source == 'amazon:p1').length, 1);
    await sync.forget(LibService.amazon);
    expect(sync.connected(LibService.amazon), isFalse);
    expect(env.library.playlistBySource('amazon:p1'), isNotNull); // playlists stay
  });
}
