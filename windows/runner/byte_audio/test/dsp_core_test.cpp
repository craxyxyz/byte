// Unit tests for the desktop sound chain (run on any machine with g++).
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
#include "../dsp_core.h"

using namespace byte_dsp;

static int failures = 0;
#define CHECK(cond, msg) do { if (!(cond)) { std::printf("FAIL %s: %s\n", __func__, msg); failures++; } } while (0)

static std::vector<float> sine(double hz, double seconds, double amp, int channels = 2) {
  size_t frames = static_cast<size_t>(seconds * kSampleRate);
  std::vector<float> out(frames * 2);
  for (size_t i = 0; i < frames; i++) {
    float v = static_cast<float>(amp * std::sin(2 * M_PI * hz * i / kSampleRate));
    out[2 * i] = v;
    out[2 * i + 1] = channels == 2 ? v : 0.0f;
  }
  return out;
}

// Peak of the second half (after the filters settle).
static double peakTail(const std::vector<float>& x, int ch = 0) {
  double p = 0;
  for (size_t i = x.size() / 2; i < x.size() / 2 + 2 * 4800 && i < x.size(); i += 2) p = std::fmax(p, std::fabs(x[i + ch]));
  return p;
}

// RBJ peaking section, normalised (the same design the Dart side sends).
static Coeffs peak(double f0, double gainDb, double q) {
  double a = std::pow(10.0, gainDb / 40.0);
  double w0 = 2 * M_PI * f0 / kSampleRate;
  double alpha = std::sin(w0) / (2 * q);
  double b0 = 1 + alpha * a, b1 = -2 * std::cos(w0), b2 = 1 - alpha * a;
  double a0 = 1 + alpha / a, a1 = -2 * std::cos(w0), a2 = 1 - alpha / a;
  return Coeffs{b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
}

static void testBypass() {
  Chain c;
  auto x = sine(1000, 0.5, 0.5);
  auto y = x;
  c.process(y.data(), y.size() / 2);
  CHECK(y == x, "an empty chain must not change a sample");
}

static void testPeakingEqBoostsItsCentre() {
  Chain c;
  Config cfg;
  cfg.eqOn = true;
  cfg.eq.push_back(peak(1000, 6.0, 1.0));
  c.configure(cfg);
  auto x = sine(1000, 0.5, 0.25);
  c.process(x.data(), x.size() / 2);
  double p = peakTail(x);
  double gainDb = 20 * std::log10(p / 0.25);
  CHECK(std::fabs(gainDb - 6.0) < 0.3, "+6 dB peak at 1 kHz must lift a 1 kHz sine by about 6 dB");
}

static void testPeakingEqLeavesFarFrequencies() {
  Chain c;
  Config cfg;
  cfg.eqOn = true;
  cfg.eq.push_back(peak(1000, 9.0, 1.0));
  c.configure(cfg);
  auto x = sine(60, 0.5, 0.25);
  c.process(x.data(), x.size() / 2);
  double gainDb = 20 * std::log10(peakTail(x) / 0.25);
  CHECK(std::fabs(gainDb) < 0.5, "a 1 kHz boost must not change 60 Hz");
}

static void testCutAndBoostAreMirror() {
  Chain c;
  Config cfg;
  cfg.eqOn = true;
  cfg.eq.push_back(peak(2000, -12.0, 2.0));
  c.configure(cfg);
  auto x = sine(2000, 0.5, 0.25);
  c.process(x.data(), x.size() / 2);
  double gainDb = 20 * std::log10(peakTail(x) / 0.25);
  CHECK(std::fabs(gainDb + 12.0) < 0.5, "-12 dB cut at 2 kHz must drop a 2 kHz sine by about 12 dB");
}

static void testInputGain() {
  Chain c;
  Config cfg;
  cfg.inputGainDb = -6.0;
  c.configure(cfg);
  auto x = sine(440, 0.2, 0.5);
  c.process(x.data(), x.size() / 2);
  double gainDb = 20 * std::log10(peakTail(x) / 0.5);
  CHECK(std::fabs(gainDb + 6.0) < 0.1, "-6 dB input gain must be -6 dB");
}

static void testMonoSumsChannels() {
  Chain c;
  Config cfg;
  cfg.mono = true;
  c.configure(cfg);
  std::vector<float> x = {0.8f, 0.2f, -0.4f, 0.0f};
  c.process(x.data(), 2);
  CHECK(std::fabs(x[0] - 0.5f) < 1e-6 && std::fabs(x[1] - 0.5f) < 1e-6, "mono frame 0 must be the average of both channels");
  CHECK(std::fabs(x[2] + 0.2f) < 1e-6 && std::fabs(x[3] + 0.2f) < 1e-6, "mono frame 1 must be the average of both channels");
}

static void testBalanceLeft() {
  Chain c;
  Config cfg;
  cfg.balance = -1.0;  // all the way left: the right side is silenced
  c.configure(cfg);
  std::vector<float> x = {0.5f, 0.5f};
  c.process(x.data(), 1);
  CHECK(std::fabs(x[0] - 0.5f) < 1e-6, "balance -1 keeps the left channel");
  CHECK(std::fabs(x[1]) < 1e-6, "balance -1 silences the right channel");
}

static void testLimiterCapsPeaks() {
  Chain c;
  Config cfg;
  cfg.inputGainDb = 12.0;
  cfg.limiterOn = true;
  cfg.limit = 0.89;
  c.configure(cfg);
  auto x = sine(300, 0.5, 0.6);
  c.process(x.data(), x.size() / 2);
  double maxAbs = 0;
  for (float v : x) maxAbs = std::fmax(maxAbs, std::fabs(v));
  CHECK(maxAbs <= 0.8901, "the limiter must keep every sample at or under 0.89");
  CHECK(maxAbs > 0.80, "the limiter must not squash the signal to silence");
}

static void testCompressorReducesLoudParts() {
  Chain c;
  Config cfg;
  cfg.compressorOn = true;
  cfg.thresholdDb = -20.0;
  cfg.ratio = 4.0;
  c.configure(cfg);
  auto loud = sine(200, 1.0, 0.9);
  c.process(loud.data(), loud.size() / 2);
  double out = 20 * std::log10(peakTail(loud) / 0.9);
  // 0.9 is -0.9 dB: 19.1 dB over a -20 dB threshold; at 4:1 about 14 dB comes off,
  // so the output lands near -15 dB (measured -13.3 with the 10 ms attack).
  CHECK(out < -10.0 && out > -17.0, "a 4:1 compressor over -20 dB must pull a loud sine down by about 14 dB");
  Chain quiet;
  quiet.configure(cfg);
  auto soft = sine(200, 1.0, 0.01);
  quiet.process(soft.data(), soft.size() / 2);
  double softDb = 20 * std::log10(peakTail(soft) / 0.01);
  CHECK(std::fabs(softDb) < 0.5, "a quiet sine under the threshold must pass unchanged");
}

static void testReverbAddsATail() {
  Chain c;
  Config cfg;
  cfg.reverbOn = true;
  cfg.rvWet = 0.5;
  cfg.rvDry = 1.0;
  cfg.rvSize = 0.8;
  cfg.rvDamping = 0.3;
  cfg.rvWidth = 1.0;
  cfg.rvPreDelayMs = 10;
  c.configure(cfg);
  // one click, then silence: the tail must still be there a second later
  size_t frames = 48000;
  std::vector<float> x(frames * 2, 0.0f);
  x[0] = 0.8f;
  x[1] = 0.8f;
  c.process(x.data(), frames);
  double tail = 0;
  for (size_t i = 24000 * 2; i < 30000 * 2; i++) tail = std::fmax(tail, std::fabs(x[i]));
  CHECK(tail > 0.0005, "reverb must leave a decaying tail after the click");
  double early = 0;
  for (size_t i = 0; i < 2 * 480; i++) early = std::fmax(early, std::fabs(x[i]));
  CHECK(early > 0.1, "the dry click must still come through at once");
}

static void testReverbWetZeroIsDryOnly() {
  Chain c;
  Config cfg;
  cfg.reverbOn = true;
  cfg.rvWet = 0.0;
  cfg.rvDry = 1.0;
  c.configure(cfg);
  auto x = sine(440, 0.1, 0.5);
  auto y = x;
  c.process(y.data(), y.size() / 2);
  double maxDiff = 0;
  for (size_t i = 0; i < x.size(); i++) maxDiff = std::fmax(maxDiff, std::fabs(x[i] - y[i]));
  CHECK(maxDiff < 1e-4, "reverb with no wet level must leave the sound as it was");
}

static void testCrossfeedMovesSound() {
  Chain c;
  Config cfg;
  cfg.crossfeedOn = true;
  cfg.xfStrength = 0.8;
  cfg.xfHz = 700;
  c.configure(cfg);
  // a left-only sine: after crossfeed the right channel must carry some of it
  auto x = sine(200, 0.5, 0.5, 1);
  c.process(x.data(), x.size() / 2);
  CHECK(peakTail(x, 1) > 0.05, "crossfeed must put some of the left signal on the right");
}

static void testResetClearsMemory() {
  Chain c;
  Config cfg;
  cfg.eqOn = true;
  cfg.eq.push_back(peak(500, 6.0, 1.0));
  c.configure(cfg);
  auto x = sine(500, 0.2, 0.5);
  c.process(x.data(), x.size() / 2);
  c.reset();
  std::vector<float> z(8, 0.0f);
  c.process(z.data(), 4);
  bool silent = true;
  for (float v : z) if (std::fabs(v) > 1e-9) silent = false;
  CHECK(silent, "after reset a silent input must give silent output");
}

int main() {
  testBypass();
  testPeakingEqBoostsItsCentre();
  testPeakingEqLeavesFarFrequencies();
  testCutAndBoostAreMirror();
  testInputGain();
  testMonoSumsChannels();
  testBalanceLeft();
  testLimiterCapsPeaks();
  testCompressorReducesLoudParts();
  testReverbAddsATail();
  testReverbWetZeroIsDryOnly();
  testCrossfeedMovesSound();
  testResetClearsMemory();
  if (failures == 0) std::printf("dsp_core: all tests passed\n");
  return failures == 0 ? 0 : 1;
}
