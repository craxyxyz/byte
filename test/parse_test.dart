import 'dart:convert';

import 'package:byte/core/innertube_parse.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/streams.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

dynamic fx(String n) => jsonDecode(fixture('$n.json'));

void main() {
  // Fixtures are real YouTube Music responses captured on 2026-11-01.
  test('song search: title, artists, album, duration, id', () {
    final items = parseSearchItems(fx('s_songs'));
    expect(items.length, greaterThanOrEqualTo(15));
    final first = items.first;
    expect(first.kind, ItemKind.song);
    expect(first.title, isNotEmpty);
    expect(first.artists.first.name, isNotEmpty);
    expect(first.artists.first.id, startsWith('UC'));
    expect(first.album, isNotEmpty);
    expect(first.albumId, startsWith('MPRE'));
    expect(first.durationSec, inInclusiveRange(60, 900));
    expect(first.id, hasLength(11));
    expect(first.thumb, startsWith('https://'));
    expect(items.every((i) => i.isPlayable), isTrue);
  });

  test('album / artist / playlist / video searches give the right kinds', () {
    expect(parseSearchItems(fx('s_albums')).where((i) => i.kind == ItemKind.album).length, greaterThan(10));
    final artists = parseSearchItems(fx('s_artists')).where((i) => i.kind == ItemKind.artist).toList();
    expect(artists.first.title, 'Arijit Singh');
    expect(artists.first.id, startsWith('UC'));
    expect(parseSearchItems(fx('s_fplaylists')).where((i) => i.kind == ItemKind.playlist).length, greaterThan(10));
    final vids = parseSearchItems(fx('s_videos'));
    expect(vids.where((i) => i.isPlayable).length, greaterThan(10));
  });

  test('mixed "All" search: top result + typed rows', () {
    final shelves = parseShelves(fx('s_all'));
    expect(shelves.first.title, 'Top result');
    final all = parseSearchItems(fx('s_all'));
    expect(all.map((i) => i.kind).toSet(), containsAll([ItemKind.artist, ItemKind.album, ItemKind.song]));
  });

  test('home feed: shelves and a continuation', () {
    final h = parseHome(fx('home'));
    expect(h.shelves.length, greaterThanOrEqualTo(2));
    expect(h.shelves.first.items, isNotEmpty);
    expect(h.continuation, isNotNull);
  });

  test('album page: header + 12 tracks that inherit album art and name', () {
    final p = parseBrowsePage('MPREb_E4GfUXfDfhy', fx('album'));
    expect(p.kind, ItemKind.album);
    expect(p.header.title, 'Aashiqui 2');
    expect(p.header.thumb, isNotNull);
    expect(p.tracks.length, 12);
    expect(p.tracks.every((t) => t.album == 'Aashiqui 2' && t.thumb != null && t.durationSec != null), isTrue);
    expect(p.tracks.first.title, 'Tum Hi Ho');
  });

  test('long playlist: first 100 tracks + continuation, then the next page', () {
    final p = parseBrowsePage('VLPLNjIr3ro3NNdl0GFDzvr0ypQYbHsZAy_g', fx('pl_big'));
    expect(p.kind, ItemKind.playlist);
    expect(p.tracks.length, 100);
    expect(p.continuation, isNotNull);
    final (more, next) = parseTrackContinuation(fx('pl_cont'));
    expect(more.length, 100);
    expect(next, isNotNull);
    expect(more.every((t) => t.isPlayable), isTrue);
  });

  test('artist page: shelves incl. top songs', () {
    final p = parseBrowsePage('UCDxKh1gFWeYsqePvgVzmPoQ', fx('artist'));
    expect(p.kind, ItemKind.artist);
    expect(p.header.title, 'Arijit Singh');
    expect(p.shelves.any((s) => s.isSongList), isTrue);
    expect(p.shelves.any((s) => s.items.any((i) => i.kind == ItemKind.album)), isTrue);
  });

  test('up next radio + lyrics tab id', () {
    final n = parseNext(fx('next'));
    expect(n.queue.length, greaterThanOrEqualTo(40));
    expect(n.queue.first.durationSec, isNotNull);
    expect(n.lyricsBrowseId, startsWith('MPLYt'));
    expect(n.relatedBrowseId, startsWith('MPTRt'));
  });

  test('plain lyrics and suggestions', () {
    expect(parsePlainLyrics(fx('lyrics_tab')), contains('\n'));
    expect(parseSuggestions(fx('suggest')), isNotEmpty);
  });

  test('broken / unknown JSON never throws', () {
    expect(parseSearchItems({'nothing': true}), isEmpty);
    expect(parseHome({}).shelves, isEmpty);
    expect(parseBrowsePage('VLx', {}).tracks, isEmpty);
    expect(parseNext([]).queue, isEmpty);
    expect(parseResponsiveItem({'flexColumns': []}), isNull);
    expect(parseTwoRowItem(42), isNull);
  });

  test('durations', () {
    expect(parseDuration('4:22'), 262);
    expect(parseDuration('1:02:03'), 3723);
    expect(parseDuration('2023'), isNull);
    expect(parseDuration('1.2B plays'), isNull);
  });

  test('thumbnail resize', () {
    expect(resizeThumb('https://lh3.googleusercontent.com/abc=w60-h60-l90-rj', 544), 'https://lh3.googleusercontent.com/abc=w544-h544-l90-rj');
    // 16:9 frames without the black bars (the centre is cropped square on screen)
    expect(resizeThumb('https://i.ytimg.com/vi/x/sddefault.jpg?sqp=1', 544), 'https://i.ytimg.com/vi/x/hq720.jpg');
    expect(resizeThumb('https://i.ytimg.com/vi/x/hqdefault.jpg', 226), 'https://i.ytimg.com/vi/x/mqdefault.jpg');
    expect(isLetterboxedThumb('https://i.ytimg.com/vi/x/hqdefault.jpg'), isTrue);
    expect(isLetterboxedThumb('https://i.ytimg.com/vi/x/hq720.jpg'), isFalse);
    expect(ytThumbVariant('https://i.ytimg.com/vi/x/hq720.jpg', 'hqdefault'), 'https://i.ytimg.com/vi/x/hqdefault.jpg');
    expect(resizeThumb(null, 10), isNull);
  });

  group('audio stream choice', () {
    final p = fakePlayer('abc');
    test('high = best audio, low = smallest, normal ≤ 140 kbps', () {
      expect(pickAudioStream(p, AudioQuality.high)!.itag, 251);
      expect(pickAudioStream(p, AudioQuality.low)!.itag, 249);
      expect(pickAudioStream(p, AudioQuality.normal)!.itag, 140);
    });
    test('iPhone gets AAC (no Opus there)', () {
      final s = pickAudioStream(p, AudioQuality.high, preferMp4: true)!;
      expect(s.itag, 140);
      expect(s.extension, 'm4a');
    });
    test('expiry read from the link; no audio = null', () {
      final s = pickAudioStream(p, AudioQuality.high)!;
      expect(s.expiresAt.year, 2100);
      expect(s.loudnessDb, 3.0);
      expect(
        pickAudioStream({
          'streamingData': {'adaptiveFormats': []},
        }, AudioQuality.high),
        isNull,
      );
    });
  });

  test('Item JSON round trip', () {
    const it = Item(
      kind: ItemKind.song,
      id: 'abc',
      title: 'T',
      artists: [ArtistRef('A', 'UC1')],
      album: 'Al',
      albumId: 'MP',
      durationSec: 10,
      thumb: 'x',
      explicit: true,
    );
    final back = Item.decode(it.encode());
    expect(back, it);
    expect(back.artists.single, const ArtistRef('A', 'UC1'));
    expect(back.durationSec, 10);
    expect(back.explicit, isTrue);
  });
}
