// © 2026 Apurba Laskar
//
// Byte on Windows and Linux: the just_audio player, played by media_kit.
// macOS, iPhone, Android and the web keep their own just_audio backends; this
// file is only registered on Windows and Linux (see [ByteDesktopAudio.register]).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:media_kit/media_kit.dart' as mk;

/// The Windows/Linux backend for just_audio.
class ByteDesktopAudio extends JustAudioPlatform {
  ByteDesktopAudio._();

  static bool _registered = false;

  /// Whether the native player library loaded (false: songs can't play,
  /// everything else still works).
  static bool available = false;

  /// Installs the backend on Windows and Linux; does nothing elsewhere.
  static void register() {
    if (_registered || kIsWeb) return;
    if (!(Platform.isWindows || Platform.isLinux)) return;
    _registered = true;
    try {
      mk.MediaKit.ensureInitialized();
      available = true;
    } catch (e) {
      debugPrint('desktop audio: $e');
    }
    JustAudioPlatform.instance = ByteDesktopAudio._();
  }

  /// Flutter's own plugin registration (Windows/Linux).
  static void registerWith() => register();

  // ── 1.4.5: the Audio Lab on a computer ──
  /// The filter chain every song runs through (the app builds it from the
  /// Audio Lab: equalizer, balance, mono, loudness, reverb, crossfeed).
  /// '' = untouched sound.
  static String effects = '';
  static final Set<_DesktopPlayer> _live = {};

  /// The filters the first live player really runs, as the player reports
  /// them (live tests).
  @visibleForTesting
  static Future<String?> debugAf() async {
    final p = _live.isEmpty ? null : _live.first._p;
    if (p == null) return null;
    return (p.platform as dynamic).getProperty('af') as Future<String>;
  }

  /// Use [chain] on every player now and on each new one.
  static Future<void> setEffects(String chain) async {
    if (chain == effects) return;
    effects = chain;
    for (final p in _live.toList()) {
      await p._applyAf(force: true);
    }
  }

  final Map<String, _DesktopPlayer> _players = {};

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    if (_players.containsKey(request.id)) {
      throw PlatformException(code: 'error', message: 'Platform player ${request.id} already exists');
    }
    final p = _DesktopPlayer(request.id);
    _players[request.id] = p;
    return p;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    await _players.remove(request.id)?.release();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async {
    for (final p in _players.values.toList()) {
      await p.release();
    }
    _players.clear();
    return DisposeAllPlayersResponse();
  }
}

class _Src {
  final String uri;
  final Map<String, String>? headers;
  _Src(this.uri, this.headers);
}

/// Flattens a just_audio source tree into the playable list.
List<_Src> flattenSources(AudioSourceMessage m) {
  if (m is ConcatenatingAudioSourceMessage) {
    return [for (final c in m.children) ...flattenSources(c)];
  }
  if (m is ClippingAudioSourceMessage) return flattenSources(m.child);
  if (m is LoopingAudioSourceMessage) {
    final one = flattenSources(m.child);
    return [for (var i = 0; i < m.count; i++) ...one];
  }
  if (m is UriAudioSourceMessage) {
    var uri = m.uri;
    // libmpv reads plain paths most reliably.
    if (uri.startsWith('file://')) uri = Uri.parse(uri).toFilePath();
    return [_Src(uri, m.headers)];
  }
  if (m is SilenceAudioSourceMessage) {
    return [_Src('av://lavfi:anullsrc=d=${m.duration.inMilliseconds / 1000}', null)];
  }
  return const [];
}

class _DesktopPlayer extends AudioPlayerPlatform {
  _DesktopPlayer(super.id) {
    if (ByteDesktopAudio.available) {
      _p = mk.Player(configuration: const mk.PlayerConfiguration(title: 'Byte', pitch: true, logLevel: mk.MPVLogLevel.error));
      // Tests on machines without a sound card: BYTE_MPV_AO=null.
      final ao = Platform.environment['BYTE_MPV_AO'];
      if (ao != null && ao.isNotEmpty) unawaited((_p!.platform as dynamic).setProperty('ao', ao) as Future<void>);
      ByteDesktopAudio._live.add(this);
      unawaited(_applyAf());
      final s = _p!.stream;
      _subs.addAll([
        s.playing.listen((_) {
          // Paused / about to start: the song stands still, so its position
          // is true as of now (a stale time here would make players
          // extrapolate the pause into the song).
          _positionAt = DateTime.now();
          _emit();
        }),
        s.duration.listen((d) {
          _duration = d > Duration.zero ? d : null;
          if (_duration != null && !_ready.isCompleted) _ready.complete();
          if (_state == ProcessingStateMessage.loading && _duration != null) _state = ProcessingStateMessage.ready;
          _emit();
        }),
        s.buffering.listen((b) {
          if (_state == ProcessingStateMessage.idle || _state == ProcessingStateMessage.completed) return;
          if (_duration == null && !b) return;
          _state = b ? ProcessingStateMessage.buffering : ProcessingStateMessage.ready;
          _emit();
        }),
        s.buffer.listen((b) {
          _buffered = b;
          _emitThrottled();
        }),
        s.position.listen((pos) {
          _position = pos;
          _positionAt = DateTime.now();
          _emitThrottled();
        }),
        s.completed.listen((done) {
          if (!done) return;
          if (_index < _count - 1 && _loop != LoopModeMessage.one) return; // the playlist moves on by itself
          _state = ProcessingStateMessage.completed;
          _emit();
        }),
        s.playlist.listen((pl) {
          if (pl.index != _index) {
            _index = pl.index;
            _emit();
          }
        }),
        s.error.listen((e) {
          if (!_ready.isCompleted) {
            _ready.completeError(PlatformException(code: 'load', message: e));
          } else {
            _errors.add(PlaybackEventMessage(
              processingState: _state,
              updateTime: DateTime.now(),
              updatePosition: _position,
              bufferedPosition: _buffered,
              duration: _duration,
              icyMetadata: null,
              currentIndex: _index,
              androidAudioSessionId: null,
              errorCode: 1,
              errorMessage: e,
            ));
          }
        }),
      ]);
    }
  }

  mk.Player? _p;
  final List<StreamSubscription<dynamic>> _subs = [];
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _data = StreamController<PlayerDataMessage>.broadcast();
  final _errors = StreamController<PlaybackEventMessage>.broadcast();
  late final Stream<PlaybackEventMessage> _merged = _mergedEvents();

  ProcessingStateMessage _state = ProcessingStateMessage.idle;
  Duration _position = Duration.zero;
  /// When [_position] was read: an event's updateTime, so a listener that
  /// extrapolates (position + time since) never runs ahead of the real song.
  DateTime _positionAt = DateTime.now();
  Duration _buffered = Duration.zero;
  Duration? _duration;
  int _index = 0;
  int _count = 0;
  LoopModeMessage _loop = LoopModeMessage.off;
  Completer<void> _ready = Completer<void>();
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);

  Stream<PlaybackEventMessage> _mergedEvents() {
    late StreamController<PlaybackEventMessage> c;
    StreamSubscription<PlaybackEventMessage>? a, b;
    c = StreamController<PlaybackEventMessage>.broadcast(
      onListen: () {
        a = _events.stream.listen(c.add);
        b = _errors.stream.listen((e) => c.addError(PlatformException(code: '${e.errorCode}', message: e.errorMessage)));
      },
      onCancel: () {
        a?.cancel();
        b?.cancel();
      },
    );
    return c.stream;
  }

  PlaybackEventMessage _event() => PlaybackEventMessage(
        processingState: _state,
        updateTime: _positionAt,
        updatePosition: _position,
        bufferedPosition: _buffered,
        duration: _duration,
        icyMetadata: null,
        currentIndex: _index,
        androidAudioSessionId: null,
      );

  void _emit() {
    if (_events.isClosed) return;
    _lastEmit = DateTime.now();
    _events.add(_event());
  }

  void _emitThrottled() {
    if (DateTime.now().difference(_lastEmit) >= const Duration(milliseconds: 500)) _emit();
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _merged;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  PlatformException _unavailable() => PlatformException(
        code: 'unavailable',
        message: Platform.isLinux
            ? 'The audio player library (libmpv) is missing. Install it with: sudo apt install libmpv2'
            : 'The audio player could not start on this computer.',
      );

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    final p = _p;
    if (p == null) throw _unavailable();
    final srcs = flattenSources(request.audioSourceMessage);
    if (srcs.isEmpty) throw PlatformException(code: 'load', message: 'Nothing to play');
    _count = srcs.length;
    _index = (request.initialIndex ?? 0).clamp(0, srcs.length - 1);
    _duration = null;
    _position = request.initialPosition ?? Duration.zero;
    _positionAt = DateTime.now();
    _buffered = Duration.zero;
    _state = ProcessingStateMessage.loading;
    _ready = Completer<void>();
    _emit();
    final start = request.initialPosition;
    final medias = <mk.Media>[
      for (var i = 0; i < srcs.length; i++)
        mk.Media(srcs[i].uri, httpHeaders: srcs[i].headers, start: i == _index && start != null && start > Duration.zero ? start : null),
    ];
    await p.open(mk.Playlist(medias, index: _index), play: false);
    try {
      await _ready.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      // A live stream with no length: carry on with an unknown duration.
    }
    _state = ProcessingStateMessage.ready;
    _emit();
    return LoadResponse(duration: _duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    final p = _p;
    if (p == null) throw _unavailable();
    if (_state == ProcessingStateMessage.completed) {
      _state = ProcessingStateMessage.ready;
    }
    await p.play();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    await _p?.pause();
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    await _p?.setVolume((request.volume * 100).clamp(0, 100).toDouble());
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    if (request.speed > 0) {
      await _p?.setRate(request.speed);
      _tempo = true;
      await _applyAf(force: true); // the player rewrote its filters
    }
    return SetSpeedResponse();
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async {
    if (request.pitch > 0) {
      try {
        await _p?.setPitch(request.pitch);
        _tempo = true;
        await _applyAf(force: true);
      } catch (_) {}
    }
    return SetPitchResponse();
  }

  /// Speed / pitch were set (the player then keeps its own tempo filter).
  bool _tempo = false;
  String? _af;

  /// This player's filters: its tempo filter (speed / pitch), then the
  /// Audio Lab chain. A chain the player refuses leaves the old one playing.
  Future<void> _applyAf({bool force = false}) async {
    final p = _p;
    if (p == null) return;
    final st = p.state;
    final fx = ByteDesktopAudio.effects;
    final af = [
      if (_tempo) 'scaletempo:scale=${(st.rate / (st.pitch <= 0 ? 1 : st.pitch)).toStringAsFixed(8)}',
      if (fx.isNotEmpty) 'lavfi=[$fx]',
    ].join(',');
    if (!force && af == _af) return;
    if (af.isEmpty && _af == null) return; // nothing set yet, nothing to clear
    _af = af;
    try {
      await (p.platform as dynamic).setProperty('af', af);
    } catch (e) {
      debugPrint('desktop audio filters: $e');
    }
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async => SetSkipSilenceResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    _loop = request.loopMode;
    await _p?.setPlaylistMode(switch (request.loopMode) {
      LoopModeMessage.off => mk.PlaylistMode.none,
      LoopModeMessage.one => mk.PlaylistMode.single,
      LoopModeMessage.all => mk.PlaylistMode.loop,
    });
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async {
    await _p?.setShuffle(request.shuffleMode == ShuffleModeMessage.all);
    return SetShuffleModeResponse();
  }

  @override
  Future<SetShuffleOrderResponse> setShuffleOrder(SetShuffleOrderRequest request) async => SetShuffleOrderResponse();

  @override
  Future<SetAutomaticallyWaitsToMinimizeStallingResponse> setAutomaticallyWaitsToMinimizeStalling(
          SetAutomaticallyWaitsToMinimizeStallingRequest request) async =>
      SetAutomaticallyWaitsToMinimizeStallingResponse();

  @override
  Future<SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse> setCanUseNetworkResourcesForLiveStreamingWhilePaused(
          SetCanUseNetworkResourcesForLiveStreamingWhilePausedRequest request) async =>
      SetCanUseNetworkResourcesForLiveStreamingWhilePausedResponse();

  @override
  Future<SetPreferredPeakBitRateResponse> setPreferredPeakBitRate(SetPreferredPeakBitRateRequest request) async =>
      SetPreferredPeakBitRateResponse();

  @override
  Future<SetAllowsExternalPlaybackResponse> setAllowsExternalPlayback(SetAllowsExternalPlaybackRequest request) async =>
      SetAllowsExternalPlaybackResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    final p = _p;
    if (p == null) return SeekResponse();
    if (request.index != null && request.index != _index && request.index! >= 0 && request.index! < _count) {
      await p.jump(request.index!);
      _index = request.index!;
    }
    final pos = request.position ?? Duration.zero;
    await p.seek(pos);
    _position = pos;
    _positionAt = DateTime.now();
    if (_state == ProcessingStateMessage.completed) _state = ProcessingStateMessage.ready;
    _emit();
    return SeekResponse();
  }

  @override
  Future<SetAndroidAudioAttributesResponse> setAndroidAudioAttributes(SetAndroidAudioAttributesRequest request) async =>
      SetAndroidAudioAttributesResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    await release();
    return DisposeResponse();
  }

  Future<void> release() async {
    ByteDesktopAudio._live.remove(this);
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final p = _p;
    _p = null;
    await p?.dispose();
    _state = ProcessingStateMessage.idle;
    if (!_events.isClosed) {
      _emit();
      await _events.close();
    }
    if (!_data.isClosed) await _data.close();
    if (!_errors.isClosed) await _errors.close();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(ConcatenatingInsertAllRequest request) async {
    final p = _p;
    if (p != null) {
      for (final c in request.children) {
        for (final s in flattenSources(c)) {
          await p.add(mk.Media(s.uri, httpHeaders: s.headers));
          _count++;
        }
      }
    }
    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(ConcatenatingRemoveRangeRequest request) async {
    final p = _p;
    if (p != null) {
      for (var i = request.endIndex - 1; i >= request.startIndex; i--) {
        await p.remove(i);
        _count--;
      }
    }
    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(ConcatenatingMoveRequest request) async {
    await _p?.move(request.currentIndex, request.newIndex);
    return ConcatenatingMoveResponse();
  }

  @override
  Future<AudioEffectSetEnabledResponse> audioEffectSetEnabled(AudioEffectSetEnabledRequest request) async =>
      AudioEffectSetEnabledResponse();
}
