// Byte desktop audio: the playback engine on Windows (own code, © 2026 Apurba Laskar).
#include "engine_win.h"

// This must be included before other Windows headers.
#include <windows.h>
#include <audioclient.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mfreadwrite.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>
#include <ks.h>
#include <ksmedia.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cmath>
#include <cstring>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "mfplat.lib")
#pragma comment(lib, "mfreadwrite.lib")
#pragma comment(lib, "mfuuid.lib")
#pragma comment(lib, "propsys.lib")

namespace byte_audio {
namespace {

constexpr int kRate = 48000;
constexpr int kChannels = 2;
constexpr size_t kQueueTarget = kRate * kChannels * 2;  // about two seconds ahead

std::string Hex(HRESULT hr) {
  char b[16];
  std::snprintf(b, sizeof b, "0x%08lX", static_cast<unsigned long>(hr));
  return b;
}

bool MfReady() {
  static bool started = [] { return SUCCEEDED(MFStartup(MF_VERSION, MFSTARTUP_LITE)); }();
  return started;
}

// Opens the first audio stream of [source] as float stereo at 48 kHz.
HRESULT OpenReader(const std::wstring& source, IMFSourceReader** reader, int64_t* durMs) {
  *reader = nullptr;
  if (!MfReady()) return E_FAIL;
  IMFSourceReader* r = nullptr;
  HRESULT hr = MFCreateSourceReaderFromURL(source.c_str(), nullptr, &r);
  if (FAILED(hr)) return hr;
  r->SetStreamSelection(MF_SOURCE_READER_ALL_STREAMS, FALSE);
  r->SetStreamSelection(MF_SOURCE_READER_FIRST_AUDIO_STREAM, TRUE);
  IMFMediaType* type = nullptr;
  hr = MFCreateMediaType(&type);
  if (SUCCEEDED(hr)) {
    type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    type->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_Float);
    type->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 32);
    type->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, kRate);
    type->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, kChannels);
    hr = r->SetCurrentMediaType(MF_SOURCE_READER_FIRST_AUDIO_STREAM, nullptr, type);
    type->Release();
  }
  if (FAILED(hr)) {
    r->Release();
    return hr;
  }
  if (durMs) {
    *durMs = -1;
    PROPVARIANT v;
    PropVariantInit(&v);
    if (SUCCEEDED(r->GetPresentationAttribute(MF_SOURCE_READER_MEDIASOURCE, MF_PD_DURATION, &v)) && v.vt == VT_UI8) {
      *durMs = static_cast<int64_t>(v.uhVal.QuadPart / 10000);
    }
    PropVariantClear(&v);
  }
  *reader = r;
  return S_OK;
}

HRESULT SeekReader(IMFSourceReader* r, int64_t ms) {
  PROPVARIANT v;
  HRESULT hr = InitPropVariantFromInt64(static_cast<LONGLONG>(ms) * 10000, &v);
  if (FAILED(hr)) return hr;
  hr = r->SetCurrentPosition(GUID_NULL, v);
  PropVariantClear(&v);
  return hr;
}

// Reads one decoded block as interleaved floats. Returns false at the end.
// [eos] is set when the stream has ended.
bool ReadBlock(IMFSourceReader* r, std::vector<float>& out, bool& eos) {
  out.clear();
  eos = false;
  for (int tries = 0; tries < 8; tries++) {
    DWORD flags = 0;
    LONGLONG ts = 0;
    IMFSample* sample = nullptr;
    HRESULT hr = r->ReadSample(MF_SOURCE_READER_FIRST_AUDIO_STREAM, 0, nullptr, &flags, &ts, &sample);
    if (FAILED(hr)) {
      eos = true;
      return false;
    }
    if (flags & MF_SOURCE_READERF_ENDOFSTREAM) {
      if (sample) sample->Release();
      eos = true;
      return false;
    }
    if (!sample) continue;
    IMFMediaBuffer* buf = nullptr;
    if (SUCCEEDED(sample->ConvertToContiguousBuffer(&buf))) {
      BYTE* p = nullptr;
      DWORD len = 0;
      if (SUCCEEDED(buf->Lock(&p, nullptr, &len))) {
        size_t n = len / sizeof(float);
        out.resize(n);
        std::memcpy(out.data(), p, n * sizeof(float));
        buf->Unlock();
      }
      buf->Release();
    }
    sample->Release();
    if (!out.empty()) return true;
  }
  return !out.empty();
}

}  // namespace

Engine::Engine() {
  decoder_ = std::thread([this] { DecodeLoop(); });
  renderer_ = std::thread([this] { RenderLoop(); });
}

Engine::~Engine() { Dispose(); }

void Engine::Dispose() {
  if (disposed_) return;
  disposed_ = true;
  quit_ = true;
  if (decoder_.joinable()) decoder_.join();
  if (renderer_.joinable()) renderer_.join();
}

void Engine::Open(const std::wstring& source, int64_t startMs) {
  std::lock_guard<std::mutex> g(mu_);
  wantPlay_ = false;
  source_ = source;
  startMs_ = startMs < 0 ? 0 : startMs;
  openPending_ = true;
  playing_ = false;
  ready_ = false;
  state_ = "loading";
  error_.clear();
}

void Engine::Play() {
  std::lock_guard<std::mutex> g(mu_);
  wantPlay_ = true;
  if (state_ == "completed") {
    seekPending_ = true;
    seekMs_ = 0;
    state_ = "ready";
  }
  if (state_ == "ready") playing_ = true;
}

void Engine::Pause() {
  std::lock_guard<std::mutex> g(mu_);
  wantPlay_ = false;
  playing_ = false;
}

void Engine::Seek(int64_t ms) {
  std::lock_guard<std::mutex> g(mu_);
  seekPending_ = true;
  seekMs_ = ms < 0 ? 0 : ms;
  resetChain_ = true;
}

void Engine::SetVolume(double volume) {
  std::lock_guard<std::mutex> g(mu_);
  volume_ = std::clamp(volume, 0.0, 1.0);
}

void Engine::SetChain(const byte_dsp::Config& config) {
  std::lock_guard<std::mutex> g(mu_);
  pendingChain_ = config;
  chainDirty_ = true;
}

EngineStatus Engine::Status() {
  std::lock_guard<std::mutex> g(mu_);
  EngineStatus s;
  s.state = state_;
  s.durMs = durMs_;
  s.playing = playing_;
  s.posMs = basePosMs_ + static_cast<int64_t>(renderedFrames_ * 1000 / kRate);
  if (durMs_ >= 0 && s.posMs > durMs_) s.posMs = durMs_;
  s.queuedMs = static_cast<int64_t>(queue_.size() / kChannels * 1000 / kRate);
  s.error = !error_.empty() ? error_ : outputError_;
  return s;
}

void Engine::DecodeLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  IMFSourceReader* reader = nullptr;
  std::vector<float> block;
  while (!quit_) {
    bool doOpen = false;
    std::wstring src;
    int64_t start = 0;
    {
      std::lock_guard<std::mutex> g(mu_);
      if (openPending_) {
        doOpen = true;
        openPending_ = false;
        src = source_;
        start = startMs_;
      }
    }
    if (doOpen) {
      if (reader) {
        reader->Release();
        reader = nullptr;
      }
      int64_t dur = -1;
      HRESULT hr = OpenReader(src, &reader, &dur);
      std::lock_guard<std::mutex> g(mu_);
      queue_.clear();
      eos_ = false;
      renderedFrames_ = 0;
      basePosMs_ = start;
      if (FAILED(hr)) {
        state_ = "error";
        error_ = "open failed " + Hex(hr);
        ready_ = false;
        durMs_ = -1;
        continue;
      }
      durMs_ = dur;
      ready_ = true;
      state_ = "ready";
      playing_ = wantPlay_;
      if (start > 0) {
        seekPending_ = true;
        seekMs_ = start;
      }
    }
    bool doSeek = false;
    int64_t target = 0;
    {
      std::lock_guard<std::mutex> g(mu_);
      if (seekPending_) {
        seekPending_ = false;
        doSeek = true;
        target = seekMs_;
      }
    }
    if (doSeek && reader) {
      HRESULT hr = SeekReader(reader, target);
      std::lock_guard<std::mutex> g(mu_);
      queue_.clear();
      eos_ = false;
      renderedFrames_ = 0;
      basePosMs_ = target;
      if (state_ == "completed") state_ = "ready";
      if (FAILED(hr)) {
        error_ = "seek failed " + Hex(hr);
      }
    }
    bool needMore = false;
    {
      std::lock_guard<std::mutex> g(mu_);
      needMore = reader && ready_ && !eos_ && queue_.size() < kQueueTarget;
    }
    if (!needMore) {
      std::this_thread::sleep_for(std::chrono::milliseconds(8));
      continue;
    }
    bool eos = false;
    bool got = ReadBlock(reader, block, eos);
    std::lock_guard<std::mutex> g(mu_);
    if (got) queue_.insert(queue_.end(), block.begin(), block.end());
    if (eos) eos_ = true;
  }
  if (reader) reader->Release();
  CoUninitialize();
}

void Engine::RenderLoop() {
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  IMMDeviceEnumerator* enumr = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* client = nullptr;
  IAudioRenderClient* render = nullptr;
  HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, __uuidof(IMMDeviceEnumerator), reinterpret_cast<void**>(&enumr));
  if (SUCCEEDED(hr)) hr = enumr->GetDefaultAudioEndpoint(eRender, eMultimedia, &device);
  if (SUCCEEDED(hr)) hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&client));
  WAVEFORMATEXTENSIBLE fmt{};
  UINT32 bufferFrames = 0;
  if (SUCCEEDED(hr)) {
    fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    fmt.Format.nChannels = kChannels;
    fmt.Format.nSamplesPerSec = kRate;
    fmt.Format.wBitsPerSample = 32;
    fmt.Format.nBlockAlign = kChannels * 4;
    fmt.Format.nAvgBytesPerSec = kRate * kChannels * 4;
    fmt.Format.cbSize = 22;
    fmt.Samples.wValidBitsPerSample = 32;
    fmt.dwChannelMask = SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
    fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                            AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                            2000000, 0, &fmt.Format, nullptr);
  }
  if (SUCCEEDED(hr)) hr = client->SetEventHandle(event);
  if (SUCCEEDED(hr)) hr = client->GetBufferSize(&bufferFrames);
  if (SUCCEEDED(hr)) hr = client->GetService(__uuidof(IAudioRenderClient), reinterpret_cast<void**>(&render));
  if (SUCCEEDED(hr)) hr = client->Start();
  if (FAILED(hr)) {
    std::lock_guard<std::mutex> g(mu_);
    outputError_ = "no audio output " + Hex(hr);
  }
  const bool outputOk = SUCCEEDED(hr);
  while (!quit_) {
    if (!outputOk) {
      std::this_thread::sleep_for(std::chrono::milliseconds(50));
      continue;
    }
    WaitForSingleObject(event, 200);
    UINT32 padding = 0;
    if (FAILED(client->GetCurrentPadding(&padding))) continue;
    UINT32 avail = bufferFrames - padding;
    if (avail == 0) continue;
    BYTE* data = nullptr;
    if (FAILED(render->GetBuffer(avail, &data))) continue;
    float* out = reinterpret_cast<float*>(data);
    size_t want = avail;
    {
      std::lock_guard<std::mutex> g(mu_);
      if (chainDirty_) {
        chain_.configure(pendingChain_);
        chainDirty_ = false;
      }
      if (resetChain_) {
        chain_.reset();
        resetChain_ = false;
      }
      size_t have = queue_.size() / kChannels;
      size_t n = 0;
      if (playing_ && ready_) {
        n = std::min(want, have);
        for (size_t i = 0; i < n * kChannels; i++) {
          out[i] = queue_.front();
          queue_.pop_front();
        }
        if (n > 0) {
          chain_.process(out, n);
          for (size_t i = 0; i < n * kChannels; i++) out[i] = static_cast<float>(out[i] * volume_);
        }
        renderedFrames_ += static_cast<int64_t>(n);
        if (n < want && eos_ && queue_.empty()) {
          playing_ = false;
          state_ = "completed";
        }
      }
      std::memset(out + n * kChannels, 0, (want - n) * kChannels * sizeof(float));
    }
    render->ReleaseBuffer(avail, 0);
  }
  if (client) client->Stop();
  if (render) render->Release();
  if (client) client->Release();
  if (device) device->Release();
  if (enumr) enumr->Release();
  if (event) CloseHandle(event);
  CoUninitialize();
}

OfflineResult RenderOffline(const std::wstring& source, const byte_dsp::Config& config, double maxSeconds) {
  OfflineResult res;
  CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  IMFSourceReader* reader = nullptr;
  HRESULT hr = OpenReader(source, &reader, nullptr);
  if (FAILED(hr)) {
    res.error = "open failed " + Hex(hr);
    CoUninitialize();
    return res;
  }
  byte_dsp::Chain chain;
  chain.configure(config);
  const int64_t limit = static_cast<int64_t>(maxSeconds * kRate);
  double sumSq = 0;
  std::vector<float> block;
  while (res.frames < limit) {
    bool eos = false;
    if (!ReadBlock(reader, block, eos)) break;
    size_t n = block.size() / kChannels;
    if (res.frames + static_cast<int64_t>(n) > limit) n = static_cast<size_t>(limit - res.frames);
    chain.process(block.data(), n);
    for (size_t i = 0; i < n * kChannels; i++) {
      double v = block[i];
      res.peak = std::max(res.peak, std::fabs(v));
      sumSq += v * v;
    }
    res.frames += static_cast<int64_t>(n);
  }
  if (res.frames > 0) res.rms = std::sqrt(sumSq / (static_cast<double>(res.frames) * kChannels));
  res.ok = res.frames > 0;
  if (!res.ok) res.error = "no audio decoded";
  reader->Release();
  CoUninitialize();
  return res;
}

}  // namespace byte_audio
