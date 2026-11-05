import 'dart:ui';

import 'package:flutter/material.dart';

import '../glass.dart' show GlassEdgePainter, ReadableGlass;
import '../style.dart' show glassEnabled;
import 'glass_policy.dart';

// Byte 2.0 © 2026 Apurba Laskar.
//
// "Liquid glass" for the floating bars (tab bar, search button, mini player):
// a frosted translucent pill, tinted by what is behind it, with a bright thin
// edge that catches the light, a soft sheen, and a soft shadow underneath.
//
// Performance rules of 2.0 hold: with "Real glass blur" ON the bar blurs what
// is behind it (one BackdropFilter, only on the bar, in its own repaint
// boundary); OFF it is a dense translucent tint with the very same highlights.
// Nothing here animates by itself, so an idle bar costs nothing per frame.

/// The blur strength of a glass bar when "Real glass blur" is on.
const double kLiquidBlurSigma = 26;

/// A saturation boost behind the blur: glass lets colours behind it glow a bit.
const List<double> _saturate = [
  1.45, -0.23, -0.22, 0, 0, //
  -0.12, 1.34, -0.22, 0, 0,
  -0.12, -0.23, 1.35, 0, 0,
  0, 0, 0, 1, 0,
];

/// The tint of a mini-player bar from the cover colour: dark enough that white
/// text keeps a 4.5:1 contrast even where the glass is most see-through (over a
/// white page).
Color liquidMiniTint(Color art, {required bool blur}) {
  final alpha = blur ? 0.74 : 0.9;
  var c = Color.lerp(art.withValues(alpha: 1), Colors.black, 0.45)!;
  for (var i = 0; i < 20; i++) {
    final worst = ReadableGlass.over(c.withValues(alpha: alpha), Colors.white);
    if (ReadableGlass.contrast(Colors.white, worst) >= 4.5) break;
    c = Color.lerp(c, Colors.black, 0.15)!;
  }
  return c.withValues(alpha: alpha);
}

/// A floating glass bar. [tint] colours the glass (default: a cool white in the
/// light theme, a smoky grey in the dark theme).
class LiquidBar extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final Color? tint;
  final bool? dark;
  final bool shadow;
  const LiquidBar({super.key, required this.child, required this.radius, this.tint, this.dark, this.shadow = true});

  /// Whether this bar blurs what is behind it right now.
  static bool get blurOn => glassEnabled() && liveBlur();

  @override
  Widget build(BuildContext context) {
    final dark = this.dark ?? Theme.of(context).brightness == Brightness.dark;
    final blur = blurOn;
    final Color base;
    if (tint != null) {
      base = tint!;
    } else if (dark) {
      base = blur ? const Color(0x6B26262C) : const Color(0xEB1F1F24);
    } else {
      base = blur ? const Color(0x73F4F6FB) : const Color(0xEBF6F7FB);
    }
    // sheen: light falls from the top-left; a faint glow comes back up from the bottom
    final sheen = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: dark ? 0.18 : 0.55),
            Colors.white.withValues(alpha: dark ? 0.03 : 0.10),
            Colors.white.withValues(alpha: dark ? 0.07 : 0.22),
          ],
          stops: const [0, 0.55, 1],
        ),
      ),
    );
    Widget body = Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(child: DecoratedBox(key: const ValueKey('liquid-tint'), decoration: BoxDecoration(color: base, borderRadius: radius))),
        Positioned.fill(child: sheen),
        // the refraction edge: a bright thin line, then a second faint one just inside it
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: GlassEdgePainter(radius: radius, dark: dark, width: 1.2)))),
        Positioned.fill(
          child: IgnorePointer(
            child: Padding(
              padding: const EdgeInsets.all(1.6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.all(Radius.circular(radius.topLeft.x)),
                  border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.05 : 0.28), width: 0.8),
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
    body = ClipRRect(
      borderRadius: radius,
      child: blur
          ? BackdropFilter(
              key: const ValueKey('liquid-blur'),
              filter: ImageFilter.compose(
                outer: const ColorFilter.matrix(_saturate),
                inner: ImageFilter.blur(sigmaX: kLiquidBlurSigma, sigmaY: kLiquidBlurSigma, tileMode: TileMode.mirror),
              ),
              child: body,
            )
          : body,
    );
    return RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: shadow
              ? [
                  BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.38 : 0.14), blurRadius: 26, offset: const Offset(0, 10)),
                  BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.30 : 0.08), blurRadius: 4, offset: const Offset(0, 1)),
                ]
              : null,
        ),
        child: body,
      ),
    );
  }
}

/// The glassy capsule behind the selected tab: a brighter, slightly accent
/// tinted drop of glass with its own bright edge.
class LiquidCapsule extends StatelessWidget {
  final Color accent;
  final bool dark;
  const LiquidCapsule({super.key, required this.accent, required this.dark});
  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(30);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.30 : 0.10), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(decoration: BoxDecoration(color: accent.withValues(alpha: dark ? 0.14 : 0.13))),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withValues(alpha: dark ? 0.22 : 0.80), Colors.white.withValues(alpha: dark ? 0.05 : 0.18)],
                ),
              ),
            ),
            IgnorePointer(child: CustomPaint(painter: GlassEdgePainter(radius: r, dark: dark, width: 1.2))),
          ],
        ),
      ),
    );
  }
}
