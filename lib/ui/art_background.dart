import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services.dart';
import 'art_colors.dart';
import 'widgets.dart';

/// Slowly drifting colour blobs from the album art, under a blurred copy of
/// the artwork: the backdrop of Now Playing and the lyrics.
class ArtBackground extends StatefulWidget {
  final Widget child;
  final bool animate;
  const ArtBackground({super.key, required this.child, this.animate = true});
  @override
  State<ArtBackground> createState() => _ArtBackgroundState();
}

class _ArtBackgroundState extends State<ArtBackground> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this, duration: const Duration(seconds: 40));
  ArtPalette palette = ArtPalette.fallback;
  String? _url;

  @override
  void initState() {
    super.initState();
    if (widget.animate) _t.repeat();
    Services.i.player.current.addListener(_update);
    _update();
  }

  @override
  void dispose() {
    Services.i.player.current.removeListener(_update);
    _t.dispose();
    super.dispose();
  }

  Future<void> _update() async {
    final it = Services.i.player.current.value;
    final url = it?.thumbAt(226);
    if (url == _url) return;
    _url = url;
    final p = await paletteFor(url);
    if (mounted && _url == url) setState(() => palette = p);
  }

  @override
  Widget build(BuildContext context) {
    final it = Services.i.player.current.value;
    return Stack(
      fit: StackFit.expand,
      children: [
        TweenAnimationBuilder<ArtPaletteTween>(
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          tween: _PalTween(end: ArtPaletteTween(palette)),
          // Legacy mesh gradient = the drifting colour blobs; otherwise a calm
          // top-to-bottom wash of the cover's colours.
          builder: (context, p, _) => Services.i.settings.meshGradient
              ? AnimatedBuilder(
                  animation: _t,
                  builder: (context, _) => CustomPaint(painter: _BlobPainter(p.p, _t.value)),
                )
              : DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color.lerp(p.p.primary, Colors.black, 0.25)!,
                        Color.lerp(p.p.secondary, Colors.black, 0.55)!,
                        Color.lerp(p.p.tertiary, Colors.black, 0.8)!,
                      ],
                    ),
                  ),
                ),
        ),
        if (it?.thumb != null)
          Opacity(
            opacity: 0.32,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60, tileMode: TileMode.mirror),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 700),
                child: _CoverFill(key: ValueKey(it!.id), item: it),
              ),
            ),
          ),
        const DecoratedBox(decoration: BoxDecoration(color: Color(0x33000000))),
        widget.child,
      ],
    );
  }
}

class _CoverFill extends StatelessWidget {
  final Item item;
  const _CoverFill({super.key, required this.item});
  @override
  Widget build(BuildContext context) {
    final p = imageProviderFor(item.thumbAt(226));
    if (p == null) return const SizedBox.expand();
    return SizedBox.expand(
      child: Image(image: p, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox()),
    );
  }
}

class ArtPaletteTween {
  final ArtPalette p;
  const ArtPaletteTween(this.p);
}

class _PalTween extends Tween<ArtPaletteTween> {
  _PalTween({super.end}) : super(begin: end);
  @override
  ArtPaletteTween lerp(double t) {
    final a = begin!.p, b = end!.p;
    return ArtPaletteTween(ArtPalette(Color.lerp(a.primary, b.primary, t)!, Color.lerp(a.secondary, b.secondary, t)!, Color.lerp(a.tertiary, b.tertiary, t)!));
  }
}

class _BlobPainter extends CustomPainter {
  final ArtPalette p;
  final double t;
  _BlobPainter(this.p, this.t);
  @override
  void paint(Canvas canvas, Size s) {
    final r = Offset.zero & s;
    canvas.drawRect(r, Paint()..color = Color.lerp(p.primary, Colors.black, 0.55)!);
    final a = t * 2 * math.pi;
    final blobs = [
      (p.primary, Offset(0.25 + 0.15 * math.sin(a), 0.25 + 0.10 * math.cos(a * 2)), 0.75),
      (p.secondary, Offset(0.80 + 0.12 * math.cos(a), 0.35 + 0.15 * math.sin(a)), 0.65),
      (p.tertiary, Offset(0.45 + 0.20 * math.sin(a * 2), 0.85 + 0.08 * math.cos(a)), 0.80),
    ];
    for (final (c, o, rad) in blobs) {
      final center = Offset(o.dx * s.width, o.dy * s.height);
      final radius = rad * math.max(s.width, s.height);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(colors: [c.withValues(alpha: 0.85), c.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BlobPainter old) => old.t != t || old.p != p;
}
