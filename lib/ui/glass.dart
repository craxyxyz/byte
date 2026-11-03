import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../services.dart';
import 'style.dart';

/// Byte's liquid glass (Appearance → Liquid glass): frosted blur, a slight
/// tint, a soft light sheen from the top and a thin bright edge that catches
/// the light on the top-left and bottom-right, like real glass.
///
/// On phones that are short on memory (or that start dropping frames) the
/// blur goes lighter automatically; with the setting off, or "Reduce dynamic
/// blur" on, the same shapes are drawn as solid fills.
class GlassPerf {
  GlassPerf._();

  /// True on low-RAM phones (or after sustained slow frames): lighter blur.
  static final ValueNotifier<bool> light = ValueNotifier(false);

  /// Why [light] is on ("low-ram", "slow-frames"), for Settings.
  static String? reason;

  static const channel = MethodChannel('byte/device');
  static bool _started = false;
  static final List<int> _frames = [];

  /// Reads the phone's memory class once and starts a short frame-time check.
  static Future<void> init() async {
    if (_started) return;
    _started = true;
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        final m = await channel.invokeMapMethod<String, Object?>('info');
        if (m != null) applyDeviceInfo(m);
      }
    } catch (_) {}
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } catch (_) {}
  }

  /// Low-RAM device flag or under ~3 GB of memory: lighter glass.
  static void applyDeviceInfo(Map<String, Object?> m) {
    final lowRam = m['lowRam'] == true;
    final mb = (m['totalMemMb'] as num?)?.toInt() ?? 0;
    if (lowRam || (mb > 0 && mb < 3000)) {
      reason = 'low-ram';
      light.value = true;
    }
  }

  static void _onTimings(List<FrameTiming> timings) {
    if (light.value) return;
    for (final t in timings) {
      _frames.add(t.totalSpan.inMicroseconds);
    }
    if (_frames.length < 300) return;
    noteFrameTimes(List.of(_frames));
    _frames.clear();
  }

  /// A window of frame times (µs): if the slowest 10 % take over 34 ms
  /// (well under 30 fps), the glass goes lighter for the rest of the run.
  static bool noteFrameTimes(List<int> micros) {
    if (micros.length < 60) return false;
    final s = List.of(micros)..sort();
    final p90 = s[(s.length * 0.9).floor().clamp(0, s.length - 1)];
    if (p90 > 34000) {
      reason = 'slow-frames';
      light.value = true;
      return true;
    }
    return false;
  }

  @visibleForTesting
  static void reset() {
    light.value = false;
    reason = null;
    _frames.clear();
  }
}

/// 1.4.1: the floating bars (mini player, tab bar, search) must stay easy to
/// read over ANY page — a white page, a busy cover, a photo. Liquid glass made
/// them too see-through, so they now sit on a near-solid tint (still frosted
/// behind it) whose colours are checked against the worst background: text
/// keeps at least 4.5:1 contrast (WCAG AA) even over pure white or black.
class ReadableGlass {
  ReadableGlass._();

  /// How opaque the mini player's tint is (the rest is the frosted blur).
  static const double miniAlpha = 0.85;

  /// WCAG contrast ratio of two opaque colours.
  static double contrast(Color a, Color b) {
    final la = a.computeLuminance(), lb = b.computeLuminance();
    final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  /// [top] (with its alpha) laid over an opaque [under].
  static Color over(Color top, Color under) => Color.alphaBlend(top, under.withValues(alpha: 1));

  /// The mini player's tint: the cover's colour, darkened until white text
  /// reads at 7:1 even when the tint sits over a pure white page (so the
  /// greyer artist line still clears 4.5:1).
  static Color miniTint(Color art) {
    var c = Color.lerp(art.withValues(alpha: 1), Colors.black, 0.5)!;
    for (var i = 0; i < 20; i++) {
      final worst = over(c.withValues(alpha: miniAlpha), Colors.white);
      if (contrast(Colors.white, worst) >= 7.0) break;
      c = Color.lerp(c, Colors.black, 0.15)!;
    }
    return c.withValues(alpha: miniAlpha);
  }

  /// The artist line's colour on the mini player.
  static const Color miniSecondary = Color(0xD9FFFFFF); // white 85 %

  /// The tab bar / search button tint: near solid, in the theme's colour.
  static Color navTint(bool dark) => dark ? const Color(0xE81C1C1E) : const Color(0xEDF8F8FA);

  /// Unselected tab labels on that tint (darker / lighter than the usual grey).
  static Color navSecondary(bool dark) => dark ? const Color(0xFFBDBDC3) : const Color(0xFF505055);
}

/// 0 = solid (glass off), 1 = light blur, 2 = full liquid glass.
int glassLevel() {
  try {
    final st = Services.i.settings;
    if (!st.glassEffects || !st.liquidGlass) return 0;
  } catch (_) {}
  return GlassPerf.light.value ? 1 : 2;
}

/// The thin bright edge: a gradient stroke, brightest at the top-left.
class GlassEdgePainter extends CustomPainter {
  final BorderRadius radius;
  final bool dark;
  final double width;
  const GlassEdgePainter({required this.radius, required this.dark, this.width = 1.0});
  @override
  void paint(Canvas canvas, Size size) {
    final r = radius.toRRect(Offset.zero & size).deflate(width / 2);
    final hi = dark ? 0.42 : 0.95;
    final lo = dark ? 0.06 : 0.25;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Colors.white.withValues(alpha: hi), Colors.white.withValues(alpha: lo), Colors.white.withValues(alpha: lo), Colors.white.withValues(alpha: hi * 0.55)],
        stops: const [0, 0.38, 0.7, 1],
      ).createShader(Offset.zero & size);
    canvas.drawRRect(r, paint);
    if (!dark) {
      // a faint outer line so white glass still reads on a white page
      final o = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5
        ..color = Colors.black.withValues(alpha: 0.07);
      canvas.drawRRect(radius.toRRect(Offset.zero & size).deflate(0.25), o);
    }
  }

  @override
  bool shouldRepaint(GlassEdgePainter old) => old.radius != radius || old.dark != dark || old.width != width;
}

/// A piece of liquid glass. [dark] picks the glass for dark backgrounds
/// (null = follow the theme). [strong] is the more opaque glass used for
/// sheets, menus and dialogs, where text must stay easy to read.
class LiquidGlass extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final Color? tint;
  final bool? dark;
  final bool strong;
  final bool shadow;
  final double? blur;
  const LiquidGlass({super.key, required this.child, required this.radius, this.tint, this.dark, this.strong = false, this.shadow = false, this.blur});

  static Color baseTint({required bool dark, required bool strong, required int level}) {
    if (level == 0) return dark ? const Color(0xFF242428) : const Color(0xFFF7F7F9);
    if (dark) return Color.fromRGBO(30, 30, 34, strong ? 0.74 : 0.42);
    return Color.fromRGBO(255, 255, 255, strong ? 0.80 : 0.55);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: GlassPerf.light,
      builder: (context, _, _) {
        final level = glassLevel();
        final isDark = dark ?? Theme.of(context).brightness == Brightness.dark;
        final base = baseTint(dark: isDark, strong: strong, level: level);
        final color = tint == null ? base : (level == 0 ? Color.alphaBlend(tint!.withValues(alpha: 1), base) : Color.alphaBlend(tint!, base));
        final sigma = level == 0 ? 0.0 : (blur ?? (strong ? 30.0 : 22.0)) * (level == 1 ? 0.3 : 1.0);
        Widget body = DecoratedBox(
          decoration: BoxDecoration(color: color, borderRadius: radius),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: level == 0
                  ? null
                  : LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.center,
                      colors: [Colors.white.withValues(alpha: isDark ? 0.10 : 0.30), Colors.white.withValues(alpha: 0)],
                    ),
            ),
            child: CustomPaint(
              key: const ValueKey('glass-edge'),
              foregroundPainter: GlassEdgePainter(radius: radius, dark: isDark, width: level == 0 ? 0.6 : 1.0),
              // ink splashes of list rows inside the glass land on this
              child: Material(type: MaterialType.transparency, child: child),
            ),
          ),
        );
        if (sigma > 0) body = BackdropFilter(filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma), child: body);
        body = ClipRRect(borderRadius: radius, child: body);
        if (!shadow) return body;
        return DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.12), blurRadius: 28, offset: const Offset(0, 10))],
          ),
          child: body,
        );
      },
    );
  }
}

/// Round glass button (player: star, ⋯, lyrics, cast, queue).
class GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final bool dark;
  final Color? iconColor;
  const GlassCircleButton({super.key, required this.icon, required this.tooltip, this.onTap, this.size = 36, this.iconSize = 20, this.dark = true, this.iconColor});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: Pressable(
        onTap: onTap,
        scale: 0.9,
        child: LiquidGlass(
          radius: BorderRadius.circular(size / 2),
          dark: dark,
          child: SizedBox(width: size, height: size, child: Icon(icon, size: iconSize, color: iconColor ?? (dark ? Colors.white : BytePalette.of(context).label))),
        ),
      ),
    ),
  );
}

/// A glass bottom sheet: the same arguments as [showModalBottomSheet].
/// The sheet itself is liquid glass with its own grab handle.
Future<T?> showByteSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  Color? backgroundColor,
  bool useSafeArea = false,
  BoxConstraints? constraints,
  bool useRootNavigator = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool showDragHandle = true,
}) {
  const r = BorderRadius.vertical(top: Radius.circular(26));
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: isScrollControlled,
    useSafeArea: useSafeArea,
    constraints: constraints,
    // 1.4.2: always on the root navigator, so a sheet opens ABOVE the mini
    // player and the tab bar (from a tab's page it used to open under them,
    // hiding its buttons — Apurba's "Create a party" sheet).
    useRootNavigator: true,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    showDragHandle: false,
    backgroundColor: Colors.transparent,
    elevation: 0,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    shape: const RoundedRectangleBorder(borderRadius: r),
    // a sheet asked for in a dark colour (the player's menus, white text) is dark glass in any theme
    builder: (c) => GlassSheetFrame(
      tint: backgroundColor?.withValues(alpha: 0.35),
      dark: backgroundColor == null ? null : backgroundColor.computeLuminance() < 0.2,
      handle: showDragHandle,
      child: builder(c),
    ),
  );
}

/// The glass behind a sheet, with a small handle at the top.
class GlassSheetFrame extends StatelessWidget {
  final Widget child;
  final Color? tint;
  final bool handle;
  final bool? dark;
  const GlassSheetFrame({super.key, required this.child, this.tint, this.handle = true, this.dark});
  @override
  Widget build(BuildContext context) {
    final dark = this.dark ?? Theme.of(context).brightness == Brightness.dark;
    return LiquidGlass(
      key: const ValueKey('glass-sheet'),
      radius: const BorderRadius.vertical(top: Radius.circular(26)),
      strong: true,
      dark: dark,
      tint: tint,
      child: Stack(
        children: [
          Padding(padding: EdgeInsets.only(top: handle ? 22 : 8), child: child),
          if (handle)
            Positioned(
              top: 9,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  width: 38,
                  height: 5,
                  decoration: BoxDecoration(color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.25), borderRadius: BorderRadius.circular(3)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A yes/no question on glass. True when [yes] was tapped.
Future<bool> showGlassConfirm(BuildContext context, String title, String body, String yes) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => GlassDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes)),
      ],
    ),
  );
  return r ?? false;
}

/// A glass alert dialog: title, content and buttons, like [AlertDialog].
class GlassDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Color? backgroundColor;
  final EdgeInsetsGeometry? contentPadding;
  const GlassDialog({super.key, this.title, this.content, this.actions, this.backgroundColor, this.contentPadding});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final dark = t.brightness == Brightness.dark || (backgroundColor != null && backgroundColor!.computeLuminance() < 0.2);
    final fg = dark ? Colors.white : BytePalette.of(context).label;
    return Dialog(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shadowColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: LiquidGlass(
          key: const ValueKey('glass-dialog'),
          radius: BorderRadius.circular(28),
          strong: true,
          dark: dark,
          shadow: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 22, 14, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (title != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8, bottom: 10),
                    child: DefaultTextStyle(style: t.textTheme.titleLarge!.copyWith(color: fg, fontWeight: FontWeight.w700), child: title!),
                  ),
                if (content != null)
                  Flexible(
                    child: Padding(
                      padding: contentPadding ?? const EdgeInsets.only(right: 8),
                      child: DefaultTextStyle(style: t.textTheme.bodyMedium!.copyWith(color: fg.withValues(alpha: 0.8), fontSize: 15), child: content!),
                    ),
                  ),
                if (actions != null && actions!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: OverflowBar(alignment: MainAxisAlignment.end, spacing: 4, children: actions!),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A glass toast (snackbar) body.
class GlassToast extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback? onAction;
  const GlassToast(this.text, {super.key, this.action, this.onAction});
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return LiquidGlass(
      key: const ValueKey('glass-toast'),
      radius: BorderRadius.circular(18),
      strong: true,
      shadow: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
        child: action == null
            ? Text(text, style: TextStyle(color: dark ? Colors.white : BytePalette.of(context).label, fontSize: 15, fontWeight: FontWeight.w600))
            : Row(
                children: [
                  Expanded(
                    child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: dark ? Colors.white : BytePalette.of(context).label, fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  TextButton(
                    key: const ValueKey('glass-toast-action'),
                    onPressed: onAction,
                    child: Text(action!, style: TextStyle(color: BytePalette.of(context).accent, fontWeight: FontWeight.w700, fontSize: 15)),
                  ),
                ],
              ),
      ),
    );
  }
}
