import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

// Byte © 2026 Apurba Laskar.

/// 1.4.5.2 (computer lag): smooth mouse-wheel scrolling on Windows and Linux.
///
/// Flutter moves a list in one jump per wheel notch, and on Windows that jump
/// is only ~40 px at 150 % scaling, so wheel scrolling felt slow and jerky
/// next to every other Windows app. Here a wheel notch glides the list under
/// the pointer (eased, ~0.2 s) by a normal Windows-sized step; notches that
/// come quickly add up into one glide. Trackpads (which send pan gestures),
/// page views and anything that handles the wheel itself keep the default.
class SmoothWheel {
  SmoothWheel._();

  static bool enabled = !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux);

  /// Wheel step multiplier: Windows sends 60 physical px per notch (≈ 40 px
  /// at 150 %); ×2.2 gives the ~90–130 px a notch scrolls in Windows apps.
  static double stepFactor = !kIsWeb && defaultTargetPlatform == TargetPlatform.windows ? 2.2 : 1.0;

  static const Duration duration = Duration(milliseconds: 220);
  static const Curve curve = Curves.easeOutCubic;

  static final Expando<_Glide> _glides = Expando('byte-wheel');

  /// Handles a mouse-wheel event for the deepest list under the pointer that
  /// can move; true = handled (the default jump must not run).
  static bool handle(PointerEvent event, HitTestResult? result) {
    if (!enabled || result == null || event is! PointerScrollEvent) return false;
    if (event.kind != PointerDeviceKind.mouse) return false;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    for (final entry in result.path) {
      final l = entry.target;
      if (l is! RenderPointerListener || l.onPointerSignal == null) continue;
      // a list's own wheel listener sits right above its viewport (the
      // viewport itself drops out of hit tests while a glide runs)
      final t = viewportUnder(l);
      if (t == null) return false; // something else handles the wheel itself
      final pos = t.offset;
      if (pos is! ScrollPosition || !pos.hasContentDimensions || !pos.hasPixels) return false;
      for (ScrollPhysics? ph = pos.physics; ph != null; ph = ph.parent) {
        if (ph is PageScrollPhysics || ph is NeverScrollableScrollPhysics) return false;
      }
      final vertical = axisDirectionToAxis(t.axisDirection) == Axis.vertical;
      var delta = vertical ? (shift ? 0.0 : event.scrollDelta.dy) : (shift && event.scrollDelta.dx == 0 ? event.scrollDelta.dy : event.scrollDelta.dx);
      if (delta == 0) continue;
      if (axisDirectionIsReversed(t.axisDirection)) delta = -delta;
      // a whole notch gets the Windows-sized step; small (precise) deltas stay as they are
      if (delta.abs() >= 20) delta *= stepFactor;
      final g = _glides[pos];
      final from = g != null && g.running ? g.to : pos.pixels;
      final to = (from + delta).clamp(pos.minScrollExtent, pos.maxScrollExtent);
      final running = g != null && g.running;
      if (!running && to == pos.pixels) continue; // at its end: the list around it
      if (to == from) return true; // still gliding to its end
      glide(pos, to, forward: delta < 0);
      return true;
    }
    return false;
  }

  /// The viewport a few single-child steps under [o] (a list's own wheel
  /// listener), or null.
  static RenderViewportBase? viewportUnder(RenderObject o) {
    RenderObject? r = o;
    for (var i = 0; i < 12 && r != null; i++) {
      if (r is RenderViewportBase) return r;
      r = r is RenderObjectWithChildMixin ? r.child : null;
    }
    return null;
  }

  /// Glides [pos] to [to] (restarting any glide already running).
  static void glide(ScrollPosition pos, double to, {required bool forward}) {
    final g = _glides[pos] ??= _Glide();
    g.to = to;
    g.running = true;
    final id = ++g.id;
    // tells listeners (the lyrics) that the person is scrolling
    _notify(pos, forward ? ScrollDirection.forward : ScrollDirection.reverse);
    pos.animateTo(to, duration: duration, curve: curve).whenComplete(() {
      if (g.id == id) {
        g.running = false;
        _notify(pos, ScrollDirection.idle);
      }
    });
  }

  static void _notify(ScrollPosition pos, ScrollDirection d) {
    final ctx = pos.context.notificationContext;
    if (ctx == null || !pos.hasContentDimensions) return;
    UserScrollNotification(metrics: pos.copyWith(), context: ctx, direction: d).dispatch(ctx);
  }
}

class _Glide {
  double to = 0;
  bool running = false;
  int id = 0;
}

/// The app's binding: the normal one, plus [SmoothWheel] on computers.
class ByteBinding extends WidgetsFlutterBinding {
  static WidgetsBinding ensureInitialized() {
    try {
      return WidgetsBinding.instance;
    } catch (_) {
      ByteBinding();
      return WidgetsBinding.instance;
    }
  }

  @override
  void dispatchEvent(PointerEvent event, HitTestResult? hitTestResult) {
    if (event is PointerScrollEvent && SmoothWheel.handle(event, hitTestResult)) return;
    super.dispatchEvent(event, hitTestResult);
  }
}
