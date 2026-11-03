import 'dart:convert';
import 'dart:io';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/lyrics/align.dart';
import 'package:byte/lyrics/lrc.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 1.4.1: lyrics sync, with real lyrics from the open lyrics site,
// YouTube Music's own timed lyrics and YouTube's captions.

String _f(String n) => File('test/fixtures/lyrics/$n').readAsStringSync();

void main() {
  group('Mann Ki Lagan on the 5:08 video (Apurba\'s phone recording)', () {
    final lrc308 = parseLrc(_f('mann_ki_lagan_lrclib_308.lrc'));
    final lrc292 = parseLrc(_f('mann_ki_lagan_lrclib_292.lrc'));
    final caps = json3Words(jsonDecode(_f('mann_ki_lagan_video_asr_hi.json3')));

    test('the lyrics site\'s "5:08" entry carries the 4:52 album timings', () {
      // Same first lines, same times (within 0.3 s), but labelled 16 s longer:
      // the duration label can't be trusted to mean "timed for this cut".
      for (final l in lrc308.take(14).where((l) => !l.isBreak)) {
        final near = lrc292.where((x) => x.text == l.text).map((x) => (x.startMs - l.startMs).abs()).reduce((a, b) => a < b ? a : b);
        expect(near, lessThan(300), reason: l.text);
      }
    });

    test('the video\'s own captions put the singing ~6 s after those timings; Byte moves the lyrics by it', () {
      final shift = lyricsShiftFromCaptions(lrc308, caps)!;
      expect(shift, inInclusiveRange(5600, 6500));
      // Already lined up → no second move.
      expect(lyricsShiftFromCaptions(shiftLyricLines(lrc308, shift), caps), 0);
    });

    test('at 58.4 s (the video sings the first "Lagan lagi" of the 2nd block) the right line is lit', () {
      final before = LyricsClock(lrc308);
      final after = LyricsClock(shiftLyricLines(lrc308, lyricsShiftFromCaptions(lrc308, caps)!));
      final lagan2 = lrc308.indexWhere((l) => l.startMs > 50000 && l.text.startsWith('लगन'));
      // 1.4: a repeated line further on (the highlight ran ~6 s ahead).
      expect(before.indexAt(58400), lagan2 + 1);
      expect(after.indexAt(58400), lagan2);
      expect(after.lines[after.indexAt(58400)].text, 'लगन लागी तुम से मन की लगन');
      // "Gali-gali ghume dil" is sung at 46.2 s and 52.7 s in the video
      final gali = lrc308.indexWhere((l) => l.text.startsWith('गली'));
      expect(after.indexAt(46600), gali);
      expect(after.indexAt(53000), gali + 1);
      // "Tere bin tarse nayan" at 55.6 s
      expect(after.lines[after.indexAt(56000)].text, 'तेरे बिन तरसे नयन');
    });

    test('shifts it never saw are found too (intro longer/shorter by any amount)', () {
      for (final d in [-12000, -3000, 2500, 9000, 20000]) {
        final moved = shiftLyricLines(lrc308, -d);
        expect((lyricsShiftFromCaptions(moved, caps)! - (6045 + d)).abs(), lessThan(400), reason: '$d');
      }
    });

    test('captions that have nothing to do with the song move nothing', () {
      final english = parseLrc(_f('blinding_lights_en.lrc'));
      expect(lyricsShiftFromCaptions(english, caps), anyOf(isNull, 0));
    });

    test('YouTube Music\'s own timed lyrics: read for the 4:52 song, none for the video', () {
      final timed = parseYtmTimedLyrics(jsonDecode(_f('mann_ki_lagan_ytm_timed_browse.json')))!;
      expect(timed.first.text, 'हो लागी तुम से मन की लगन');
      expect(timed.first.startMs, 25350);
      // They agree with the lyrics site's album timings to ~0.5 s.
      final gali = timed.indexWhere((l) => l.text.startsWith('गली'));
      expect((timed[gali].startMs - lrc292.firstWhere((l) => l.text.startsWith('गली')).startMs).abs(), lessThan(600));
      expect(parseYtmTimedLyrics(jsonDecode(_f('mann_ki_lagan_video_ytm_untimed_browse.json'))), isNull);
    });
  });

  test('end to end: the lyrics service lines the site\'s timings up with the video and remembers it', () async {
    const video = Item(kind: ItemKind.video, id: 'lrkaKvhRnEI', title: 'Mann Ki Lagan', artists: [ArtistRef('Rahat Fateh Ali Khan')], durationSec: 308);
    final net = FakeNet((r, b) {
      if (r.url.host == 'lrclib.net' && r.url.path == '/api/get') return jsonRes({'syncedLyrics': _f('mann_ki_lagan_lrclib_308.lrc'), 'duration': 308});
      if (r.url.path.endsWith('/player')) {
        return jsonRes({
          'captions': {
            'playerCaptionsTracklistRenderer': {
              'captionTracks': [
                {'baseUrl': 'https://www.youtube.com/api/timedtext?v=lrkaKvhRnEI&lang=hi&kind=asr', 'languageCode': 'hi', 'kind': 'asr'},
              ],
            },
          },
        });
      }
      if (r.url.path == '/api/timedtext') return jsonRes(_f('mann_ki_lagan_video_asr_hi.json3'));
      return null;
    });
    final cache = MemoryLyricsCache();
    final svc = LyricsService(net, InnerTube(net), cache: cache)
      ..order = (() => ['lrclib'])
      ..off = (() => {'kugou', 'ytm', 'ytcaptions', 'files', 'addons', 'musixmatch'});
    final l = await svc.forItem(video);
    expect(l.kind, LyricsKind.synced);
    expect(l.shiftedMs, inInclusiveRange(5600, 6500));
    expect(l.lines.first.startMs, 25550 + l.shiftedMs!);
    final again = await LyricsService(FakeNet((r, b) => throw Exception('offline')), InnerTube(net), cache: cache).forItem(video);
    expect(again.lines.first.startMs, l.lines.first.startMs);
    expect(again.shiftedMs, l.shiftedMs);
  });

  group('choosing the lyrics for the version that plays', () {
    Lyrics s(int durMs, String src) => Lyrics.synced(const [LyricLine(1000, 'a'), LyricLine(2000, 'b')], src, durationMs: durMs);
    test('timed within 2 s beats an earlier source timed for another cut', () {
      final l = pickLyrics([('lrclib', s(292000, 'Open lyrics')), ('kugou', s(307500, 'Lyrics library'))], 308);
      expect(l.source, 'Lyrics library');
    });
    test('source order decides between two that fit', () {
      expect(pickLyrics([('lrclib', s(307000, 'Open lyrics')), ('kugou', s(308200, 'Lyrics library'))], 308).source, 'Open lyrics');
    });
    test('timings for a cut 16 s off are not shown as synced: the words come without timings', () {
      final l = pickLyrics([('lrclib', s(292000, 'Open lyrics'))], 308);
      expect(l.kind, LyricsKind.plain);
      expect(l.plain, 'a\nb');
    });
    test('a plain page beats wrong timings', () {
      final l = pickLyrics([('lrclib', s(292000, 'Open lyrics')), ('ytm', Lyrics.plain('words', 'Song page'))], 308);
      expect(l.source, 'Song page');
    });
  });

  group('LRC parsing, real files', () {
    test('Hindi (Devanagari) — centiseconds', () {
      final l = parseLrc(_f('mann_ki_lagan_lrclib_308.lrc'));
      expect(l.first.startMs, 25550);
      expect(LyricsClock(l, leadMs: 0).lines[LyricsClock(l, leadMs: 0).indexAt(40400)].text, 'गली-गली घूमे दिल तुझे ढूँढे');
    });
    test('Hindi (Latin letters)', () {
      final l = parseLrc(_f('tum_hi_ho_hi.lrc'));
      final c = LyricsClock(l, leadMs: 0);
      expect(c.lines[c.indexAt(48300)].text, 'Kyun ki tum hi ho');
      expect(c.lines[c.indexAt(50700)].text, 'Ab tum hi ho');
    });
    test('Bengali', () {
      final l = parseLrc(_f('bojhena_se_bojhena_bn.lrc'));
      final c = LyricsClock(l, leadMs: 0);
      expect(c.lines[c.indexAt(88900)].text, 'বোঝে না, সে বোঝে না');
      expect(c.indexAt(80900), l.indexWhere((x) => x.startMs == 80850));
      expect(c.indexAt(80800), l.indexWhere((x) => x.startMs == 78000));
    });
    test('English, with empty break lines', () {
      final l = parseLrc(_f('blinding_lights_en.lrc'));
      final c = LyricsClock(l, leadMs: 0);
      expect(c.lines[c.indexAt(30000)].text, 'I\'ve been on my own for long enough');
      expect(c.lines[c.indexAt(37500)].isBreak, isTrue);
    });
    test('ms vs cs vs ds, [offset:] sign, several stamps on one line', () {
      final l = parseLrc('[offset:+500]\n[00:10.5]a\n[00:11.25]b\n[00:12.125]c\n[00:20.00][00:30.00]chorus\n');
      // + offset = lyrics come sooner (LRC spec)
      expect(l.map((x) => x.startMs).toList(), [10000, 10750, 11625, 19500, 29500]);
      expect(l.where((x) => x.text == 'chorus').length, 2);
      expect(parseLrc('[offset:-250]\n[00:01.00]x').first.startMs, 1250);
    });
    test('word timings follow the offset and fill in order', () {
      final l = parseLrc('[offset:100]\n[00:01.00]<00:01.00>Tum <00:01.50>hi <00:02.00>ho\n[00:03.00]next');
      expect(l.first.words!.map((w) => w.startMs).toList(), [900, 1400, 1900]);
      final c = LyricsClock(l, leadMs: 0);
      expect(c.wordFill(0, 1400), [1.0, 0.0, 0.0]);
      expect(c.wordFill(0, 1650)[1], closeTo(0.5, 0.01));
    });
    test('repeated identical lines: the lit one is picked by time, never by text', () {
      final l = parseLrc('[00:10.00]Lagan lagi\n[00:13.00]Lagan lagi\n[00:16.00]Lagan lagi\n[00:19.00]Aa ja');
      final c = LyricsClock(l, leadMs: 0);
      expect([for (final t in [10100, 13100, 16100, 18900]) c.indexAt(t)], [0, 1, 2, 2]);
    });
  });
}
