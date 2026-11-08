import 'dart:typed_data';

import 'package:byte/lyrics/lyric_card.dart';
import 'package:flutter_test/flutter_test.dart';

int _u32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];

void main() {
  testWidgets('a lyrics card is a PNG at the asked width, taller with more lines', (tester) async {
    late Uint8List short, long;
    await tester.runAsync(() async {
      short = await renderLyricCard(lines: const ['one line'], title: 'Song', artist: 'Artist', width: 640);
      long = await renderLyricCard(
        lines: List.generate(12, (i) => 'line number $i of the song, long enough to wrap on a small card width'),
        title: 'A long song title that goes on',
        artist: 'Someone',
        width: 640,
      );
    });
    // PNG signature, then the IHDR chunk: width and height
    expect(short.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(_u32(short, 16), 640);
    expect(_u32(long, 16), 640);
    expect(_u32(long, 20), greaterThan(_u32(short, 20)));
  });
}
