// Byte © 2026 Apurba Laskar.
//
// 2.0.9 — sound on a computer (Windows).
//
// Normal playback stays on the system player that the app has always used.
// While Audio Lab has an effect on, a song plays through Byte's own engine
// (native/byte_audio: decode, equalizer, reverb, crossfeed, balance, mono,
// loudness, limiter, then the output device). The two paths sit behind the
// same player calls, so the rest of the app does not change. Speed and pitch
// are not in the engine: a song at another speed plays on the normal path.
// The Windows media overlay (title, artist, artwork, play / pause / next /
// previous) is bound here too.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';

import '../audiolab/audio_lab.dart';

/// One state read from the engine.
class EngineStatus {
  final String state; // idle | loading | ready | completed | error
  final int posMs;
  final int? durMs;
  final bool playing;
  final String error;
  final int queuedMs;
  const EngineStatus({required this.state, required this.posMs, required this.durMs, required this.playing, required this.error, required this.queuedMs});

  static EngineStatus fromMap(Map<dynamic, dynamic> m) => EngineStatus(
        state: (m['state'] as String?) ?? 'idle',
        posMs: (m['posMs'] as num?)?.toInt() ?? 0,
        durMs: (m['durMs'] as num?)?.toInt(),
        playing: m['playing'] == true,
        error: (m['error'] as String?) ?? '',
        queuedMs: (m['queuedMs'] as num?)?.toInt() ?? 0,
      );
}

/// Calls into the Windows sound plugin (windows/byte_audio). Tests pass a fake.
abstract class DesktopEngineBridge {
  Future<int> create();
  Future<void> dispose(int id);
  Future<void> open(int id, String source, int startMs);
  Future<void> play(int id);
  Future<void> pause(int id);
  Future<void> seek(int id, int ms);
  Future<void> volume(int id, double volume);
  Future<EngineStatus> status(int id);
  Future<void> setChain(Map<String, Object?> chain);
  Future<bool> overlayInit();
  Future<void> overlayUpdate(Map<String, Object?> m);
  Future<List<String>> overlayPoll();
}

class MethodChannelDesktopEngine implements DesktopEngineBridge {
  static const _ch = MethodChannel('byte/desktop_audio');

  Future<T?> _call<T>(String m, [Map<String, Object?>? args]) async {
    try {
      return await _ch.invokeMethod<T>(m, args);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<int> create() async => ((await _call<Map>('engine.create'))?['id'] as num?)?.toInt() ?? 0;
  @override
  Future<void> dispose(int id) => _call<void>('engine.dispose', {'id': id});
  @override
  Future<void> open(int id, String source, int startMs) => _call<void>('engine.open', {'id': id, 'source': source, 'startMs': startMs});
  @override
  Future<void> play(int id) => _call<void>('engine.play', {'id': id});
  @override
  Future<void> pause(int id) => _call<void>('engine.pause', {'id': id});
  @override
  Future<void> seek(int id, int ms) => _call<void>('engine.seek', {'id': id, 'ms': ms});
  @override
  Future<void> volume(int id, double volume) => _call<void>('engine.volume', {'id': id, 'volume': volume});
  @override
  Future<EngineStatus> status(int id) async {
    final m = await _call<Map>('engine.status', {'id': id});
    return m == null ? const EngineStatus(state: 'error', posMs: 0, durMs: null, playing: false, error: 'no engine', queuedMs: 0) : EngineStatus.fromMap(m);
  }

  @override
  Future<void> setChain(Map<String, Object?> chain) => _call<void>('dsp.set', chain);
  @override
  Future<bool> overlayInit() async => (await _call<bool>('smtc.init')) ?? false;
  @override
  Future<void> overlayUpdate(Map<String, Object?> m) => _call<void>('smtc.update', m);
  @override
  Future<List<String>> overlayPoll() async => ((await _call<List>('smtc.poll')) ?? const []).cast<String>();
}

/// Whether the sound engine is the one in use on this computer.
bool get desktopEngineSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

/// The Audio Lab's sound on a computer, as the engine takes it. Biquad sections
/// come from the same design the on-screen curve uses ([EqMath.sectionCoefficients]).
Map<String, Object?> encodeDesktopChain(AudioLab lab) {
  final c = lab.nativeConfig();
  double d(String k) => (c[k] as num).toDouble();
  final eq = <List<double>>[];
  if (lab.anyEq) {
    for (final n in lab.activeNodes) {
      final k = EqMath.sectionCoefficients(n);
      if (k != null) eq.add(k);
    }
  }
  final xfOn = c['crossfeed'] == true && lab.crossfeedAmount > 0;
  return {
    'inputGainDb': d('inputGain'),
    'eqOn': eq.isNotEmpty,
    'eq': eq,
    'reverbOn': c['rvOn'] == true,
    'rvWet': (lab.rv('mix') * lab.rv('wet')).clamp(0.0, 1.0),
    'rvDry': d('rvDry').clamp(0.05, 1.0),
    'rvSize': d('rvSize').clamp(0.0, 1.0),
    'rvDamping': d('rvDamping').clamp(0.0, 1.0),
    'rvWidth': d('rvWidth').clamp(0.0, 1.0),
    'rvPreDelayMs': d('rvPreDelay').clamp(0.0, 100.0),
    'crossfeedOn': xfOn,
    'xfStrength': xfOn ? (lab.crossfeedAmount * (0.15 + (lab.crossfeedDb + 15) / 14 * 0.6)).clamp(0.05, 1.0) : 0.0,
    'xfHz': lab.crossfeedHz,
    'mono': c['mono'] == true,
    'balance': d('balance').clamp(-1.0, 1.0),
    'compressorOn': c['mbcOn'] == true,
    'thresholdDb': d('threshold'),
    'ratio': d('ratio').clamp(1.0, 20.0),
    'limiterOn': c['limiterOn'] == true,
    'limit': 0.89,
  };
}

/// True when any effect of the Audio Lab changes the sound.
bool desktopEffectsOn(AudioLab lab) {
  final c = lab.nativeConfig();
  return c['eqOn'] == true || c['rvOn'] == true || c['mbcOn'] == true || c['limiterOn'] == true || c['mono'] == true || (c['crossfeed'] == true && lab.crossfeedAmount > 0) || (c['balance'] as num).abs() > 0.009;
}

/// One press of a media button can reach the app twice: as a key and through
/// the system overlay. Whichever comes first acts; the other is dropped for
/// half a second.
class MediaButtons {
  MediaButtons._();
  static const window = Duration(milliseconds: 500);
  static DateTime? _keyAt, _overlayAt;

  /// Called by the keyboard path before it acts. False = the overlay just did it.
  static bool takeKey([DateTime? now]) => _take(now ?? DateTime.now(), isKey: true);

  /// Called by the overlay path before it acts. False = the key just did it.
  static bool takeOverlay([DateTime? now]) => _take(now ?? DateTime.now(), isKey: false);

  static bool _take(DateTime now, {required bool isKey}) {
    final other = isKey ? _overlayAt : _keyAt;
    if (other != null && now.difference(other) < window) return false;
    if (isKey) {
      _keyAt = now;
    } else {
      _overlayAt = now;
    }
    return true;
  }

  static void reset() {
    _keyAt = null;
    _overlayAt = null;
  }
}

/// Shared state for every player on this computer.
class DesktopSound {
  DesktopSound._();
  static DesktopEngineBridge bridge = MethodChannelDesktopEngine();

  /// Audio Lab effects are on right now: songs that can take them go to the engine.
  static bool effectsOn = false;

  /// The last chain sent to the engine.
  static Map<String, Object?>? chain;

  static final Set<SwitchPlayer> players = {};

  /// Sets the effects and the chain; players already playing move paths.
  static Future<void> setEffects(AudioLab lab) async {
    final on = desktopEffectsOn(lab);
    final next = encodeDesktopChain(lab);
    // Compared by value: the equalizer sections are nested lists.
    final changedChain = chain == null || jsonEncode(chain) != jsonEncode(next);
    chain = next;
    if (changedChain) await bridge.setChain(next);
    if (on != effectsOn) {
      effectsOn = on;
      for (final p in players.toList()) {
        await p.reroute();
      }
    }
  }
}

/// The platform player for one Byte deck: the normal player or the engine,
/// chosen at each load, with the same calls and events for both.
class SwitchPlayer extends AudioPlayerPlatform {
  SwitchPlayer(super.id, this.inner) {
    DesktopSound.players.add(this);
    _innerEvents = inner.playbackEventMessageStream.listen((m) {
      if (!_onEngine) {
        _lastPos = m.updatePosition;
        _dur = m.duration ?? _dur;
        _events.add(m);
      }
    }, onError: (Object e, StackTrace st) {});
    _innerData = inner.playerDataMessageStream.listen((m) {
      if (!_onEngine) _data.add(m);
    }, onError: (Object e, StackTrace st) {});
  }

  final AudioPlayerPlatform inner;
  final StreamController<PlaybackEventMessage> _events = StreamController.broadcast();
  final StreamController<PlayerDataMessage> _data = StreamController.broadcast();
  StreamSubscription? _innerEvents, _innerData;

  int? _engineId;
  Timer? _pump;
  bool _onEngine = false;
  bool _playing = false;
  double _speed = 1, _pitch = 1;
  LoadRequest? _lastReq;
  Duration _lastPos = Duration.zero;
  Duration? _dur;
  int _gen = 0;
  bool _disposed = false;
  String? _lastState;

  /// True while this deck's sound comes from the engine.
  bool get onEngine => _onEngine;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  bool _wants(LoadRequest req) {
    if (!DesktopSound.effectsOn || !desktopEngineSupported) return false;
    if (_speed != 1 || _pitch != 1) return false;
    final src = req.audioSourceMessage;
    if (src is! UriAudioSourceMessage) return false;
    final u = src.uri;
    return u.startsWith('http://') || u.startsWith('https://') || u.startsWith('file:');
  }

  String _enginePath(String uri) {
    if (uri.startsWith('file:')) {
      try {
        return Uri.parse(uri).toFilePath(windows: true);
      } catch (_) {
        return uri;
      }
    }
    return uri;
  }

  Future<void> _ensureEngine() async {
    _engineId ??= await DesktopSound.bridge.create();
    if (DesktopSound.chain != null) await DesktopSound.bridge.setChain(DesktopSound.chain!);
  }

  void _emitState(ProcessingStateMessage s, {String? error}) {
    final key = '$s:${error ?? ''}';
    if (_lastState == key) return;
    _lastState = key;
    _events.add(PlaybackEventMessage(
      processingState: s,
      updateTime: DateTime.now(),
      updatePosition: _lastPos,
      bufferedPosition: _lastPos,
      duration: _dur,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
      errorCode: error == null ? null : 1,
      errorMessage: error,
    ));
  }

  void _startPump() {
    _pump ??= Timer.periodic(const Duration(milliseconds: 200), (_) => unawaited(_tick()));
  }

  void _stopPump() {
    _pump?.cancel();
    _pump = null;
  }

  Future<void> _tick() async {
    final id = _engineId;
    if (!_onEngine || id == null || _disposed) return;
    final st = await DesktopSound.bridge.status(id);
    if (!_onEngine) return;
    _lastPos = Duration(milliseconds: st.posMs);
    _dur = st.durMs == null || st.durMs! < 0 ? _dur : Duration(milliseconds: st.durMs!);
    if (st.error.isNotEmpty && st.state == 'error') {
      _emitState(ProcessingStateMessage.idle, error: st.error);
      return;
    }
    if (st.playing != _playing) {
      _playing = st.playing;
      _data.add(PlayerDataMessage(playing: _playing));
    }
    final ps = switch (st.state) {
      'loading' => ProcessingStateMessage.loading,
      'completed' => ProcessingStateMessage.completed,
      _ => ProcessingStateMessage.ready,
    };
    if (st.state == 'completed') _stopPump();
    _events.add(PlaybackEventMessage(
      processingState: ps,
      updateTime: DateTime.now(),
      updatePosition: _lastPos,
      bufferedPosition: _lastPos + Duration(milliseconds: st.queuedMs),
      duration: _dur,
      icyMetadata: null,
      currentIndex: 0,
      androidAudioSessionId: null,
    ));
  }

  /// Moves the deck to the other path at the same spot, keeping play / pause.
  Future<void> reroute() async {
    final req = _lastReq;
    if (req == null || _disposed) return;
    final wantEngine = _wants(req);
    if (wantEngine == _onEngine) return;
    final pos = _lastPos;
    final wasPlaying = _playing;
    final gen = ++_gen;
    if (wantEngine) {
      await _toEngine(req, pos, wasPlaying);
    } else {
      await _toInner(req, pos, wasPlaying);
    }
    if (gen != _gen) return;
  }

  Future<void> _toEngine(LoadRequest req, Duration pos, bool play) async {
    final uri = (req.audioSourceMessage as UriAudioSourceMessage).uri;
    try {
      await inner.pause(PauseRequest());
    } catch (_) {}
    _onEngine = true;
    _lastPos = pos;
    await _ensureEngine();
    final id = _engineId!;
    await DesktopSound.bridge.open(id, _enginePath(uri), pos.inMilliseconds);
    _startPump();
    _emitState(ProcessingStateMessage.loading);
    final st = await _waitReady(id);
    if (st == null || st.state == 'error') {
      _onEngine = false;
      _emitState(ProcessingStateMessage.idle, error: st?.error ?? 'the sound engine did not open the song');
      return;
    }
    _dur = st.durMs == null || st.durMs! < 0 ? _dur : Duration(milliseconds: st.durMs!);
    _emitState(ProcessingStateMessage.ready);
    if (play) {
      await DesktopSound.bridge.play(id);
      _playing = true;
      _data.add(PlayerDataMessage(playing: true));
    }
  }

  Future<EngineStatus?> _waitReady(int id) async {
    for (var i = 0; i < 300; i++) {
      if (_disposed || !_onEngine) return null;
      final st = await DesktopSound.bridge.status(id);
      if (st.state == 'ready' || st.state == 'completed' || st.state == 'error') return st;
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
    return null;
  }

  Future<void> _toInner(LoadRequest req, Duration pos, bool play) async {
    if (_onEngine) {
      final id = _engineId;
      if (id != null) await DesktopSound.bridge.pause(id);
      _stopPump();
    }
    _onEngine = false;
    _playing = false;
    await inner.load(LoadRequest(audioSourceMessage: req.audioSourceMessage, initialPosition: pos, initialIndex: null));
    if (play) await inner.play(PlayRequest());
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final gen = ++_gen;
    _lastReq = request;
    _lastPos = request.initialPosition ?? Duration.zero;
    if (_onEngine) {
      final id = _engineId;
      if (id != null) await DesktopSound.bridge.pause(id);
      _stopPump();
    }
    if (!_wants(request)) {
      _onEngine = false;
      _playing = false;
      final r = await inner.load(request);
      return r;
    }
    _playing = false;
    await _toEngine(request, request.initialPosition ?? Duration.zero, false);
    if (gen != _gen) return LoadResponse(duration: _dur);
    return LoadResponse(duration: _dur);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    if (!_onEngine) {
      _playing = true;
      return inner.play(request);
    }
    final id = _engineId;
    if (id == null) return PlayResponse();
    await DesktopSound.bridge.play(id);
    _playing = true;
    _data.add(PlayerDataMessage(playing: true));
    _startPump();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    if (!_onEngine) {
      _playing = false;
      return inner.pause(request);
    }
    final id = _engineId;
    if (id != null) await DesktopSound.bridge.pause(id);
    _playing = false;
    _data.add(PlayerDataMessage(playing: false));
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    if (!_onEngine) return inner.seek(request);
    final id = _engineId;
    final p = request.position ?? Duration.zero;
    _lastPos = p;
    if (id != null) {
      await DesktopSound.bridge.seek(id, p.inMilliseconds);
      _startPump();
    }
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    if (_onEngine && _engineId != null) await DesktopSound.bridge.volume(_engineId!, request.volume);
    return inner.setVolume(request);
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    _speed = request.speed;
    final r = await inner.setSpeed(request);
    if (_onEngine && _speed != 1) await reroute();
    return r;
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    _pitch = request.pitch;
    final r = await inner.setPitch(request);
    if (_onEngine && _pitch != 1) await reroute();
    return r;
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) => inner.setSkipSilence(request);

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) => inner.setLoopMode(request);

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) => inner.setShuffleMode(request);

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) => inner.setShuffleOrder(request);

  // Settings the engine does not use go to the normal player unchanged.
  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(SetAutomaticallyWaitsToMinimizeStallingRequest request) => inner.setAutomaticallyWaitsToMinimizeStalling(request);

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse> setCanUseNetworkResourcesForLiveStreamingWhilePaused(SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request) => inner.setCanUseNetworkResourcesForLiveStreamingWhilePaused(request);

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(SetPreferredPeakBitRateRequest request) => inner.setPreferredPeakBitRate(request);

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(SetAllowsExternalPlaybackRequest request) => inner.setAllowsExternalPlayback(request);

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest request) => inner.setAndroidAudioAttributes(request);

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest request) => inner.concatenatingInsertAll(request);

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest request) => inner.concatenatingRemoveRange(request);

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest request) => inner.concatenatingMove(request);

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(AudioEffectSetEnabledRequest request) => inner.audioEffectSetEnabled(request);

  @override
  Future<SetWebCrossOriginResponse> setWebCrossOrigin(SetWebCrossOriginRequest request) => inner.setWebCrossOrigin(request);

  @override
  Future<SetWebSinkIdResponse> setWebSinkId(SetWebSinkIdRequest request) => inner.setWebSinkId(request);

  /// Lets go of the engine for this deck (the platform player is being disposed).
  Future<void> releaseEngine() async {
    _disposed = true;
    _stopPump();
    DesktopSound.players.remove(this);
    final id = _engineId;
    _engineId = null;
    if (id != null) {
      try {
        await DesktopSound.bridge.pause(id);
        await DesktopSound.bridge.dispose(id);
      } catch (_) {}
    }
    await _innerEvents?.cancel();
    await _innerData?.cancel();
    unawaited(_events.close());
    unawaited(_data.close());
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await releaseEngine();
    return inner.dispose(request);
  }
}

/// Puts [SwitchPlayer] in front of the system player on Windows.
class ByteSwitchPlatform extends JustAudioPlatform {
  ByteSwitchPlatform(this.inner);
  final JustAudioPlatform inner;
  final Map<String, SwitchPlayer> _players = {};

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = await inner.init(request);
    final s = SwitchPlayer(request.id, p);
    _players[request.id] = s;
    return s;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    await _players.remove(request.id)?.releaseEngine();
    return inner.disposePlayer(request);
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async {
    for (final p in _players.values.toList()) {
      await p.releaseEngine();
    }
    _players.clear();
    return inner.disposeAllPlayers(request);
  }
}

/// The Audio Lab's sound backend on Windows: the caps the engine has, and
/// every change pushed to it.
class WindowsSoundBackend extends SoundBackend {
  WindowsSoundBackend();

  @override
  SoundCaps get caps => SoundCaps.computer;

  @override
  Future<void> apply(AudioLab lab, Map<String, Object?> config) async {
    if (!desktopEngineSupported) return;
    await DesktopSound.setEffects(lab);
  }
}

/// The Windows media overlay: shows what is playing and sends its buttons back.
class DesktopMediaOverlay {
  DesktopMediaOverlay({required this.play, required this.pause, required this.next, required this.previous, required this.stop, required this.snapshot, DesktopEngineBridge? bridge})
      : _bridge = bridge ?? MethodChannelDesktopEngine();

  final Future<void> Function() play, pause, next, previous, stop;
  final ({String title, String artist, String album, String art, bool hasItem, bool playing, int posMs, int durMs}) Function() snapshot;
  final DesktopEngineBridge _bridge;
  Timer? _timer;
  bool _ready = false;
  String _last = '';

  Future<void> start() async {
    _ready = await _bridge.overlayInit();
    if (!_ready) return;
    _timer = Timer.periodic(const Duration(milliseconds: 300), (_) => unawaited(_tick()));
  }

  void stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    if (!_ready) return;
    for (final name in await _bridge.overlayPoll()) {
      if (!MediaButtons.takeOverlay()) continue;
      switch (name) {
        case 'play':
          await play();
        case 'pause':
          await pause();
        case 'next':
          await next();
        case 'previous':
          await previous();
        case 'stop':
          await stop();
      }
    }
    final s = snapshot();
    final key = '${s.title}|${s.artist}|${s.album}|${s.art}|${s.hasItem}|${s.playing}|${s.durMs}';
    final second = s.posMs ~/ 1000;
    if (key != _last || second != _lastSecond) {
      _last = key;
      _lastSecond = second;
      await _bridge.overlayUpdate({
        'title': s.title,
        'artist': s.artist,
        'album': s.album,
        'art': s.art,
        'hasItem': s.hasItem,
        'playing': s.playing,
        'posMs': s.posMs,
        'durMs': s.durMs,
      });
    }
  }

  int _lastSecond = -1;
}
