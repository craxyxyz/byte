import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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
    Services.i.player.current.addListener(_update);
    _update();
  }

  /// 1.4.5.2 (computer lag): the drift clock only runs while the drifting
  /// blobs are actually on screen. It used to tick every frame even with the
  /// calm (default) background, so the whole player redrew 60–120 times a
  /// second, paused or not.
  void _clock(bool mesh) {
    final want = widget.animate && mesh;
    if (want && !_t.isAnimating) _t.repeat();
    if (!want && _t.isAnimating) _t.stop();
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
    final mesh = Services.i.settings.meshGradient;
    _clock(mesh);
    return Stack(
      fit: StackFit.expand,
      children: [
        TweenAnimationBuilder<ArtPaletteTween>(
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
          tween: _PalTween(end: ArtPaletteTween(palette)),
          // Legacy mesh gradient = the drifting colour blobs; otherwise a calm
          // top-to-bottom wash of the cover's colours.
          builder: (context, p, _) => mesh
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
        if (it?.thumb != null && kIsWeb && !BlurredCover.onWeb)
          Opacity(
            opacity: 0.32,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60, tileMode: TileMode.mirror),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 700),
                child: _CoverFill(key: ValueKey(it!.id), item: it),
              ),
            ),
          )
        else if (it?.thumb != null)
          // 1.4.5.2: the cover is blurred ONCE per song into a small image and
          // that image is stretched over the window, instead of a live
          // full-window blur + transparency layer redone on every frame.
          RepaintBoundary(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 700),
              child: BlurredCover(key: ValueKey(it!.id), url: it.thumbAt(226)),
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
  // 1.4.5.2: equal colours = the same tween, so a rebuild doesn't restart the
  // 0.9 s colour fade (it did on every rebuild of the player).
  @override
  bool operator ==(Object other) => other is ArtPaletteTween && other.p.primary == p.primary && other.p.secondary == p.secondary && other.p.tertiary == p.tertiary;
  @override
  int get hashCode => Object.hash(p.primary, p.secondary, p.tertiary);
}

/// 1.4.5.2: the player's blurred cover backdrop, made once per song: the
/// cover is decoded tiny ([texels] wide), blurred into a small image, and that
/// image is drawn stretched over the window at 32 % strength. Looks the same
/// as a 60 px blur of the full cover; costs one textured rectangle per frame.
class BlurredCover extends StatefulWidget {
  final String? url;

  /// How strong the blurred picture is drawn (0.32 behind the player).
  final double opacity;
  const BlurredCover({super.key, required this.url, this.opacity = 0.32});

  static const int texels = 64;

  /// 2.0: the web app uses the pre-blurred picture too (it used a live 60 px
  /// blur under a transparency layer on every frame).
  static bool onWeb = true;

  /// Blur in texels of the small image (≈ a 60 px blur on a laptop window).
  static const double sigma = 3.2;

  /// Blurs [src] (already small) into a new image of the same size.
  @visibleForTesting
  static ui.Image blur(ui.Image src) {
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImage(src, Offset.zero, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.mirror));
    final pic = rec.endRecording();
    try {
      return pic.toImageSync(src.width, src.height);
    } finally {
      pic.dispose();
    }
  }

  @override
  State<BlurredCover> createState() => _BlurredCoverState();
}

class _BlurredCoverState extends State<BlurredCover> {
  ImageStream? _stream;
  ImageStreamListener? _l;
  ui.Image? _img;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_stream == null) _resolve();
  }

  void _resolve() {
    final p = imageProviderFor(widget.url);
    if (p == null) return;
    final stream = ResizeImage(p, width: BlurredCover.texels).resolve(createLocalImageConfiguration(context));
    _l = ImageStreamListener((info, _) {
      if (!mounted) {
        info.dispose();
        return;
      }
      ui.Image out;
      try {
        out = BlurredCover.blur(info.image);
      } catch (_) {
        out = info.image.clone();
      }
      info.dispose();
      setState(() {
        _img?.dispose();
        _img = out;
      });
    }, onError: (_, _) {});
    _stream = stream..addListener(_l!);
  }

  @override
  void dispose() {
    if (_l != null) _stream?.removeListener(_l!);
    _img?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    if (img == null) return const SizedBox.expand();
    return SizedBox.expand(
      child: RawImage(image: img, fit: BoxFit.cover, filterQuality: FilterQuality.medium, color: Color.fromRGBO(255, 255, 255, widget.opacity), colorBlendMode: BlendMode.modulate),
    );
  }
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
