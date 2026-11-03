import AVFoundation
import Flutter
import MediaPlayer
import UIKit
import WebKit

// Byte © 2026 Apurba Laskar
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Equalizer for the iPhone player (Settings → Playback → Equalizer).
    ByteEQ.install()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The sign-in page's YouTube Music session cookies, read on the phone.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ByteCookies") {
      let channel = FlutterMethodChannel(name: "byte/cookies", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "get" else {
          result(FlutterMethodNotImplemented)
          return
        }
        // 1.4.2: any app's cookies by url (music-app log-ins); YouTube Music by default
        let args = call.arguments as? [String: Any]
        let host = URL(string: (args?["url"] as? String) ?? "https://music.youtube.com")?.host ?? "music.youtube.com"
        let site = host.split(separator: ".").suffix(2).joined(separator: ".")
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          let header = cookies
            .filter { $0.domain.hasSuffix(site) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
          result(header)
        }
      }
    }
    // Output sheet (device, volume, sample rate) and Cast discovery.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ByteAudioRoute") {
      ByteAudioRoute.register(registrar.messenger())
      ByteCastBrowser.register(registrar.messenger())
    }
    // 1.4.2: lyrics screen open → the screen doesn't dim or lock.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ByteDisplay") {
      let channel = FlutterMethodChannel(name: "byte/display", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "keepScreenOn":
          let on = (call.arguments as? Bool) ?? false
          DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = on
            result(true)
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    // App icon chooser (Settings → Advanced → App icon). Icons live in
    // Assets.xcassets as AppIcon-<Name> sets.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ByteIcons") {
      let channel = FlutterMethodChannel(name: "byte/icons", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "set":
          let want = (call.arguments as? String) ?? "Default"
          guard UIApplication.shared.supportsAlternateIcons else {
            result(false)
            return
          }
          let name: String? = want == "Default" ? nil : "AppIcon-\(want)"
          if UIApplication.shared.alternateIconName == name {
            result(true)
            return
          }
          UIApplication.shared.setAlternateIconName(name) { error in
            result(error == nil)
          }
        case "get":
          let n = UIApplication.shared.alternateIconName
          result(n.map { $0.replacingOccurrences(of: "AppIcon-", with: "") } ?? "Default")
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    // Equalizer settings from Dart.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ByteEQ") {
      let channel = FlutterMethodChannel(name: "byte/eq", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "set" || call.method == "lowcut" || call.method == "channels", let args = call.arguments as? [String: Any] else {
          result(FlutterMethodNotImplemented)
          return
        }
        if call.method == "channels" {
          ByteEQ.setBalance(Float((args["balance"] as? Double) ?? 0), mono: (args["mono"] as? Bool) ?? false)
          result(true)
          return
        }
        if call.method == "lowcut" {
          ByteEQ.setLowCut((args["key"] as? String) ?? "", amount: Float((args["amount"] as? Double) ?? 0))
          result(true)
          return
        }
        let on = (args["enabled"] as? Bool) ?? false
        let freqs = ((args["freqs"] as? [Double]) ?? []).map { NSNumber(value: $0) }
        let gains = ((args["gains"] as? [Double]) ?? []).map { NSNumber(value: $0) }
        ByteEQ.setEnabled(on, frequencies: freqs, gains: gains)
        result(true)
      }
    }
    // Automix: decode a song to PCM for analysis.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ByteAutomix") {
      let channel = FlutterMethodChannel(name: "byte/automix", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        guard call.method == "decode", let args = call.arguments as? [String: Any], let path = args["path"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        let rate = (args["rate"] as? Int) ?? 11025
        let maxSeconds = (args["maxSeconds"] as? Int) ?? 1200
        AutomixDecoder.decode(path: path, rate: Double(rate), maxSeconds: Double(maxSeconds)) { data, error in
          DispatchQueue.main.async {
            if let d = data {
              result(FlutterStandardTypedData(bytes: d))
            } else {
              result(FlutterError(code: "decode", message: error ?? "decode failed", details: nil))
            }
          }
        }
      }
    }
    // byte://listen/CODE party links.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ByteLinks") {
      ByteLinks.shared.attach(registrar)
    }
  }
}

/// Delivers byte:// links (Listen together invites) to Dart.
class ByteLinks: NSObject, FlutterSceneLifeCycleDelegate {
  static let shared = ByteLinks()
  private var channel: FlutterMethodChannel?
  private var initial: String?

  func attach(_ registrar: FlutterPluginRegistrar) {
    let ch = FlutterMethodChannel(name: "byte/links", binaryMessenger: registrar.messenger())
    ch.setMethodCallHandler { [weak self] call, result in
      if call.method == "initial" {
        result(self?.initial)
        self?.initial = nil
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    channel = ch
    registrar.addSceneDelegate(self)
  }

  func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions?) -> Bool {
    if let url = connectionOptions?.urlContexts.first?.url, url.scheme == "byte" {
      initial = url.absoluteString
    }
    return false
  }

  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    guard let url = URLContexts.first?.url, url.scheme == "byte" else { return false }
    channel?.invokeMethod("link", arguments: url.absoluteString)
    return true
  }
}

/// Automix: reads a song file on the phone (AVAssetReader) as mono 16-bit
/// PCM at a low sample rate for Byte's analysis (tempo, beats, loudness).
enum AutomixDecoder {
  static let queue = DispatchQueue(label: "byte.automix.decode", qos: .utility)

  static func decode(path: String, rate: Double, maxSeconds: Double, done: @escaping (Data?, String?) -> Void) {
    queue.async {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      do {
        let reader = try AVAssetReader(asset: asset)
        let tracks = asset.tracks(withMediaType: .audio)
        guard !tracks.isEmpty else {
          done(nil, "no audio track")
          return
        }
        let settings: [String: Any] = [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVSampleRateKey: rate,
          AVNumberOfChannelsKey: 1,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
          done(nil, "can't read this file")
          return
        }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxSeconds, preferredTimescale: 600))
        guard reader.startReading() else {
          done(nil, reader.error?.localizedDescription ?? "can't read this file")
          return
        }
        var data = Data()
        while let sample = output.copyNextSampleBuffer() {
          guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
          let length = CMBlockBufferGetDataLength(block)
          if length == 0 { continue }
          var chunk = Data(count: length)
          let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
          }
          if status == kCMBlockBufferNoErr { data.append(chunk) }
        }
        if reader.status == .failed {
          done(nil, reader.error?.localizedDescription ?? "decode failed")
        } else {
          done(data, nil)
        }
      } catch {
        done(nil, error.localizedDescription)
      }
    }
  }
}

// Byte © 2026 Apurba Laskar. iPhone side of the output sheet (byte/audio) and
// Cast discovery through Bonjour (byte/cast).
final class ByteAudioRoute {
  private static let volumeView = MPVolumeView(frame: CGRect(x: -100, y: -100, width: 1, height: 1))

  static func register(_ messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "byte/audio", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      switch call.method {
      case "info":
        result(info())
      case "setVolume":
        let v = ((call.arguments as? [String: Any])?["v"] as? Double) ?? 0.5
        // The system volume slider is the only way to set the iPhone's volume.
        DispatchQueue.main.async {
          if volumeView.superview == nil, let w = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first }).first {
            w.addSubview(volumeView)
          }
          if let s = volumeView.subviews.compactMap({ $0 as? UISlider }).first {
            s.value = Float(v)
            s.sendActions(for: .valueChanged)
          }
          result(nil)
        }
      case "multicast":
        result(nil)  // iOS: Bonjour handles discovery, no lock needed
      case "usbMixer":
        result("unsupported")  // bit-perfect USB mixing is an Android 14 feature
      case "soundSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func info() -> [String: Any] {
    let s = AVAudioSession.sharedInstance()
    let out = s.currentRoute.outputs.first
    var type = "speaker"
    switch out?.portType {
    case .some(.bluetoothA2DP), .some(.bluetoothLE), .some(.bluetoothHFP): type = "bluetooth"
    case .some(.headphones): type = "wired"
    case .some(.usbAudio): type = "usb"
    case .some(.HDMI): type = "hdmi"
    case .some(.airPlay): type = "airplay"
    default: type = "speaker"
    }
    var spatial = false
    if #available(iOS 15.0, *) { spatial = out?.isSpatialAudioEnabled ?? false }
    return [
      "deviceName": UIDevice.current.name,
      "outputType": type,
      "outputName": out?.portName ?? NSNull(),
      "sampleRate": Int(s.sampleRate),
      "framesPerBuffer": Int(s.ioBufferDuration * s.sampleRate),
      "volume": Double(s.outputVolume),
      "maxVolume": 1.0,
      "atmos": false,
      "spatialAvailable": spatial,
      "spatialEnabled": spatial,
    ]
  }
}

/// Finds Google Cast speakers and TVs with the system Bonjour browser.
final class ByteCastBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private let browser = NetServiceBrowser()
  private var services: [NetService] = []
  private var found: [[String: Any]] = []
  private var done: (([[String: Any]]) -> Void)?

  static func register(_ messenger: FlutterBinaryMessenger) {
    let ch = FlutterMethodChannel(name: "byte/cast", binaryMessenger: messenger)
    ch.setMethodCallHandler { call, result in
      guard call.method == "scan" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let secs = ((call.arguments as? [String: Any])?["seconds"] as? Int) ?? 5
      let b = ByteCastBrowser()
      b.scan(seconds: secs) { list in result(list) }
    }
  }

  func scan(seconds: Int, completion: @escaping ([[String: Any]]) -> Void) {
    done = completion
    browser.delegate = self
    browser.searchForServices(ofType: "_googlecast._tcp.", inDomain: "local.")
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [self] in
      browser.stop()
      services.forEach { $0.stop() }
      done?(found)
      done = nil
    }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    services.append(service)
    service.delegate = self
    service.resolve(withTimeout: 3)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    var txt: [String: String] = [:]
    if let data = sender.txtRecordData() {
      for (k, v) in NetService.dictionary(fromTXTRecord: data) {
        txt[k] = String(data: v, encoding: .utf8)
      }
    }
    // the first IPv4 address
    var host: String?
    for a in sender.addresses ?? [] {
      a.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
        guard let sa = p.baseAddress?.assumingMemoryBound(to: sockaddr.self), sa.pointee.sa_family == UInt8(AF_INET) else { return }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(a.count), &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
          host = String(cString: buf)
        }
      }
      if host != nil { break }
    }
    guard let h = host else { return }
    found.append(["id": txt["id"] ?? sender.name, "name": txt["fn"] ?? sender.name, "host": h, "port": sender.port, "model": txt["md"] ?? ""])
  }
}
