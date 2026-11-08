// Byte desktop audio: the method channel (own code, © 2026 Apurba Laskar).
#include "byte_desktop_audio.h"

#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "engine_win.h"
#include "smtc_win.h"

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

std::wstring ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0);
  std::wstring w(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), n);
  return w;
}

const EncodableValue* Get(const EncodableMap& m, const char* key) {
  auto it = m.find(EncodableValue(key));
  return it == m.end() ? nullptr : &it->second;
}

std::string Str(const EncodableMap& m, const char* key, const std::string& def = "") {
  auto* v = Get(m, key);
  if (!v) return def;
  if (auto* s = std::get_if<std::string>(v)) return *s;
  return def;
}

double Num(const EncodableMap& m, const char* key, double def) {
  auto* v = Get(m, key);
  if (!v) return def;
  if (auto* d = std::get_if<double>(v)) return *d;
  if (auto* i = std::get_if<int32_t>(v)) return *i;
  if (auto* l = std::get_if<int64_t>(v)) return static_cast<double>(*l);
  return def;
}

bool Flag(const EncodableMap& m, const char* key, bool def) {
  auto* v = Get(m, key);
  if (!v) return def;
  if (auto* b = std::get_if<bool>(v)) return *b;
  return def;
}

int64_t Int(const EncodableMap& m, const char* key, int64_t def) {
  return static_cast<int64_t>(Num(m, key, static_cast<double>(def)));
}

// The sound chain as the Dart side sends it (see lib/player/desktop_engine.dart).
byte_dsp::Config ReadConfig(const EncodableMap& m) {
  byte_dsp::Config c;
  c.inputGainDb = Num(m, "inputGainDb", 0);
  c.eqOn = Flag(m, "eqOn", false);
  if (auto* list = Get(m, "eq")) {
    if (auto* sections = std::get_if<EncodableList>(list)) {
      for (auto& s : *sections) {
        auto* k = std::get_if<EncodableList>(&s);
        if (!k || k->size() < 5) continue;
        byte_dsp::Coeffs co;
        auto d = [&](size_t i) -> double {
          auto& v = (*k)[i];
          if (auto* x = std::get_if<double>(&v)) return *x;
          if (auto* y = std::get_if<int32_t>(&v)) return *y;
          return 0.0;
        };
        co.b0 = d(0);
        co.b1 = d(1);
        co.b2 = d(2);
        co.a1 = d(3);
        co.a2 = d(4);
        c.eq.push_back(co);
      }
    }
  }
  c.reverbOn = Flag(m, "reverbOn", false);
  c.rvWet = Num(m, "rvWet", 0);
  c.rvDry = Num(m, "rvDry", 1);
  c.rvSize = Num(m, "rvSize", 0.5);
  c.rvDamping = Num(m, "rvDamping", 0.5);
  c.rvWidth = Num(m, "rvWidth", 1);
  c.rvPreDelayMs = Num(m, "rvPreDelayMs", 0);
  c.crossfeedOn = Flag(m, "crossfeedOn", false);
  c.xfStrength = Num(m, "xfStrength", 0);
  c.xfHz = Num(m, "xfHz", 700);
  c.mono = Flag(m, "mono", false);
  c.balance = Num(m, "balance", 0);
  c.compressorOn = Flag(m, "compressorOn", false);
  c.thresholdDb = Num(m, "thresholdDb", -6);
  c.ratio = Num(m, "ratio", 1);
  c.limiterOn = Flag(m, "limiterOn", false);
  c.limit = Num(m, "limit", 0.89);
  return c;
}

class ByteDesktopAudioPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  ByteDesktopAudioPlugin();
  ~ByteDesktopAudioPlugin() override;

 private:
  void HandleMethodCall(const flutter::MethodCall<EncodableValue>& call, std::unique_ptr<flutter::MethodResult<EncodableValue>> result);
  byte_audio::Engine* EngineFor(int64_t id);

  std::map<int64_t, std::unique_ptr<byte_audio::Engine>> engines_;
  int64_t nextId_ = 1;
  byte_audio::MediaOverlay overlay_;
  byte_dsp::Config lastChain_;
  bool haveChain_ = false;
  bool overlayTried_ = false;
};

// static
void ByteDesktopAudioPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(registrar->messenger(), "byte/desktop_audio",
                                                                          &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<ByteDesktopAudioPlugin>();
  channel->SetMethodCallHandler([plugin_pointer = plugin.get()](const auto& call, auto result) {
    plugin_pointer->HandleMethodCall(call, std::move(result));
  });
  registrar->AddPlugin(std::move(plugin));
}

ByteDesktopAudioPlugin::ByteDesktopAudioPlugin() = default;

ByteDesktopAudioPlugin::~ByteDesktopAudioPlugin() {
  engines_.clear();
}

byte_audio::Engine* ByteDesktopAudioPlugin::EngineFor(int64_t id) {
  auto it = engines_.find(id);
  return it == engines_.end() ? nullptr : it->second.get();
}

void ByteDesktopAudioPlugin::HandleMethodCall(const flutter::MethodCall<EncodableValue>& call,
                                              std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& method = call.method_name();
  EncodableMap args;
  if (auto* m = std::get_if<EncodableMap>(call.arguments())) args = *m;

  if (method == "dsp.set") {
    // The sound chain is one setting for the whole app: every engine gets it,
    // and an engine created later starts with it.
    lastChain_ = ReadConfig(args);
    haveChain_ = true;
    for (auto& e : engines_) e.second->SetChain(lastChain_);
    result->Success();
    return;
  }
  if (method == "engine.create") {
    int64_t id = nextId_++;
    engines_[id] = std::make_unique<byte_audio::Engine>();
    if (haveChain_) engines_[id]->SetChain(lastChain_);
    EncodableMap out{{EncodableValue("id"), EncodableValue(id)}};
    result->Success(EncodableValue(out));
    return;
  }
  if (method == "engine.dispose") {
    engines_.erase(Int(args, "id", 0));
    result->Success();
    return;
  }
  if (method == "engine.open") {
    auto* e = EngineFor(Int(args, "id", 0));
    if (!e) return result->Error("no-engine", "engine not found");
    e->Open(ToWide(Str(args, "source")), Int(args, "startMs", 0));
    result->Success();
    return;
  }
  if (method == "engine.play" || method == "engine.pause" || method == "engine.seek" || method == "engine.volume" ||
      method == "engine.status") {
    auto* e = EngineFor(Int(args, "id", 0));
    if (!e) return result->Error("no-engine", "engine not found");
    if (method == "engine.play") e->Play();
    else if (method == "engine.pause") e->Pause();
    else if (method == "engine.seek") e->Seek(Int(args, "ms", 0));
    else if (method == "engine.volume") e->SetVolume(Num(args, "volume", 1));
    else {
      auto s = e->Status();
      EncodableMap out{
          {EncodableValue("state"), EncodableValue(s.state)},
          {EncodableValue("posMs"), EncodableValue(s.posMs)},
          {EncodableValue("durMs"), EncodableValue(s.durMs)},
          {EncodableValue("playing"), EncodableValue(s.playing)},
          {EncodableValue("error"), EncodableValue(s.error)},
          {EncodableValue("queuedMs"), EncodableValue(s.queuedMs)},
      };
      result->Success(EncodableValue(out));
      return;
    }
    result->Success();
    return;
  }
  if (method == "smtc.init") {
    if (!overlayTried_) {
      overlayTried_ = true;
      overlay_.Init();
    }
    result->Success(EncodableValue(overlayTried_));
    return;
  }
  if (method == "smtc.update") {
    overlay_.Update(ToWide(Str(args, "title")), ToWide(Str(args, "artist")), ToWide(Str(args, "album")), ToWide(Str(args, "art")),
                    Flag(args, "hasItem", false), Flag(args, "playing", false), Int(args, "posMs", 0), Int(args, "durMs", 0));
    result->Success();
    return;
  }
  if (method == "smtc.poll") {
    EncodableList out;
    for (auto& name : overlay_.Poll()) out.push_back(EncodableValue(name));
    result->Success(EncodableValue(out));
    return;
  }
  if (method == "offline.render") {
    auto r = byte_audio::RenderOffline(ToWide(Str(args, "source")), ReadConfig(args), Num(args, "maxSeconds", 5));
    EncodableMap out{
        {EncodableValue("ok"), EncodableValue(r.ok)},
        {EncodableValue("error"), EncodableValue(r.error)},
        {EncodableValue("frames"), EncodableValue(r.frames)},
        {EncodableValue("peak"), EncodableValue(r.peak)},
        {EncodableValue("rms"), EncodableValue(r.rms)},
    };
    result->Success(EncodableValue(out));
    return;
  }
  result->NotImplemented();
}

}  // namespace

void ByteDesktopAudioRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  ByteDesktopAudioPlugin::RegisterWithRegistrar(flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
