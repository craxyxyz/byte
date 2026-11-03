// © 2026 Apurba Laskar
// Byte 1.4.3 — three fresh concepts for the Developer card on
// Settings → About, so the owner can pick one:
//   A. DeveloperConceptA — "Vinyl": a now-playing card; a record slides out
//      from behind the avatar, a tiny equalizer, tap to flip in 3D to the
//      links.
//   B. DeveloperConceptB — "Aurora glass": a slow aurora behind frosted
//      glass, the name types in, the buttons pop in, the card tilts with a
//      sideways drag.
//   C. DeveloperConceptC — "Signature": his name written as a hand-drawn
//      signature, sparkles settle, pill chips shimmer once, a beat ring.
// All three show fully at rest with no ticker when system animations are
// off (MediaQuery.disableAnimations). Icons are drawn here (no asset files).

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../brand.dart';
import '../services.dart';
import 'developer_card.dart' show DeveloperLinks, openExternal;
import 'style.dart';

bool _stillOf(BuildContext c) => MediaQuery.maybeDisableAnimationsOf(c) ?? false;

double _iv(double t, double a, double b, [Curve curve = Curves.linear]) => curve.transform(((t - a) / (b - a)).clamp(0.0, 1.0));

const _red1 = Color(0xFFFF375F);
const _red2 = Color(0xFFB0127A);
const _purple = Color(0xFF8E3BD6);
const _amber = Color(0xFFFF9F0A);

// ════════════════════════════════════════════════════════════════════════
// A — Vinyl
// ════════════════════════════════════════════════════════════════════════

class DeveloperConceptA extends StatefulWidget {
  final Future<bool> Function(Uri) open;
  const DeveloperConceptA({super.key, this.open = openExternal});

  static const entrance = Duration(milliseconds: 1500);
  static const flipTime = Duration(milliseconds: 650);

  @override
  State<DeveloperConceptA> createState() => _ConceptAState();
}

class _ConceptAState extends State<DeveloperConceptA> with TickerProviderStateMixin {
  late final _enter = AnimationController(vsync: this, duration: DeveloperConceptA.entrance);
  late final _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
  late final _eq = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
  late final _flip = AnimationController(vsync: this, duration: DeveloperConceptA.flipTime);
  bool _back = false;
  bool? _wasStill;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = _stillOf(context);
    if (still == _wasStill) return;
    _wasStill = still;
    if (still) {
      _enter.value = 1;
      _spin.stop();
      _eq.stop();
      _flip.value = _back ? 1 : 0;
    } else {
      if (_enter.value < 1) _enter.forward();
      _spin.repeat();
      _eq.repeat();
    }
  }

  void _toggle() {
    _back = !_back;
    if (_stillOf(context)) {
      _flip.value = _back ? 1 : 0;
    } else {
      _back ? _flip.forward() : _flip.reverse();
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _spin.dispose();
    _eq.dispose();
    _flip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _enter,
      builder: (context, child) {
        final t = _iv(_enter.value, 0, 0.45, Curves.easeOutCubic);
        return Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 28 * (1 - t)), child: child));
      },
      child: Semantics(
        button: true,
        label: 'Developer card, tap to flip',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggle,
          child: AnimatedBuilder(
            animation: _flip,
            builder: (context, _) {
              final a = Curves.easeInOutCubic.transform(_flip.value) * math.pi;
              final back = a > math.pi / 2;
              final face = back
                  ? Transform(alignment: Alignment.center, transform: Matrix4.rotationY(math.pi), child: _backFace(p, dark))
                  : _frontFace(p, dark);
              return Transform(
                alignment: Alignment.center,
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateY(a),
                child: face,
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _shell(BytePalette p, bool dark, Widget child) => Container(
    height: 204,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(26),
      border: Border.all(color: p.separator),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: dark ? const [Color(0xFF2A1220), Color(0xFF141113)] : const [Color(0xFFFFF0F3), Color(0xFFF6F3F4)],
      ),
    ),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(25),
      child: Stack(
        children: [
          // a soft glow from a gradient (no blurred shadow)
          Positioned(
            left: -60,
            top: -80,
            width: 260,
            height: 260,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [_red1.withValues(alpha: dark ? 0.22 : 0.14), _red1.withValues(alpha: 0)]),
              ),
            ),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(18, 18, 18, 14), child: child),
        ],
      ),
    ),
  );

  Widget _frontFace(BytePalette p, bool dark) {
    return _shell(
      p,
      dark,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 76 + 40,
                height: 76,
                child: AnimatedBuilder(
                  animation: _enter,
                  builder: (context, child) {
                    final s = _iv(_enter.value, 0.3, 0.85, Curves.easeOutBack);
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 40 * s,
                          top: 2,
                          child: RepaintBoundary(
                            child: RotationTransition(
                              turns: _spin,
                              child: CustomPaint(size: const Size.square(72), painter: _VinylPainter(dark: dark)),
                            ),
                          ),
                        ),
                        child!,
                      ],
                    );
                  },
                  child: _Avatar(size: 76, ring: dark ? const Color(0xFF2A1220) : Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('DEVELOPER', style: TextStyle(color: p.accent, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
                        const SizedBox(width: 8),
                        RepaintBoundary(
                          child: CustomPaint(size: const Size(19, 12), painter: _EqPainter(_eq, p.accent, still: _stillOf(context))),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      DeveloperLinks.name,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.fade,
                      style: TextStyle(color: p.label, fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                    ),
                    const SizedBox(height: 2),
                    Text('Made ${Brand.appName} for you', style: BT.sub.copyWith(color: p.secondary)),
                  ],
                ),
              ),
            ],
          ),
          const Spacer(),
          // a now-playing progress line
          AnimatedBuilder(
            animation: _enter,
            builder: (context, _) {
              final f = 0.62 * _iv(_enter.value, 0.35, 1, Curves.easeOutCubic);
              return Row(
                children: [
                  Text(Brand.appName, style: BT.caption.copyWith(color: p.secondary, fontWeight: FontWeight.w600)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 4,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: DecoratedBox(decoration: BoxDecoration(color: p.label.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(2))),
                          ),
                          FractionallySizedBox(
                            widthFactor: f,
                            heightFactor: 1,
                            alignment: Alignment.centerLeft,
                            child: DecoratedBox(
                              decoration: BoxDecoration(gradient: const LinearGradient(colors: [_red1, _red2]), borderRadius: BorderRadius.circular(2)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text('v${Brand.version}', style: BT.caption.copyWith(color: p.secondary)),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.threesixty_rounded, size: 16, color: p.tertiary),
              const SizedBox(width: 6),
              Text('Tap to flip · find me online', style: BT.caption.copyWith(color: p.secondary)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _backFace(BytePalette p, bool dark) {
    return _shell(
      p,
      dark,
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('Find me on', style: BT.bodyStrong.copyWith(color: p.label, fontWeight: FontWeight.w800)),
              const Spacer(),
              Icon(Icons.threesixty_rounded, size: 18, color: p.tertiary),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: _Tile(
                    glyph: const _InstaGlyph(),
                    title: 'Instagram',
                    sub: DeveloperLinks.instagramHandle,
                    onTap: () => widget.open(DeveloperLinks.instagram),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _Tile(
                    glyph: const _FbGlyph(),
                    title: 'Facebook',
                    sub: 'Say hello',
                    onTap: () => widget.open(DeveloperLinks.facebook),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(Brand.copyright, textAlign: TextAlign.center, style: BT.caption.copyWith(color: p.tertiary)),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final Widget glyph;
  final String title;
  final String sub;
  final VoidCallback onTap;
  const _Tile({required this.glyph, required this.title, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _Press(
      onTap: onTap,
      label: '$title $sub',
      radius: 18,
      color: dark ? Colors.white.withValues(alpha: 0.06) : Colors.white,
      border: p.separator,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox.square(dimension: 32, child: glyph),
                const Spacer(),
                Icon(Icons.north_east_rounded, size: 16, color: p.tertiary),
              ],
            ),
            const Spacer(),
            Text(title, style: BT.row.copyWith(color: p.label, fontWeight: FontWeight.w700)),
            Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.caption.copyWith(color: p.secondary)),
          ],
        ),
      ),
    );
  }
}

class _VinylPainter extends CustomPainter {
  final bool dark;
  _VinylPainter({required this.dark});

  @override
  void paint(Canvas c, Size s) {
    final r = s.width / 2;
    final o = Offset(r, r);
    c.drawCircle(o, r, Paint()..color = dark ? const Color(0xFF050405) : const Color(0xFF17131A));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..color = Colors.white.withValues(alpha: 0.07);
    for (var g = r * 0.44; g < r * 0.95; g += 2.6) {
      c.drawCircle(o, g, groove);
    }
    // two light catches, turning with the record
    final sheen = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.16),
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0.12),
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.08, 0.16, 0.5, 0.58, 0.66, 1.0],
      ).createShader(Rect.fromCircle(center: o, radius: r));
    c.drawCircle(o, r * 0.96, sheen);
    // the label
    c.drawCircle(
      o,
      r * 0.36,
      Paint()..shader = const LinearGradient(colors: [_red1, _amber], begin: Alignment.topLeft, end: Alignment.bottomRight).createShader(Rect.fromCircle(center: o, radius: r * 0.36)),
    );
    c.drawCircle(o + Offset(0, -r * 0.22), r * 0.05, Paint()..color = Colors.white.withValues(alpha: 0.9));
    c.drawCircle(o, r * 0.06, Paint()..color = dark ? const Color(0xFF050405) : const Color(0xFF17131A));
  }

  @override
  bool shouldRepaint(_VinylPainter old) => old.dark != dark;
}

/// Four bouncing bars (loop-seamless: integer frequencies).
class _EqPainter extends CustomPainter {
  final Animation<double> t;
  final Color color;
  final bool still;
  _EqPainter(this.t, this.color, {required this.still}) : super(repaint: t);

  static const _f = [2, 3, 1, 4];
  static const _ph = [0.0, 1.3, 2.1, 0.7];
  static const _rest = [0.55, 0.95, 0.4, 0.75];

  @override
  void paint(Canvas c, Size s) {
    final paint = Paint()..color = color;
    const w = 3.0;
    for (var i = 0; i < 4; i++) {
      final h = still ? _rest[i] : 0.25 + 0.75 * (math.sin(2 * math.pi * _f[i] * t.value + _ph[i]).abs());
      final bh = s.height * h;
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * (w + 2.3), s.height - bh, w, bh), const Radius.circular(1.5)), paint);
    }
  }

  @override
  bool shouldRepaint(_EqPainter old) => old.color != color || old.still != still;
}

// ════════════════════════════════════════════════════════════════════════
// B — Aurora glass
// ════════════════════════════════════════════════════════════════════════

class DeveloperConceptB extends StatefulWidget {
  final Future<bool> Function(Uri) open;
  const DeveloperConceptB({super.key, this.open = openExternal});

  static const entrance = Duration(milliseconds: 2400);

  @override
  State<DeveloperConceptB> createState() => _ConceptBState();
}

class _ConceptBState extends State<DeveloperConceptB> with TickerProviderStateMixin {
  late final _enter = AnimationController(vsync: this, duration: DeveloperConceptB.entrance);
  late final _aurora = AnimationController(vsync: this, duration: const Duration(seconds: 16));
  late final _spring = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  Offset _tilt = Offset.zero; // −1…1 each way, while the finger is down
  Offset _released = Offset.zero;
  bool _dragging = false;
  bool? _wasStill;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = _stillOf(context);
    if (still == _wasStill) return;
    _wasStill = still;
    if (still) {
      _enter.value = 1;
      _aurora.stop();
    } else {
      if (_enter.value < 1) _enter.forward();
      _aurora.repeat();
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _aurora.dispose();
    _spring.dispose();
    super.dispose();
  }

  Offset get _currentTilt {
    if (_dragging) return _tilt;
    if (_spring.isAnimating || _spring.value < 1) {
      return _released * (1 - const ElasticOutCurve(0.55).transform(_spring.value));
    }
    return Offset.zero;
  }

  // Horizontal drags only, so the About page still scrolls vertically; the
  // finger's height on the card gives the up/down tilt.
  void _start(DragStartDetails d) {
    _spring.stop();
    _dragging = true;
    _tilt = _currentTiltFromSpring();
  }

  Offset _currentTiltFromSpring() => _spring.value < 1 ? _released * (1 - const ElasticOutCurve(0.55).transform(_spring.value)) : Offset.zero;

  void _update(DragUpdateDetails d, Size size) {
    setState(() {
      final dx = (_tilt.dx + d.delta.dx / 110).clamp(-1.0, 1.0);
      final dy = ((d.localPosition.dy / size.height) * 2 - 1).clamp(-1.0, 1.0);
      _tilt = Offset(dx, dy);
    });
  }

  void _end([DragEndDetails? _]) {
    _dragging = false;
    _released = _tilt;
    _tilt = Offset.zero;
    if (_stillOf(context)) {
      _spring.value = 1;
      setState(() {});
    } else {
      _spring.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final ink = dark ? Colors.white : const Color(0xFF1A0B12);
    final inkSoft = dark ? Colors.white.withValues(alpha: 0.72) : const Color(0xFF1A0B12).withValues(alpha: 0.62);
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, 244);
        return GestureDetector(
          onHorizontalDragStart: _start,
          onHorizontalDragUpdate: (d) => _update(d, size),
          onHorizontalDragEnd: _end,
          onHorizontalDragCancel: _end,
          child: AnimatedBuilder(
            animation: Listenable.merge([_enter, _spring]),
            builder: (context, child) {
              final t = _iv(_enter.value, 0, 0.3, Curves.easeOutCubic);
              final tilt = _currentTilt;
              return Opacity(
                opacity: t,
                child: Transform.translate(
                  offset: Offset(0, 28 * (1 - t)),
                  child: Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..setEntry(3, 2, 0.0011)
                      ..rotateX(-tilt.dy * 0.12)
                      ..rotateY(tilt.dx * 0.22),
                    child: SizedBox(
                      height: size.height,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(30),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            RepaintBoundary(
                              child: CustomPaint(painter: _AuroraPainter(_aurora, dark: dark, shift: Offset(-tilt.dx * 18, -tilt.dy * 10))),
                            ),
                            Padding(
                              padding: const EdgeInsets.all(12),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(22),
                                child: BackdropFilter(
                                  filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(22),
                                      color: dark ? Colors.black.withValues(alpha: 0.36) : Colors.white.withValues(alpha: 0.48),
                                      border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.16 : 0.7)),
                                      gradient: LinearGradient(
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                        colors: [Colors.white.withValues(alpha: dark ? 0.10 : 0.30), Colors.white.withValues(alpha: 0)],
                                      ),
                                    ),
                                    child: Transform.translate(offset: Offset(tilt.dx * 5, tilt.dy * 3), child: child),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      AnimatedBuilder(
                        animation: _enter,
                        builder: (context, child) {
                          final s = _iv(_enter.value, 0.08, 0.4, Curves.easeOutBack);
                          return Transform.scale(scale: 0.6 + 0.4 * s, child: Opacity(opacity: s.clamp(0.0, 1.0), child: child));
                        },
                        child: _Avatar(size: 62, ring: Colors.white.withValues(alpha: 0.85)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            AnimatedBuilder(
                              animation: _enter,
                              builder: (context, child) => Opacity(opacity: _iv(_enter.value, 0.12, 0.25), child: child),
                              child: Text('DEVELOPER', style: TextStyle(color: inkSoft, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.8)),
                            ),
                            const SizedBox(height: 3),
                            AnimatedBuilder(animation: _enter, builder: (context, _) => _typed(ink, p)),
                            const SizedBox(height: 2),
                            AnimatedBuilder(
                              animation: _enter,
                              builder: (context, child) => Opacity(opacity: _iv(_enter.value, 0.6, 0.75), child: child),
                              child: Text('Made ${Brand.appName} with love', style: BT.sub.copyWith(color: inkSoft)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  Row(
                    children: [
                      Expanded(
                        child: _Pop(
                          anim: _enter,
                          from: 0.6,
                          child: _GlassButton(
                            glyph: const _InstaGlyph(),
                            label: 'Instagram',
                            onTap: () => widget.open(DeveloperLinks.instagram),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _Pop(
                          anim: _enter,
                          from: 0.68,
                          child: _GlassButton(
                            glyph: const _FbGlyph(),
                            label: 'Facebook',
                            onTap: () => widget.open(DeveloperLinks.facebook),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  AnimatedBuilder(
                    animation: _enter,
                    builder: (context, child) => Opacity(opacity: _iv(_enter.value, 0.8, 0.95), child: child),
                    child: Text(
                      '${DeveloperLinks.instagramHandle}  ·  ${Brand.copyright}',
                      textAlign: TextAlign.center,
                      style: BT.caption.copyWith(color: inkSoft, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _typed(Color ink, BytePalette p) {
    const name = DeveloperLinks.name;
    final v = _enter.value;
    final n = (name.length * _iv(v, 0.22, 0.62)).round();
    final typing = v > 0.18 && v < 0.82;
    final caretOn = typing && ((v * DeveloperConceptB.entrance.inMilliseconds) ~/ 260).isEven;
    const style = TextStyle(fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -0.5, height: 1.2);
    return Semantics(
      label: name,
      child: ExcludeSemantics(
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(text: name.substring(0, n), style: style.copyWith(color: ink)),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Container(width: 2, height: 22, margin: const EdgeInsets.symmetric(horizontal: 1), color: caretOn ? _red1 : Colors.transparent),
              ),
              TextSpan(text: name.substring(n), style: style.copyWith(color: Colors.transparent)),
            ],
          ),
          maxLines: 1,
          softWrap: false,
        ),
      ),
    );
  }
}

/// Springy pop-in for a child, starting at [from] of [anim].
class _Pop extends StatelessWidget {
  final Animation<double> anim;
  final double from;
  final Widget child;
  const _Pop({required this.anim, required this.from, required this.child});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: anim,
    builder: (context, child) {
      final raw = _iv(anim.value, from, from + 0.3);
      final s = raw >= 1 ? 1.0 : const ElasticOutCurve(0.45).transform(raw);
      return Opacity(
        opacity: _iv(anim.value, from, from + 0.06),
        child: Transform.scale(scale: 0.4 + 0.6 * s, child: child),
      );
    },
    child: child,
  );
}

class _GlassButton extends StatelessWidget {
  final Widget glyph;
  final String label;
  final VoidCallback onTap;
  const _GlassButton({required this.glyph, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _Press(
      onTap: onTap,
      label: label,
      radius: 25,
      color: dark ? Colors.white.withValues(alpha: 0.10) : Colors.white.withValues(alpha: 0.62),
      border: Colors.white.withValues(alpha: dark ? 0.20 : 0.9),
      child: SizedBox(
        height: 50,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox.square(dimension: 26, child: glyph),
            const SizedBox(width: 9),
            Text(label, style: TextStyle(color: dark ? Colors.white : const Color(0xFF1A0B12), fontSize: 15.5, fontWeight: FontWeight.w700, letterSpacing: -0.2)),
          ],
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final Animation<double> t;
  final bool dark;
  final Offset shift;
  _AuroraPainter(this.t, {required this.dark, required this.shift}) : super(repaint: t);

  // colour, x/y frequency (integers loop seamlessly), phase, radius
  static const _blobs = [
    (_red1, 1, 2, 0.0, 0.62),
    (_purple, 2, 1, 1.7, 0.66),
    (_amber, 1, 1, 3.4, 0.52),
    (_red2, 1, 2, 4.6, 0.55),
  ];

  @override
  void paint(Canvas c, Size s) {
    c.drawRect(Offset.zero & s, Paint()..color = dark ? const Color(0xFF14060F) : const Color(0xFFFFE8EE));
    final tw = 2 * math.pi * t.value;
    for (final (color, fx, fy, ph, rad) in _blobs) {
      final cx = s.width * (0.5 + 0.36 * math.cos(tw * fx + ph)) + shift.dx;
      final cy = s.height * (0.5 + 0.40 * math.sin(tw * fy + ph * 1.3)) + shift.dy;
      final r = s.width * rad;
      final a = dark ? 0.78 : 0.70;
      c.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [color.withValues(alpha: a), color.withValues(alpha: a * 0.4), color.withValues(alpha: 0)],
            stops: const [0, 0.45, 1],
          ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.dark != dark || old.shift != shift;
}

// ════════════════════════════════════════════════════════════════════════
// C — Signature
// ════════════════════════════════════════════════════════════════════════

class DeveloperConceptC extends StatefulWidget {
  final Future<bool> Function(Uri) open;
  const DeveloperConceptC({super.key, this.open = openExternal});

  static const entrance = Duration(milliseconds: 3400);

  @override
  State<DeveloperConceptC> createState() => _ConceptCState();
}

class _ConceptCState extends State<DeveloperConceptC> with TickerProviderStateMixin {
  late final _enter = AnimationController(vsync: this, duration: DeveloperConceptC.entrance);
  late final _beat = AnimationController(vsync: this, duration: _idleBeat);
  static const _idleBeat = Duration(milliseconds: 1800);
  static const _playingBeat = Duration(milliseconds: 860);
  StreamSubscription<Object?>? _sub;
  bool _playing = false;
  bool? _wasStill;

  @override
  void initState() {
    super.initState();
    try {
      _playing = Services.i.player.playing;
      _sub = Services.i.player.playbackState.listen((s) {
        if (s.playing != _playing) {
          _playing = s.playing;
          _restartBeat();
        }
      });
    } catch (_) {
      // no player (tests, previews): the slow pulse
    }
  }

  // 2.0: the pulse beats only while a song plays, 30 times a second on a
  // timer (not every screen refresh); paused, it rests and nothing draws.
  Timer? _beatTimer;

  void _restartBeat() {
    if (!mounted) return;
    _beatTimer?.cancel();
    _beatTimer = null;
    if (_stillOf(context) || !_playing) {
      _beat.value = 0.35;
      return;
    }
    final start = DateTime.now().millisecondsSinceEpoch;
    final ms = _playingBeat.inMilliseconds;
    _beatTimer = Timer.periodic(const Duration(milliseconds: 40), (_) {
      if (!mounted) return;
      _beat.value = ((DateTime.now().millisecondsSinceEpoch - start) % ms) / ms;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final still = _stillOf(context);
    if (still == _wasStill) return;
    _wasStill = still;
    if (still) {
      _enter.value = 1;
      _beat.stop();
      _beat.value = 0.35;
    } else {
      if (_enter.value < 1) _enter.forward();
      _restartBeat();
    }
  }

  @override
  void dispose() {
    _beatTimer?.cancel();
    _sub?.cancel();
    _enter.dispose();
    _beat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: _enter,
      builder: (context, child) {
        final t = _iv(_enter.value, 0, 0.14, Curves.easeOutCubic);
        return Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 24 * (1 - t)), child: child));
      },
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: p.separator),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: dark ? const [Color(0xFF1E1A1C), Color(0xFF131112)] : const [Colors.white, Color(0xFFFBF7F8)],
          ),
        ),
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: 64,
                  child: CustomPaint(
                    painter: _BeatPainter(_beat, color: _red1, still: _stillOf(context)),
                    child: const Center(child: _Avatar(size: 46)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('DEVELOPER', style: TextStyle(color: p.accent, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
                      const SizedBox(height: 2),
                      Text('Made ${Brand.appName} with love', style: BT.sub.copyWith(color: p.secondary)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Semantics(
              label: DeveloperLinks.name,
              child: SizedBox(
                height: 104,
                child: RepaintBoundary(
                  child: CustomPaint(painter: _SignaturePainter(_enter, dark: dark)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            AnimatedBuilder(
              animation: _enter,
              builder: (context, child) {
                final t = _iv(_enter.value, 0.58, 0.76, Curves.easeOutCubic);
                return Opacity(opacity: t, child: Transform.translate(offset: Offset(0, 12 * (1 - t)), child: child));
              },
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: _Chip(
                      glyph: const _InstaGlyph(),
                      label: DeveloperLinks.instagramHandle,
                      shimmer: _enter,
                      at: 0.78,
                      onTap: () => widget.open(DeveloperLinks.instagram),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(
                    child: _Chip(
                      glyph: const _FbGlyph(),
                      label: 'Facebook',
                      shimmer: _enter,
                      at: 0.84,
                      onTap: () => widget.open(DeveloperLinks.facebook),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final Widget glyph;
  final String label;
  final Animation<double> shimmer;
  final double at;
  final VoidCallback onTap;
  const _Chip({required this.glyph, required this.label, required this.shimmer, required this.at, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return _Press(
      onTap: onTap,
      label: label,
      radius: 22,
      color: dark ? Colors.white.withValues(alpha: 0.07) : const Color(0xFFF6F1F3),
      border: p.separator,
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox.square(dimension: 26, child: glyph),
                const SizedBox(width: 9),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w700, fontSize: 14.5),
                  ),
                ),
              ],
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(child: CustomPaint(painter: _ShinePainter(shimmer, from: at, dark: dark))),
            ),
          ),
        ],
      ),
    );
  }
}

/// One diagonal light sweep across a chip, once, during [from]…[from]+0.14.
class _ShinePainter extends CustomPainter {
  final Animation<double> t;
  final double from;
  final bool dark;
  _ShinePainter(this.t, {required this.from, required this.dark}) : super(repaint: t);

  @override
  void paint(Canvas c, Size s) {
    final k = (t.value - from) / 0.14;
    if (k <= 0 || k >= 1) return;
    final x = -s.width * 0.4 + k * s.width * 1.8;
    final band = Rect.fromLTWH(x - 30, -s.height, 60, s.height * 3);
    final shine = Paint()
      ..shader = LinearGradient(
        colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: dark ? 0.28 : 0.85), Colors.white.withValues(alpha: 0)],
      ).createShader(band);
    c.save();
    c.translate(x, s.height / 2);
    c.rotate(0.35);
    c.translate(-x, -s.height / 2);
    c.drawRect(band, shine);
    c.restore();
  }

  @override
  bool shouldRepaint(_ShinePainter old) => old.from != from || old.dark != dark;
}

/// Expanding rings around the avatar, a slow heartbeat.
class _BeatPainter extends CustomPainter {
  final Animation<double> t;
  final Color color;
  final bool still;
  _BeatPainter(this.t, {required this.color, required this.still}) : super(repaint: t);

  @override
  void paint(Canvas c, Size s) {
    final o = s.center(Offset.zero);
    const r0 = 24.0;
    final rMax = s.width / 2 - 1;
    // the steady ring
    c.drawCircle(
      o,
      r0 + 3,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..shader = const SweepGradient(colors: [_red1, _amber, _purple, _red1]).createShader(Rect.fromCircle(center: o, radius: r0 + 3)),
    );
    for (final off in still ? const [0.35] : const [0.0, 0.5]) {
      final k = (t.value + off) % 1.0;
      final e = Curves.easeOutCubic.transform(k);
      final r = r0 + 3 + (rMax - r0 - 3) * e;
      c.drawCircle(
        o,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2 * (1 - k) + 0.6
          ..color = color.withValues(alpha: 0.55 * (1 - k)),
      );
    }
  }

  @override
  bool shouldRepaint(_BeatPainter old) => old.color != color || old.still != still;
}

/// "Apurba Laskar" as a pen-pressure signature (1.4.3 v2): hand-authored
/// strokes (A, "purba", "Laskar", the swash), Catmull-Rom points turned into
/// cubics and slanted, then drawn as a ribbon whose width follows the pen:
/// thick on downstrokes, hairline on upstrokes, tapered at both ends. Ink is a
/// pink→purple gradient (gold in dark mode) with a light that travels with
/// the nib, then one sweep across the finished name.
class _SignaturePainter extends CustomPainter {
  final Animation<double> t;
  final bool dark;
  _SignaturePainter(this.t, {required this.dark}) : super(repaint: t);

  // Points in the design box (baseline y = 100, x-height 70, ascenders ~22).
  static const _a = <double>[-4, 100, 8, 84, 20, 52, 30, 26, 33, 22, 36, 30, 40, 62, 44, 100, 49, 103];
  static const _purba = <double>[4, 82, 22, 75, 44, 71, 56, 70, 60, 74, 58, 100, 55, 136, 57, 104, 62, 80, 70, 71, 79, 74, 80, 88, 72, 99, 62, 98, 70, 99, 80, 96, 86, 86, 90, 70, 89, 92, 95, 100, 103, 95, 107, 80, 109, 70, 108, 94, 113, 100, 119, 96, 122, 82, 122, 70, 123, 99, 123, 86, 128, 74, 136, 70, 141, 74, 148, 52, 154, 30, 154, 24, 149, 26, 145, 42, 142, 72, 141, 96, 149, 100, 158, 95, 161, 82, 154, 73, 147, 78, 155, 83, 166, 80, 178, 72, 168, 70, 162, 82, 165, 98, 173, 98, 179, 86, 182, 70, 181, 94, 187, 100, 196, 94];
  static const _laskar = <double>[212, 64, 226, 38, 238, 22, 236, 17, 228, 24, 222, 50, 216, 94, 208, 104, 214, 110, 226, 103, 238, 100, 247, 95, 258, 72, 248, 70, 242, 82, 245, 98, 254, 98, 260, 86, 262, 72, 262, 96, 268, 100, 274, 95, 280, 72, 287, 84, 284, 99, 274, 98, 281, 99, 291, 95, 300, 62, 307, 34, 310, 24, 304, 24, 300, 42, 296, 100, 299, 86, 310, 72, 316, 78, 306, 86, 300, 86, 308, 90, 314, 100, 323, 96, 336, 72, 326, 70, 320, 82, 323, 98, 332, 98, 338, 86, 340, 72, 340, 96, 346, 100, 353, 95, 357, 82, 358, 70, 359, 99, 359, 86, 364, 74, 372, 70, 378, 75];
  static const _swash = <double>[2, 126, 60, 130, 200, 129, 320, 118, 392, 104, 412, 92];
  static const box = Rect.fromLTRB(-10, 12, 420, 140);

  // when the pen starts and finishes (fractions of the entrance: ~1.8 s)
  static const penFrom = 0.08;
  static const penTo = 0.62;

  static Offset _slant(double x, double y) => Offset(x + (100 - y) * 0.22, y);

  static Path _curve(List<double> flat) {
    final pts = <Offset>[for (var i = 0; i < flat.length; i += 2) _slant(flat[i], flat[i + 1])];
    final q = [pts.first, ...pts, pts.last];
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < q.length - 2; i++) {
      final p0 = q[i - 1], p1 = q[i], p2 = q[i + 1], p3 = q[i + 2];
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    return path;
  }

  /// One stroke sampled every unit: centre, normal and pen width.
  static List<_Nib> _sample(List<double> flat, {required double thin, required double thick, double taperIn = 10, double taperOut = 16}) {
    final out = <_Nib>[];
    for (final m in _curve(flat).computeMetrics()) {
      final n = math.max(2, m.length.ceil());
      for (var i = 0; i <= n; i++) {
        final d = m.length * i / n;
        final tan = m.getTangentForOffset(d);
        if (tan == null) continue;
        final v = tan.vector;
        final down = math.max(0.0, v.dy); // pen moving down the page
        var w = thin + (thick - thin) * math.pow(down, 1.15);
        final ramp = math.min(1.0, math.min((d + 2) / taperIn, (m.length - d + 2) / taperOut));
        w *= 0.35 + 0.65 * ramp.clamp(0.0, 1.0);
        out.add(_Nib(tan.position, Offset(-v.dy, v.dx), w, d));
      }
    }
    return out;
  }

  static List<List<_Nib>>? _cache;
  static List<List<_Nib>> get strokes => _cache ??= [
    _sample(_a, thin: 1.4, thick: 5.4),
    _sample(_purba, thin: 1.3, thick: 4.8),
    _sample(_laskar, thin: 1.3, thick: 4.8),
    _sample(_swash, thin: 1.1, thick: 3.0, taperIn: 40, taperOut: 70),
  ];
  static double get total => strokes.fold(0.0, (a, s) => a + s.last.d);

  /// The ribbon of [s] up to sample [upTo] (exclusive), as a filled outline.
  static Path _ribbon(List<_Nib> s, int upTo) {
    final p = Path();
    if (upTo < 2) return p;
    final a = s[0];
    p.moveTo(a.at.dx + a.n.dx * a.w / 2, a.at.dy + a.n.dy * a.w / 2);
    for (var i = 1; i < upTo; i++) {
      final b = s[i];
      p.lineTo(b.at.dx + b.n.dx * b.w / 2, b.at.dy + b.n.dy * b.w / 2);
    }
    for (var i = upTo - 1; i >= 0; i--) {
      final b = s[i];
      p.lineTo(b.at.dx - b.n.dx * b.w / 2, b.at.dy - b.n.dy * b.w / 2);
    }
    p.close();
    // round the pen's two ends
    p.addOval(Rect.fromCircle(center: a.at, radius: a.w / 2));
    final e = s[upTo - 1];
    p.addOval(Rect.fromCircle(center: e.at, radius: e.w / 2));
    return p;
  }

  static final List<Path?> _full = List.filled(4, null);

  List<Color> get _ink => dark
      ? const [Color(0xFFC9963B), Color(0xFFFFE3A0), Color(0xFFE2B24E), Color(0xFFB8862C)]
      : const [Color(0xFFE0103F), Color(0xFFC2127A), Color(0xFF7A3BD6)];

  // sparkles: position in the design box, size, colour index, delay
  static const _sparks = [
    (Offset(-4, 40), 7.0, 0, 0.00),
    (Offset(76, 14), 5.0, 1, 0.05),
    (Offset(200, 30), 8.0, 2, 0.10),
    (Offset(268, 10), 5.0, 0, 0.02),
    (Offset(404, 52), 9.0, 1, 0.08),
    (Offset(418, 116), 5.0, 2, 0.14),
    (Offset(330, 138), 6.0, 0, 0.11),
    (Offset(150, 140), 5.0, 1, 0.04),
    (Offset(8, 136), 6.0, 2, 0.16),
    (Offset(380, 22), 4.0, 2, 0.18),
  ];

  @override
  void paint(Canvas c, Size s) {
    final v = t.value;
    final scale = math.min(s.width / box.width, s.height / box.height);
    final dx = (s.width - box.width * scale) / 2 - box.left * scale;
    final dy = (s.height - box.height * scale) / 2 - box.top * scale;
    c.save();
    c.translate(dx, dy);
    c.scale(scale);

    final prog = _iv(v, penFrom, penTo, Curves.easeInOutSine);
    var left = total * prog;
    Offset? tip;
    final ink = Path();
    final all = strokes;
    for (var i = 0; i < all.length && left > 0; i++) {
      final st = all[i];
      final len = st.last.d;
      if (left >= len) {
        ink.addPath(_full[i] ??= _ribbon(st, st.length), Offset.zero);
      } else {
        var k = 0;
        while (k < st.length && st[k].d <= left) {
          k++;
        }
        ink.addPath(_ribbon(st, k), Offset.zero);
        if (k > 0) tip = st[k - 1].at;
      }
      left -= len;
    }
    final layer = box.inflate(8);
    c.saveLayer(layer, Paint());
    c.drawPath(ink, Paint()..shader = LinearGradient(colors: _ink).createShader(Rect.fromLTRB(box.left, 20, box.right, 130)));
    // a soft light rides with the nib, then one sweep across the name
    final sweep = _iv(v, 0.64, 0.82, Curves.easeInOutCubic);
    final shineX = tip?.dx ?? (sweep > 0 && sweep < 1 ? box.left - 40 + (box.width + 80) * sweep : null);
    if (shineX != null) {
      final r = Rect.fromLTRB(shineX - 46, box.top, shineX + 46, box.bottom);
      c.drawRect(
        r,
        Paint()
          ..blendMode = BlendMode.srcATop
          ..shader = LinearGradient(colors: [Colors.white.withValues(alpha: 0), Colors.white.withValues(alpha: dark ? 0.75 : 0.55), Colors.white.withValues(alpha: 0)]).createShader(r),
      );
    }
    c.restore();

    // the pen nib leading the stroke
    if (tip != null && prog > 0 && prog < 1) {
      final glow = dark ? const Color(0xFFFFE3A0) : const Color(0xFFFF375F);
      c.drawCircle(tip, 10, Paint()..shader = RadialGradient(colors: [glow.withValues(alpha: 0.6), glow.withValues(alpha: 0)]).createShader(Rect.fromCircle(center: tip, radius: 10)));
      c.drawCircle(tip, 2.4, Paint()..color = dark ? Colors.white : const Color(0xFF8E0E3A));
    }

    // sparkles drift down into place after the pen lifts, then rest
    const colours = [_amber, _red1, _purple];
    for (final (pos, size, ci, delay) in _sparks) {
      final k = _iv(v, 0.60 + delay, 0.82 + delay, Curves.easeOutCubic);
      if (k <= 0) continue;
      final twinkle = math.sin(k * math.pi);
      final alpha = (0.45 + 0.55 * twinkle) * k.clamp(0.0, 1.0);
      final at = pos + Offset(0, -16 * (1 - k));
      _star(c, at, size * (0.7 + 0.5 * twinkle), colours[ci].withValues(alpha: alpha));
    }
    c.restore();
  }

  static void _star(Canvas c, Offset o, double r, Color color) {
    final w = r * 0.28;
    final p = Path()
      ..moveTo(o.dx, o.dy - r)
      ..quadraticBezierTo(o.dx + w * 0.4, o.dy - w * 0.4, o.dx + r, o.dy)
      ..quadraticBezierTo(o.dx + w * 0.4, o.dy + w * 0.4, o.dx, o.dy + r)
      ..quadraticBezierTo(o.dx - w * 0.4, o.dy + w * 0.4, o.dx - r, o.dy)
      ..quadraticBezierTo(o.dx - w * 0.4, o.dy - w * 0.4, o.dx, o.dy - r)
      ..close();
    c.drawPath(p, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SignaturePainter old) => old.dark != dark;
}

/// One sample of the pen: where, which way is "across", how wide, how far along.
class _Nib {
  final Offset at;
  final Offset n;
  final double w;
  final double d;
  const _Nib(this.at, this.n, this.w, this.d);
}

// ════════════════════════════════════════════════════════════════════════
// Shared bits
// ════════════════════════════════════════════════════════════════════════

/// The "AL" initials on the red gradient.
class _Avatar extends StatelessWidget {
  final double size;
  final Color? ring;
  const _Avatar({required this.size, this.ring});

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: const LinearGradient(colors: [_red1, _red2], begin: Alignment.topLeft, end: Alignment.bottomRight),
      border: ring == null ? null : Border.all(color: ring!, width: 3),
    ),
    child: Text(
      'AL',
      style: TextStyle(color: Colors.white, fontSize: size * 0.36, fontWeight: FontWeight.w800, letterSpacing: 0.5, height: 1),
    ),
  );
}

/// A tappable surface that dips to 96 % while pressed, with a ripple.
class _Press extends StatefulWidget {
  final VoidCallback onTap;
  final String label;
  final double radius;
  final Color color;
  final Color border;
  final Widget child;
  const _Press({required this.onTap, required this.label, required this.radius, required this.color, required this.border, required this.child});

  @override
  State<_Press> createState() => _PressState();
}

class _PressState extends State<_Press> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final still = _stillOf(context);
    final r = BorderRadius.circular(widget.radius);
    return Semantics(
      button: true,
      label: widget.label,
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: still ? Duration.zero : const Duration(milliseconds: 120),
        child: Material(
          color: widget.color,
          shape: RoundedRectangleBorder(borderRadius: r, side: BorderSide(color: widget.border)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onTap,
            onHighlightChanged: (v) => setState(() => _down = v),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

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

/// A white "f" on a blue circle (drawn, scales with its box).
class _FbGlyph extends StatelessWidget {
  const _FbGlyph();
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final w = box.maxWidth.isFinite ? box.maxWidth : 30.0;
      return Container(
        alignment: Alignment.center,
        decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF1877F2)),
        child: Padding(
          padding: EdgeInsets.only(top: w * 0.1, left: w * 0.03),
          child: Text('f', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: w * 0.7, height: 1)),
        ),
      );
    },
  );
}
