// Byte © 2026 Apurba Laskar
// The browser's Fullscreen API. Browsers only allow it right after a tap or
// key press; anything else is refused and ignored.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

Future<void> setBrowserFullscreen(bool on) async {
  try {
    final doc = globalContext.getProperty<JSObject?>('document'.toJS);
    if (doc == null) return;
    final current = doc.getProperty<JSAny?>('fullscreenElement'.toJS);
    if (on) {
      if (current != null) return;
      final el = doc.getProperty<JSObject?>('documentElement'.toJS);
      if (el == null || !el.has('requestFullscreen')) return;
      final p = el.callMethod<JSAny?>('requestFullscreen'.toJS);
      if (p != null && p.isA<JSPromise>()) await (p as JSPromise).toDart;
    } else {
      if (current == null || !doc.has('exitFullscreen')) return;
      final p = doc.callMethod<JSAny?>('exitFullscreen'.toJS);
      if (p != null && p.isA<JSPromise>()) await (p as JSPromise).toDart;
    }
  } catch (_) {}
}
