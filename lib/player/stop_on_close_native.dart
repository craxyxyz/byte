// Byte 2.0 © 2026 Apurba Laskar.
//
// Android: the playback service decides what happens when Byte is swiped away
// from recents, so it needs to know the "Stop music on close from recents"
// setting without waiting for Dart (which may not be reachable at that moment).
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class StopOnCloseNative {
  static const channel = MethodChannel('byte/playback');

  /// Writes the setting where the service reads it (Android only; elsewhere nothing to do).
  static Future<void> push(bool on) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod<bool>('stopOnClose', on);
    } catch (_) {}
  }
}
