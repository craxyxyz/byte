// Byte © 2026 Apurba Laskar
// Windows: keep the display on through the Windows kernel call that every
// media player uses (SetThreadExecutionState). No package, no permission.
import 'dart:ffi';
import 'dart:io' show Platform;

typedef _SetStateNative = Uint32 Function(Uint32 flags);
typedef _SetState = int Function(int flags);

const int _esContinuous = 0x80000000; // this setting stays until it is changed back
const int _esDisplayRequired = 0x00000002; // the screen does not sleep

_SetState? _set;
bool _looked = false;

/// [on] = the display stays on; off = back to the normal sleep rules.
void setDesktopScreenOn(bool on) {
  if (!Platform.isWindows) return;
  try {
    if (!_looked) {
      _looked = true;
      _set = DynamicLibrary.open('kernel32.dll').lookupFunction<_SetStateNative, _SetState>('SetThreadExecutionState');
    }
    _set?.call(on ? (_esContinuous | _esDisplayRequired) : _esContinuous);
  } catch (_) {
    // an old Windows without the call: the screen sleeps as usual
  }
}
