// Byte 2.0 © 2026 Apurba Laskar: no embedded player off the web (tests set a fake).
bool embedAvailable() => false;
void embedLoad(String id, double startSec) {}
void embedPlay() {}
void embedPause() {}
void embedSeek(double s) {}
void embedVolume(double v) {}
void embedHide() {}
Map<String, Object?> embedSnap() => const {};
