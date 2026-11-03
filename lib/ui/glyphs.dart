import 'package:flutter/material.dart';

/// Byte's own drawn glyphs where the stock icon sets have no close match.

/// A rounded-square speech bubble with two quote marks (the lyrics button).
class LyricsGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const LyricsGlyph({super.key, this.size = 26, this.color = Colors.white});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _LyricsPainter(color));
}

class _LyricsPainter extends CustomPainter {
  final Color color;
  _LyricsPainter(this.color);
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.085
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final l = w * 0.12, t = w * 0.12, r = w * 0.88, b = w * 0.72, rad = w * 0.16;
    final p = Path()
      ..moveTo(l + rad, t)
      ..lineTo(r - rad, t)
      ..quadraticBezierTo(r, t, r, t + rad)
      ..lineTo(r, b - rad)
      ..quadraticBezierTo(r, b, r - rad, b)
      ..lineTo(w * 0.42, b)
      ..lineTo(w * 0.27, w * 0.88)
      ..lineTo(w * 0.27, b)
      ..lineTo(l + rad, b)
      ..quadraticBezierTo(l, b, l, b - rad)
      ..lineTo(l, t + rad)
      ..quadraticBezierTo(l, t, l + rad, t)
      ..close();
    canvas.drawPath(p, stroke);
    final fill = Paint()..color = color;
    // two quote marks: a dot with a short tail each
    for (final cx in [w * 0.40, w * 0.60]) {
      final cy = w * 0.38;
      canvas.drawCircle(Offset(cx, cy), w * 0.065, fill);
      final tail = Path()
        ..moveTo(cx + w * 0.06, cy)
        ..quadraticBezierTo(cx + w * 0.055, cy + w * 0.12, cx - w * 0.04, cy + w * 0.15)
        ..lineTo(cx - w * 0.03, cy + w * 0.11)
        ..quadraticBezierTo(cx + w * 0.01, cy + w * 0.07, cx - w * 0.01, cy + w * 0.03)
        ..close();
      canvas.drawPath(tail, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _LyricsPainter old) => old.color != color;
}

/// A filled rounded square with two shorter bars stacked above it (Library).
class LibraryGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const LibraryGlyph({super.key, this.size = 26, required this.color});
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _LibraryPainter(color));
}

class _LibraryPainter extends CustomPainter {
  final Color color;
  _LibraryPainter(this.color);
  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final f = Paint()..color = color;
    canvas.drawRRect(RRect.fromLTRBR(w * 0.12, w * 0.40, w * 0.88, w * 0.90, Radius.circular(w * 0.11)), f);
    canvas.drawRRect(RRect.fromLTRBR(w * 0.20, w * 0.25, w * 0.80, w * 0.32, Radius.circular(w * 0.04)), f);
    canvas.drawRRect(RRect.fromLTRBR(w * 0.29, w * 0.11, w * 0.71, w * 0.18, Radius.circular(w * 0.04)), f);
  }

  @override
  bool shouldRepaint(covariant _LibraryPainter old) => old.color != color;
}

/// A tab's icon: the drawn Library glyph or the filled stock icon.
Widget tabGlyph(int index, IconData icon, {required Color color, double size = 26}) =>
    index == 2 ? LibraryGlyph(size: size, color: color) : Icon(icon, size: size, color: color);
