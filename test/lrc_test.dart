import 'package:byte/lyrics/lrc.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLrc', () {
    test('line-synced LRC, sorted, metadata ignored', () {
      final l = parseLrc('[ar:Someone]\n[ti:Song]\n[00:12.34]Second\n[00:01.5]First\n[01:02.123]Third\n\nno time tag line');
      expect(l.map((e) => e.text), ['First', 'Second', 'Third']);
      expect(l.map((e) => e.startMs), [1500, 12340, 62123]);
      expect(l.every((e) => e.words == null), isTrue);
    });

    test('one line with several timestamps repeats', () {
      final l = parseLrc('[00:10.00][00:30.00]Chorus\n[00:20.00]Verse');
      expect(l.map((e) => (e.startMs, e.text)), [(10000, 'Chorus'), (20000, 'Verse'), (30000, 'Chorus')]);
    });

    test('offset tag shifts lines (positive = earlier)', () {
      final l = parseLrc('[offset:+500]\n[00:10.00]A');
      expect(l.single.startMs, 9500);
    });

    test('empty timed line is an instrumental break', () {
      final l = parseLrc('[00:05.00]Hello\n[00:09.00]\n[00:20.00]World');
      expect(l[1].isBreak, isTrue);
    });

    test('enhanced LRC gives word timings', () {
      final l = parseLrc('[00:01.00]<00:01.00>Hello <00:01.50>big <00:02.00>world<00:03.00>\n[00:04.00]Next');
      final w = l.first.words!;
      expect(l.first.text, 'Hello big world');
      expect(w.map((e) => e.text.trim()), ['Hello', 'big', 'world']);
      expect(w.map((e) => (e.startMs, e.endMs)), [(1000, 1500), (1500, 2000), (2000, 3000)]);
      expect(l[1].words, isNull);
    });

    test('garbage input gives no lines', () {
      expect(parseLrc('just some text\nwithout tags'), isEmpty);
    });
  });

  group('LyricsClock', () {
    final lines = parseLrc('[00:10.00]Line one here\n[00:15.00]Two\n[00:30.00]Three is long enough');
    final c = LyricsClock(lines, leadMs: 200, trackDurationMs: 60000);

    test('active line index with lead-in', () {
      expect(c.indexAt(0), -1);
      expect(c.indexAt(9700), -1);
      expect(c.indexAt(9800), 0); // 200 ms early
      expect(c.indexAt(14000), 0);
      expect(c.indexAt(14800), 1);
      expect(c.indexAt(59000), 2);
    });

    test('line end is the next line start, last line uses track end', () {
      expect(c.lineEnd(0), 15000);
      expect(c.lineEnd(2), 60000);
    });

    test('sing duration never longer than the words need', () {
      expect(c.singDuration(1), lessThanOrEqualTo(15000 - 15000 + 1000 + 3 * 95 + 700));
      expect(c.singDuration(1), greaterThanOrEqualTo(1000));
      expect(c.singDuration(0), 5000.clamp(0, 700 + 'Line one here'.length * 95));
    });

    test('progress goes 0 → 1 across the sung part of a line', () {
      expect(c.lineProgress(0, 10000), 0);
      expect(c.lineProgress(0, 10000 + c.singDuration(0) ~/ 2), closeTo(0.5, 0.01));
      expect(c.lineProgress(0, 14999), 1);
    });

    test('estimated word fill sweeps words left to right', () {
      final mid = c.wordFill(0, 10000 + c.singDuration(0) ~/ 2);
      expect(mid.first, 1.0);
      expect(mid.last, 0.0);
      expect(c.wordFill(0, 10000).every((f) => f == 0), isTrue);
      expect(c.wordFill(0, 14999).every((f) => f == 1), isTrue);
    });

    test('real word timings drive the fill exactly', () {
      final l2 = parseLrc('[00:01.00]<00:01.00>a <00:02.00>b <00:03.00>c<00:04.00>');
      final c2 = LyricsClock(l2);
      expect(c2.wordFill(0, 1500), [0.5, 0, 0]);
      expect(c2.wordFill(0, 2500), [1, 0.5, 0]);
      expect(c2.lineProgress(0, 4000), 1);
    });

    test('long instrumental gaps are detected, short ones are not', () {
      // after line 1 is sung (~1 s) there are ~14 s until "Three"
      expect(c.breakAt(20000), isNotNull);
      expect(c.breakAt(10500), isNull); // still singing line one
      expect(c.breakAt(3000), isNotNull); // intro before the first line
    });
  });

  test('splitWords keeps spaces with words', () {
    expect(splitWords('Tum hi  ho'), ['Tum ', 'hi  ', 'ho']);
    expect(splitWords(''), isEmpty);
  });
}
