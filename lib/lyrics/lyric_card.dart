// Byte © 2026 Apurba Laskar.
//
// 2.0.9: a lyrics card — the picked lines on a picture, ready to share.
// Drawn with the picture recorder (no widget tree), so it renders the same on
// a phone and on a computer.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// The card as a PNG. [lines] are the picked lines in order; [title] and
/// [artist] go under them. [width] is the image width in pixels.
Future<Uint8List> renderLyricCard({
  required List<String> lines,
  required String title,
  String artist = '',
  int width = 1080,
  Color accent = const Color(0xFFFF4D7A),
}) async {
  final w = width.toDouble();
  final pad = w * 0.09;
  final textW = w - pad * 2;
  final lineStyle = TextStyle(color: const Color(0xFFFFFFFF), fontSize: w * 0.052, height: 1.32, fontWeight: FontWeight.w600);
  final footStyle = TextStyle(color: const Color(0xCCFFFFFF), fontSize: w * 0.03, height: 1.3);
  final brandStyle = TextStyle(color: accent, fontSize: w * 0.028, fontWeight: FontWeight.w700, letterSpacing: 1.2);

  final body = TextPainter(
    text: TextSpan(text: lines.where((l) => l.trim().isNotEmpty).join('\n'), style: lineStyle),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(maxWidth: textW);
  final foot = TextPainter(
    text: TextSpan(text: artist.isEmpty ? '— $title' : '— $title · $artist', style: footStyle),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
    maxLines: 2,
    ellipsis: '…',
  )..layout(maxWidth: textW);
  final brand = TextPainter(text: TextSpan(text: 'BYTE', style: brandStyle), textDirection: TextDirection.ltr)..layout();

  final topPad = w * 0.12;
  final gap = w * 0.07;
  final h = math.max(w * 0.8, topPad + body.height + gap + foot.height + w * 0.14 + brand.height + w * 0.06);

  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec, ui.Rect.fromLTWH(0, 0, w, h));

  // background: a dark wine gradient with a soft accent glow
  final bg = ui.Paint()
    ..shader = ui.Gradient.linear(ui.Offset(0, 0), ui.Offset(w * 0.4, h), const [Color(0xFF16090F), Color(0xFF3A0E26), Color(0xFF0B0609)], const [0, 0.55, 1]);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w, h), bg);
  final glow = ui.Paint()
    ..shader = ui.Gradient.radial(ui.Offset(w * 0.85, h * 0.12), w * 0.7, [accent.withValues(alpha: 0.38), accent.withValues(alpha: 0)]);
  canvas.drawRect(ui.Rect.fromLTWH(0, 0, w, h), glow);

  body.paint(canvas, ui.Offset(pad, topPad));
  final footY = topPad + body.height + gap;
  foot.paint(canvas, ui.Offset(pad, footY));
  brand.paint(canvas, ui.Offset(pad, h - w * 0.06 - brand.height));

  final picture = rec.endRecording();
  final image = await picture.toImage(w.round(), h.round());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
