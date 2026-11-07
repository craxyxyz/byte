// Byte © 2026 Apurba Laskar
// Windows: the window's own full screen, done by Byte (2.0.7). The window
// plugin used before left the window's frame in place on some machines (the
// title bar and the window border stayed on the top and bottom edges). This
// takes the caption, the frame and the system menu off the window, puts it on
// the whole monitor, and on exit puts back the exact style and place it had.
// Only Windows calls it; the Win32 functions come from user32.dll.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _FindN = IntPtr Function(Pointer<Uint16> className, Pointer<Uint16> title);
typedef _FindD = int Function(Pointer<Uint16> className, Pointer<Uint16> title);
typedef _ForegroundN = IntPtr Function();
typedef _ForegroundD = int Function();
typedef _GetLongN = IntPtr Function(IntPtr hwnd, Int32 index);
typedef _GetLongD = int Function(int hwnd, int index);
typedef _SetLongN = IntPtr Function(IntPtr hwnd, Int32 index, IntPtr value);
typedef _SetLongD = int Function(int hwnd, int index, int value);
typedef _MonitorN = IntPtr Function(IntPtr hwnd, Uint32 flags);
typedef _MonitorD = int Function(int hwnd, int flags);
typedef _MonInfoN = Int32 Function(IntPtr monitor, Pointer<Uint8> info);
typedef _MonInfoD = int Function(int monitor, Pointer<Uint8> info);
typedef _PlaceN = Int32 Function(IntPtr hwnd, Pointer<Uint8> placement);
typedef _PlaceD = int Function(int hwnd, Pointer<Uint8> placement);
typedef _RectN = Int32 Function(IntPtr hwnd, Pointer<Uint8> rect);
typedef _RectD = int Function(int hwnd, Pointer<Uint8> rect);
typedef _PosN = Int32 Function(IntPtr hwnd, IntPtr after, Int32 x, Int32 y, Int32 cx, Int32 cy, Uint32 flags);
typedef _PosD = int Function(int hwnd, int after, int x, int y, int cx, int cy, int flags);
typedef _ShowN = Int32 Function(IntPtr hwnd, Int32 cmd);
typedef _ShowD = int Function(int hwnd, int cmd);
typedef _ZoomN = Int32 Function(IntPtr hwnd);
typedef _ZoomD = int Function(int hwnd);

const int _gwlStyle = -16;
const int _gwlExStyle = -20;
const int _wsOverlappedWindow = 0x00CF0000; // caption, frame, system menu, min/max boxes
const int _wsPopup = 0x80000000;
const int _wsExDlgModalFrame = 0x00000001;
const int _wsExWindowEdge = 0x00000100;
const int _wsExClientEdge = 0x00000200;
const int _wsExStaticEdge = 0x00020000;
const int _swpNoSize = 0x0001;
const int _swpNoMove = 0x0002;
const int _swpNoZOrder = 0x0004;
const int _swpNoOwnerZOrder = 0x0200;
const int _swpNoActivate = 0x0010;
const int _swpFrameChanged = 0x0020;
const int _swpShowWindow = 0x0040;
const int _swRestore = 9;
const int _monitorDefaultToNearest = 2;
const int _windowPlacementSize = 44; // WINDOWPLACEMENT
const int _monitorInfoSize = 40; // MONITORINFO

class _User32 {
  _User32._(DynamicLibrary lib)
      : findWindow = lib.lookupFunction<_FindN, _FindD>('FindWindowW'),
        foreground = lib.lookupFunction<_ForegroundN, _ForegroundD>('GetForegroundWindow'),
        getLong = lib.lookupFunction<_GetLongN, _GetLongD>('GetWindowLongPtrW'),
        setLong = lib.lookupFunction<_SetLongN, _SetLongD>('SetWindowLongPtrW'),
        monitorFrom = lib.lookupFunction<_MonitorN, _MonitorD>('MonitorFromWindow'),
        monitorInfo = lib.lookupFunction<_MonInfoN, _MonInfoD>('GetMonitorInfoW'),
        getPlacement = lib.lookupFunction<_PlaceN, _PlaceD>('GetWindowPlacement'),
        setPlacement = lib.lookupFunction<_PlaceN, _PlaceD>('SetWindowPlacement'),
        getRect = lib.lookupFunction<_RectN, _RectD>('GetWindowRect'),
        setPos = lib.lookupFunction<_PosN, _PosD>('SetWindowPos'),
        show = lib.lookupFunction<_ShowN, _ShowD>('ShowWindow'),
        isZoomed = lib.lookupFunction<_ZoomN, _ZoomD>('IsZoomed');

  static _User32? _inst;
  static _User32 get i => _inst ??= _User32._(DynamicLibrary.open('user32.dll'));

  final _FindD findWindow;
  final _ForegroundD foreground;
  final _GetLongD getLong;
  final _SetLongD setLong;
  final _MonitorD monitorFrom;
  final _MonInfoD monitorInfo;
  final _PlaceD getPlacement;
  final _PlaceD setPlacement;
  final _RectD getRect;
  final _PosD setPos;
  final _ShowD show;
  final _ZoomD isZoomed;
}

int _hwnd = 0;
bool _full = false;
int _savedStyle = 0;
int _savedExStyle = 0;
Uint8List? _savedPlacement;

/// The Byte window: the Flutter runner's own top-level window (its class name
/// is fixed in the runner); the foreground window when that is not found.
/// Dart runs on the engine's UI thread, so a thread-bound call (GetActiveWindow)
/// would see no window; FindWindowW is not thread-bound.
int _window() {
  const name = 'FLUTTER_RUNNER_WIN32_WINDOW';
  final cls = calloc<Uint16>(name.length + 1);
  try {
    for (var i = 0; i < name.length; i++) {
      cls[i] = name.codeUnitAt(i);
    }
    cls[name.length] = 0;
    final h = _User32.i.findWindow(cls, nullptr);
    if (h != 0) return h;
  } finally {
    calloc.free(cls);
  }
  return _User32.i.foreground();
}

/// Full screen on (the whole monitor, no caption, no frame) or off (the window
/// exactly as it was). Throws when Windows refuses; the app keeps its window.
Future<void> setFullScreen(bool on) async {
  if (on == _full) return;
  final u = _User32.i;
  if (on) {
    final hwnd = _window();
    if (hwnd == 0) throw StateError('no window to take full screen');
    final place = calloc<Uint8>(_windowPlacementSize);
    try {
      place.cast<Uint32>()[0] = _windowPlacementSize;
      if (u.getPlacement(hwnd, place) == 0) throw StateError('no placement');
      _savedPlacement = Uint8List.fromList(place.asTypedList(_windowPlacementSize));
    } finally {
      calloc.free(place);
    }
    final info = calloc<Uint8>(_monitorInfoSize);
    try {
      info.cast<Uint32>()[0] = _monitorInfoSize;
      final mon = u.monitorFrom(hwnd, _monitorDefaultToNearest);
      if (u.monitorInfo(mon, info) == 0) throw StateError('no monitor');
      final r = info.cast<Int32>();
      final left = r[1], top = r[2], right = r[3], bottom = r[4];
      _savedStyle = u.getLong(hwnd, _gwlStyle);
      _savedExStyle = u.getLong(hwnd, _gwlExStyle);
      if (u.isZoomed(hwnd) != 0) u.show(hwnd, _swRestore);
      final style = (_savedStyle & ~_wsOverlappedWindow) | _wsPopup;
      final ex = _savedExStyle & ~(_wsExDlgModalFrame | _wsExWindowEdge | _wsExClientEdge | _wsExStaticEdge);
      u.setLong(hwnd, _gwlStyle, style);
      u.setLong(hwnd, _gwlExStyle, ex);
      u.setPos(hwnd, 0, left, top, right - left, bottom - top, _swpFrameChanged | _swpShowWindow | _swpNoOwnerZOrder);
      _hwnd = hwnd;
      _full = true;
    } finally {
      calloc.free(info);
    }
    return;
  }
  final hwnd = _hwnd;
  if (hwnd == 0) {
    _full = false;
    return;
  }
  u.setLong(hwnd, _gwlStyle, _savedStyle);
  u.setLong(hwnd, _gwlExStyle, _savedExStyle);
  final saved = _savedPlacement;
  if (saved != null) {
    final place = calloc<Uint8>(_windowPlacementSize);
    try {
      place.asTypedList(_windowPlacementSize).setAll(0, saved);
      u.setPlacement(hwnd, place);
    } finally {
      calloc.free(place);
    }
  }
  u.setPos(hwnd, 0, 0, 0, 0, 0, _swpNoMove | _swpNoSize | _swpNoZOrder | _swpNoActivate | _swpFrameChanged);
  _full = false;
  _hwnd = 0;
}

/// Windows' style bits of the Byte window now (for checks).
int currentStyle() {
  final hwnd = _hwnd != 0 ? _hwnd : _window();
  return _User32.i.getLong(hwnd, _gwlStyle);
}

/// The window's rectangle now, left/top/right/bottom in pixels (for checks).
List<int> windowRect() {
  final hwnd = _hwnd != 0 ? _hwnd : _window();
  final r = calloc<Uint8>(16);
  try {
    if (_User32.i.getRect(hwnd, r) == 0) return const [];
    final v = r.cast<Int32>();
    return [v[0], v[1], v[2], v[3]];
  } finally {
    calloc.free(r);
  }
}

/// The monitor's rectangle the window is on now (for checks).
List<int> monitorRect() {
  final hwnd = _hwnd != 0 ? _hwnd : _window();
  final info = calloc<Uint8>(_monitorInfoSize);
  try {
    info.cast<Uint32>()[0] = _monitorInfoSize;
    final mon = _User32.i.monitorFrom(hwnd, _monitorDefaultToNearest);
    if (_User32.i.monitorInfo(mon, info) == 0) return const [];
    final v = info.cast<Int32>();
    return [v[1], v[2], v[3], v[4]];
  } finally {
    calloc.free(info);
  }
}
