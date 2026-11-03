// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba): "Phone pe kabhi kabhi Byte app close ho jata hai; song off
// ho phir bhi lock screen mein show karna chahiye."
//  • uncaught errors go to a small, rotating log (Settings → About → Report a problem)
//  • a paused / finished song stays on the lock screen and notification
//    ("ready, paused", never "idle"), only Stop removes it
//  • swiping Byte away keeps a paused song (unless "Stop music on close")
//  • the last song comes back paused at its spot after Byte was closed
import 'dart:io';
import 'dart:ui';

import 'package:audio_service/audio_service.dart';
import 'package:byte/core/crash_log.dart';
import 'package:byte/core/models.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/resume_point.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/report_problem.dart';
import 'package:byte/ui/screens/settings_pages.dart' show AboutScreen;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Item s(String id, {int sec = 200}) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: sec);

void main() {
  group('crash log', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('byte_crash_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('writes an error with its time, source, version and stack; reads it back', () {
      final log = CrashLog(dir: dir.path, version: () => '1.4.5', now: () => DateTime(2026, 11, 3, 20, 5));
      expect(log.read(), isEmpty);
      log.record(StateError('the stream broke'), StackTrace.fromString('#0 play (byte_handler.dart:640)\n#1 main'), source: 'Async');
      final t = log.read();
      expect(t, contains('[2026-11-03T20:05:00.000] Async error · Byte 1.4.5'));
      expect(t, contains('Bad state: the stream broke'));
      expect(t, contains('#0 play (byte_handler.dart:640)'));
      expect(File('${dir.path}/crash_log.txt').existsSync(), isTrue, reason: 'the file Android also writes to');
      expect(log.report(), startsWith('Byte 1.4.5\n'));
    });

    test('the same error over and over is written once per 5 s', () {
      var now = DateTime(2026, 11, 3);
      final log = CrashLog(dir: dir.path, now: () => now);
      for (var k = 0; k < 50; k++) {
        log.record(Exception('frame'), null);
      }
      expect(log.count, 1);
      now = now.add(const Duration(seconds: 6));
      log.record(Exception('frame'), null);
      expect(log.count, 2);
      log.record(Exception('other'), null);
      expect(log.count, 3);
    });

    test('rotates: never more than two small files, newest kept', () {
      var n = 0;
      final log = CrashLog(dir: dir.path, maxBytes: 2000, now: () => DateTime(2026).add(Duration(seconds: 10 * n)));
      for (n = 0; n < 200; n++) {
        log.record(Exception('error number $n ${'x' * 60}'), null);
      }
      final cur = File('${dir.path}/crash_log.txt'), old = File('${dir.path}/crash_log.1.txt');
      expect(cur.lengthSync(), lessThanOrEqualTo(2000));
      expect(old.existsSync(), isTrue);
      expect(old.lengthSync(), lessThanOrEqualTo(2000));
      final t = log.read();
      expect(t, contains('error number 199'), reason: 'the newest error stays');
      expect(t, isNot(contains('error number 0 ')), reason: 'the oldest rotated out');
      expect(t.indexOf('error number 198') < t.indexOf('error number 199'), isTrue, reason: 'oldest first');
      log.clear();
      expect(log.read(), isEmpty);
      expect(cur.existsSync() || old.existsSync(), isFalse);
    });

    test('no folder (web): kept in memory, also bounded', () {
      final log = CrashLog(maxBytes: 1000);
      for (var k = 0; k < 100; k++) {
        log.record(Exception('e$k ${'y' * 40}'), null);
      }
      expect(log.read().length, lessThanOrEqualTo(1000));
      expect(log.read(), contains('e99'));
    });

    test('install: Flutter errors and uncaught async errors are recorded; async ones do not close Byte', () {
      final prevFlutter = FlutterError.onError;
      final prevPlatform = PlatformDispatcher.instance.onError;
      var shown = 0;
      FlutterError.onError = (_) => shown++;
      addTearDown(() {
        FlutterError.onError = prevFlutter;
        PlatformDispatcher.instance.onError = prevPlatform;
        CrashLog.i = null;
      });
      final log = CrashLog(dir: dir.path);
      CrashLog.install(log);
      expect(CrashLog.i, same(log));
      FlutterError.onError!(FlutterErrorDetails(exception: Exception('overflow in a row'), stack: StackTrace.current, library: 'rendering'));
      expect(shown, 1, reason: 'the old handler still runs');
      final handled = PlatformDispatcher.instance.onError!(StateError('unawaited future failed'), StackTrace.current);
      expect(handled, isTrue);
      final t = log.read();
      expect(t, contains('Flutter (rendering) error'));
      expect(t, contains('overflow in a row'));
      expect(t, contains('Async error'));
      expect(t, contains('unawaited future failed'));
    });
  });

  group('Report a problem', () {
    testWidgets('About has the row; the sheet shows the log, shares it, copies it, clears it', (t) async {
      t.view.physicalSize = const Size(390, 1800);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final dir = Directory.systemTemp.createTempSync('byte_report_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final log = CrashLog(dir: dir.path, version: () => '1.4.5');
      log.record(StateError('Android said no'), null, source: 'Async');
      CrashLog.i = log;
      addTearDown(() => CrashLog.i = null);
      String? clip;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await t.pumpWidget(const MaterialApp(home: AboutScreen()));
      await t.pump(const Duration(milliseconds: 300));
      final row = find.byKey(const ValueKey('report-problem'));
      expect(row, findsOneWidget);
      expect(find.text('Report a problem'), findsOneWidget);
      await t.pump(const Duration(seconds: 3));
      await t.ensureVisible(row);
      await t.tap(row);
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byType(ReportProblemSheet), findsOneWidget);
      expect(find.textContaining('Android said no'), findsOneWidget);
      expect(find.textContaining('1 thing went wrong'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('report-copy')));
      await t.pump();
      expect(clip, contains('Byte 1.4.5'));
      expect(clip, contains('Android said no'));

      await t.tap(find.byKey(const ValueKey('report-clear')));
      await t.pump();
      expect(log.read(), isEmpty);
      expect(find.textContaining('Nothing has gone wrong so far'), findsOneWidget);
    });

    testWidgets('Share hands the whole report to the share sheet; no share sheet → copied instead', (t) async {
      final log = CrashLog(version: () => '1.4.5')..record(Exception('boom'), null);
      String? shared;
      await t.pumpWidget(MaterialApp(home: Scaffold(body: ReportProblemSheet(log: log, share: (x) async => shared = x))));
      await t.tap(find.byKey(const ValueKey('report-share')));
      await t.pump();
      expect(shared, startsWith('Byte 1.4.5'));
      expect(shared, contains('boom'));

      String? clip;
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String?;
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await t.pumpWidget(MaterialApp(home: Scaffold(body: ReportProblemSheet(log: log, share: (x) async => throw UnsupportedError('no share')))));
      await t.tap(find.byKey(const ValueKey('report-share')));
      await t.pump();
      expect(clip, contains('boom'));
      expect(find.text('Copied, paste it in a message'), findsOneWidget);
    });
  });

  group('resume point', () {
    test('keeps a slice of the queue around the song, its spot and where it came from', () {
      final order = [for (var k = 0; k < 300; k++) s('song$k')];
      final r = ResumePoint.of(order, 150, positionMs: 61000, from: 'Liked songs')!;
      expect(r.items.length, ResumePoint.keep);
      expect(r.item.id, 'song150');
      final back = ResumePoint.decode(r.encode())!;
      expect(back.item.id, 'song150');
      expect(back.items.first.id, 'song130');
      expect(back.positionMs, 61000);
      expect(back.from, 'Liked songs');
      expect(ResumePoint.of(order, -1, positionMs: 0), isNull);
      expect(ResumePoint.decode(null), isNull);
      expect(ResumePoint.decode('not json'), isNull);
      expect(ResumePoint.decode('{"q":[],"i":0}'), isNull);
    });
  });

  group('lock screen / notification', () {
    late Services sv;
    late ByteAudioHandler p;
    final durations = <String, int>{};

    setUp(() async {
      sv = await makeServices();
      p = sv.player;
      sv.settings.autoplay = false;
      sv.settings.normalizeVolume = false;
      sv.settings.crossfadeSeconds = 0;
      sv.settings.stopOnClose = false;
      await p.setRepeatMode(AudioServiceRepeatMode.none);
      durations.clear();
      fakeAudio.durationFor = (uri) {
        final m = RegExp(r'media\.example/([^/]+)/').firstMatch(uri);
        return Duration(milliseconds: durations[m?.group(1)] ?? 200000);
      };
    });
    tearDown(() async => p.stop());

    Future<void> until(bool Function() ok, {int ms = 8000, String? why}) async {
      final end = DateTime.now().add(Duration(milliseconds: ms));
      while (!ok()) {
        if (DateTime.now().isAfter(end)) fail('timed out${why == null ? '' : ': $why'}');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }

    String? sounding() {
      for (final x in fakeAudio.players.values) {
        if (x.playing && x.state.name == 'ready') return RegExp(r'media\.example/([^/]+)/').firstMatch(x.uri ?? '')?.group(1);
      }
      return null;
    }

    test('the notification config: swipeable when paused, kept in the foreground on pause (patched service)', () {
      expect(byteAudioConfig.androidNotificationOngoing, isFalse);
      expect(byteAudioConfig.androidStopForegroundOnPause, isTrue);
      final java = File('packages/audio_service/android/src/main/java/com/ryanheise/audioservice/AudioService.java').readAsStringSync();
      expect(java, contains('PAUSED_FOREGROUND_MS'), reason: 'stays in the foreground for a while after a pause');
      expect(java, contains('foreground start refused; playing on without it'), reason: 'Android 12+ refusal is caught, not a crash');
      expect(java, contains('showPausedNotification'), reason: 'a restored paused song shows on the lock screen');
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('path: packages/audio_service'));
    });

    test('lockScreenState: paused/ended/idle with a song → ready; Stop → idle', () {
      AudioProcessingState f(AudioProcessingState x, {bool song = true, bool stopped = false, bool playing = false}) =>
          ByteAudioHandler.lockScreenState(x, hasSong: song, stopped: stopped, playing: playing);
      expect(f(AudioProcessingState.idle), AudioProcessingState.ready);
      expect(f(AudioProcessingState.completed), AudioProcessingState.ready);
      expect(f(AudioProcessingState.completed, playing: true), AudioProcessingState.completed);
      expect(f(AudioProcessingState.idle, stopped: true), AudioProcessingState.idle);
      expect(f(AudioProcessingState.idle, song: false), AudioProcessingState.idle);
      expect(f(AudioProcessingState.buffering), AudioProcessingState.buffering);
      expect(f(AudioProcessingState.error), AudioProcessingState.error);
    });

    test('Pause → ready, not playing, play button; the song stays on the lock screen', () async {
      await p.playItems([s('keepaaaaaa1'), s('keepaaaaaa2')]);
      await until(() => sounding() == 'keepaaaaaa1', why: 'plays');
      await p.pause();
      await until(() => !p.playbackState.value.playing);
      final st = p.playbackState.value;
      expect(st.processingState, AudioProcessingState.ready);
      expect(st.playing, isFalse);
      expect(st.controls.map((c) => c.action), contains(MediaAction.play));
      expect(p.mediaItem.value?.id, 'keepaaaaaa1');
    });

    test('the queue ends with nothing next → ready + paused (not "completed"/idle), song still shown', () async {
      durations['keepaaaaaa3'] = 400;
      await p.playItems([s('keepaaaaaa3', sec: 1)]);
      await until(() => sounding() == 'keepaaaaaa3', why: 'plays');
      await until(() => !p.playbackState.value.playing && sounding() == null, why: 'ends');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final st = p.playbackState.value;
      expect(st.processingState, AudioProcessingState.ready);
      expect(st.playing, isFalse);
      expect(p.mediaItem.value?.id, 'keepaaaaaa3');
      expect(p.current.value?.id, 'keepaaaaaa3');
    });

    test('Stop → idle (the notification goes); playing again brings it back', () async {
      await p.playItems([s('keepaaaaaa5')]);
      await until(() => sounding() == 'keepaaaaaa5');
      await p.stop();
      expect(p.playbackState.value.processingState, AudioProcessingState.idle);
      expect(p.playbackState.value.playing, isFalse);
      await p.playItems([s('keepaaaaaa6')]);
      await until(() => sounding() == 'keepaaaaaa6');
      expect(p.playbackState.value.processingState, AudioProcessingState.ready);
    });

    test('swiped away from recents while paused → the song stays (unless "Stop music on close" is on)', () async {
      await p.playItems([s('keepaaaaaa7')]);
      await until(() => sounding() == 'keepaaaaaa7');
      await p.pause();
      await p.onTaskRemoved();
      expect(p.playbackState.value.processingState, AudioProcessingState.ready);
      expect(p.current.value?.id, 'keepaaaaaa7');
      final r = ResumePoint.decode(sv.library.get(ByteAudioHandler.resumeKey));
      expect(r?.item.id, 'keepaaaaaa7', reason: 'saved on the way out');

      sv.settings.stopOnClose = true;
      await p.onTaskRemoved();
      expect(p.playbackState.value.processingState, AudioProcessingState.idle);
    });

    test('the resume point follows the song and its spot while playing and on pause', () async {
      await p.playItems([s('keepaaaaaa8'), s('keepaaaaaa9')], from: 'Liked songs');
      await until(() => sounding() == 'keepaaaaaa8');
      await until(() => ResumePoint.decode(sv.library.get(ByteAudioHandler.resumeKey))?.item.id == 'keepaaaaaa8', why: 'saved while playing');
      await p.seek(const Duration(seconds: 30));
      await p.pause();
      await until(() => (ResumePoint.decode(sv.library.get(ByteAudioHandler.resumeKey))?.positionMs ?? 0) >= 30000, why: 'saved on pause');
      final r = ResumePoint.decode(sv.library.get(ByteAudioHandler.resumeKey))!;
      expect(r.items.map((i) => i.id), ['keepaaaaaa8', 'keepaaaaaa9']);
      expect(r.from, 'Liked songs');
    });

    test('Byte opened again after being closed: last song back, paused at its spot, on the lock screen; Play resumes there', () async {
      await sv.library.put(
        ByteAudioHandler.resumeKey,
        ResumePoint.of([s('restaaaaaa1'), s('restaaaaaa2'), s('restaaaaaa3')], 1, positionMs: 42000, from: 'Liked songs')!.encode(),
      );
      final fresh = ByteAudioHandler(resolver: sv.resolver, yt: sv.yt, library: sv.library, settings: sv.settings);
      addTearDown(() async {
        await fresh.stop();
        await fresh.disposeAll();
      });
      expect(await fresh.restoreLast(), isTrue);
      expect(fresh.current.value?.id, 'restaaaaaa2');
      expect(fresh.mediaItem.value?.id, 'restaaaaaa2');
      expect(fresh.queueModel.playOrder.map((i) => i.id), ['restaaaaaa1', 'restaaaaaa2', 'restaaaaaa3']);
      expect(fresh.playingFrom.value, 'Liked songs');
      expect(fresh.position, const Duration(seconds: 42));
      final st = fresh.playbackState.value;
      expect(st.processingState, AudioProcessingState.ready, reason: 'paused on the lock screen, not gone');
      expect(st.playing, isFalse);
      expect(st.updatePosition, const Duration(seconds: 42));
      expect(sounding(), isNull, reason: 'nothing plays (or loads) until Play');
      expect(await fresh.restoreLast(), isFalse, reason: 'only once, and never over a song already there');

      await fresh.seek(const Duration(seconds: 50));
      expect(fresh.position, const Duration(seconds: 50));
      await fresh.play();
      await until(() => sounding() == 'restaaaaaa2', why: 'Play loads it');
      expect(fresh.position.inMilliseconds, greaterThanOrEqualTo(50000), reason: 'resumes at its spot');
    });

    test('nothing saved → nothing restored', () async {
      await sv.library.put(ByteAudioHandler.resumeKey, null);
      final fresh = ByteAudioHandler(resolver: sv.resolver, yt: sv.yt, library: sv.library, settings: sv.settings);
      addTearDown(fresh.disposeAll);
      expect(await fresh.restoreLast(), isFalse);
      expect(fresh.current.value, isNull);
      expect(fresh.playbackState.value.processingState, AudioProcessingState.idle);
    });
  });
}
