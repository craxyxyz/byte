// Byte © 2026 Apurba Laskar
// The browser's own idea of whether it has a connection (navigator.onLine).
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

bool deviceOnline() {
  try {
    final nav = globalContext.getProperty<JSObject?>('navigator'.toJS);
    final v = nav?.getProperty<JSAny?>('onLine'.toJS);
    return v == null || !v.isA<JSBoolean>() || (v as JSBoolean).toDart;
  } catch (_) {
    return true;
  }
}
