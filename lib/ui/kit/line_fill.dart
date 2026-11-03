import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

// Byte 2.0 © 2026 Apurba Laskar.
//
// One line of text (cut with "…" when long) whose first part is bright and
// the rest dim, the bright part following a clock. Laid out once; a tick only
// moves the clip (the small lyric line under the cover).

class _EdgeClipper extends CustomClipper<Rect> {
  final String text;
  final TextStyle style;
  final TextDirection dir;
  final TextScaler scaler;
  final ValueListenable<int> clock;
  final double Function(int ms) fraction;
  _EdgeClipper(this.text, this.style, this.dir, this.scaler, this.clock, this.fraction) : super(reclip: clock);
  TextPainter? _tp;
  double _w = -1;

  @override
  Rect getClip(Size size) {
    if (_tp == null || _w != size.width) {
      _tp?.dispose();
      _tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: dir, textScaler: scaler, maxLines: 1, ellipsis: '…')..layout(maxWidth: size.width);
      _w = size.width;
    }
    final n = (text.length * fraction(clock.value).clamp(0.0, 1.0)).round();
    final x = _tp!.getOffsetForCaret(TextPosition(offset: n), Rect.zero).dx.clamp(0.0, size.width);
    return dir == TextDirection.rtl ? Rect.fromLTRB(size.width - x, -4, size.width, size.height + 4) : Rect.fromLTRB(-4, -4, x, size.height + 4);
  }

  @override
  bool shouldReclip(covariant _EdgeClipper o) => o.text != text || o.style != style || o.dir != dir || o.scaler != scaler || !identical(o.clock, clock);
}

class _DimLine extends CustomPainter {
  final String text;
  final TextStyle style;
  final TextDirection dir;
  final TextScaler scaler;
  _DimLine(this.text, this.style, this.dir, this.scaler);
  TextPainter? _tp;
  double _w = -1;
  @override
  void paint(Canvas canvas, Size size) {
    if (_tp == null || _w != size.width) {
      _tp?.dispose();
      _tp = TextPainter(text: TextSpan(text: text, style: style), textDirection: dir, textScaler: scaler, maxLines: 1, ellipsis: '…')..layout(maxWidth: size.width);
      _w = size.width;
    }
    _tp!.paint(canvas, Offset.zero);
  }

  @override
  bool shouldRepaint(covariant _DimLine o) => o.text != text || o.style != style || o.dir != dir || o.scaler != scaler;
}

class LineFill extends StatelessWidget {
  final String text;
  final TextStyle style;
  final double dimAlpha;
  final ValueListenable<int> clock;

  /// 0..1 of the letters lit at the clock's time.
  final double Function(int ms) fraction;
  const LineFill({super.key, required this.text, required this.style, required this.clock, required this.fraction, this.dimAlpha = 0.42});

  @override
  Widget build(BuildContext context) {
    final st = DefaultTextStyle.of(context).style.merge(style);
    final dir = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final lit = st.color ?? const Color(0xFFFFFFFF);
    return RepaintBoundary(
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _DimLine(text, st.copyWith(color: lit.withValues(alpha: dimAlpha)), dir, scaler))),
          ClipRect(
            clipper: _EdgeClipper(text, st, dir, scaler, clock, fraction),
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: st),
          ),
        ],
      ),
    );
  }
}
