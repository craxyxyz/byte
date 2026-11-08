// Byte desktop audio: the Windows media overlay (own code, © 2026 Apurba Laskar).
#include "smtc_win.h"

#include <chrono>

#include <windows.h>
#include <systemmediatransportcontrolsinterop.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Media.h>
#include <winrt/Windows.Storage.Streams.h>

#pragma comment(lib, "windowsapp")

using namespace winrt::Windows::Media;

namespace byte_audio {

struct MediaOverlay::Impl {
  SystemMediaTransportControls smtc{nullptr};
  winrt::event_token buttonToken{};
  MediaOverlay* owner = nullptr;
  bool ok = false;
};

namespace {

HWND FindAppWindow() {
  HWND h = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  if (!h) h = GetForegroundWindow();
  return h;
}

}  // namespace

MediaOverlay::MediaOverlay() = default;

MediaOverlay::~MediaOverlay() {
  if (impl_) {
    if (impl_->ok) {
      try {
        impl_->smtc.ButtonPressed(impl_->buttonToken);
        impl_->smtc.IsEnabled(false);
      } catch (...) {
      }
    }
    delete impl_;
  }
}

void MediaOverlay::Push(const char* name) {
  std::lock_guard<std::mutex> g(mu_);
  pending_.push_back(name);
}

bool MediaOverlay::Init() {
  if (impl_) return impl_->ok;
  impl_ = new Impl();
  impl_->owner = this;
  try {
    HWND hwnd = FindAppWindow();
    if (!hwnd) return false;
    auto interop = winrt::get_activation_factory<SystemMediaTransportControls, ISystemMediaTransportControlsInterop>();
    SystemMediaTransportControls s{nullptr};
    winrt::check_hresult(interop->GetForWindow(hwnd, winrt::guid_of<SystemMediaTransportControls>(), winrt::put_abi(s)));
    impl_->smtc = s;
    impl_->smtc.IsEnabled(true);
    impl_->smtc.IsPlayEnabled(true);
    impl_->smtc.IsPauseEnabled(true);
    impl_->smtc.IsNextEnabled(true);
    impl_->smtc.IsPreviousEnabled(true);
    impl_->smtc.IsStopEnabled(false);
    impl_->buttonToken = impl_->smtc.ButtonPressed(
        [this](SystemMediaTransportControls const&, SystemMediaTransportControlsButtonPressedEventArgs const& args) {
          switch (args.Button()) {
            case SystemMediaTransportControlsButton::Play: Push("play"); break;
            case SystemMediaTransportControlsButton::Pause: Push("pause"); break;
            case SystemMediaTransportControlsButton::Next: Push("next"); break;
            case SystemMediaTransportControlsButton::Previous: Push("previous"); break;
            case SystemMediaTransportControlsButton::Stop: Push("stop"); break;
            default: break;
          }
        });
    impl_->ok = true;
  } catch (...) {
    impl_->ok = false;
  }
  return impl_->ok;
}

void MediaOverlay::Update(const std::wstring& title, const std::wstring& artist, const std::wstring& album,
                          const std::wstring& artUrl, bool hasItem, bool playing, int64_t posMs, int64_t durMs) {
  if (!impl_ || !impl_->ok) return;
  try {
    auto smtc = impl_->smtc;
    smtc.PlaybackStatus(!hasItem ? MediaPlaybackStatus::Closed : (playing ? MediaPlaybackStatus::Playing : MediaPlaybackStatus::Paused));
    auto upd = smtc.DisplayUpdater();
    upd.Type(MediaPlaybackType::Music);
    auto music = upd.MusicProperties();
    music.Title(winrt::hstring(title));
    music.Artist(winrt::hstring(artist));
    music.AlbumTitle(winrt::hstring(album));
    if (!artUrl.empty()) {
      try {
        upd.Thumbnail(winrt::Windows::Storage::Streams::RandomAccessStreamReference::CreateFromUri(winrt::Windows::Foundation::Uri(winrt::hstring(artUrl))));
      } catch (...) {
      }
    }
    upd.Update();
    if (hasItem && durMs > 0) {
      SystemMediaTransportControlsTimelineProperties tl;
      tl.StartTime(std::chrono::milliseconds(0));
      tl.MinSeekTime(std::chrono::milliseconds(0));
      tl.Position(std::chrono::milliseconds(posMs < 0 ? 0 : posMs));
      tl.MaxSeekTime(std::chrono::milliseconds(durMs));
      tl.EndTime(std::chrono::milliseconds(durMs));
      smtc.UpdateTimelineProperties(tl);
    }
  } catch (...) {
  }
}

std::vector<std::string> MediaOverlay::Poll() {
  std::lock_guard<std::mutex> g(mu_);
  std::vector<std::string> out;
  out.swap(pending_);
  return out;
}

}  // namespace byte_audio
