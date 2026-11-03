// Byte © 2026 Apurba Laskar
// The browser's Screen Wake Lock (Chrome, Edge, Safari 16.4+, Firefox 126+).
// Browsers without it, or a page that isn't visible, simply refuse: ignored.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

extension type _WakeLock(JSObject _) implements JSObject {
  external JSPromise<_Sentinel> request(JSString type);
}

extension type _Sentinel(JSObject _) implements JSObject {
  external JSPromise<JSAny?> release();
}

_Sentinel? _held;
bool _want = false;

Future<void> setScreenWakeLock(bool on) async {
  _want = on;
  try {
    if (!on) {
      final s = _held;
      _held = null;
      if (s != null) await s.release().toDart;
      return;
    }
    if (_held != null) return;
    final nav = globalContext.getProperty<JSObject?>('navigator'.toJS);
    if (nav == null || !nav.has('wakeLock')) return;
    final lock = _WakeLock(nav.getProperty<JSObject>('wakeLock'.toJS));
    final s = await lock.request('screen'.toJS).toDart;
    if (!_want || _held != null) {
      // Released (or held again) while the browser was answering.
      await s.release().toDart;
      return;
    }
    _held = s;
  } catch (_) {}
}
