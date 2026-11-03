// Byte © 2026 Apurba Laskar.
// 1.4.3 dual lyrics (Apurba, "Jo Tu Na Mila"): lyrics in another script show
// the original and the SAME words in Roman letters, line by line, word by
// word, on one clock. Real lyrics from lrclib in test/fixtures/dual.
import 'dart:io';

import 'package:byte/core/models.dart';
import 'package:byte/lyrics/dual.dart';
import 'package:byte/lyrics/lrc.dart';
import 'package:byte/lyrics/urdu_roman.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

String _fx(String f) => File('test/fixtures/dual/$f').readAsStringSync();
Lyrics _synced(String f) => Lyrics.synced(parseLrc(_fx(f)), 'Open lyrics');

/// Nukta letters typed either way (क़ / क + ़, ড় / ড + ়) compare alike.
String _norm(String s) {
  const base = {0x0958: 0x0915, 0x0959: 0x0916, 0x095A: 0x0917, 0x095B: 0x091C, 0x095C: 0x0921, 0x095D: 0x0922, 0x095E: 0x092B, 0x095F: 0x092F, 0x09DC: 0x09A1, 0x09DD: 0x09A2, 0x09DF: 0x09AF};
  return String.fromCharCodes(s.trim().runes.where((r) => r != 0x093C && r != 0x09BC).map((r) => base[r] ?? r));
}

int _lineOf(DualLyrics d, String orig) {
  final o = d.original;
  for (var i = 0; i < o.lines.length; i++) {
    if (_norm(o.lines[i].text) == _norm(orig)) return i;
  }
  throw StateError('no line $orig');
}

/// The Roman line shown for the original line [orig] (first match).
String romanOf(DualLyrics d, String orig) => d.lines[_lineOf(d, orig)].text;

DualRoute? routeOf(DualLyrics d, String orig) => d.lines[_lineOf(d, orig)].route;

/// Both columns: the same line is active and every word fills alike.
void expectSameHighlight(DualLyrics d) {
  final o = LyricsClock(d.original.lines);
  final r = LyricsClock(d.roman.lines);
  expect(d.roman.lines.length, d.original.lines.length);
  final end = d.original.lines.last.startMs + 4000;
  for (var ms = 0; ms < end; ms += 733) {
    final i = o.indexAt(ms);
    expect(r.indexAt(ms), i, reason: 'line at $ms');
    if (i < 0 || d.original.lines[i].isBreak) continue;
    final fo = o.wordFill(i, ms), fr = r.wordFill(i, ms);
    expect(fr.length, fo.length, reason: 'words of line $i');
    for (var k = 0; k < fo.length; k++) {
      expect(fr[k], closeTo(fo[k], 0.02), reason: 'line $i word $k at $ms');
    }
  }
}

void main() {
  group('which lyrics get two columns', () {
    test('other scripts yes; English and Roman Hindi no', () {
      expect(needsDualText('مجھ سے مل پائے گا نہیں'), isTrue);
      expect(needsDualText('तुम ही हो'), isTrue);
      expect(needsDualText('বোঝে না, সে বোঝে না'), isTrue);
      expect(needsDualText('ਦੱਸ ਪੁੱਤ, ਤੇਰਾ head down ਕਾਸਤੋਂ?'), isTrue); // Punjabi with English words
      expect(needsDualText('Tum hi ho, ab tum hi ho'), isFalse);
      expect(needsDualText('Baby I love you'), isFalse);
    });
    test('1.4.4: Romanized is the default look for them (Both is a pick); English stays single', () {
      final ur = _synced('jo_tu_na_mila_ur.lrc');
      final en = Lyrics.synced(const [LyricLine(0, 'Hello there'), LyricLine(2000, 'General Kenobi')], 'x');
      final romanHindi = _synced('tum_hi_ho_roman.lrc');
      expect(defaultLookFor(ur, 'latin'), LyricsLook.romanized);
      expect(defaultLookFor(ur, 'latin', picked: 'dual'), LyricsLook.dual);
      expect(defaultLookFor(ur, 'hindi'), LyricsLook.romanized); // Urdu: no Hindi-letter look, Roman letters
      expect(defaultLookFor(ur, 'original'), LyricsLook.original); // the person can still pick
      expect(defaultLookFor(_synced('295_pa.lrc'), 'latin'), LyricsLook.romanized);
      expect(defaultLookFor(_synced('bojhena_bn.lrc'), 'latin'), LyricsLook.romanized);
      expect(defaultLookFor(en, 'latin'), LyricsLook.original);
      expect(defaultLookFor(romanHindi, 'latin'), LyricsLook.original);
    });
  });

  group('Jo Tu Na Mila (Urdu)', () {
    final ur = _synced('jo_tu_na_mila_ur.lrc');
    test('route 1: the Roman version from the lyric library, matched by words (its timings are 25 s off)', () {
      final d = buildDual(ur, versions: [_synced('jo_tu_na_mila_roman.lrc')]);
      expect(d.mainRoute, DualRoute.romanVersion);
      expect(romanOf(d, 'مجھ سے مل پائے گا نہیں'), 'Mujh se mil paayega nahin');
      expect(romanOf(d, 'دیکھوں کیوں راہیں میں تیری'), 'Dekhun kyun rahein main teri');
      expect(romanOf(d, 'کہہ دے تو آئے گا نہیں'), 'Keh de to aayega nahin');
      expect(romanOf(d, 'پیار تھا وقت نہیں جو بیت گیا دو پل میں'), 'Pyaar tha waqt nahin jo beet gaya do pal mein');
      expect(romanOf(d, 'کل تھے یہیں، کیوں اب نہیں؟'), 'Kal the yahin, kyun ab nahin?');
      expect(routeOf(d, 'مجھ سے مل پائے گا نہیں'), DualRoute.romanVersion);
      expectSameHighlight(d);
    });
    test('route 3: Byte\'s own Urdu reading when no version exists', () {
      final d = buildDual(ur);
      expect(d.mainRoute, DualRoute.urduReader);
      expect(romanOf(d, 'مجھ سے مل پائے گا نہیں'), 'Mujh se mil paaye ga nahin');
      expect(romanOf(d, 'دیکھوں کیوں راہیں میں تیری'), 'Dekhun kyun raahein main teri');
      expect(romanOf(d, 'تو بن کے یاد رہے فریاد رہے گا دل میں'), 'Tu ban ke yaad rahe faryaad rahe ga dil mein');
      expect(romanOf(d, 'ہو کے جدا یہ تو بولو'), 'Ho ke juda ye to bolo');
      expect(romanOf(d, 'کیوں دیا درد ہمیں، ہم آج تلک نہ سمجھے؟'), 'Kyun diya dard humein, hum aaj talak na samjhe?');
      expect(romanOf(d, 'دل کو کیا بتاؤں گا؟ دل کو کیا بتاؤں گا؟'), 'Dil ko kya bataoon ga? Dil ko kya bataoon ga?');
      expectSameHighlight(d);
    });
    test('a version with other words is not used', () {
      final d = buildDual(ur, versions: [Lyrics.plain('Baby I love you\nYeah yeah\nAll night long', 'x')]);
      expect(d.mainRoute, DualRoute.urduReader);
    });
    test('unknown Urdu words still read with vowels', () {
      expect(readUrduLetters('سب'), 'sab');
      expect(readUrduLetters('درد'), 'dard');
      expect(romanizeUrdu('صنم'), 'Sanam');
      expect(romanizeUrdu('میں تیرا'), 'Main tera');
      expect(romanizeUrdu('دل میں'), 'Dil mein');
    });
  });

  group('295 (Punjabi, Gurmukhi)', () {
    final pa = _synced('295_pa.lrc');
    test('route 1, English words kept, Title Case turned to sentence case', () {
      final d = buildDual(pa, versions: [_synced('295_roman.lrc')]);
      expect(d.mainRoute, DualRoute.romanVersion);
      expect(romanOf(d, 'ਕੁਛ ਤੈਨੂੰ ਫੜ ਥੱਲੇ ਲਾਉਣਾ ਚਾਹੁੰਦੇ ਨੇ'), 'Kuch tainu farh thalle launa chahunde ne');
      expect(romanOf(d, 'ਦੱਸ ਪੁੱਤ, ਤੇਰਾ head down ਕਾਸਤੋਂ?'), 'Das putt, tera head down kaston?');
      expect(romanOf(d, 'ਨਾਮ ਲੈਕੇ ਤੇਰਾ ਅੱਗੇ ਆਉਣਾ ਚਾਹੁੰਦੇ ਨੇ'), 'Naam laike tera agge auna chahunde ne');
      expect(romanOf(d, 'ਹੋ, ਜਿਨ੍ਹਾਂ ਦੇ ਜਵਾਕਾਂ ਦੇ ਨਾਂ John ਤੇ Steve ਆਂ'), startsWith('Ho, '));
      expectSameHighlight(d);
    });
  });

  group('Bojhena Shey Bojhena (Bengali)', () {
    final bn = _synced('bojhena_bn.lrc');
    test('route 2: the library\'s "Roman" version has other words, so Bengali rules read it', () {
      final d = buildDual(bn, versions: [Lyrics.plain(_fx('bojhena_roman_wrong.txt'), 'Open lyrics')]);
      expect(d.mainRoute, DualRoute.scriptRules);
      expect(romanOf(d, 'বোঝে না, সে বোঝে না'), 'Bojhe na, se bojhe na');
      expect(romanOf(d, 'তাকে আটকে রাখার চেষ্টা'), 'Take atke rakhar cheshta');
      expect(romanOf(d, 'তবু দেখতে দেখতে কাটছি'), 'Tobu dekhte dekhte katchhi');
      expect(romanOf(d, 'আরও বাড়িয়ে দিচ্ছে তেষ্টা'), contains('bariye')); // ড় is "r"
      expectSameHighlight(d);
    });
  });

  group('Tum Hi Ho (Hindi, Devanagari)', () {
    final hi = _synced('tum_hi_ho_hi.lrc');
    test('route 1 from the Roman version', () {
      final d = buildDual(hi, versions: [_synced('tum_hi_ho_roman.lrc')]);
      expect(d.mainRoute, DualRoute.romanVersion);
      expect(romanOf(d, 'तेरे बिना क्या वजूद मेरा?'), 'Tere bina kya wajood mera?');
      expect(romanOf(d, 'मेरी आशिक़ी अब तुम ही हो'), 'Meri aashiqui ab tum hi ho');
      expect(romanOf(d, 'तुझसे जुदा अगर हो जाएँगे'), 'Tujh se juda agar ho jaayenge');
      expect(romanOf(d, 'हम तेरे बिन अब रह नहीं सकते'), 'Hum tere bin ab reh nahi sakte');
      expectSameHighlight(d);
    });
    test('route 2 without one: Hindi rules, typed spellings', () {
      final d = buildDual(hi);
      expect(romanOf(d, 'हम तेरे बिन अब रह नहीं सकते'), 'Hum tere bin ab rah nahin sakte');
      expect(romanOf(d, 'चैन भी, मेरा दर्द भी'), 'Chain bhi, mera dard bhi');
      expect(romanOf(d, 'मेरी आशिक़ी अब तुम ही हो'), 'Meri aashiqi ab tum hi ho');
    });
    test('a Devanagari version gives an Urdu song its Roman side (route 2)', () {
      final ur = Lyrics.synced(const [LyricLine(0, 'دل کو کیا بتاؤں گا'), LyricLine(4000, 'سوچا کہوں گا ایک دن')], 'x');
      final deva = Lyrics.synced(const [LyricLine(9000, 'सोचा कहूँगा एक दिन'), LyricLine(1000, 'दिल को क्या बताऊंगा')], 'x');
      final d = buildDual(ur, versions: [deva]);
      expect(d.lines.first.route, DualRoute.devanagariVersion);
      expect(d.lines.first.text, startsWith('Dil ko kya'));
    });
  });

  test('word timings of the original carry to the Roman words', () {
    final o = Lyrics.synced(const [
      LyricLine(1000, 'مجھ سے مل', [LyricWord('مجھ ', 1000, 1400), LyricWord('سے ', 1400, 1700), LyricWord('مل', 1700, 2300)]),
      LyricLine(3000, 'نہیں'),
    ], 'x');
    final d = buildDual(o);
    expect(d.roman.lines.first.words!.map((w) => (w.text, w.startMs, w.endMs)), [('Mujh ', 1000, 1400), ('se ', 1400, 1700), ('mil', 1700, 2300)]);
    expectSameHighlight(d);
  });

  group('on screen', () {
    late Services sv;
    setUpAll(() async {
      sv = await makeServices();
    });

    Future<void> pumpView(WidgetTester tester, Size size, DualLyrics d) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.black,
          body: SyncedLyricsView(lyrics: d.original, roman: d.roman, now: () => 149800, onSeek: (_) {}),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 600));
    }

    testWidgets('phone: Roman over the original, both lines there; tablet: two columns', (tester) async {
      expect(sv.settings.lyricsScript, 'latin');
      final d = buildDual(_synced('jo_tu_na_mila_ur.lrc'), versions: [_synced('jo_tu_na_mila_roman.lrc')]);
      await pumpView(tester, const Size(390, 844), d);
      expect(find.byKey(const ValueKey('dual-stack0')), findsOneWidget);
      expect(find.byKey(const ValueKey('dual-cols0')), findsNothing);
      expect(find.text('Kal the yahin, kyun ab nahin?'), findsOneWidget);
      expect(find.text('کل تھے یہیں، کیوں اب نہیں؟'), findsOneWidget);
      await pumpView(tester, const Size(1280, 800), d);
      expect(find.byKey(const ValueKey('dual-cols0')), findsOneWidget);
      // left column Roman, right column the original
      final roman = tester.getCenter(find.text('Kal the yahin, kyun ab nahin?'));
      final urdu = tester.getCenter(find.text('کل تھے یہیں، کیوں اب نہیں؟'));
      expect(roman.dx, lessThan(urdu.dx));
      await tester.pumpWidget(const SizedBox());
    });

    test('the lyric library\'s Roman version is found and used (dualFor)', () async {
      final s = await makeServices(
        net: FakeNet((r, body) {
          final u = r.url.toString();
          if (u.contains('lrclib.net/api/search')) {
            return jsonRes([
              {'id': 1, 'trackName': 'Jo Tu Na Mila', 'artistName': 'Asim Azhar', 'duration': 234, 'syncedLyrics': _fx('jo_tu_na_mila_ur.lrc')},
              {'id': 2, 'trackName': 'Jo Tu Na Mila', 'artistName': 'Asim Azhar & Kunaal Verma', 'duration': 234, 'syncedLyrics': _fx('jo_tu_na_mila_roman.lrc')},
            ]);
          }
          return jsonRes({}, 404);
        }),
      );
      const song = Item(kind: ItemKind.song, id: 'jtnm1', title: 'Jo Tu Na Mila', artists: [ArtistRef('Asim Azhar')], durationSec: 234);
      final d = await s.lyrics.dualFor(song, _synced('jo_tu_na_mila_ur.lrc'));
      expect(d.mainRoute, DualRoute.romanVersion);
      expect(romanOf(d, 'مجھ سے مل پائے گا نہیں'), 'Mujh se mil paayega nahin');
    });
  });
}
