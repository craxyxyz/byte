// Byte desktop audio: the sound chain (own code, © 2026 Apurba Laskar).
//
// Pure C++ with no Windows headers, so it can be unit-tested anywhere.
// Order matches the Audio Lab on the phone: input gain → equalizer (biquad
// sections computed in Dart, one per point) → reverb → crossfeed → mono /
// balance → loudness compressor → limiter. Samples are interleaved stereo
// float at 48 kHz.
#pragma once

#include <cmath>
#include <algorithm>
#include <cstddef>
#include <vector>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace byte_dsp {

constexpr double kSampleRate = 48000.0;

// One biquad section, already normalised (a0 == 1).
struct Coeffs {
  double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
};

struct Config {
  double inputGainDb = 0;     // preamp + loudness boost
  bool eqOn = false;
  std::vector<Coeffs> eq;     // cascade, applied in order

  bool reverbOn = false;
  double rvWet = 0;           // mix * wet, 0..1
  double rvDry = 1;           // 0.05..1
  double rvSize = 0.5;        // 0..1
  double rvDamping = 0.5;     // 0..1
  double rvWidth = 1;         // 0..1
  double rvPreDelayMs = 0;    // 0..100

  bool crossfeedOn = false;
  double xfStrength = 0;      // 0..1
  double xfHz = 700;          // cut-off of the crossed signal

  bool mono = false;
  double balance = 0;         // -1 (left) .. 1 (right)

  bool compressorOn = false;
  double thresholdDb = -6;
  double ratio = 1;

  bool limiterOn = false;
  double limit = 0.89;
};

namespace detail {

// Freeverb-style tunings, scaled to 48 kHz.
constexpr int kCombTuning[4] = {1116, 1188, 1277, 1356};
constexpr int kAllpassTuning[2] = {556, 441};
constexpr int kRightSpread = 23;

struct Comb {
  std::vector<float> buf;
  size_t idx = 0;
  float store = 0;
  void resize(size_t n) { buf.assign(n, 0.0f); idx = 0; store = 0; }
  float process(float input, float feedback, float damp1, float damp2) {
    float out = buf[idx];
    store = out * damp2 + store * damp1;
    buf[idx] = input + store * feedback;
    if (++idx >= buf.size()) idx = 0;
    return out;
  }
};

struct Allpass {
  std::vector<float> buf;
  size_t idx = 0;
  void resize(size_t n) { buf.assign(n, 0.0f); idx = 0; }
  float process(float input) {
    float bufout = buf[idx];
    float out = -input + bufout;
    buf[idx] = input + bufout * 0.5f;
    if (++idx >= buf.size()) idx = 0;
    return out;
  }
};

struct Reverb {
  Comb comb[2][4];
  Allpass ap[2][2];
  std::vector<float> pre[2];
  size_t preIdx = 0;
  size_t preLen = 1;

  void reset() {
    for (int c = 0; c < 2; c++) {
      for (auto& k : comb[c]) std::fill(k.buf.begin(), k.buf.end(), 0.0f);
      for (auto& a : ap[c]) std::fill(a.buf.begin(), a.buf.end(), 0.0f);
      std::fill(pre[c].begin(), pre[c].end(), 0.0f);
    }
    preIdx = 0;
  }
};

struct Biquad2 {  // direct form II transposed, one channel
  double z1 = 0, z2 = 0;
  float process(const Coeffs& k, double x) {
    double y = k.b0 * x + z1;
    z1 = k.b1 * x - k.a1 * y + z2;
    z2 = k.b2 * x - k.a2 * y;
    return static_cast<float>(y);
  }
};

}  // namespace detail

class Chain {
 public:
  Chain() { configure(Config{}); }

  // Replaces the settings. Filter memories are kept, so a parameter change
  // mid-song does not click; a new reverb size resets the tail.
  void configure(const Config& c) {
    bool reverbSizeChanged = c.reverbOn && (!reverbReady_ || c.rvPreDelayMs != cfg_.rvPreDelayMs);
    cfg_ = c;
    gain_ = std::pow(10.0, cfg_.inputGainDb / 20.0);
    eqL_.assign(cfg_.eq.size(), detail::Biquad2{});
    eqR_.assign(cfg_.eq.size(), detail::Biquad2{});
    if (cfg_.reverbOn) {
      if (reverbSizeChanged || !reverbReady_) buildReverb();
    }
    reverbReady_ = cfg_.reverbOn;
    double bal = cfg_.balance;
    gl_ = bal > 0 ? 1 - bal : 1.0;
    gr_ = bal < 0 ? 1 + bal : 1.0;
    xfA_ = std::exp(-2.0 * M_PI * cfg_.xfHz / kSampleRate);
    compAtt_ = std::exp(-1.0 / (0.010 * kSampleRate));
    compRel_ = std::exp(-1.0 / (0.200 * kSampleRate));
    limRel_ = std::exp(-1.0 / (0.050 * kSampleRate));
  }

  void reset() {
    for (auto& s : eqL_) s = detail::Biquad2{};
    for (auto& s : eqR_) s = detail::Biquad2{};
    xfL_ = xfR_ = 0;
    env_ = 0;
    limEnv_ = 1;
    if (reverbReady_) reverb_.reset();
  }

  // True when [configure] left the chain doing nothing.
  bool bypassed() const {
    bool eq = cfg_.eqOn && !cfg_.eq.empty();
    bool stereo = cfg_.mono || std::fabs(cfg_.balance) > 0.009;
    return !eq && !cfg_.reverbOn && !cfg_.crossfeedOn && !stereo && !cfg_.compressorOn && !cfg_.limiterOn && std::fabs(gain_ - 1.0) < 1e-9;
  }

  // Processes [frames] stereo frames in place.
  void process(float* inter, size_t frames) {
    if (bypassed()) return;
    const bool eq = cfg_.eqOn && !cfg_.eq.empty();
    for (size_t i = 0; i < frames; i++) {
      double l = inter[2 * i] * gain_;
      double r = inter[2 * i + 1] * gain_;
      if (eq) {
        for (size_t k = 0; k < cfg_.eq.size(); k++) {
          l = eqL_[k].process(cfg_.eq[k], l);
          r = eqR_[k].process(cfg_.eq[k], r);
        }
      }
      if (cfg_.reverbOn) {
        float wl, wr;
        reverbFrame(static_cast<float>(l), static_cast<float>(r), wl, wr);
        l = wl;
        r = wr;
      }
      if (cfg_.crossfeedOn && cfg_.xfStrength > 0) {
        double a = cfg_.xfStrength * 0.5;
        xfL_ = (1 - xfA_) * l + xfA_ * xfL_;
        xfR_ = (1 - xfA_) * r + xfA_ * xfR_;
        double nl = l + a * xfR_;
        double nr = r + a * xfL_;
        l = nl;
        r = nr;
      }
      if (cfg_.mono || std::fabs(cfg_.balance) > 0.009) {
        if (cfg_.mono) {
          double c0 = gl_ * 0.5 * l + gl_ * 0.5 * r;
          double c1 = gr_ * 0.5 * l + gr_ * 0.5 * r;
          l = c0;
          r = c1;
        } else {
          l = gl_ * l;
          r = gr_ * r;
        }
      }
      if (cfg_.compressorOn) {
        double peak = std::fmax(std::fabs(l), std::fabs(r));
        double lvl = peak > 1e-9 ? 20.0 * std::log10(peak) : -180.0;
        double coef = lvl > env_ ? compAtt_ : compRel_;
        env_ = coef * env_ + (1 - coef) * lvl;
        double over = env_ - cfg_.thresholdDb;
        if (over > 0) {
          double reductionDb = over * (1.0 - 1.0 / cfg_.ratio);
          double g = std::pow(10.0, -reductionDb / 20.0);
          l *= g;
          r *= g;
        }
      }
      if (cfg_.limiterOn) {
        double peak = std::fmax(std::fabs(l), std::fabs(r));
        double want = peak > cfg_.limit ? cfg_.limit / peak : 1.0;
        if (want < limEnv_) limEnv_ = want;
        else limEnv_ = want + (limEnv_ - want) * limRel_;
        l *= limEnv_;
        r *= limEnv_;
      }
      inter[2 * i] = static_cast<float>(l);
      inter[2 * i + 1] = static_cast<float>(r);
    }
  }

 private:
  void buildReverb() {
    size_t pre = static_cast<size_t>(std::max(0.0, cfg_.rvPreDelayMs) * kSampleRate / 1000.0) + 1;
    preLen_ = pre;
    for (int c = 0; c < 2; c++) {
      int spread = c == 1 ? detail::kRightSpread : 0;
      for (int k = 0; k < 4; k++) reverb_.comb[c][k].resize(static_cast<size_t>(detail::kCombTuning[k] + spread));
      for (int k = 0; k < 2; k++) reverb_.ap[c][k].resize(static_cast<size_t>(detail::kAllpassTuning[k] + spread));
      reverb_.pre[c].assign(pre, 0.0f);
    }
    reverb_.preIdx = 0;
  }

  void reverbFrame(float inL, float inR, float& outL, float& outR) {
    const float feedback = static_cast<float>(0.70 + cfg_.rvSize * 0.28);
    const float damp = static_cast<float>(cfg_.rvDamping * 0.4);
    const float damp1 = damp, damp2 = 1 - damp;
    const float wet = static_cast<float>(cfg_.rvWet);
    const float dry = static_cast<float>(cfg_.rvDry);
    const float width = static_cast<float>(cfg_.rvWidth);
    // Freeverb's wet scale (3) brings the four-comb sum to the usual level.
    float wet1 = 3.0f * wet * (width / 2 + 0.5f), wet2 = 3.0f * wet * ((1 - width) / 2);
    float in[2] = {inL, inR};
    float mixed[2];
    for (int c = 0; c < 2; c++) {
      auto& pre = reverb_.pre[c];
      float delayed = pre[reverb_.preIdx % pre.size()];
      pre[reverb_.preIdx % pre.size()] = in[c];
      mixed[c] = delayed;
    }
    if (++reverb_.preIdx >= preLen_) reverb_.preIdx = 0;
    float input = (mixed[0] + mixed[1]) * 0.015f;
    float acc[2] = {0, 0};
    for (int c = 0; c < 2; c++) {
      float s = 0;
      for (int k = 0; k < 4; k++) s += reverb_.comb[c][k].process(input, feedback, damp1, damp2);
      for (int k = 0; k < 2; k++) s = reverb_.ap[c][k].process(s);
      acc[c] = s;
    }
    float wl = acc[0] * wet1 + acc[1] * wet2;
    float wr = acc[1] * wet1 + acc[0] * wet2;
    outL = in[0] * dry + wl;
    outR = in[1] * dry + wr;
  }

  Config cfg_;
  double gain_ = 1;
  std::vector<detail::Biquad2> eqL_, eqR_;
  bool reverbReady_ = false;
  detail::Reverb reverb_;
  size_t preLen_ = 1;
  double gl_ = 1, gr_ = 1;
  double xfA_ = 0, xfL_ = 0, xfR_ = 0;
  double compAtt_ = 0, compRel_ = 0, env_ = -180;
  double limRel_ = 0, limEnv_ = 1;
};

}  // namespace byte_dsp
