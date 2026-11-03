// © 2026 Apurba Laskar
// Windows/Linux audio backend, end to end on a real libmpv:
//   flutter test test_live/desktop_audio_test.dart      (Linux: needs libmpv2 + ffmpeg;
//   on a machine with no sound card: BYTE_MPV_AO=null flutter test …)
import 'dart:io';

import 'package:byte_desktop_audio/byte_desktop_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Directory.systemTemp.createTempSync('byte_desktop_audio');
  final song = '${dir.path}/tone.mp3';

  setUpAll(() async {
    final r = await Process.run('ffmpeg', ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=6', '-c:a', 'libmp3lame', song]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    ByteDesktopAudio.register();
  });

  test('loads, plays, seeks, pauses and completes', () async {
    expect(ByteDesktopAudio.available, isTrue, reason: 'libmpv did not load');
    final p = AudioPlayer();
    final d = await p.setAudioSource(AudioSource.uri(Uri.file(song)));
    expect(d, isNotNull);
    expect(d!.inMilliseconds, inInclusiveRange(5800, 6300));
    await p.setVolume(0.5);
    p.play();
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(p.playing, isTrue);
    expect(p.position.inMilliseconds, greaterThan(500));
    await p.seek(const Duration(seconds: 4));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(p.position.inMilliseconds, greaterThanOrEqualTo(4000));
    await p.pause();
    final at = p.position;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect((p.position - at).inMilliseconds.abs(), lessThan(150));
    p.play();
    await p.processingStateStream.firstWhere((s) => s == ProcessingState.completed).timeout(const Duration(seconds: 8));
    await p.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('a missing file is an error, not a hang', () async {
    final p = AudioPlayer();
    await expectLater(p.setAudioSource(AudioSource.uri(Uri.file('${dir.path}/nope.mp3'))), throwsA(anything));
    await p.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));
}
