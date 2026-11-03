import '../../services.dart';

// Byte 2.0 © 2026 Apurba Laskar.
//
// Glass in 2.0 is drawn without a live blur by default: a live blur re-blurs
// whatever scrolls under a bar on EVERY frame, which is what made scrolling
// stutter on ordinary phones. The frosted look comes from a denser tint, the
// light sheen and the bright edge instead. "Real glass blur" (Settings →
// Performance) brings the live blur back for people who want it.

/// Whether glass surfaces blur what is behind them live.
bool liveBlur() {
  try {
    return Services.i.settings.realBlur;
  } catch (_) {
    return false;
  }
}

/// How opaque a frosted tint must be to read well without a live blur.
double frostedAlpha(double alpha, {bool dark = false}) {
  if (liveBlur()) return alpha;
  final min = dark ? 0.86 : 0.9;
  return alpha < min ? min : alpha;
}
