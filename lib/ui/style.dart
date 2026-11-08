import 'dart:ui';
import 'kit/glass_policy.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services.dart';
import 'glass.dart';

/// Byte's brand colours, taken from the logo (white "b)" on red-pink).
class ByteColors {
  /// The logo's two reds: top and bottom of the icon.
  static const pink = Color(0xFFFF4563);
  static const red = Color(0xFFF01848);

  /// Buttons, sliders, switches: a touch deeper so white text on it passes
  /// contrast (4.9:1), and red text on white does too.
  static const brand = Color(0xFFE0103F);

  /// Deep end of the brand gradient (big surfaces like the DJ card).
  static const deep = Color(0xFFB80D36);

  /// Red text on light backgrounds and grey cards (4.9:1 on the grey card).
  static const brandText = Color(0xFFD20E3B);

  /// Red text on dark backgrounds (6.6:1 on near-black).
  static const brandOnDark = Color(0xFFFF5C78);

  /// The logo gradient, used sparingly (logo tiles, the DJ, the play button).
  static const logoGradient = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [pink, red]);

  /// The richer gradient for large brand surfaces: deep on the left (where
  /// white text sits) into the logo's pink.
  static const surfaceGradient = LinearGradient(
    begin: Alignment(-1, -0.4),
    end: Alignment(1, 0.4),
    colors: [deep, brand, red, pink],
    stops: [0, 0.38, 0.72, 1],
  );
}

/// Byte's colour tokens (clean light look by default, true dark as an option).
@immutable
class BytePalette extends ThemeExtension<BytePalette> {
  final Color bg; // page background
  final Color label; // primary text
  final Color secondary; // grey text
  final Color tertiary; // chevrons, hints
  final Color separator; // hairlines
  final Color grouped; // grouped-list cards, tiles
  final Color fill; // search field, segmented track
  final Color glass; // floating bars tint
  final Color glassBorder;
  final Color accent; // highlights (rank #1, links)
  final Color avatar; // avatar circle
  final Color skeleton;
  const BytePalette({
    required this.bg,
    required this.label,
    required this.secondary,
    required this.tertiary,
    required this.separator,
    required this.grouped,
    required this.fill,
    required this.glass,
    required this.glassBorder,
    required this.accent,
    required this.avatar,
    required this.skeleton,
  });

  static const light = BytePalette(
    bg: Color(0xFFFFFFFF),
    label: Color(0xFF000000),
    secondary: Color(0xFF6E6E73),
    tertiary: Color(0xFFAEAEB2),
    separator: Color(0xFFE8E4E6),
    grouped: Color(0xFFF6F3F4),
    fill: Color(0xFFF1EDEF),
    glass: Color(0xC7F7F7F9),
    glassBorder: Color(0x14000000),
    accent: ByteColors.brandText,
    avatar: Color(0xFF7E95A5),
    skeleton: Color(0xFFEDEDF0),
  );

  static const dark = BytePalette(
    bg: Color(0xFF000000),
    label: Color(0xFFFFFFFF),
    secondary: Color(0xFF98989F),
    tertiary: Color(0xFF636366),
    separator: Color(0xFF2E2A2C),
    grouped: Color(0xFF1B191A),
    fill: Color(0xFF252224),
    glass: Color(0xB81C1C1E),
    glassBorder: Color(0x1FFFFFFF),
    accent: ByteColors.brandOnDark,
    avatar: Color(0xFF5E7585),
    skeleton: Color(0xFF1C1C1E),
  );

  static BytePalette of(BuildContext context) => Theme.of(context).extension<BytePalette>() ?? light;

  @override
  BytePalette copyWith() => this;

  BytePalette copyWithBg(Color c) => BytePalette(
    bg: c,
    label: label,
    secondary: secondary,
    tertiary: tertiary,
    separator: separator,
    grouped: grouped,
    fill: fill,
    glass: glass,
    glassBorder: glassBorder,
    accent: accent,
    avatar: avatar,
    skeleton: skeleton,
  );

  @override
  BytePalette lerp(BytePalette? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return BytePalette(
      bg: l(bg, other.bg),
      label: l(label, other.label),
      secondary: l(secondary, other.secondary),
      tertiary: l(tertiary, other.tertiary),
      separator: l(separator, other.separator),
      grouped: l(grouped, other.grouped),
      fill: l(fill, other.fill),
      glass: l(glass, other.glass),
      glassBorder: l(glassBorder, other.glassBorder),
      accent: l(accent, other.accent),
      avatar: l(avatar, other.avatar),
      skeleton: l(skeleton, other.skeleton),
    );
  }
}

/// Type scale used across the app.
class BT {
  static const largeTitle = TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.9, height: 1.15);
  static const title2 = TextStyle(fontSize: 22, fontWeight: FontWeight.w800, letterSpacing: -0.4);
  static const title3 = TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.3);
  static const section = TextStyle(fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.3);
  static const body = TextStyle(fontSize: 17, fontWeight: FontWeight.w400, letterSpacing: -0.2);
  static const bodyStrong = TextStyle(fontSize: 17, fontWeight: FontWeight.w600, letterSpacing: -0.2);
  static const row = TextStyle(fontSize: 16, fontWeight: FontWeight.w400, letterSpacing: -0.2);
  static const sub = TextStyle(fontSize: 14, fontWeight: FontWeight.w400, letterSpacing: -0.1);
  static const caption = TextStyle(fontSize: 13, fontWeight: FontWeight.w400);
  static const caps = TextStyle(fontSize: 13, fontWeight: FontWeight.w400, letterSpacing: 0.2);
  static const tab = TextStyle(fontSize: 11, fontWeight: FontWeight.w600, letterSpacing: 0.1);
}

/// Whether frosted-glass blur is on (Settings → Performance).
bool glassEnabled() {
  try {
    return Services.i.settings.glassEffects;
  } catch (_) {
    return true;
  }
}

/// A frosted, translucent surface (bars, pills, buttons over content).
class GlassBox extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final Color? tint;
  final bool shadow;
  final double blur;

  /// The floating bar's "liquid" glass: a soft light sheen on top (Appearance → Liquid Glass).
  final bool liquid;

  /// Top bars: the blur fades out downwards instead of ending in a line (Progressive Blur).
  final bool fadeBottom;
  const GlassBox({super.key, required this.child, required this.radius, this.tint, this.shadow = true, this.blur = 24, this.liquid = false, this.fadeBottom = false});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final st = Services.i.settings;
    final on = glassEnabled() && (!liquid || st.liquidGlass);
    // Appearance → Liquid glass: the thin bright edge + sheen on every glass bar.
    final shine = on && st.liquidGlass;
    final fade = fadeBottom && on && st.progressiveBlur;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final base = tint ?? (on ? p.glass : Color.alphaBlend(p.glass.withValues(alpha: 1), p.bg));
    final color = on ? base.withValues(alpha: frostedAlpha(base.a, dark: dark)) : base;
    final sigma = GlassPerf.light.value ? blur * 0.3 : blur;
    // 1.4.1 fix: the tint and the light sheen are two layers. They used to be
    // one BoxDecoration with both a colour and a gradient, and a gradient
    // replaces the colour, so with Liquid glass on the bars (mini player, tab
    // bar) had NO tint at all, only the faint sheen over the blur — the "low
    // visibility" Apurba saw on his phone.
    Widget inner = shine && !fade ? CustomPaint(foregroundPainter: GlassEdgePainter(radius: radius, dark: dark), child: child) : child;
    if (shine && !fade) {
      inner = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: liquid ? Alignment.bottomCenter : Alignment.center,
            colors: [Colors.white.withValues(alpha: dark ? 0.08 : (liquid ? 0.16 : 0.22)), Colors.white.withValues(alpha: 0.0)],
          ),
        ),
        child: inner,
      );
    }
    Widget body = DecoratedBox(
      key: const ValueKey('glass-tint'),
      decoration: BoxDecoration(
        color: color,
        borderRadius: radius,
        border: fade || shine ? null : Border.all(color: p.glassBorder, width: 0.6),
      ),
      child: inner,
    );
    if (on && liveBlur()) body = BackdropFilter(filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: body);
    if (fade && liveBlur()) {
      body = ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (r) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.white, Colors.white, Colors.transparent],
          stops: [0, 0.6, 1],
        ).createShader(r),
        child: body,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: shadow ? [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 24, offset: const Offset(0, 6))] : null,
      ),
      child: ClipRRect(borderRadius: radius, child: body),
    );
  }
}

/// Round frosted button (back, history, search…).
class CircleGlassButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final String? tooltip;
  final double iconSize;
  const CircleGlassButton({super.key, required this.icon, this.onTap, this.size = 44, this.tooltip, this.iconSize = 24});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    Widget w = GlassBox(
      radius: BorderRadius.circular(size / 2),
      shadow: false,
      child: SizedBox(
        width: size,
        height: size,
        child: Icon(icon, size: iconSize, color: p.label),
      ),
    );
    w = Pressable(onTap: onTap, child: w);
    return tooltip == null ? w : Tooltip(message: tooltip!, child: w);
  }
}

/// Scales down a little while pressed (the iOS-like touch feel).
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// A right click on a computer (the same menu as a long press on a phone).
  final VoidCallback? onSecondaryTap;
  final double scale;
  const Pressable({super.key, required this.child, this.onTap, this.onLongPress, this.onSecondaryTap, this.scale = 0.96});
  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool down = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.onTap == null && widget.onLongPress == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => setState(() => down = true),
      onTapCancel: () => setState(() => down = false),
      onTapUp: (_) => setState(() => down = false),
      onTap: widget.onTap == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              widget.onTap!();
            },
      onLongPress: widget.onLongPress,
      onSecondaryTap: widget.onSecondaryTap,
      child: AnimatedScale(scale: down ? widget.scale : 1, duration: const Duration(milliseconds: 140), curve: Curves.easeOut, child: widget.child),
      ),
    );
  }
}

/// iOS-style switch (green), used in Settings.
class ByteSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const ByteSwitch({super.key, required this.value, this.onChanged});
  @override
  Widget build(BuildContext context) => CupertinoSwitch(
    value: value,
    activeTrackColor: ByteColors.brand,
    onChanged: onChanged == null
        ? null
        : (v) {
            HapticFeedback.selectionClick();
            onChanged!(v);
          },
  );
}

/// 1.4 smoothness: the same soft, bouncy scrolling on every list (also with
/// a mouse or trackpad on the web version).
class ByteScrollBehavior extends MaterialScrollBehavior {
  const ByteScrollBehavior();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  @override
  Set<PointerDeviceKind> get dragDevices => {...super.dragDevices, PointerDeviceKind.mouse, PointerDeviceKind.trackpad};
}

/// Pill segmented control ("YouTube | Library | Podcasts").
class SegmentedPill extends StatelessWidget {
  final List<String> labels;
  final int index;
  final ValueChanged<int> onChanged;
  const SegmentedPill({super.key, required this.labels, required this.index, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth / labels.length;
        return Container(
          height: 40,
          decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(20)),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                left: w * index + 3,
                top: 3,
                bottom: 3,
                width: w - 6,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: dark ? const Color(0xFF3A3A3C) : Colors.white,
                    borderRadius: BorderRadius.circular(17),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.10), blurRadius: 6, offset: const Offset(0, 2))],
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          HapticFeedback.selectionClick();
                          onChanged(i);
                        },
                        child: Center(
                          child: Text(
                            labels[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 15, fontWeight: i == index ? FontWeight.w600 : FontWeight.w500, color: p.label),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Grey rounded block used for skeleton loading.
class Skel extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const Skel({super.key, this.width, required this.height, this.radius = 8});
  @override
  Widget build(BuildContext context) => _Shimmer(
    child: Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: BytePalette.of(context).skeleton, borderRadius: BorderRadius.circular(radius)),
    ),
  );
}

class _Shimmer extends StatefulWidget {
  final Widget child;
  const _Shimmer({required this.child});
  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(opacity: Tween(begin: 0.55, end: 1.0).animate(c), child: widget.child);
}

/// "Section" header used in lists ("Top Picks for You", "Recents", "Playlists").
class SectionTitle extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;
  final EdgeInsets padding;
  const SectionTitle(this.text, {super.key, this.action, this.onAction, this.padding = const EdgeInsets.fromLTRB(16, 22, 16, 10)});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.section.copyWith(color: p.label)),
          ),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              child: Text(action!, style: BT.body.copyWith(color: p.secondary)),
            ),
        ],
      ),
    );
  }
}

/// Grouped card (Settings, lists): rounded light-grey panel with hairlines between rows.
class GroupCard extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsets margin;
  final double dividerIndent;
  const GroupCard({super.key, required this.children, this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 0), this.dividerIndent = 56});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) rows.add(Divider(height: 0.5, thickness: 0.5, indent: dividerIndent, color: p.separator));
      rows.add(children[i]);
    }
    return Padding(
      padding: margin,
      // A Material (not a plain coloured box) so every row's press ripple is
      // drawn on the card itself — before 1.4 the ripples were hidden under it.
      child: Material(
        color: p.grouped,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    );
  }
}

/// Small caps label above a group ("AUDIO QUALITY").
class GroupLabel extends StatelessWidget {
  final String text;
  const GroupLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 26, 32, 8),
    child: Text(text.toUpperCase(), style: BT.caps.copyWith(color: BytePalette.of(context).secondary)),
  );
}

/// A row inside a [GroupCard].
class GroupRow extends StatelessWidget {
  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final String? value;
  final Widget? badge;
  final Widget? trailing;
  final bool chevron;
  final bool enabled;
  final VoidCallback? onTap;
  final Color? titleColor;
  const GroupRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.value,
    this.badge,
    this.trailing,
    this.chevron = false,
    this.enabled = true,
    this.onTap,
    this.titleColor,
  });
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final fade = enabled ? 1.0 : 0.4;
    return InkWell(mouseCursor: SystemMouseCursors.click, 
      onTap: enabled ? onTap : null,
      child: Opacity(
        opacity: fade,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 54),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 14, 10),
            child: Row(
              children: [
                if (leading != null) ...[leading!, const SizedBox(width: 14)] else if (icon != null) ...[
                  SizedBox(width: 26, child: Icon(icon, size: 24, color: p.label)),
                  const SizedBox(width: 14),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 1.4.6: a badge ("IN USE") that doesn't fit beside the
                      // title moves under it instead of spilling off the row.
                      if (badge == null)
                        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: titleColor ?? p.label))
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: titleColor ?? p.label)),
                            badge!,
                          ],
                        ),
                      if (subtitle != null && subtitle!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(subtitle!, maxLines: 3, overflow: TextOverflow.ellipsis, style: BT.sub.copyWith(color: p.secondary)),
                      ],
                    ],
                  ),
                ),
                if (value != null) ...[
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(value!, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: p.secondary)),
                  ),
                ],
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                if (chevron) ...[const SizedBox(width: 6), Icon(Icons.chevron_right_rounded, size: 24, color: p.tertiary)],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Small grey chip ("IN USE").
class Badge2 extends StatelessWidget {
  final String text;
  const Badge2(this.text, {super.key});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(6)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: p.secondary)),
    );
  }
}

/// Plain list row on the page background (Library: Downloads, Local Music…).
class PlainRow extends StatelessWidget {
  final Widget icon;
  final String title;
  final String? trailingText;
  final VoidCallback? onTap;
  final bool divider;
  const PlainRow({super.key, required this.icon, required this.title, this.onTap, this.divider = true, this.trailingText});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return InkWell(mouseCursor: SystemMouseCursors.click, 
      onTap: onTap,
      child: SizedBox(
        height: 58,
        child: Row(
          children: [
            const SizedBox(width: 24),
            SizedBox(width: 28, child: Center(child: icon)),
            const SizedBox(width: 12),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: divider ? Border(bottom: BorderSide(color: p.separator, width: 0.6)) : null,
                ),
                child: SizedBox(
                  height: 58,
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: p.label)),
                      ),
                      if (trailingText != null) Text(trailingText!, style: BT.sub.copyWith(color: p.secondary)),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right_rounded, color: p.tertiary, size: 24),
                      const SizedBox(width: 14),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Space the floating bars take at the bottom of every page.
double bottomBarSpace(BuildContext context) {
  final wide = MediaQuery.sizeOf(context).width >= 820;
  return MediaQuery.paddingOf(context).bottom + (wide ? 104 : 168);
}
