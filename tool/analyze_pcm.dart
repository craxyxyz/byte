// ignore_for_file: avoid_print
// Dev tool: analyse a raw mono s16le PCM file. dart run tool/analyze_pcm.dart file.raw [rate]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:byte/automix/analysis.dart';

void main(List<String> a) {
  for (final path in a.where((x) => !RegExp(r'^\d+$').hasMatch(x))) {
    final rate = a.length > 1 && RegExp(r'^\d+$').hasMatch(a.last) ? int.parse(a.last) : 11025;
    final b = File(path).readAsBytesSync();
    final pcm = Int16List.view(Uint8List.fromList(b).buffer, 0, b.length ~/ 2);
    final sw = Stopwatch()..start();
    final r = analyzePcm(pcm, rate);
    File('$path.json').writeAsStringSync(jsonEncode({...r.toJson(), 'beatsAbs': r.beatsMs}));
    print('$path: $r  (${sw.elapsedMilliseconds} ms) ${debugLastAnalysis()}');
  }
}
