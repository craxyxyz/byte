// Byte 2.0 © 2026 Apurba Laskar
// Talks to web/embed.js (the official embedded player).
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

JSObject? get _e => globalContext.getProperty<JSObject?>('byteEmbed'.toJS);

bool embedAvailable() => _e != null;
void embedLoad(String id, double startSec) => _e?.callMethod('load'.toJS, id.toJS, startSec.toJS);
void embedPlay() => _e?.callMethod('play'.toJS);
void embedPause() => _e?.callMethod('pause'.toJS);
void embedSeek(double s) => _e?.callMethod('seek'.toJS, s.toJS);
void embedVolume(double v) => _e?.callMethod('volume'.toJS, v.toJS);
void embedHide() => _e?.callMethod('hide'.toJS);
Map<String, Object?> embedSnap() {
  final r = _e?.callMethod<JSString?>('snap'.toJS);
  if (r == null) return const {};
  return (jsonDecode(r.toDart) as Map).cast<String, Object?>();
}
