// Byte © 2026 Apurba Laskar
// Not Windows (or no dart:io): the Windows window switch does nothing here.
Future<void> setFullScreen(bool on) async => throw UnsupportedError('windows only');

int currentStyle() => 0;

List<int> windowRect() => const [];

List<int> monitorRect() => const [];
