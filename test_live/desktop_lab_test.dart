// © 2026 Apurba Laskar
// 1.4.5: the Audio Lab on a real libmpv (Windows/Linux player): the filter
// chain is accepted, survives speed / pitch changes, and the song still plays.
//   BYTE_MPV_AO=null flutter test test_live/desktop_lab_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';

import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/audiolab/mpv_filters.dart';
import 'package:byte_desktop_audio/byte_desktop_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final dir = Directory.systemTemp.createTempSync('byte_desktop_lab');
  final song = '${dir.path}/tone.mp3';

  setUpAll(() async {
    final r = await Process.run('ffmpeg', ['-v', 'error', '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=8', '-c:a', 'libmp3lame', song]);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    ByteDesktopAudio.register();
  });

  test('equalizer + balance + mono + loudness + reverb + crossfeed run on the player, through speed and pitch changes', () async {
    expect(ByteDesktopAudio.available, isTrue, reason: 'libmpv did not load');
    final lab = AudioLab()..openForTest({
      'eqOn': true, 'preset': 'Bass Booster', 'nodes': [for (final n in nodesFromBands(eqPresets['Bass Booster']!)) n.toJson()],
      'rvOn': true, 'ldOn': true, 'xfOn': true, 'mono': true, 'bal': -0.25,
    });
    final graph = mpvFilterGraph(lab);
    final p = AudioPlayer();
    await p.setAudioSource(AudioSource.uri(Uri.file(song)));
    await ByteDesktopAudio.setEffects(graph);
    p.play();
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    var af = await ByteDesktopAudio.debugAf();
    expect(af, contains('lavfi'), reason: 'player reports: $af');
    expect(af, contains('equalizer'));
    expect(p.playing, isTrue);
    final at = p.position;
    expect(at.inMilliseconds, greaterThan(400), reason: 'sound keeps flowing through the filters');
    await p.setSpeed(1.25);
    await p.setPitch(0.9);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    af = await ByteDesktopAudio.debugAf();
    expect(af, contains('scaletempo'), reason: 'speed/pitch kept: $af');
    expect(af, contains('lavfi'), reason: 'Audio Lab kept after a speed change: $af');
    expect(p.position > at, isTrue);
    await ByteDesktopAudio.setEffects('');
    af = await ByteDesktopAudio.debugAf();
    expect(af, isNot(contains('lavfi')), reason: 'turned off: $af');
    await p.dispose();
  }, timeout: const Timeout(Duration(seconds: 40)));
}
