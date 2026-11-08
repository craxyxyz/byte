// Byte desktop audio: the Windows media overlay (own code, © 2026 Apurba Laskar).
//
// Binds the app window to the system's media transport controls: the overlay
// and lock screen show the title, artist and artwork, and the play, pause,
// next and previous buttons come back to the app as names to poll.
#pragma once

#include <windows.h>

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace byte_audio {

class MediaOverlay {
 public:
  MediaOverlay();
  ~MediaOverlay();
  // Attaches to the app window (once). False when the system has no overlay.
  bool Init();
  void Update(const std::wstring& title, const std::wstring& artist, const std::wstring& album,
              const std::wstring& artUrl, bool hasItem, bool playing, int64_t posMs, int64_t durMs);
  // Button names pressed since the last poll: play, pause, next, previous, stop.
  std::vector<std::string> Poll();

 private:
  struct Impl;
  Impl* impl_ = nullptr;
  std::mutex mu_;
  std::vector<std::string> pending_;
  friend struct Impl;
  void Push(const char* name);
};

}  // namespace byte_audio
