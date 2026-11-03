import 'package:flutter/material.dart';

import 'style.dart';

/// Byte's mark: a lowercase "b" with one sound wave beside it — "b)".
/// Drawn from the same geometry as the app icon (thick round strokes).
void paintByteMark(Canvas canvas, Offset origin, double scale, Paint paint) {
  canvas.save();
  canvas.translate(origin.dx, origin.dy);
  canvas.scale(scale);
  final p = paint
    ..style = PaintingStyle.stroke
    ..strokeWidth = 104
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  // stem + bowl
  final b = Path()
    ..moveTo(0, -372)
    ..lineTo(0, 172)
    ..moveTo(0, -172)
    ..arcToPoint(const Offset(0, 172), radius: const Radius.circular(172));
  canvas.drawPath(b, p);
  // the sound wave
  final w = Path()
    ..moveTo(230.2, -222.3)
    ..arcToPoint(const Offset(230.2, 222.3), radius: const Radius.circular(320));
  canvas.drawPath(w, p);
  canvas.restore();
}

/// The app icon: white mark on the logo's red-pink rounded square.
class ByteLogo extends StatelessWidget {
  final double size;
  final bool tile;
  const ByteLogo({super.key, this.size = 40, this.tile = true});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Byte',
    image: true,
    child: SizedBox(
      width: size,
      height: size,
      child: tile ? CustomPaint(painter: ByteLogoPainter()) : ByteMark(size: size, color: BytePalette.of(context).accent),
    ),
  );
}

class ByteLogoPainter extends CustomPainter {
  ByteLogoPainter();

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    final rect = Offset.zero & s;
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(w * 230 / 1024));
    canvas.drawRRect(rr, Paint()..shader = ByteColors.logoGradient.createShader(rect));
    final k = w / 1024;
    paintByteMark(canvas, Offset(377.0 * k, 575.9 * k), 0.8465 * k, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant ByteLogoPainter old) => false;
}

/// Byte's mark on its own in one colour (Home header, sidebar, About).
class ByteMark extends StatelessWidget {
  final double size;
  final Color color;
  final Gradient? gradient;
  const ByteMark({super.key, this.size = 32, required this.color, this.gradient});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Byte',
    child: SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _MarkPainter(color, gradient)),
    ),
  );
}

class _MarkPainter extends CustomPainter {
  final Color color;
  final Gradient? gradient;
  _MarkPainter(this.color, this.gradient);
  @override
  void paint(Canvas canvas, Size s) {
    // mark bounds incl. stroke: x -52…372, y -424…274 (698 tall)
    final k = s.height / 698;
    final markW = 424 * k;
    final origin = Offset((s.width - markW) / 2 + 52 * k, 424 * k);
    final paint = Paint()..color = color;
    if (gradient != null) paint.shader = gradient!.createShader(Offset.zero & s);
    paintByteMark(canvas, origin, k, paint);
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => old.color != color || old.gradient != gradient;
}

/// "b) Byte" — the mark beside the name, for headers.
class ByteWordmark extends StatelessWidget {
  final double height;
  final Color? color;
  const ByteWordmark({super.key, this.height = 30, this.color});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Semantics(
      label: 'Byte',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ByteLogo(size: height),
          SizedBox(width: height * 0.32),
          Text(
            'Byte',
            style: TextStyle(fontSize: height * 0.86, fontWeight: FontWeight.w800, letterSpacing: -height * 0.03, height: 1, color: color ?? p.label),
          ),
        ],
      ),
    );
  }
}
