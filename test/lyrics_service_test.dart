import 'dart:convert';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/lyrics/lrc.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const song = Item(kind: ItemKind.song, id: 'fsiPzT50ZiM', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], album: 'Aashiqui 2', durationSec: 262);

void main() {
  test('synced lyrics from LRCLIB exact match', () async {
    final net = FakeNet(catalogue);
    final l = await LyricsService(net, InnerTube(net)).forItem(song);
    expect(l.kind, LyricsKind.synced);
    expect(l.lines.first.text, 'Hum tere bin ab reh nahi sakte');
    expect(l.source, 'Open lyrics');
    final get = net.log.firstWhere((r) => r.url.path == '/api/get');
    expect(get.url.queryParameters['duration'], '262');
    expect(get.headers['User-Agent'], contains('Byte'));
  });

  test('falls back to search, picks the closest duration', () async {
    final net = FakeNet((r, b) {
      if (r.url.path == '/api/get') return jsonRes({'message': 'not found'}, 404);
      if (r.url.path == '/api/search') {
        return jsonRes([
          {'duration': 180, 'syncedLyrics': '[00:01.00]wrong version'},
          {'duration': 263, 'syncedLyrics': '[00:01.00]right version'},
          {'duration': 262, 'plainLyrics': 'plain only'},
        ]);
      }
      return null;
    });
    final l = await LyricsService(net, InnerTube(net)).forItem(song);
    expect(l.lines.single.text, 'right version');
  });

  test('no LRCLIB lyrics → plain lyrics from YouTube Music → cached', () async {
    final net = FakeNet((r, b) {
      if (r.url.host == 'lrclib.net') return jsonRes(r.url.path == '/api/search' ? [] : {'message': 'nf'}, r.url.path == '/api/search' ? 200 : 404);
      return catalogue(r, b);
    });
    final svc = LyricsService(net, InnerTube(net));
    final l = await svc.forItem(song);
    expect(l.kind, LyricsKind.plain);
    expect(l.source, 'Song page');
    final calls = net.log.length;
    final again = await svc.forItem(song);
    expect(again.kind, LyricsKind.plain);
    expect(net.log.length, calls, reason: 'second time comes from the cache');
  });

  test('nothing anywhere → "no lyrics" state, offline never throws', () async {
    final net = FakeNet((r, b) => throw Exception('offline'));
    final l = await LyricsService(net, InnerTube(net)).forItem(song);
    expect(l.kind, LyricsKind.none);
  });

  test('word-synced lyrics survive the cache round trip', () async {
    final cache = MemoryLyricsCache();
    final net = FakeNet((r, b) {
      if (r.url.path == '/api/get') return jsonRes({'syncedLyrics': '[00:01.00]<00:01.00>a <00:02.00>b<00:03.00>', 'duration': 262});
      return null;
    });
    await LyricsService(net, InnerTube(net), cache: cache).forItem(song);
    final again = await LyricsService(FakeNet((r, b) => throw Exception('x')), InnerTube(net), cache: cache).forItem(song);
    expect(again.hasWordTimings, isTrue);
    expect(again.lines.first.words!.map((w) => w.endMs), [2000, 3000]);
    expect(jsonDecode(cache.read('ly2:${song.id}')!)['k'], 'synced');
  });

  test('cleanTitle / cleanArtist', () {
    expect(cleanTitle('Kesariya (From "Brahmastra")'), 'Kesariya');
    expect(cleanTitle('Shape of You [Official Video]'), 'Shape of You');
    expect(cleanTitle('Song Name - Official Lyric Video'), 'Song Name');
    expect(cleanTitle('Señorita (feat. Someone)'), 'Señorita');
    expect(cleanTitle('Plain'), 'Plain');
    expect(cleanArtist('Shashwat Sachdev, Arijit Singh & Armaan Khan'), 'Shashwat Sachdev');
  });
}
