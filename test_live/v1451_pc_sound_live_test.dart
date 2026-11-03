// © 2026 Apurba Laskar
// 1.4.5.1 live sound check (real libmpv, records the sound card):
//   Linux:   XDG_RUNTIME_DIR=… flutter test test_live/v1451_pc_sound_live_test.dart
//   Windows: (CI, virtual speaker) BYTE_LEVEL_CMD="python .github/scripts/loopback_level.py"
// A level command prints the mean level (dB) of what the speaker played for
// N seconds; without one, Linux records PulseAudio's default monitor.
// • Every Audio Lab option saved ON (as on Apurba's laptop): the song is loud.
//   On Windows no filter chain reaches the player at all.
// • A player that refuses a chain turns the filters off and the song gets its
//   sound back (reloaded at the same spot).
// • Linux keeps the Audio Lab; the same speed again rewrites nothing.
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/audiolab/desktop_sound_backend.dart';
import 'package:byte/audiolab/mpv_filters.dart';
import 'package:byte_desktop_audio/byte_desktop_audio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';

final _dir = Directory.systemTemp.createTempSync('byte1451');

/// Mean level (dB) of what the speaker played for [secs] (null: no recorder).
Future<double?> level(double secs) async {
  final cmd = Platform.environment['BYTE_LEVEL_CMD'];
  try {
    if (cmd != null && cmd.isNotEmpty) {
      final parts = cmd.split(' ');
      final r = await Process.run(parts.first, [...parts.skip(1), '$secs']);
      return double.tryParse('${r.stdout}'.trim().split('\n').last.trim());
    }
    if (!Platform.isLinux) return null;
    final out = '${_dir.path}/rec_${DateTime.now().microsecondsSinceEpoch}.wav';
    final r = await Process.start('timeout', ['-k', '1', '$secs', 'parec', '-d', '@DEFAULT_MONITOR@', '--file-format=wav', out]);
    await r.exitCode;
    final a = await Process.run('ffmpeg', ['-hide_banner', '-i', out, '-af', 'volumedetect', '-f', 'null', '-']);
    final m = RegExp(r'mean_volume: (-?[\d.]+) dB').firstMatch('${a.stderr}');
    return m == null ? null : double.parse(m.group(1)!);
  } catch (_) {
    return null;
  }
}

/// 40 s of a 440 Hz tone, stereo 48 kHz 16-bit WAV.
String _tone() {
  const sr = 48000, secs = 40;
  final n = sr * secs;
  final b = ByteData(44 + n * 4);
  void s(int o, String t) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(o + i, t.codeUnitAt(i));
    }
  }
  s(0, 'RIFF');
  b.setUint32(4, 36 + n * 4, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, 2, Endian.little);
  b.setUint32(24, sr, Endian.little);
  b.setUint32(28, sr * 4, Endian.little);
  b.setUint16(32, 4, Endian.little);
  b.setUint16(34, 16, Endian.little);
  s(36, 'data');
  b.setUint32(40, n * 4, Endian.little);
  for (var i = 0; i < n; i++) {
    final v = (math.sin(2 * math.pi * 440 * i / sr) * 0.3 * 32767).round();
    b.setInt16(44 + i * 4, v, Endian.little);
    b.setInt16(46 + i * 4, v, Endian.little);
  }
  final f = File('${_dir.path}/tone.wav')..writeAsBytesSync(b.buffer.asUint8List());
  return f.path;
}

/// Every Audio Lab option on, as saved on a laptop that used 1.4.4 / 1.4.5.
Map<String, Object?> everythingOn() => {
  'eqOn': true,
  'preset': 'Bass Booster',
  'nodes': [for (final n in nodesFromBands(eqPresets['Bass Booster']!)) n.toJson()],
  'autoPre': false,
  'preamp': -3.0,
  'rvOn': true,
  'ldOn': true,
  'xfOn': true,
  'mono': true,
  'bal': -0.25,
  'f32': true,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late String song;
  setUpAll(() async {
    song = _tone();
    ByteDesktopAudio.register();
  });
  tearDown(() async {
    ByteDesktopAudio.filtersSupported = ByteDesktopAudio.defaultFiltersSupported();
    ByteDesktopAudio.filtersRejected.value = false;
    await ByteDesktopAudio.setEffects('');
  });

  Future<AudioPlayer> start({double speed = 1}) async {
    final p = AudioPlayer();
    await p.setAudioSource(AudioSource.uri(Uri.file(song)));
    await p.setVolume(1);
    await p.setSpeed(speed);
    await p.setPitch(1);
    return p;
  }

  test('every Audio Lab option saved ON (through the real Audio Lab engine): the song is loud', () async {
    expect(ByteDesktopAudio.available, isTrue, reason: 'libmpv did not load');
    final lab = AudioLab()..openForTest(everythingOn());
    final engine = AudioLabEngine(lab, backend: const DesktopSoundBackend());
    final p = await start();
    await engine.start();
    p.play();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final af = await ByteDesktopAudio.debugAf();
    if (Platform.isWindows) expect(af, isNot(contains('lavfi')), reason: 'Windows got a filter chain: $af');
    final db = await level(2);
    stdout.writeln('[sound] everything-on: ${db?.toStringAsFixed(1)} dB, af=$af, playing=${p.playing}, pos=${p.position}');
    expect(p.playing, isTrue);
    if (db != null) expect(db, greaterThan(-40), reason: 'silent: $db dB');
    if (Platform.isWindows) expect(db, isNotNull, reason: 'no recorder on Windows');
    await p.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('defaults (Audio Lab untouched), speed 1.25 then 1: the song is loud', () async {
    final p = await start(speed: 1.25);
    await p.setSpeed(1);
    p.play();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final db = await level(2);
    stdout.writeln('[sound] defaults: ${db?.toStringAsFixed(1)} dB, af=${await ByteDesktopAudio.debugAf()}');
    if (db != null) expect(db, greaterThan(-40), reason: 'silent: $db dB');
    await p.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a new song loaded while one plays keeps playing (Next / tapping a song): the speaker is loud', () async {
    // 1.4.5 desktop: the player loaded the new song paused, but the app still
    // counted it as playing and never sent play again: progress moved, silent.
    final p = await start();
    p.play();
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await p.setAudioSource(AudioSource.uri(Uri.file(song)), initialPosition: const Duration(seconds: 5));
    await p.setVolume(1);
    await p.play(); // what the app does: a no-op while just_audio counts it as playing
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final db = await level(2);
    stdout.writeln('[sound] next song while playing: ${db?.toStringAsFixed(1)} dB, playing=${p.playing}, pos=${p.position}');
    expect(p.playing, isTrue);
    if (db != null) expect(db, greaterThan(-40), reason: 'silent after loading the next song: $db dB');
    await p.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a player that refuses a chain: filters off, the song gets its sound back', () async {
    ByteDesktopAudio.filtersSupported = true; // pretend, so the chain is sent
    final p = await start();
    p.play();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await ByteDesktopAudio.setEffects('nosuchfilter=g=1,alimiter=limit=0.89');
    for (var i = 0; i < 50 && !ByteDesktopAudio.filtersRejected.value; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(ByteDesktopAudio.filtersRejected.value, isTrue, reason: "the player's failure line was not seen");
    expect(ByteDesktopAudio.filtersSupported, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final af = await ByteDesktopAudio.debugAf();
    expect(af, isNot(contains('lavfi')), reason: af);
    final db = await level(2);
    stdout.writeln('[sound] after a refused chain: ${db?.toStringAsFixed(1)} dB, af=$af, pos=${p.position}');
    expect(p.playing, isTrue);
    if (db != null) expect(db, greaterThan(-40), reason: 'silent: $db dB');
    await p.dispose();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('Linux: the Audio Lab chain runs and is audible; the same speed again rewrites nothing', () async {
    final p = await start();
    final lab = AudioLab()..openForTest({'eqOn': true, 'preset': 'Bass Booster', 'nodes': [for (final n in nodesFromBands(eqPresets['Bass Booster']!)) n.toJson()]});
    await ByteDesktopAudio.setEffects(mpvFilterGraph(lab));
    p.play();
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final af = await ByteDesktopAudio.debugAf();
    expect(af, contains('equalizer'), reason: af);
    final writes = ByteDesktopAudio.afWrites;
    for (var i = 0; i < 10; i++) {
      await p.setSpeed(1);
      await p.setPitch(1);
    }
    expect(ByteDesktopAudio.afWrites, writes, reason: 'the same speed rebuilt the sound chain');
    final db = await level(2);
    stdout.writeln('[sound] linux lab: ${db?.toStringAsFixed(1)} dB');
    if (db != null) expect(db, greaterThan(-40), reason: 'silent: $db dB');
    await p.dispose();
  }, skip: !Platform.isLinux, timeout: const Timeout(Duration(seconds: 60)));
}
