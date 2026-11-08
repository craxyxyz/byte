// Byte © 2026 Apurba Laskar.
//
// 2.0.9 runner check for Byte's own sound engine on Windows: a generated WAV
// goes through the same decode and sound chain the app uses. Asserts the
// measured gain of an equalizer point (the numbers, not a listening test),
// the engine's open / ready / duration path, and what the runner cannot show
// (no audio output device on the runner: recorded as written, not as a pass).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:byte/audiolab/audio_lab.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _ch = MethodChannel('byte/desktop_audio');

Uint8List _wav(double hz, double seconds, double amp) {
  const rate = 48000, chans = 2;
  final frames = (rate * seconds).round();
  final data = ByteData(44 + frames * chans * 2);
  void s(int o, String t) {
    for (var i = 0; i < 4; i++) {
      data.setUint8(o + i, t.codeUnitAt(i));
    }
  }

  s(0, 'RIFF');
  data.setUint32(4, 36 + frames * chans * 2, Endian.little);
  s(8, 'WAVE');
  s(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, chans, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * chans * 2, Endian.little);
  data.setUint16(32, chans * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  s(36, 'data');
  data.setUint32(40, frames * chans * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    final v = (amp * math.sin(2 * math.pi * hz * i / rate) * 32767).round();
    for (var c = 0; c < chans; c++) {
      data.setInt16(44 + (i * chans + c) * 2, v, Endian.little);
    }
  }
  return data.buffer.asUint8List();
}

Map<String, Object?> _chain({List<List<double>> eq = const [], bool mono = false}) => {
      'inputGainDb': 0.0,
      'eqOn': eq.isNotEmpty,
      'eq': eq,
      'reverbOn': false,
      'rvWet': 0.0,
      'rvDry': 1.0,
      'rvSize': 0.5,
      'rvDamping': 0.5,
      'rvWidth': 1.0,
      'rvPreDelayMs': 0.0,
      'crossfeedOn': false,
      'xfStrength': 0.0,
      'xfHz': 700.0,
      'mono': mono,
      'balance': 0.0,
      'compressorOn': false,
      'thresholdDb': -6.0,
      'ratio': 1.0,
      'limiterOn': false,
      'limit': 0.89,
    };

final _lines = <String>[];
void _note(String s) {
  _lines.add(s);
  // ignore: avoid_print
  print('AUDIO-CHECK $s');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows sound engine: decode, equalizer gain, open and ready, overlay', (tester) async {
    final dir = Platform.environment['BYTE_AUDIO_DIR'] ?? Directory.systemTemp.path;
    Directory(dir).createSync(recursive: true);
    final path = '$dir${Platform.pathSeparator}tone440.wav';
    File(path).writeAsBytesSync(_wav(440, 2, 0.3));
    final outFile = File('$dir${Platform.pathSeparator}engine.txt');

    Future<Map<dynamic, dynamic>> render(Map<String, Object?> chain) async =>
        (await _ch.invokeMethod<Map>('offline.render', {...chain, 'source': path, 'maxSeconds': 2.0}))!;

    // 1) plain decode: a 0.3 peak sine is 0.212 RMS
    final plain = await render(_chain());
    _note('plain render ok=${plain['ok']} frames=${plain['frames']} rms=${plain['rms']} peak=${plain['peak']} err=${plain['error']}');
    expect(plain['ok'], isTrue, reason: 'the file decodes');
    final plainRms = (plain['rms'] as num).toDouble();
    expect(plainRms, closeTo(0.3 / math.sqrt(2), 0.02), reason: 'decoded level matches the source');

    // 2) +12 dB at 440 Hz: about four times the RMS (12 dB = x3.98)
    final boost = AudioLabEq.coefficients(440, 12);
    final up = await render(_chain(eq: [boost]));
    final upRms = (up['rms'] as num).toDouble();
    final gainUp = 20 * math.log(upRms / plainRms) / math.ln10;
    _note('+12 dB at 440 Hz: rms ratio ${(upRms / plainRms).toStringAsFixed(3)} = ${gainUp.toStringAsFixed(2)} dB');
    expect(upRms / plainRms, closeTo(3.98, 0.25));

    // 3) -12 dB at 440 Hz: a quarter of the RMS
    final cut = await render(_chain(eq: [AudioLabEq.coefficients(440, -12)]));
    final cutRms = (cut['rms'] as num).toDouble();
    _note('-12 dB at 440 Hz: rms ratio ${(cutRms / plainRms).toStringAsFixed(3)}');
    expect(cutRms / plainRms, closeTo(0.25, 0.04));

    // 4) +12 dB at 5 kHz leaves the 440 Hz tone alone
    final far = await render(_chain(eq: [AudioLabEq.coefficients(5000, 12)]));
    final farRms = (far['rms'] as num).toDouble();
    _note('+12 dB at 5 kHz on a 440 Hz tone: rms ratio ${(farRms / plainRms).toStringAsFixed(3)}');
    expect(farRms / plainRms, closeTo(1.0, 0.03));

    // 5) mono on a mono-in-both-channels tone changes nothing
    final mono = await render(_chain(mono: true));
    _note('mono on a centred tone: rms ratio ${((mono['rms'] as num).toDouble() / plainRms).toStringAsFixed(3)}');
    expect((mono['rms'] as num).toDouble() / plainRms, closeTo(1.0, 0.02));

    // 6) the engine opens the file: ready with a duration near 2 s
    final created = await _ch.invokeMethod<Map>('engine.create');
    final id = (created!['id'] as num).toInt();
    await _ch.invokeMethod('dsp.set', _chain(eq: [boost]));
    await _ch.invokeMethod('engine.open', {'id': id, 'source': path, 'startMs': 0});
    Map<dynamic, dynamic> st = {};
    for (var i = 0; i < 200; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      st = (await _ch.invokeMethod<Map>('engine.status', {'id': id}))!;
      if (st['state'] == 'ready' || st['state'] == 'error') break;
    }
    _note('engine open: state=${st['state']} durMs=${st['durMs']} error=${st['error']}');
    expect(st['state'], 'ready');
    expect((st['durMs'] as num).toInt(), closeTo(2000, 80));
    await _ch.invokeMethod('engine.play', {'id': id});
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 800)));
    st = (await _ch.invokeMethod<Map>('engine.status', {'id': id}))!;
    _note('after 0.8 s playing: state=${st['state']} posMs=${st['posMs']} playing=${st['playing']} error=${st['error']}');
    await _ch.invokeMethod('engine.dispose', {'id': id});

    // 7) the system overlay: available on this runner or not, both are written
    final overlay = await _ch.invokeMethod<bool>('smtc.init');
    await _ch.invokeMethod('smtc.update', {
      'title': 'Test song',
      'artist': 'Test artist',
      'album': 'Test album',
      'art': '',
      'hasItem': true,
      'playing': false,
      'posMs': 1000,
      'durMs': 2000,
    });
    _note('overlay init: $overlay');

    await outFile.writeAsString(_lines.join('\n'));
  });
}

class AudioLabEq {
  /// A peak point's coefficients from the same design the app uses.
  static List<double> coefficients(double hz, double db) => EqMath.sectionCoefficients(EqNode(EqNodeType.peak, hz, db, 1.0))!;
}
