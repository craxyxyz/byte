// Byte © 2026 Apurba Laskar.
//
// Settings → About → Developer (1.4.3): who made Byte, with his own social
// links. Icons are drawn here (no brand asset files).

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../brand.dart';
import 'style.dart';

class DeveloperLinks {
  static const name = 'Apurba Laskar';
  static const instagramHandle = '@apurbaaa_';
  static final instagram = Uri.parse('https://www.instagram.com/apurbaaa_');
  static final facebook = Uri.parse('https://www.facebook.com/share/19dyN68CzU/');
}

/// Opens [u] in its own app / the browser.
Future<bool> openExternal(Uri u) async {
  try {
    return await launchUrl(u, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

class DeveloperCard extends StatefulWidget {
  /// Tests swap this to catch the link without leaving the app.
  final Future<bool> Function(Uri) open;
  const DeveloperCard({super.key, this.open = openExternal});

  /// One entrance: card, then the two rows, then the label shimmer.
  static const entrance = Duration(milliseconds: 1600);

  /// One slow turn of the ring around the avatar.
  static const ringTurn = Duration(seconds: 7);

  @override
  State<DeveloperCard> createState() => _DeveloperCardState();
}

class _DeveloperCardState extends State<DeveloperCard> with TickerProviderStateMixin {
  late final AnimationController enter = AnimationController(vsync: this, duration: DeveloperCard.entrance);
  late final AnimationController ring = AnimationController(vsync: this, duration: DeveloperCard.ringTurn);
  bool? _still;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce motion (system "remove animations"): everything shows at rest.
    final still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (still == _still) return;
    _still = still;
    if (still) {
      enter.value = 1;
      ring.stop();
    } else {
      if (enter.value < 1) enter.forward();
      ring.repeat();
    }
  }

  @override
  void dispose() {
    enter.dispose();
    ring.dispose();
    super.dispose();
  }

  Animation<double> _part(double a, double b) => CurvedAnimation(parent: enter, curve: Interval(a, b, curve: Curves.easeOutCubic));

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final card = _part(0, 0.45);
    final row1 = _part(0.22, 0.62);
    final row2 = _part(0.32, 0.72);
    final shine = CurvedAnimation(parent: enter, curve: const Interval(0.5, 1, curve: Curves.easeInOut));
    Widget slideIn(Animation<double> a, Widget child, {double dy = 14}) => AnimatedBuilder(
      animation: a,
      child: child,
      builder: (_, c) => Opacity(opacity: a.value, child: Transform.translate(offset: Offset(0, dy * (1 - a.value)), child: c)),
    );
    final hair = Divider(height: 0.6, thickness: 0.6, color: p.separator.withValues(alpha: 0.45));
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
      child: slideIn(
        card,
        dy: 26,
        Container(
          key: const ValueKey('developer-card'),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: dark
                  ? [Color.lerp(p.grouped, const Color(0xFFFF375F), 0.07)!, p.grouped]
                  : [Color.lerp(p.grouped, const Color(0xFFFF375F), 0.035)!, p.grouped],
            ),
            border: Border.all(color: dark ? Colors.white.withValues(alpha: 0.09) : Colors.black.withValues(alpha: 0.06), width: 0.8),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.30 : 0.045), blurRadius: 18, offset: const Offset(0, 4))],
          ),
          clipBehavior: Clip.antiAlias,
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
                  child: Row(
                    children: [
                      _RingAvatar(turn: ring),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _Shimmer(
                              progress: shine,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                                child: Text('DEVELOPER', style: BT.caption.copyWith(color: p.accent, fontWeight: FontWeight.w800, fontSize: 10.5, letterSpacing: 1.4)),
                              ),
                            ),
                            const SizedBox(height: 7),
                            Text(DeveloperLinks.name, style: TextStyle(color: p.label, fontWeight: FontWeight.w800, fontSize: 23, letterSpacing: -0.4, height: 1.1)),
                            const SizedBox(height: 3),
                            Text('Made ${Brand.appName} with love', style: TextStyle(color: p.secondary, fontWeight: FontWeight.w400, fontSize: 14, letterSpacing: 0.1)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                hair,
                slideIn(
                  row1,
                  _LinkRow(
                    key: const ValueKey('developer-instagram'),
                    icon: const _InstaGlyph(),
                    title: 'Instagram',
                    subtitle: DeveloperLinks.instagramHandle,
                    onTap: () => widget.open(DeveloperLinks.instagram),
                  ),
                ),
                Padding(padding: const EdgeInsets.only(left: 64), child: hair),
                slideIn(
                  row2,
                  _LinkRow(
                    key: const ValueKey('developer-facebook'),
                    icon: const _FbGlyph(),
                    title: 'Facebook',
                    subtitle: 'Say hello',
                    onTap: () => widget.open(DeveloperLinks.facebook),
                  ),
                ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The "AL" avatar inside a slowly turning red→purple sweep ring with a soft glow.
class _RingAvatar extends StatelessWidget {
  final Animation<double> turn;
  const _RingAvatar({required this.turn});
  @override
  Widget build(BuildContext context) {
    final bg = BytePalette.of(context).grouped;
    return SizedBox(
      width: 68,
      height: 68,
      child: Stack(
        alignment: Alignment.center,
        children: [
          RepaintBoundary(
            child: AnimatedBuilder(
              animation: turn,
              builder: (_, _) => CustomPaint(size: const Size.square(68), painter: _RingPainter(turn.value)),
            ),
          ),
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: bg, width: 2.5)),
            child: Container(
              alignment: Alignment.center,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [Color(0xFFFF375F), Color(0xFFB0127A)], begin: Alignment.topLeft, end: Alignment.bottomRight),
              ),
              child: const Text('AL', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 19, letterSpacing: 0.6)),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double t;
  _RingPainter(this.t);
  static const _colors = [Color(0xFFFF375F), Color(0xFFFF9F0A), Color(0xFFB0127A), Color(0xFF6E3BD6), Color(0xFFFF375F)];
  @override
  void paint(Canvas c, Size s) {
    final rect = Offset.zero & s;
    final center = rect.center;
    final shader = SweepGradient(colors: _colors, transform: GradientRotation(t * 2 * math.pi)).createShader(rect);
    // soft glow
    c.drawCircle(
      center,
      s.width / 2 - 3,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5)
        ..color = Colors.white.withValues(alpha: 0.55),
    );
    c.drawCircle(
      center,
      s.width / 2 - 2,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.t != t;
}

/// One soft light sweep across [child] as [progress] runs 0 → 1.
class _Shimmer extends StatelessWidget {
  final Animation<double> progress;
  final Widget child;
  const _Shimmer({required this.progress, required this.child});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: progress,
    child: child,
    builder: (_, c) {
      final v = progress.value;
      if (v <= 0 || v >= 1) return c!;
      final x = -1.5 + 3.0 * v;
      return ShaderMask(
        blendMode: BlendMode.srcATop,
        shaderCallback: (r) => LinearGradient(
          begin: Alignment(x - 0.6, -0.3),
          end: Alignment(x + 0.6, 0.3),
          colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: 0.75), Colors.white.withValues(alpha: 0)],
        ).createShader(r),
        child: c,
      );
    },
  );
}

class _LinkRow extends StatefulWidget {
  final Widget icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _LinkRow({super.key, required this.icon, required this.title, required this.subtitle, required this.onTap});
  @override
  State<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends State<_LinkRow> {
  bool down = false;
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return AnimatedScale(
      scale: down ? 0.97 : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged: (v) => setState(() => down = v),
        splashColor: p.accent.withValues(alpha: 0.10),
        highlightColor: p.accent.withValues(alpha: 0.05),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          child: Row(
            children: [
              SizedBox(width: 32, height: 32, child: widget.icon),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: TextStyle(color: p.label, fontWeight: FontWeight.w600, fontSize: 16)),
                    Text(widget.subtitle, style: TextStyle(color: p.secondary, fontSize: 13)),
                  ],
                ),
              ),
              Icon(Icons.arrow_outward_rounded, size: 18, color: p.tertiary),
            ],
          ),
        ),
      ),
    );
  }
}

/// A camera glyph on a warm gradient tile (drawn, not an asset).
class _InstaGlyph extends StatelessWidget {
  const _InstaGlyph();
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(8),
      gradient: const LinearGradient(colors: [Color(0xFFFFB347), Color(0xFFFF3D6E), Color(0xFF8E3BD6)], begin: Alignment.bottomLeft, end: Alignment.topRight),
    ),
    child: CustomPaint(painter: _CameraPainter()),
  );
}

class _CameraPainter extends CustomPainter {
  @override
  void paint(Canvas c, Size s) {
    final w = s.width;
    final pen = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.075;
    c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(w * 0.22, w * 0.22, w * 0.56, w * 0.56), Radius.circular(w * 0.16)), pen);
    c.drawCircle(Offset(w / 2, w / 2), w * 0.13, pen);
    c.drawCircle(Offset(w * 0.66, w * 0.34), w * 0.035, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_CameraPainter old) => false;
}

/// A white "f" on a blue circle (drawn, not an asset).
class _FbGlyph extends StatelessWidget {
  const _FbGlyph();
  @override
  Widget build(BuildContext context) => Container(
    alignment: Alignment.center,
    decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1877F2)),
    child: const Padding(
      padding: EdgeInsets.only(top: 3, left: 1),
      child: Text('f', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 21, height: 1)),
    ),
  );
}
