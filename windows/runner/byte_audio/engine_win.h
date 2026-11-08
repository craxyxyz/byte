// Byte desktop audio: one playback engine (own code, © 2026 Apurba Laskar).
//
// A decoder thread reads the song through the system's Media Foundation
// reader (float stereo, 48 kHz) into a queue; a render thread pulls from the
// queue, runs the sound chain and writes to the default output with WASAPI
// shared mode (event driven). Nothing here is third-party code.
#pragma once

#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

#include "dsp_core.h"

namespace byte_audio {

struct EngineStatus {
  std::string state;  // idle | loading | ready | completed | error
  int64_t posMs = 0;
  int64_t durMs = -1;
  bool playing = false;
  std::string error;  // empty when fine
  int64_t queuedMs = 0;
};

class Engine {
 public:
  Engine();
  ~Engine();
  Engine(const Engine&) = delete;
  Engine& operator=(const Engine&) = delete;

  // Loads [source] (a file path or an http(s) address) from [startMs]. Returns
  // at once; the state moves loading → ready (or error) on the decoder thread.
  void Open(const std::wstring& source, int64_t startMs);
  void Play();
  void Pause();
  void Seek(int64_t ms);
  void SetVolume(double volume);
  void SetChain(const byte_dsp::Config& config);
  EngineStatus Status();
  void Dispose();

 private:
  void DecodeLoop();
  void RenderLoop();

  std::mutex mu_;
  std::atomic<bool> quit_{false};
  bool disposed_ = false;

  // request state (guarded by mu_)
  std::wstring source_;
  int64_t startMs_ = 0;
  bool openPending_ = false;
  bool seekPending_ = false;
  int64_t seekMs_ = 0;
  bool playing_ = false;
  double volume_ = 1.0;
  bool chainDirty_ = false;
  byte_dsp::Config pendingChain_;
  bool resetChain_ = false;
  bool wantPlay_ = false;      // the caller asked to play (kept across loads)
  byte_dsp::Chain chain_;      // guarded by mu_

  // decoded audio (guarded by mu_)
  std::deque<float> queue_;  // interleaved stereo
  bool eos_ = false;
  bool ready_ = false;
  int64_t durMs_ = -1;
  int64_t basePosMs_ = 0;
  int64_t renderedFrames_ = 0;
  std::string state_ = "idle";
  std::string error_;
  std::string outputError_;

  std::thread decoder_;
  std::thread renderer_;
};

// Decodes [source] through the same chain the engine uses, without an output
// device: peak and RMS of the result (for the runner's checks).
struct OfflineResult {
  bool ok = false;
  std::string error;
  int64_t frames = 0;
  double peak = 0;
  double rms = 0;
};
OfflineResult RenderOffline(const std::wstring& source, const byte_dsp::Config& config, double maxSeconds);

}  // namespace byte_audio
