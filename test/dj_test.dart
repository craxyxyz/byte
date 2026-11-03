import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/innertube_parse.dart';
import 'package:byte/core/models.dart';
import 'package:byte/dj/dj_controller.dart';
import 'package:byte/dj/dj_lines.dart';
import 'package:byte/dj/dj_session.dart';
import 'package:byte/services.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'helpers.dart';

Item song(String id, String title, {String artist = 'Arijit Singh', int sec = 200}) =>
    Item(kind: ItemKind.song, id: id, title: title, artists: [ArtistRef(artist)], durationSec: sec);

/// YouTube Music double: radio = 10 numbered songs per seed, search = 10 per query.
class FakeYt extends InnerTube {
  final List<String> calls = [];
  bool offline = false;
  FakeYt() : super(FakeNet(catalogue));
  @override
  Future<NextInfo> next(String videoId, {String? playlistId}) async {
    calls.add('radio:$videoId');
    if (offline) throw Exception('SocketException: offline');
    return NextInfo([for (var i = 0; i < 10; i++) song('r${videoId.substring(0, 4)}$i'.padRight(11, 'x'), 'Radio $i of $videoId', artist: 'Radio Artist $i')], null, null);
  }

  @override
  Future<List<Item>> search(String query, SearchFilter filter) async {
    calls.add('search:$query');
    if (offline) throw Exception('SocketException: offline');
    final tag = query.hashCode.abs().toRadixString(36).padLeft(4, '0').substring(0, 4);
    return [for (var i = 0; i < 10; i++) song('s$tag$i'.padRight(11, 'y'), '$query #$i', artist: 'Search Artist')];
  }
}

/// 1.4.3: the DJ never speaks. Watches the old speech channel (and any
/// platform text-to-speech plugin channel) so a regression shows up as calls.
class SpeechSpy {
  final List<String> calls = [];
  static const channels = ['byte/voice', 'flutter_tts'];
  void install() {
    for (final c in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(c), (m) async {
        calls.add('$c.${m.method}');
        return true;
      });
    }
  }

  void remove() {
    for (final c in channels) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
  }
}

Future<void> addHistoryAt(Item it, DateTime at) async {
  final box = Hive.box('history');
  await box.put(it.id, jsonEncode({'item': it.toJson(), 'at': at.millisecondsSinceEpoch}));
}

void main() {
  group('DJ lines', () {
    test('every line is short, names nobody else, and fills its blanks', () {
      final bad = RegExp(r'spotify|google|youtube|apple|amazon|chatgpt|openai|claude|gemini|\bAI\b|siri|alexa', caseSensitive: false);
      for (final l in DjLines.allTemplates) {
        expect(bad.hasMatch(l), isFalse, reason: l);
        expect(l.length, lessThan(130), reason: l);
      }
      final lines = DjLines(rng: Random(1));
      final now = DateTime(2026, 11, 2, 8, 30);
      for (final m in DjMoment.values) {
        for (var i = 0; i < 6; i++) {
          final s = lines.line(m, name: 'Apurba', hinglish: i.isEven, now: now, artist: i % 3 == 0 ? null : 'Arijit Singh', vibe: 'party mode', language: 'Bangla aur Hindi');
          expect(s.contains('{'), isFalse, reason: s);
          expect(s.contains('  '), isFalse, reason: s);
          expect(s.trim(), isNotEmpty);
        }
      }
    });

    test('opening line greets by time of day and uses his name; no line twice in a row', () {
      final lines = DjLines(rng: Random(7));
      final morning = lines.line(DjMoment.favourites, name: 'Apurba', hinglish: true, now: DateTime(2026, 11, 2, 8), opening: true);
      expect(morning, contains('Apurba'));
      expect(morning.toLowerCase(), anyOf(contains('morning'), contains('subah'), contains('rise and shine')));
      final night = lines.line(DjMoment.favourites, name: 'Apurba', hinglish: false, now: DateTime(2026, 11, 2, 23, 30), opening: true);
      expect(night.toLowerCase(), anyOf(contains('night'), contains('still up')));
      String? last;
      for (var i = 0; i < 30; i++) {
        final s = lines.line(DjMoment.throwback, name: 'Apurba', hinglish: true, now: DateTime(2026, 11, 2, 20));
        expect(s, isNot(last));
        last = s;
      }
    });

    test('language profile spots Bengali and Hindi', () {
      final p = languageProfile([
        song('a', 'আমার সোনার বাংলা'),
        song('b', 'Tumi Robe Nirobe (Rabindrasangeet)'),
        song('c', 'तुम ही हो'),
        song('d', 'Shape of You', artist: 'Ed Sheeran'),
      ]);
      expect(p['Bengali'], 2);
      expect(p['Hindi'], 1);
    });
  });

  group('DJ session', () {
    late Services sv;
    late FakeYt yt;
    late DjBrain brain;
    final now = DateTime(2026, 11, 2, 21, 15);

    setUp(() async {
      sv = await makeServices();
      await sv.library.clearHistory();
      for (final l in sv.library.likes) {
        await sv.library.setLiked(l, false);
      }
      yt = FakeYt();
      brain = DjBrain(library: sv.library, stats: sv.stats, yt: yt, rng: Random(3), now: () => now, segmentSize: 6);
    });

    Future<void> fillTaste() async {
      for (var i = 0; i < 8; i++) {
        await sv.library.setLiked(song('like$i'.padRight(11, 'L'), 'Liked $i'), true);
      }
      for (var i = 0; i < 10; i++) {
        await addHistoryAt(song('rec$i'.padRight(11, 'R'), 'Recent $i'), now.subtract(Duration(hours: i)));
      }
      for (var i = 0; i < 8; i++) {
        await addHistoryAt(song('old$i'.padRight(11, 'O'), 'Purana Gaana $i'), now.subtract(Duration(days: 40 + i)));
      }
      await addHistoryAt(song('bng1'.padRight(11, 'B'), 'Ami Tomar (Bangla)', artist: 'Anupam Roy'), now.subtract(const Duration(hours: 30)));
      await addHistoryAt(song('bng2'.padRight(11, 'B'), 'Tumi Robe Nirobe', artist: 'Rabindrasangeet'), now.subtract(const Duration(hours: 31)));
      await addHistoryAt(song('bng3'.padRight(11, 'B'), 'আমি তোমার', artist: 'Shreya'), now.subtract(const Duration(hours: 32)));
    }

    test('favourites come from likes, plays and history', () async {
      await fillTaste();
      final s = (await brain.build(SegmentKind.favourites))!;
      expect(s.items, hasLength(6));
      final mine = {...sv.library.likes.map((e) => e.id), ...sv.library.history.map((e) => e.item.id)};
      expect(s.items.every((i) => mine.contains(i.id)), isTrue);
      expect(s.title, 'Your favourites');
    });

    test('"New for you" only has songs he hasn\'t heard', () async {
      await fillTaste();
      final s = (await brain.build(SegmentKind.discover))!;
      final known = brain.known();
      expect(s.items, isNotEmpty);
      expect(s.items.any((i) => known.contains(i.id)), isFalse);
      expect(yt.calls.any((c) => c.startsWith('radio:')), isTrue);
    });

    test('throwback = loved songs not played for weeks', () async {
      await fillTaste();
      final s = (await brain.build(SegmentKind.throwback))!;
      expect(s.items.every((i) => i.id.startsWith('old')), isTrue);
    });

    test('Bengali listener gets a Bengali + Hindi mix', () async {
      await fillTaste();
      expect(brain.mainLanguage(), 'Bengali');
      final s = (await brain.build(SegmentKind.language))!;
      expect(s.title, 'Bengali + Hindi mix');
      expect(s.items, hasLength(6));
      // his own Bengali songs first, then radio from one of them (+ a Hindi pick)
      expect(s.items.where((i) => i.id.startsWith('bng')), isNotEmpty);
      expect(yt.calls.any((c) => c.startsWith('radio:bng')), isTrue);
    });

    test('the running order cycles segments, never repeats a song', () async {
      await fillTaste();
      final used = <String>{};
      final kinds = <SegmentKind>[];
      for (var i = 0; i < 6; i++) {
        final s = (await brain.next(exclude: used))!;
        kinds.add(s.kind);
        for (final it in s.items) {
          expect(used.add(it.id), isTrue, reason: 'repeated ${it.id}');
        }
      }
      // v1.3: a radio show — favourites, throwbacks, new for you, and round again
      expect(kinds, [
        SegmentKind.favourites,
        SegmentKind.throwback,
        SegmentKind.discover,
        SegmentKind.favourites,
        SegmentKind.throwback,
        SegmentKind.discover,
      ]);
    });

    test('brand-new phone (no history): still builds a session from the time of day', () async {
      final s = await brain.next();
      expect(s, isNotNull);
      expect(s!.items, isNotEmpty);
    });

    test('offline: no segment, no crash', () async {
      yt.offline = true;
      expect(await brain.next(), isNull);
    });
  });

  group('DJ controller (real player; the DJ never speaks)', () {
    late Services sv;
    late FakeYt yt;
    late SpeechSpy speech;
    late DjController dj;
    late List<double> ducks;

    setUp(() async {
      sv = await makeServices();
      sv.settings.autoplay = false;
      sv.settings.verifyStreams = false;
      sv.settings.djLanguage = 'hinglish';
      sv.settings.djName = '';
      await sv.library.clearHistory();
      for (var i = 0; i < 8; i++) {
        await sv.library.setLiked(song('lk$i'.padRight(11, 'K'), 'Liked $i'), true);
      }
      yt = FakeYt();
      speech = SpeechSpy()..install();
      fakeAudio.durationFor = (_) => const Duration(seconds: 200);
      dj = DjController(
        player: sv.player,
        brain: DjBrain(library: sv.library, stats: sv.stats, yt: yt, rng: Random(5), now: () => DateTime(2026, 11, 2, 8, 40)),
        settings: sv.settings,
        now: () => DateTime(2026, 11, 2, 8, 40),
      );
      ducks = [];
      dj.addListener(() => ducks.add(sv.player.duckLevel));
    });
    tearDown(() async {
      speech.remove();
      dj.stop();
      dj.dispose();
      await sv.player.stop();
    });

    Future<void> until(bool Function() ok, {int ms = 8000}) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('timed out');
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    void expectSilent() {
      expect(speech.calls, isEmpty, reason: 'the DJ must never speak');
      expect(sv.player.duckLevel, 1.0, reason: 'no dip for speech');
      expect(ducks.every((d) => d == 1.0), isTrue, reason: 'the music never dipped: $ducks');
    }

    test('starts a session: plays the first segment, greeting only on screen, no speech, no dip', () async {
      await dj.start();
      expect(dj.active, isTrue);
      expect(dj.segments.first.kind, SegmentKind.favourites);
      expect(sv.player.current.value!.id, dj.segments.first.items.first.id);
      await until(() => dj.lastLine != null);
      expect(dj.lastLine, contains('Apurba'));
      expect(dj.lastLine!.toLowerCase(), anyOf(contains('morning'), contains('subah'), contains('rise and shine')));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expectSilent();
      // the next segment is queued behind the first
      await until(() => dj.segments.length >= 2);
      expect(sv.player.queueModel.length, greaterThan(dj.segments.first.items.length));
    });

    test('every transition (next song, pause/play, skip, next segment) stays silent', () async {
      await dj.start();
      await until(() => dj.segments.length >= 2);
      await sv.player.skipToNext();
      await sv.player.pause();
      await sv.player.play();
      final second = dj.segments[1];
      final first = dj.lastLine;
      sv.player.skipToQueueItem(sv.player.queueModel.playOrder.indexWhere((i) => i.id == second.items.first.id));
      await until(() => dj.currentSegment == 1 && dj.lastLine != first);
      expect(dj.segment!.kind, second.kind);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      expectSilent();
    });

    test('switch it up: a new vibe replaces what was coming, with its own line on screen (silent)', () async {
      await dj.start();
      await until(() => dj.lastLine != null);
      final before = dj.segment!;
      final line = dj.lastLine;
      await dj.switchItUp();
      await until(() => dj.segment != before && dj.segment!.kind == SegmentKind.vibe);
      expect(sv.player.current.value!.id, dj.segment!.items.first.id);
      await until(() => dj.lastLine != line);
      expect(djVibes.any((v) => dj.lastLine!.contains(v.spoken)), isTrue, reason: dj.lastLine);
      // nothing from the old plan is left in the queue after the new vibe
      final q = sv.player.queueModel.playOrder.skip(sv.player.queueModel.position).map((e) => e.id).toSet();
      expect(q.intersection(before.items.skip(1).map((e) => e.id).toSet()), isEmpty);
      expectSilent();
    });

    test('the app has no speech engine left (Dart, Android, iPhone)', () {
      final hits = <String>[];
      for (final dir in ['lib', 'android/app/src/main', 'ios/Runner']) {
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
          if (!RegExp(r'\.(dart|kt|java|swift|xml|m|h)$').hasMatch(f.path)) continue;
          final t = f.readAsStringSync();
          for (final w in ['TextToSpeech', 'AVSpeechSynthesizer', 'AVSpeechUtterance', "'byte/voice'", 'TTS_SERVICE', 'flutter_tts']) {
            if (t.contains(w)) hits.add('${f.path}: $w');
          }
        }
      }
      expect(hits, isEmpty);
      expect(File('pubspec.yaml').readAsStringSync(), isNot(contains('tts')));
    });

    test('playing something else ends the DJ quietly', () async {
      await dj.start();
      await sv.player.playItems([song('other00000x', 'Something else')]);
      await until(() => !dj.active);
    });

    test('no internet: a clear message, no crash', () async {
      yt.offline = true;
      await sv.library.clearHistory();
      for (final l in sv.library.likes) {
        await sv.library.setLiked(l, false);
      }
      await dj.start();
      expect(dj.active, isFalse);
      expect(dj.error, isNotNull);
    });
  });
}
