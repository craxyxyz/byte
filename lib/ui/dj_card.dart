import 'dart:math';

import 'package:flutter/material.dart';

import '../services.dart';
import 'logo.dart';
import 'nav.dart';
import 'screens/dj_screen.dart';
import 'glass.dart';
import 'style.dart';

/// The DJ's colours: Byte's brand gradient (deep red into the logo's pink).
const djGradient = [ByteColors.deep, ByteColors.brand, ByteColors.red, ByteColors.pink];

/// The DJ surface: brand gradient with a soft light from the top right and
/// the "b)" mark drawn large and faint, like a watermark.
class DjSurface extends StatelessWidget {
  final double radius;
  final Widget child;
  final bool waves;
  final bool active;
  final bool speaking;
  const DjSurface({super.key, required this.radius, required this.child, this.waves = true, this.active = false, this.speaking = false});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: ByteColors.surfaceGradient,
        boxShadow: [BoxShadow(color: ByteColors.red.withValues(alpha: 0.22), blurRadius: 24, offset: const Offset(0, 10))],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(center: const Alignment(0.9, -1.1), radius: 1.1, colors: [Colors.white.withValues(alpha: 0.22), Colors.white.withValues(alpha: 0)]),
                ),
              ),
            ),
            Positioned(
              right: -18,
              top: -6,
              bottom: -6,
              child: LayoutBuilder(
                builder: (context, c) => ByteMark(size: c.maxHeight, color: Colors.white.withValues(alpha: 0.13)),
              ),
            ),
            if (waves) Positioned(right: -10, top: 0, bottom: 0, width: 170, child: DjWaves(active: active, speaking: speaking)),
            child,
          ],
        ),
      ),
    );
  }
}

/// Home → the small "DJ" pill at the top: the DJ is a feature inside the app,
/// not a tab. Tap opens the DJ (talk to it, Mere liye mix, For you, sections,
/// voice). While the DJ is on it shows a live dot.
class DjPill extends StatelessWidget {
  const DjPill({super.key});
  @override
  Widget build(BuildContext context) {
    final dj = Services.i.dj;
    return ListenableBuilder(
      listenable: dj,
      builder: (context, _) {
        final on = dj.active;
        final p = BytePalette.of(context);
        return Semantics(
          button: true,
          label: on ? 'DJ is on, open the DJ' : 'Open the DJ',
          child: Pressable(
            key: const ValueKey('home-dj-pill'),
            onTap: () => openDj(context),
            child: LiquidGlass(
              radius: BorderRadius.circular(20),
              tint: on ? ByteColors.brand.withValues(alpha: 0.20) : null,
              child: SizedBox(
                height: 40,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.graphic_eq_rounded, size: 20, color: on ? ByteColors.brand : p.label),
                      const SizedBox(width: 6),
                      Text('DJ', style: TextStyle(color: on ? ByteColors.brand : p.label, fontSize: 15, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
                      if (on) ...[
                        const SizedBox(width: 6),
                        Container(width: 7, height: 7, decoration: const BoxDecoration(color: ByteColors.brand, shape: BoxShape.circle)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Opens the DJ page (from Home's pill, the player's ⋯ menu, anywhere).
void openDj(BuildContext context) {
  final shell = pushInCurrentTab;
  if (shell != null) {
    shell(const DjScreen());
  } else {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DjScreen()));
  }
}

/// Home → "DJ": starts (or opens) the personal DJ session.
class DjCard extends StatelessWidget {
  const DjCard({super.key});
  @override
  Widget build(BuildContext context) {
    final dj = Services.i.dj;
    return ListenableBuilder(
      listenable: dj,
      builder: (context, _) {
        final on = dj.active;
        final title = on ? 'DJ is on' : 'DJ';
        final sub = on
            ? (dj.segment?.title ?? 'Playing for you')
            : '${Services.i.settings.djName} ke liye non-stop mix';
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Pressable(
            onTap: () async {
              if (!on && !dj.starting) {
                // start right away; the DJ screen shows it coming up
                dj.start();
              }
              pushPage(context, const DjScreen());
            },
            child: SizedBox(
              height: 118,
              child: DjSurface(
                radius: 24,
                active: on && Services.i.player.playing,
                
                child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                title,
                                maxLines: 1,
                                style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: -0.8, height: 1),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                sub,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 14, height: 1.25),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Container(
                          width: 48,
                          height: 48,
                          decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                          child: dj.starting
                              ? const Padding(padding: EdgeInsets.all(14), child: CircularProgressIndicator(strokeWidth: 2.6, color: ByteColors.brand))
                              : Icon(on ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded, color: ByteColors.brand, size: 30),
                        ),
                      ],
                    ),
                  ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Soft moving bars behind the DJ's name (taller while the DJ talks).
class DjWaves extends StatefulWidget {
  final bool active;
  final bool speaking;
  const DjWaves({super.key, required this.active, this.speaking = false});
  @override
  State<DjWaves> createState() => _DjWavesState();
}

class _DjWavesState extends State<DjWaves> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 3));

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant DjWaves old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final reduce = Services.i.settings.reduceMotion;
    if (widget.active && !reduce) {
      if (!_c.isAnimating) _c.repeat();
    } else {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(painter: _WavePainter(_c.value, widget.speaking ? 1.0 : (widget.active ? 0.6 : 0.35))),
    ),
  );
}

class _WavePainter extends CustomPainter {
  final double t;
  final double level;
  _WavePainter(this.t, this.level);
  @override
  void paint(Canvas canvas, Size size) {
    const bars = 14;
    final w = size.width / (bars * 1.6);
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.16);
    for (var i = 0; i < bars; i++) {
      final ph = t * 2 * pi + i * 0.7;
      final h = size.height * (0.18 + level * 0.5 * (0.5 + 0.5 * sin(ph) * cos(ph * 0.6 + i)));
      final x = i * w * 1.6;
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(x, (size.height - h) / 2, w, h), Radius.circular(w / 2));
      canvas.drawRRect(r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) => old.t != t || old.level != level;
}
