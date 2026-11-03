import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

// Byte 2.0 © 2026 Apurba Laskar.
//
// Lyrics whose words light up as they are sung, without rebuilding widgets
// on every tick: the line is laid out once (the dim copy painted from a
// cached text layout, the bright copy a normal text widget), and each tick of
// the clock only moves the clip over the bright copy (repaint, no rebuild, no
// per-word layers or shader masks).

/// Fill (0..1) of every word of the line at the clock's time.
typedef WordFills = List<double> Function(int ms);

TextPainter _painter(String text, TextStyle style, TextAlign align, TextDirection dir, TextScaler scaler, {int? maxLines}) => TextPainter(
  text: TextSpan(text: text, style: style),
  textAlign: align,
  textDirection: dir,
  textScaler: scaler,
  maxLines: maxLines,
  ellipsis: maxLines == null ? null : '…',
);

/// Paints [text] in [style] from a layout cached per width.
class _TextPaint extends CustomPainter {
  final String text;
  final TextStyle style;
  final TextAlign align;
  final TextDirection dir;
  final TextScaler scaler;
  _TextPaint(this.text, this.style, this.align, this.dir, this.scaler);
  TextPainter? _tp;
  double _w = -1;
  @override
  void paint(Canvas canvas, Size size) {
    if (_tp == null || _w != size.width) {
      _tp?.dispose();
      _tp = _painter(text, style, align, dir, scaler)..layout(maxWidth: size.width);
      _w = size.width;
    }
    _tp!.paint(canvas, Offset.zero);
  }

  @override
  bool shouldRepaint(covariant _TextPaint o) => o.text != text || o.style != style || o.align != align || o.dir != dir || o.scaler != scaler;
}

/// The clip of the words sung so far: whole words, and the word being sung up
/// to where the singer is (from the right for a right-to-left script).
class FillClipper extends CustomClipper<Path> {
  final String text;
  final List<String> words;
  final TextStyle style;
  final TextAlign align;
  final TextDirection dir;
  final TextScaler scaler;
  final ValueListenable<int> clock;
  final WordFills fills;
  FillClipper({required this.text, required this.words, required this.style, required this.align, required this.dir, required this.scaler, required this.clock, required this.fills}) : super(reclip: clock);

  double _w = -1;
  List<List<TextBox>> _boxes = const [];

  /// How many times the clip was worked out (tests: ticks don't rebuild).
  static int clips = 0;

  void _measure(double width) {
    if (width == _w) return;
    _w = width;
    final tp = _painter(text, style, align, dir, scaler)..layout(maxWidth: width);
    final out = <List<TextBox>>[];
    var from = 0;
    for (final w in words) {
      final t = w.trim();
      final at = t.isEmpty ? -1 : text.indexOf(t, from);
      if (at < 0) {
        out.add(const []);
        continue;
      }
      from = at + t.length;
      out.add(tp.getBoxesForSelection(TextSelection(baseOffset: at, extentOffset: from)));
    }
    tp.dispose();
    _boxes = out;
  }

  @override
  Path getClip(Size size) {
    clips++;
    _measure(size.width);
    final f = fills(clock.value);
    final p = Path();
    for (var i = 0; i < _boxes.length && i < f.length; i++) {
      final v = f[i].clamp(0.0, 1.0);
      if (v <= 0) continue;
      for (final b in _boxes[i]) {
        final r = b.toRect().inflate(3);
        if (v >= 1) {
          p.addRect(r);
        } else if (b.direction == TextDirection.rtl) {
          p.addRect(Rect.fromLTRB(r.right - r.width * v, r.top, r.right, r.bottom));
        } else {
          p.addRect(Rect.fromLTRB(r.left, r.top, r.left + r.width * v, r.bottom));
        }
      }
    }
    return p;
  }

  @override
  bool shouldReclip(covariant FillClipper o) => o.text != text || o.style != style || o.align != align || o.dir != dir || o.scaler != scaler || !identical(o.clock, clock) || !listEquals(o.words, words);
}

class FillText extends StatelessWidget {
  final String text;
  final List<String> words;
  final TextStyle style;
  final Color dim;
  final TextAlign align;
  final TextDirection direction;
  final ValueListenable<int> clock;
  final WordFills fills;
  const FillText({
    super.key,
    required this.text,
    required this.words,
    required this.style,
    required this.dim,
    required this.clock,
    required this.fills,
    this.align = TextAlign.start,
    this.direction = TextDirection.ltr,
  });

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final st = DefaultTextStyle.of(context).style.merge(style);
    return RepaintBoundary(
      child: Stack(
        children: [
          Positioned.fill(child: CustomPaint(painter: _TextPaint(text, st.copyWith(color: dim), align, direction, scaler))),
          ClipPath(
            clipper: FillClipper(text: text, words: words, style: st, align: align, dir: direction, scaler: scaler, clock: clock, fills: fills),
            child: SizedBox(
              width: double.infinity,
              child: RichText(text: TextSpan(text: text, style: st), textAlign: align, textDirection: direction, textScaler: scaler),
            ),
          ),
        ],
      ),
    );
  }
}
