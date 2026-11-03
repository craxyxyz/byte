import 'package:byte/lyrics/lrc.dart';
import 'package:byte/lyrics/romanize.dart';
import 'package:byte/lyrics/script.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/now_playing.dart' show FullBleedCover;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 1.3.1: fixes from Apurba's real-phone video (KALYANI (Remix), Nov 2).

const kalyani = """
[00:44.43] ചിരിക്കല്ലെ പെണ്ണേ കല്യാണി
[00:46.01] നിന്റെ മാറത്തെ പുള്ളിയിൽ എന്നെ നീ കുടുക്കി
[00:48.61] നിന്റെ കണ്ണിലെ നിറം കണ്ട്, കയ്യിലെ വള കണ്ട്
[00:51.38] കാലിലെ കൊലുസിട്ട് എന്നെ നീ കുടുക്കി
[00:53.90] അരയിലെ അരഞ്ഞാണം അരക്കെട്ടിൽ കിടക്കുമ്പോൾ
[00:56.25] എനിക്കെന്റെ മോഹങ്ങൾ അണപൊട്ടി ഒഴുകുമ്പോൾ
[00:58.65] നോക്കല്ലെ നീ ഒരുത്തീ
""";

void main() {
  group('Hindi letters for lyrics (same words)', () {
    test('Malayalam → Devanagari, chillus and the tt / nt letter groups', () {
      expect(toDevanagari('കല്യാണി'), 'कल्याणि');
      expect(toDevanagari('കാറ്റിൻ തൂവൽ'), 'काट्टिन् तूवल्');
      expect(toDevanagari('എനിക്കെന്റെ'), 'एनिक्केन्टे');
      expect(toDevanagari('നോക്കല്ലെ നീ ഒരുത്തീ'), 'नोक्कल्ले नी ओरुत्ती');
      expect(toDevanagari('മോഹങ്ങൾ'), 'मोहङ्ङळ्');
    });
    test('Tamil, Bengali, Punjabi, Telugu, Kannada, Gujarati', () {
      expect(toDevanagari('காற்று'), 'कात्रु');
      expect(toDevanagari('ஒன்று'), 'ओन्ड्रु');
      expect(toDevanagari('আমার'), 'आमार');
      expect(toDevanagari('ਪਿਆਰ'), 'पिआर');
      expect(toDevanagari('ప్రేమ'), 'प्रेम');
      expect(toDevanagari('ಪ್ರೀತಿ'), 'प्रीति');
      expect(toDevanagari('પ્રેમ'), 'प्रेम');
    });
    test('Hindi, English, emoji and digits stay as they are', () {
      expect(toDevanagari('तुम ही हो'), 'तुम ही हो');
      expect(toDevanagari('Baby I love you ❤️'), 'Baby I love you ❤️');
      expect(toDevanagari('൧൨ ௩'), '12 3');
    });
    test('English letters, typed the casual way (no accents, Hindi drops the unsaid "a")', () {
      const cases = {
        'तुझे देखा तो ये जाना सनम': 'Tujhe dekha to ye jana sanam',
        'तुम ही हो': 'Tum hi ho',
        'आज फिर जीने की तमन्ना है': 'Aaj phir jine ki tamanna hai',
        'दिल धड़कने लगा': 'Dil dhadakne laga',
        'अपना बना ले पिया': 'Apna bana le piya',
        'ज़िंदगी': 'Zindagi',
        'मैं तेरा': 'Main tera',
        'अच्छा': 'Accha',
        'प्यार': 'Pyaar',
        'കല്യാണി': 'Kalyani',
        'എന്റെ ഖൽബിലെ': 'Ente khalbile',
        'എന്ന്': 'Ennu',
        'മഴ': 'Mazha',
        'আমি তোমায় ভালোবাসি': 'Ami tomay bhalobasi',
        'জীবন': 'Jibon',
        'ਤੇਰੇ ਬਿਨਾ': 'Tere bina',
        'కళ్యాణి': 'Kalyani',
        'காற்று': 'Katru',
        'Baby I love you': 'Baby I love you',
        'Love you कल्याणी': 'Love you kalyani',
      };
      cases.forEach((from, to) => expect(romanizeLyric(from), to, reason: from));
      for (final s in cases.values) {
        expect(s, isNot(matches(RegExp(r'[āīūṇṭḍṛś]'))));
      }
    });
    test('English letters is the default; Hindi and the song\'s own stay as choices', () async {
      final st = (await makeServices()).settings;
      expect(st.lyricsScript, 'latin');
      final hi = Lyrics.synced(const [LyricLine(0, 'तुम ही हो')], 'x');
      expect(defaultLookFor(hi, 'latin'), LyricsLook.romanized); // 1.4.4: Roman letters only (1.4.3 had both)
      expect(lyricsInLook(hi, LyricsLook.romanized).lines.first.text, 'Tum hi ho');
      final w = Lyrics.synced(const [LyricLine(0, 'तुम ही हो', [LyricWord('तुम ', 0, 300), LyricWord('ही ', 300, 600), LyricWord('हो', 600, 900)])], 'x');
      final r = romanizeLyrics(w);
      expect(r.lines.first.words!.map((x) => x.text).join(), 'Tum hi ho'); // word timing kept
      expect(r.lines.first.words!.last.endMs, 900);
      st.lyricsScript = 'hindi';
      expect(st.lyricsScript, 'hindi');
      st.lyricsScript = 'latin';
    });
    test('the default letters setting picks the look', () {
      final ml = Lyrics.synced(parseLrc(kalyani), 'x');
      final hi = Lyrics.synced(const [LyricLine(0, 'तुम ही हो')], 'x');
      final en = Lyrics.synced(const [LyricLine(0, 'Hello there')], 'x');
      expect(defaultLookFor(ml, 'hindi'), LyricsLook.hindi);
      expect(defaultLookFor(hi, 'hindi'), LyricsLook.original);
      expect(defaultLookFor(en, 'hindi'), LyricsLook.original);
      expect(defaultLookFor(ml, 'latin'), LyricsLook.romanized); // 1.4.4
      expect(defaultLookFor(ml, 'original'), LyricsLook.original);
    });
    test('Hindi letters keep every line\'s and word\'s timing', () {
      final ml = Lyrics.synced([
        ...parseLrc(kalyani),
        const LyricLine(60000, 'നീ നീ', [LyricWord('നീ ', 60000, 60400), LyricWord('നീ', 60400, 60900)]),
      ], 'Open lyrics');
      final d = lyricsInLook(ml, LyricsLook.hindi);
      expect(d.lines.length, ml.lines.length);
      for (var i = 0; i < d.lines.length; i++) {
        expect(d.lines[i].startMs, ml.lines[i].startMs);
        expect(hasOtherIndicLetters(d.lines[i].text), isFalse);
      }
      expect(d.lines.last.words!.map((w) => (w.startMs, w.endMs)), [(60000, 60400), (60400, 60900)]);
      expect(d.lines.last.words!.first.text, 'नी ');
      expect(d.source, 'Open lyrics');
    });
  });

  group('lyrics timing (real LRC from the video\'s song)', () {
    test('the line changes a little before it is sung, never after', () {
      final c = LyricsClock(parseLrc(kalyani));
      // 1.4.1: lead 300 -> 150 ms (Apurba's recording: the highlight ran early)
      expect(c.leadMs, 150);
      expect(c.lines[c.indexAt(51230)].text, startsWith('കാലിലെ'), reason: '51.38 s line shows from 51.23 s');
      expect(c.lines[c.indexAt(51220)].text, startsWith('നിന്റെ കണ്ണിലെ'));
      final e = c.lines.firstWhere((l) => l.text.startsWith('എനിക്കെന്റെ')).startMs;
      expect(c.lines[c.indexAt(e - 150)].text, startsWith('എനിക്കെന്റെ'));
      expect(c.lines[c.indexAt(e - 151)].text, isNot(startsWith('എനിക്കെന്റെ')));
      expect(c.indexAt(1000), -1);
    });
    test('LRC offset tag and two stamps on one line', () {
      final l = parseLrc('[offset:+500]\n[00:10.00][00:20.00]Hi\n[00:15.50]There');
      expect(l.map((x) => (x.startMs, x.text)), [(9500, 'Hi'), (15000, 'There'), (19500, 'Hi')]);
    });
  });

  group('full-screen cover (1.4: back up, square from the top like the reference)', () {
    test('a screen-wide square from the top on every phone shape', () {
      expect(FullBleedCover.heightFor(const Size(390, 844), 0), 390);
      expect(FullBleedCover.heightFor(const Size(390, 844), 520), 390, reason: 'no longer stretched down to the title');
      expect(FullBleedCover.heightFor(const Size(412, 915), 2000), 412);
      expect(FullBleedCover.heightFor(const Size(600, 700)), closeTo(406, 0.01), reason: 'short wide screens keep room for the controls');
    });
  });
}
