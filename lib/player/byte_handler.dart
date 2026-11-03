import 'dart:async';
import 'dart:math';
import 'dart:io' show File, Platform;

import 'package:audio_service/audio_service.dart';
import 'resume_point.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../automix/automix_service.dart';
import '../automix/order.dart';
import '../automix/planner.dart';
import '../core/cover_cache.dart';
import '../core/innertube.dart';
import '../core/lock_art.dart';
import '../core/models.dart';
import '../data/webdav.dart';
import '../core/streams.dart';
import '../data/library.dart';
import '../data/settings.dart';
import 'equalizer.dart';
import 'chunked_source.dart';
import 'crossfade.dart';
import 'queue.dart' as q;
import '../data/audio_format.dart';

enum SleepMode { off, timer, endOfTrack }

/// A smooth clock for the UI (lyrics, progress bar): interpolates between
/// player position updates so animations run at full frame rate.
class PositionClock {
  int _baseMs = 0;
  int _baseAt = 0;
  bool playing = false;
  double speed = 1;
  void set(int posMs, {bool? playing, double? speed}) {
    _baseMs = posMs;
    _baseAt = DateTime.now().millisecondsSinceEpoch;
    if (playing != null) this.playing = playing;
    if (speed != null) this.speed = speed;
  }

  int get nowMs {
    if (!playing) return _baseMs;
    return _baseMs + ((DateTime.now().millisecondsSinceEpoch - _baseAt) * speed).round();
  }
}

/// The media notification and lock-screen player (Android). The art is
/// never scaled down here: the lock screen card gets the full square file.
/// The notification itself is public on the lock screen (audio_service sets
/// VISIBILITY_PUBLIC; MainActivity makes the channel public too), and a tap
/// opens Byte on the Now Playing screen (see the shell).
const byteAudioConfig = AudioServiceConfig(
  androidNotificationChannelId: 'com.apurbalaskar.byte.playback',
  androidNotificationChannelName: 'Music playback',
  androidNotificationChannelDescription: 'The song playing, with its controls, on the lock screen and in notifications',
  androidNotificationIcon: 'drawable/ic_stat_byte',
  // 1.4.5 (Apurba: "song off ho phir bhi lock screen mein show karna chahiye"):
  // paused = the notification stays with its play button and can be swiped
  // away; the service itself stays in the foreground for 10 min after a pause
  // (packages/audio_service/BYTE_CHANGES.md) so Android doesn't close Byte.
  androidNotificationOngoing: false,
  androidStopForegroundOnPause: true,
  androidNotificationClickStartsActivity: true,
  androidShowNotificationBadge: false,
  artDownscaleWidth: null,
  artDownscaleHeight: null,
  preloadArtwork: false,
);

/// What the lock screen / notification may ask for besides its buttons:
/// [MediaAction.seek] makes the lock-screen seek bar draggable.
const lockScreenActions = {MediaAction.seek, MediaAction.seekForward, MediaAction.seekBackward, MediaAction.skipToQueueItem, MediaAction.playPause};

MediaItem mediaItemFor(Item it) => MediaItem(
  id: it.id,
  title: it.title,
  artist: it.artistLine.isEmpty ? null : it.artistLine,
  album: it.album,
  duration: it.durationSec == null ? null : Duration(seconds: it.durationSec!),
  artUri: _artUri(it),
  extras: {'item': it.encode()},
);

/// The lock screen / notification / car picture: a square file on the
/// phone (≥720 px, see [LockArt]) once it's made; until then the big web
/// picture (1080 px), so the card is never empty while it downloads.
Uri? _artUri(Item it) {
  final f = LockArt.existing(it);
  if (f != null) return Uri.file(f.path);
  final t = it.thumbAt(1080);
  if (t == null || t.isEmpty) return null;
  if (t.startsWith('/')) return Uri.file(t);
  return Uri.tryParse(t);
}

/// Makes the square lock-screen picture for [it] (any song: web cover,
/// YouTube frame or a song on the phone).
Future<File?> squareArtFor(Item it) => LockArt.make(it);

/// Byte's player: two decks (for real crossfade and gapless hand-off),
/// the queue, background media session, sleep timer and speed.
/// Another device playing Byte's queue (a Cast speaker or TV).
abstract class RemoteOutput {
  String get remoteName;
  bool get remotePlaying;
  int get positionMs;
  Duration? get remoteDuration;
  Future<void> load(Item it, {Duration? startAt});
  Future<void> remotePlay();
  Future<void> remotePause();
  Future<void> remoteSeek(Duration d);
  Future<void> remoteVolume(double v);
}

class ByteAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final StreamResolver resolver;
  final InnerTube yt;
  final Library library;
  final Settings settings;
  final q.PlayQueue queueModel = q.PlayQueue();
  final PositionClock clock = PositionClock();

  final ValueNotifier<Item?> current = ValueNotifier(null);
  final ValueNotifier<String?> error = ValueNotifier(null);
  final ValueNotifier<bool> loading = ValueNotifier(false);
  final ValueNotifier<int> queueVersion = ValueNotifier(0);

  /// Set while a Cast device plays the queue; the phone stays quiet.
  RemoteOutput? remote;
  Timer? _remoteTick;
  final ValueNotifier<AudioStream?> currentStream = ValueNotifier(null);
  final ValueNotifier<(SleepMode, DateTime?)> sleep = ValueNotifier((SleepMode.off, null));

  late AudioPlayer _cur;
  late AudioPlayer _idle;
  final List<StreamSubscription> _subs = [];
  Timer? _tick;
  Item? _preparedOnIdle;
  bool _fading = false;
  int _fadeStartAt = 0;
  int _fadeMs = 0;
  AudioPlayer? _fadingOut;
  double _outGain = 1;
  int _loadToken = 0;

  /// Songs played or suggested since Byte started (for "Don't repeat songs").
  final Set<String> sessionSeen = {};

  /// Changes every time a song starts (used to count plays).
  int get playToken => _loadToken;
  bool _extendingRadio = false;

  final ByteEqualizer? equalizer;

  /// Automix: fetches + analyses upcoming songs for DJ-style blends.
  final AutomixService? automix;

  /// Each deck's own Android equalizer (Automix bass swap).
  final Map<AudioPlayer, AndroidEqualizer> _deckEq = {};

  /// The file each deck is playing, when it's a file (iPhone bass swap key).
  final Map<AudioPlayer, String> _deckFile = {};

  ByteAudioHandler({
    required this.resolver,
    required this.yt,
    required this.library,
    required this.settings,
    AudioPlayer Function()? playerFactory,
    this.equalizer,
    this.automix,
  }) {
    final eq = equalizer;
    final make =
        playerFactory ??
        () {
          final deckEq = eq != null && !eq.ios && ByteEqualizer.android ? eq.create() : null;
          // No player-wide user agent: it would replace each stream's own
          // (just_audio puts the player's agent over the source's headers).
          final p = AudioPlayer(
            useProxyForRequestHeaders: false,
            audioPipeline: deckEq != null ? AudioPipeline(androidAudioEffects: [deckEq]) : null,
          );
          if (deckEq != null) _deckEq[p] = deckEq;
          return p;
        };
    _cur = make();
    _idle = make();
    for (final p in [_cur, _idle]) {
      _subs.add(p.playbackEventStream.listen((_) => _broadcast(p), onError: (Object e, StackTrace st) => _onPlayerError(p, e)));
      // just_audio 0.10 reports a stream that breaks mid-song here (not as a
      // stream error), so this is what catches a dropped connection.
      _subs.add(p.errorStream.listen((e) => _onPlayerError(p, e)));
      _subs.add(p.playerStateStream.listen((s) => _onPlayerState(p, s)));
    }
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => _onTick());
    queueModel.repeat = q.RepeatMode.values[(library.get('repeat') as int?) ?? 0];
    queueModel.setShuffle(library.get('shuffle') == true);
  }

  AudioPlayer get activePlayer => _cur;

  /// Both players (Audio Lab attaches its effects to each).
  List<AudioPlayer> get decks => [_cur, _idle];

  /// Audio Lab: fade length on pause / play / skip (0 = off).
  int Function() pauseFadeMs = () => 0;

  /// Audio Lab: true = play these two songs back to back with no blend
  /// ("Keep gapless albums intact").
  bool Function(Item a, Item b) keepTogether = (_, _) => false;

  double _pitch = 1;
  Future<void> setPitch(double pitch) async {
    _pitch = pitch.clamp(0.25, 4.0);
    for (final p in [_cur, _idle]) {
      try {
        await p.setPitch(_pitch);
      } catch (_) {}
    }
  }
  // During the pause between songs the next one waits at its start (the
  // deck may still hold the song that just ended).
  Duration get position => _restoredAt ?? (inGap && !_gapLoaded ? Duration.zero : _cur.position);
  Duration? get duration => remote?.remoteDuration ?? _cur.duration ?? (current.value?.durationSec == null ? null : Duration(seconds: current.value!.durationSec!));
  bool get playing => remote != null ? remote!.remotePlaying : (_cur.playing || inGap);

  /// Is sound actually coming out (false during the pause between songs)?
  /// Listen together follows this, so guests start with the host.
  bool get audible => remote != null ? remote!.remotePlaying : (_cur.playing && _cur.processingState != ProcessingState.completed);

  // ── 1.4.5: a short silence between songs ──────────────────────────────
  /// Apurba: "ek song khatam hone ke baad dusra song turant suru ho ja raha
  /// hai, thoda 2-3 sec baad next song play karna". When a song ends on its
  /// own and no blend is set (Crossfade 0, Automix off), the next one
  /// starts after this much silence. Next / Play / tapping a song skip it,
  /// Pause cancels it. 0 = the old instant hand-off.
  Duration autoAdvanceGap = const Duration(milliseconds: 2500);

  /// The timer the gap waits on (a fake clock in tests).
  Timer Function(Duration, void Function()) gapTimer = Timer.new;

  /// true while the next song waits out the gap (it already shows).
  final ValueNotifier<bool> waitingForNext = ValueNotifier(false);

  Timer? _gapT;
  int _gapToken = -1; // the play the gap belongs to
  bool _gapLoaded = false; // its song is loaded and only waits for the timer
  bool _gapHeld = false; // paused during the gap (or loaded paused): don't start

  // ── 1.4.5 party sync (listen_together.dart) ─────────────────────────
  /// When the waiting next song starts by itself (null: not waiting).
  DateTime? gapEndsAt;

  /// Listen together closes a small drift by playing this deck a touch
  /// faster or slower (0.98–1.02) for a moment; the person's speed setting
  /// is kept (it's multiplied, never saved).
  Future<void> setPartyRate(double r) async {
    if (remote != null || _fading || _ease != null) return; // a blend owns the speed
    try {
      await _cur.setSpeed(settings.speed * r.clamp(0.98, 1.02));
    } catch (_) {}
  }
  /// Counts real seeks (the person, the lock screen, the party). Listen
  /// together watches this instead of guessing seeks from position jumps:
  /// a backend whose position updates coarsely or blips to 0 (desktop) was
  /// read as "the host seeked" and pulled every guest back.
  final ValueNotifier<int> seeks = ValueNotifier(0);
  // ── end party sync ───────────────────────────────────────────────────

  /// The next song is showing and will start by itself after the gap.
  bool get inGap => _gapToken >= 0 && _gapToken == _loadToken && !_gapHeld;

  /// The silence to leave between [ended] and [next] when one ends on its own.
  Duration? _gapBetween(Item? ended, Item? next) {
    if (autoAdvanceGap <= Duration.zero || remote != null) return null;
    // A crossfade set by hand overlaps as before (Automix no longer overlaps).
    if (!_automixOn && settings.crossfadeSeconds > 0) return null;
    if (ended != null && next != null && keepTogether(ended, next)) return null; // gapless album
    return autoAdvanceGap;
  }

  void _beginGap(Duration d, int token, {bool held = false}) {
    _gapT?.cancel();
    _gapToken = token;
    _gapLoaded = false;
    _gapHeld = held;
    _gapT = held ? null : gapTimer(d, _gapElapsed);
    gapEndsAt = held ? null : DateTime.now().add(d); // party: shared start time
    waitingForNext.value = !held;
  }

  void _clearGap() {
    _gapT?.cancel();
    _gapT = null;
    gapEndsAt = null;
    _gapToken = -1;
    _gapLoaded = false;
    _gapHeld = false;
    waitingForNext.value = false;
  }

  void _gapElapsed() {
    _gapT = null;
    if (_gapToken != _loadToken || _gapToken < 0) {
      _clearGap();
      return;
    }
    if (_gapHeld) return;
    waitingForNext.value = false;
    if (_gapLoaded) {
      _clearGap();
      unawaited(_cur.play());
    }
    // still loading: the load starts it the moment it's ready
  }

  /// Where a freshly loaded song would start: now, or after the gap.
  void _startLoaded(int token) {
    if (token == _gapToken) {
      if (_gapHeld) {
        _clearGap();
        _broadcast(_cur);
        return;
      }
      if (_gapT != null) {
        _gapLoaded = true;
        _broadcast(_cur);
        return;
      }
      _clearGap();
    }
    unawaited(_cur.play());
  }

  /// Pause during the gap: the next song stays, but doesn't start.
  bool _holdGap() {
    if (!inGap) return false;
    _gapT?.cancel();
    _gapT = null;
    gapEndsAt = null;
    if (_gapLoaded) {
      _clearGap();
    } else {
      _gapHeld = true; // still loading: load it, don't start it
      waitingForNext.value = false;
    }
    _broadcast(_cur);
    return true;
  }
  Stream<Duration> get positionStream => _cur.positionStream;

  // ── loading sources ──────────────────────────────────────────────────
  Future<AudioQuality> _quality() async {
    try {
      final c = await Connectivity().checkConnectivity();
      _onWifi = c.contains(ConnectivityResult.wifi) || c.contains(ConnectivityResult.ethernet);
      if (_onWifi) return settings.wifiQuality;
      return settings.mobileQuality;
    } catch (_) {
      return settings.wifiQuality;
    }
  }

  bool _onWifi = true;

  /// On Wi-Fi (or Ethernet) as of the last song load.
  bool get onWifi => _onWifi;

  Future<bool> _online() async {
    try {
      final c = await Connectivity().checkConnectivity();
      return !(c.length == 1 && c.first == ConnectivityResult.none) && c.isNotEmpty;
    } catch (_) {
      return true;
    }
  }

  /// Resolves when the phone has a connection again (tests swap it).
  Future<void> Function() waitOnline = () async {
    final c = Connectivity();
    bool on(List<ConnectivityResult> r) => r.isNotEmpty && !(r.length == 1 && r.first == ConnectivityResult.none);
    if (on(await c.checkConnectivity())) {
      // Connected but the server didn't answer: try again shortly.
      await Future<void>.delayed(const Duration(seconds: 4));
      return;
    }
    await c.onConnectivityChanged.firstWhere(on);
  };

  bool get _needsMp4 => !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  /// Web build: the address a song's audio streams from (see lib/web/).
  static Uri Function(String videoId, AudioQuality q)? webPlayUrl;

  /// Addon and SMB songs: the app wires these up (see services.dart).
  Future<AudioSource?> Function(Item it)? externalSource;

  /// Whether sound is going to the phone's own speaker right now.
  bool Function() onPhoneSpeaker = () => false;

  bool get _normalizeNow => settings.normalizeVolume && !(settings.normalizeOffOnSpeaker && onPhoneSpeaker());

  Future<AudioSource> _sourceFor(Item it, {Set<String> avoid = const {}}) async {
    if (it.isAddon || it.isSmb) {
      final s = await externalSource?.call(it);
      if (s == null) throw StateError('This source isn\'t set up on this phone');
      _gains[it.id] = 1.0;
      return s;
    }
    if (it.isDav) {
      final u = Uri.parse(it.id.substring(4));
      return AudioSource.uri(u, headers: WebDav.headersFor?.call(u));
    }
    if (it.isLocal) return AudioSource.uri(Uri.file(it.id.substring(6)));
    final dl = library.download(it.id);
    final hasDl = dl != null && !kIsWeb && File(dl.path).existsSync();
    if (hasDl && settings.preferDownloads) return AudioSource.uri(Uri.file(dl.path));
    // Automix fetched this song ahead of time: play the copy on the phone.
    final cached = _automixOn ? automix!.cachedFile(it.id) : null;
    if (cached != null) {
      final an = automix!.analysisOf(it.id);
      if (_normalizeNow && an != null) _gains[it.id] = loudnessGain(an.loudnessDb);
      return AudioSource.uri(Uri.file(cached));
    }
    // Web: the Byte web server finds and streams the audio in one call.
    if (kIsWeb && webPlayUrl != null) {
      final id = it.kind == ItemKind.video ? await _officialAudioId(it.id) : it.id;
      _gains[it.id] = 1.0;
      return AudioSource.uri(webPlayUrl!(id, await _quality()));
    }
    final AudioStream s;
    try {
      // A music video plays as sound only: from the song's official audio
      // track when YouTube Music has one (no intro/outro, no video data).
      final id = it.kind == ItemKind.video ? await _officialAudioId(it.id) : it.id;
      s = await resolver.resolve(id, await _quality(), preferMp4: _needsMp4, probe: settings.verifyStreams, avoid: avoid);
    } catch (_) {
      // Offline or blocked: the downloaded copy still plays.
      if (hasDl) return AudioSource.uri(Uri.file(dl.path));
      rethrow;
    }
    if (identical(it, current.value) || it.id == current.value?.id) currentStream.value = s;
    final an = _automixOn ? automix!.analysisOf(it.id) : null;
    _gains[it.id] = _normalizeNow ? (an != null ? loudnessGain(an.loudnessDb) : normalisationGain(s.loudnessDb)) : 1.0;
    // Each client's stream must be fetched with that client's own user agent:
    // a fallback client's link played with another client's agent gets
    // refused partway through the song.
    if (chunkedStreams && s.contentLength != null && s.contentLength! > 0) {
      return ChunkedHttpSource(Uri.parse(s.url), length: s.contentLength!, mime: s.mime, userAgent: s.userAgent);
    }
    return AudioSource.uri(Uri.parse(s.url), headers: s.userAgent == null ? null : {'User-Agent': s.userAgent!});
  }

  final Map<String, String> _officialAudio = {};

  /// The official audio track of a music video (its own id when it has none).
  Future<String> _officialAudioId(String videoId) async {
    final known = _officialAudio[videoId];
    if (known != null) return known;
    var id = videoId;
    try {
      final v = await yt.versions(videoId).timeout(const Duration(seconds: 3));
      id = v?.audio?.item.id ?? videoId;
    } catch (_) {}
    _officialAudio[videoId] = id;
    return id;
  }

  /// Fetch YouTube streams in bounded pieces (see [ChunkedHttpSource]).
  /// Off in the widget tests, whose fake player reads the link directly.
  bool chunkedStreams = !kIsWeb && !Platform.environment.containsKey('FLUTTER_TEST');

  final Map<String, double> _gains = {};
  double _gainFor(Item? it) => (it == null ? 1 : (_gains[it.id] ?? 1.0)) * _duck * _appVolume;

  /// The player's own volume (where the phone's media volume can't be set).
  double _appVolume = 1;
  void setAppVolume(double v) {
    _appVolume = v.clamp(0.0, 1.0);
    _applyVolumes();
  }

  /// Loads [src] on deck [p] and remembers which file it is.
  Future<void> _load(AudioPlayer p, AudioSource src, {Duration? initialPosition, bool preload = true}) async {
    _deckFile.remove(p);
    if (src is UriAudioSource && src.uri.scheme == 'file') _deckFile[p] = src.uri.toFilePath();
    await p.setAudioSource(src, initialPosition: initialPosition, preload: preload);
  }

  // ── ducking (the DJ talking over the music) ───────────────────────────
  double _duck = 1;
  Timer? _duckTimer;
  double get duckLevel => _duck;

  /// Lowers (or restores, with 1.0) the music volume smoothly over [ms].
  Future<void> duck(double level, {int ms = 450}) async {
    _duckTimer?.cancel();
    final from = _duck, to = level.clamp(0.0, 1.0);
    if (ms <= 0 || from == to) {
      _duck = to;
      _applyVolumes();
      return;
    }
    final started = DateTime.now().millisecondsSinceEpoch;
    final done = Completer<void>();
    _duckTimer = Timer.periodic(const Duration(milliseconds: 40), (t) {
      final k = ((DateTime.now().millisecondsSinceEpoch - started) / ms).clamp(0.0, 1.0);
      _duck = from + (to - from) * k;
      _applyVolumes();
      if (k >= 1) {
        t.cancel();
        if (!done.isCompleted) done.complete();
      }
    });
    return done.future.timeout(Duration(milliseconds: ms + 500), onTimeout: () {});
  }

  void _applyVolumes() {
    if (_fading) return; // the fade tick applies it
    final (mode, at) = sleep.value;
    var v = _gainFor(current.value);
    if (mode == SleepMode.timer && at != null) v *= sleepFadeVolume(at.difference(DateTime.now()).inMilliseconds);
    _cur.setVolume(v);
  }

  bool get _automixOn => automix != null && settings.automix && !kIsWeb;

  /// Is a blend between two songs running right now?
  bool get inTransition => _fading;

  /// The blend now running (or about to), for the player screen.
  TransitionPlan? get activePlan => _activePlan;

  // ── public API used by the UI ─────────────────────────────────────────
  /// Plays [items] starting at [start]. With [radio], the queue keeps
  /// filling with similar songs (like tapping a song in YouTube Music).
  /// Where the queue came from ("Kesariya Radio", an album or playlist name),
  /// shown on the player under the title.
  final ValueNotifier<String?> playingFrom = ValueNotifier(null);

  Future<void> playItems(List<Item> items, {int start = 0, bool? shuffle, bool radio = false, bool rememberShuffle = true, String? from, bool startPaused = false}) async {
    final playable = items.where((i) => i.isPlayable).toList();
    if (playable.isEmpty) return;
    final s = start.clamp(0, playable.length - 1);
    playingFrom.value = from ??
        (radio
            ? '${playable[s].artists.isNotEmpty ? playable[s].artists.first.name : playable[s].title} Radio'
            : null);
    _cancelFade(finishIncoming: false);
    queueModel.load(playable, start: s, shuffle: shuffle);
    _preparedOnIdle = null;
    if (shuffle != null && rememberShuffle) await library.put('shuffle', shuffle);
    _queueChanged();
    await _playCurrent(startPaused: startPaused);
    if (radio && !playable[s].isLocal) {
      _radioFails = 0;
      _radioRetryAt = 0;
      unawaited(_extendWithRadio(playable[s], force: true));
    } else {
      topUpRadio();
    }
  }

  Future<void> playSong(Item it) => playItems([it], radio: true);

  /// 1.4.1: up next made from the listener's own signals (see dj/up_next.dart);
  /// null = YouTube Music's radio as it comes.
  Future<List<Item>> Function(Item seed, Set<String> exclude)? personalRadio;

  // ── 1.4.5 up next: with autoplay on, the queue always holds the next
  // [radioAhead] similar songs, filled as soon as a song starts (not in its
  // last 30 s) and topped up as they play; a failed fetch retries with a
  // back-off. A party guest never picks: it shows the host's list. ──

  /// Similar songs autoplay keeps ahead in the queue.
  static int radioAhead = 10;

  /// One fetch never holds the queue longer than this (a hung request used
  /// to leave autoplay stuck for the rest of the session).
  static Duration radioTimeout = const Duration(seconds: 20);

  /// Fetching similar songs right now (the queue shows a loading row).
  final ValueNotifier<bool> radioLoading = ValueNotifier(false);

  /// In a party as a guest: the host's upcoming songs (empty = not here
  /// yet). null = not a guest. A guest's own queue never picks a song.
  final ValueNotifier<List<Item>?> partyUpNext = ValueNotifier(null);

  /// A song the listener skipped by hand, and how much of it they heard
  /// (up next learns from it).
  void Function(Item it, int heardMs)? onUserSkip;

  /// Something else keeps the queue filled right now (the DJ's set).
  bool Function()? holdRadio;

  final Set<String> _radioIds = {};
  int _radioRetryAt = 0;
  int _radioFails = 0;

  /// Was [id] put in the queue by autoplay?
  bool isRadioPick(String id) => _radioIds.contains(id);

  /// Songs after the current one in the queue.
  int get upcomingCount => max(0, queueModel.playOrder.length - queueModel.position - 1);

  /// Autoplay should keep the queue filled here.
  bool get radioWanted {
    final cur = current.value;
    return settings.autoplay && cur != null && !cur.isLocal && remote == null && partyUpNext.value == null && queueModel.repeat == q.RepeatMode.off && !(holdRadio?.call() ?? false);
  }

  /// Fills the queue up to [radioAhead] similar songs when it runs short.
  void topUpRadio() {
    if (!radioWanted || _extendingRadio || upcomingCount >= radioAhead) return;
    if (DateTime.now().millisecondsSinceEpoch < _radioRetryAt) return;
    unawaited(_extendWithRadio(current.value!));
  }

  /// A song skipped by hand within 30 s: the similar songs autoplay lined up
  /// by the same artist go (they're found again later if loved), then refill.
  void dropRadioLike(Item skipped) {
    final a = skipped.artists.isEmpty ? '' : skipped.artists.first.name.trim().toLowerCase();
    if (a.isEmpty) return;
    final order = queueModel.playOrder;
    var changed = false;
    for (var i = order.length - 1; i > queueModel.position; i--) {
      final it = order[i];
      if (_radioIds.contains(it.id) && it.artists.any((x) => x.name.trim().toLowerCase() == a)) {
        queueModel.removeAt(i);
        changed = true;
      }
    }
    if (changed) {
      _preparedOnIdle = null;
      _queueChanged();
    }
  }

  Future<void>? _radioJob;

  Future<void> _extendWithRadio(Item seed, {bool force = false}) async {
    if (partyUpNext.value != null) return;
    if (_extendingRadio) {
      // the listener is waiting (Next, a song's end): let the fetch running now land
      if (force) await _radioJob;
      return;
    }
    if (!force && DateTime.now().millisecondsSinceEpoch < _radioRetryAt) return;
    final job = Completer<void>();
    _radioJob = job.future;
    _extendingRadio = true;
    radioLoading.value = true;
    var added = 0;
    var stale = false;
    try {
      final noRepeat = settings.noRepeatInSession;
      List<Item> got = const [];
      if (personalRadio != null) {
        try {
          got = await personalRadio!(seed, {...queueModel.originalOrder.map((i) => i.id), if (noRepeat) ...sessionSeen}).timeout(radioTimeout);
        } catch (_) {}
      }
      if (got.isEmpty) got = (await yt.next(seed.id).timeout(radioTimeout)).queue;
      // "Don't repeat songs in this session": skip anything already played or suggested.
      final add = <Item>[];
      for (final i in got) {
        if (i.id == seed.id || !i.isPlayable || queueModel.contains(i.id) || (noRepeat && sessionSeen.contains(i.id)) || add.any((x) => x.id == i.id)) continue;
        add.add(i);
      }
      // the song changed while this was fetched: the picks were for another song
      if (current.value?.id != seed.id && !force) {
        stale = true;
        return;
      }
      sessionSeen.addAll(add.map((i) => i.id));
      _radioIds.addAll(add.map((i) => i.id));
      queueModel.addAll(add);
      added = add.length;
      if (add.isNotEmpty) {
        _queueChanged();
        _preparedOnIdle = null;
      }
    } catch (_) {
    } finally {
      _extendingRadio = false;
      radioLoading.value = false;
      job.complete();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (stale) {
        _radioRetryAt = 0;
      } else if (added > 0) {
        _radioFails = 0;
        _radioRetryAt = now + 2000;
      } else {
        // nothing new (offline, a failed fetch): try again in 3, 6, 12 … 60 s
        _radioFails++;
        _radioRetryAt = now + min(60000, 3000 * (1 << min(_radioFails - 1, 5)));
      }
    }
  }

  void playNextItem(Item it) {
    if (queueModel.isEmpty) {
      playItems([it]);
      return;
    }
    queueModel.playNext(it);
    _preparedOnIdle = null;
    _queueChanged();
  }

  void addToQueue(Iterable<Item> its) {
    if (queueModel.isEmpty) {
      playItems(its.toList());
      return;
    }
    queueModel.addAll(its.where((i) => i.isPlayable));
    _preparedOnIdle = null;
    _queueChanged();
  }

  /// Everything after the current song is replaced by [its] (DJ "Switch it up").
  void replaceUpcoming(List<Item> its) {
    queueModel.clearUpcoming();
    queueModel.addAll(its.where((i) => i.isPlayable));
    _preparedOnIdle = null;
    _queueChanged();
  }

  /// Moves on to the next song with a quick blend (instead of a hard cut).
  Future<void> blendToNext({int ms = 3000}) async {
    final next = queueModel.nextItem;
    if (next == null || !_cur.playing || _fading) {
      await skipToNext();
      return;
    }
    final from = automix?.analysisOf(next.id)?.audioStartMs ?? 0;
    if (_preparedOnIdle?.id != next.id) await _prepareNext(next, from: from);
    if (_preparedOnIdle?.id != next.id || queueModel.nextItem?.id != next.id || _fading) {
      await skipToNext();
      return;
    }
    final a = automix?.analysisOf(next.id);
    final plan = TransitionPlan(
      startAtMs: _cur.position.inMilliseconds,
      incomingFromMs: from,
      fadeMs: ms,
      inGain: a != null && _normalizeNow ? loudnessGain(a.loudnessDb) : (_gains[next.id] ?? 1),
      kind: 'simple',
    );
    await _startTransition(plan, ms);
  }

  void moveQueueItem(int from, int to) {
    queueModel.move(from, to);
    _preparedOnIdle = null;
    _queueChanged();
  }

  void removeFromQueue(int index) {
    if (index == queueModel.position) return; // can't remove what's playing
    queueModel.removeAt(index);
    _preparedOnIdle = null;
    _queueChanged();
  }

  void _queueChanged() {
    queue.add(queueModel.playOrder.map(mediaItemFor).toList());
    queueVersion.value++;
    _broadcast(_cur);
  }

  @override
  Future<void> play() async {
    if (current.value == null) return;
    if (remote != null) return remote!.remotePlay();
    // Play during the pause between songs: start the next one now.
    if (_gapToken >= 0 && _gapToken == _loadToken) {
      if (_gapLoaded) {
        _clearGap();
        await _cur.play();
      } else {
        // still loading: it starts the moment it's ready
        _gapT?.cancel();
        _gapT = null;
        _gapHeld = false;
        waitingForNext.value = false;
        _broadcast(_cur);
      }
      return;
    }
    // Long pauses outlive YouTube's stream links: reload at the same spot.
    final s = currentStream.value;
    if (s != null && s.expired && !current.value!.isLocal && !library.isDownloaded(current.value!.id)) {
      final pos = _cur.position;
      resolver.forget(current.value!.id);
      await _playCurrent(startAt: pos);
      return;
    }
    if (_cur.processingState == ProcessingState.idle) {
      await _playCurrent(startAt: _restoredAt ?? _cur.position); // 1.4.5: restored last song resumes at its spot
      return;
    }
    final fade = pauseFadeMs();
    if (fade > 0 && !_cur.playing) {
      // Fade in instead of starting at full volume.
      _duck = 0;
      _applyVolumes();
      unawaited(_cur.play());
      await duck(1, ms: fade);
      return;
    }
    await _cur.play();
  }

  @override
  Future<void> pause() async {
    if (remote != null) return remote!.remotePause();
    if (_holdGap()) return;
    _cancelFade(finishIncoming: true);
    final fade = pauseFadeMs();
    if (fade > 0 && _cur.playing) {
      await duck(0, ms: fade);
      await _cur.pause();
      _duck = 1;
      _applyVolumes();
      return;
    }
    await _cur.pause();
  }

  @override
  Future<void> stop() async {
    _userStopped = true; // 1.4.5: only Stop (or a swipe) takes the notification away
    _restoredAt = null;
    _clearGap();
    _cancelFade(finishIncoming: false);
    await _cur.stop();
    await _idle.stop();
    _preparedOnIdle = null;
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    if (remote != null) {
      clock.set(position.inMilliseconds);
      return remote!.remoteSeek(position);
    }
    _cancelFade(finishIncoming: true);
    if (_restoredAt != null && _cur.processingState == ProcessingState.idle) {
      _restoredAt = position; // 1.4.5: restored, not loaded yet: remember the spot
      clock.set(position.inMilliseconds);
      _broadcast(_cur);
      return;
    }
    // Seeking in the next song during the pause between songs starts it there.
    final startNow = inGap && _gapLoaded;
    if (startNow) _clearGap();
    await _cur.seek(position);
    clock.set(position.inMilliseconds);
    if (startNow) unawaited(_cur.play());
    seeks.value++; // party sync: a real seek (not a position glitch)
  }

  @override
  Future<void> skipToNext() async {
    _cancelFade(finishIncoming: true);
    final skipped = current.value;
    if (skipped != null && remote == null) onUserSkip?.call(skipped, inGap ? 1 << 30 : _cur.position.inMilliseconds);
    if (queueModel.next(userInitiated: true)) {
      await _playCurrent();
    } else if (partyUpNext.value?.isNotEmpty ?? false) {
      // a party guest: Next goes to the host's next song
      await playItems([partyUpNext.value!.first]);
    } else if (settings.autoplay && current.value != null) {
      await _extendWithRadio(current.value!, force: true);
      if (queueModel.next(userInitiated: true)) await _playCurrent();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    _cancelFade(finishIncoming: true);
    // During the pause between songs the next one sits at 0:00: back goes to
    // the song that just ended.
    if ((!inGap && _cur.position > const Duration(seconds: 3)) || !queueModel.previous()) {
      await seek(Duration.zero);
      return;
    }
    await _playCurrent();
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    _cancelFade(finishIncoming: false);
    queueModel.jumpTo(index);
    await _playCurrent();
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    queueModel.setShuffle(shuffleMode != AudioServiceShuffleMode.none);
    await library.put('shuffle', queueModel.shuffle);
    _preparedOnIdle = null;
    _queueChanged();
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    queueModel.repeat = switch (repeatMode) {
      AudioServiceRepeatMode.none => q.RepeatMode.off,
      AudioServiceRepeatMode.one => q.RepeatMode.one,
      _ => q.RepeatMode.all,
    };
    await library.put('repeat', queueModel.repeat.index);
    _preparedOnIdle = null;
    _broadcast(_cur);
  }

  Future<void> cycleRepeat() => setRepeatMode(switch (queueModel.repeat) {
    q.RepeatMode.off => AudioServiceRepeatMode.all,
    q.RepeatMode.all => AudioServiceRepeatMode.one,
    q.RepeatMode.one => AudioServiceRepeatMode.none,
  });

  @override
  Future<void> setSpeed(double speed) async {
    final s = speed.clamp(0.5, 2.0);
    settings.speed = s;
    _ease = null;
    await _cur.setSpeed(s);
    await _idle.setSpeed(s);
    clock.set(_cur.position.inMilliseconds, speed: s);
  }

  Future<void> applySkipSilence() async {
    for (final p in [_cur, _idle]) {
      try {
        await p.setSkipSilenceEnabled(settings.skipSilence);
      } catch (_) {}
    }
  }

  // ── sleep timer ───────────────────────────────────────────────────────
  void setSleepTimer(Duration? d) {
    if (d == null) {
      sleep.value = (SleepMode.off, null);
      _cur.setVolume(_gainFor(current.value));
    } else {
      sleep.value = (SleepMode.timer, DateTime.now().add(d));
    }
  }

  void sleepAtEndOfTrack() => sleep.value = (SleepMode.endOfTrack, null);

  // ── casting ───────────────────────────────────────────────────────────
  /// The phone goes quiet while a Cast device plays.
  Future<void> pauseLocalForRemote() async {
    _cancelFade(finishIncoming: false);
    await _cur.pause();
    await _idle.stop();
    _preparedOnIdle = null;
    _remoteTick?.cancel();
    _remoteTick = Timer.periodic(const Duration(seconds: 1), (_) => remoteChanged());
  }

  /// Casting ended: carry on here from [at].
  Future<void> resumeLocalAfterRemote(Duration at, {bool play = true}) async {
    _remoteTick?.cancel();
    _remoteTick = null;
    await _playCurrent(startAt: at);
    if (!play) await _cur.pause();
    _broadcast(_cur);
  }

  /// The remote's state moved: refresh the clock, buttons and lock screen.
  void remoteChanged() {
    final r = remote;
    if (r == null) return;
    clock.set(r.positionMs, playing: r.remotePlaying);
    final st = playbackState.value;
    playbackState.add(
      st.copyWith(
        playing: r.remotePlaying,
        controls: [MediaControl.skipToPrevious, if (r.remotePlaying) MediaControl.pause else MediaControl.play, MediaControl.skipToNext],
        systemActions: lockScreenActions,
        androidCompactActionIndices: const [0, 1, 2],
        updatePosition: Duration(milliseconds: r.positionMs),
        bufferedPosition: Duration(milliseconds: r.positionMs),
        speed: 1.0,
        processingState: AudioProcessingState.ready,
      ),
    );
  }

  /// The song on the remote finished: next one, same rules as here.
  Future<void> remoteEnded() async {
    if (queueModel.next()) {
      await _playCurrent();
    } else if (settings.autoplay && current.value != null) {
      await _extendWithRadio(current.value!, force: true);
      if (queueModel.next()) await _playCurrent();
    }
    _queueChanged();
  }

  String? _artPath;

  /// Sends the song's details to the lock screen / notification, keeping
  /// its picture file safe from clean-up while it's on screen.
  void _publish(MediaItem m) {
    final u = m.artUri;
    if (u != null && u.isScheme('file')) {
      final path = u.toFilePath();
      if (path != _artPath) {
        LockArt.use(path, previous: _artPath);
        _artPath = path;
      }
    }
    mediaItem.add(m);
  }

  /// Makes the sharp square picture for [it] when it isn't on the phone yet
  /// (or only a small stand-in is), then swaps it in if [it] still plays.
  void _publishArt(Item it) {
    final have = LockArt.existing(it);
    if (have != null && LockArt.isFull(have)) return;
    unawaited(
      LockArt.make(it).then((f) {
        final mi = mediaItem.value;
        if (f == null || current.value?.id != it.id || mi == null || mi.id != it.id) return;
        final u = Uri.file(f.path);
        if (mi.artUri != u) _publish(mi.copyWith(artUri: u));
      }),
    );
  }

  // ── the core: start the current queue item ───────────────────────────
  Future<void> _playCurrent({Duration? startAt, Duration? afterGap, bool startPaused = false}) async {
    final it = queueModel.current;
    if (it == null) return;
    _restoredAt = null; // 1.4.5 (resume point)
    _userStopped = false;
    final token = ++_loadToken;
    _prepTries = 0;
    _tailFor = null;
    _tailTimer?.cancel();
    _tailTimer = null;
    if (afterGap != null || startPaused) {
      _beginGap(afterGap ?? Duration.zero, token, held: startPaused);
    } else {
      _clearGap();
    }
    _attempts = 0;
    _recovering = false;
    _healthyFromMs = startAt?.inMilliseconds ?? 0;
    _stallSince = null;
    error.value = null;
    current.value = it;
    sessionSeen.add(it.id);
    if (it.isOnPhone) unawaited(AudioFormats.of(it.id.substring(6))); // the real format, for the badge
    _publish(mediaItemFor(it));
    _publishArt(it);
    clock.set(startAt?.inMilliseconds ?? 0, playing: false);
    _broadcast(_cur);
    if (settings.saveHistory) unawaited(library.addHistory(it));
    _prefetchCovers();
    if (remote != null) {
      await _cur.stop();
      await remote!.load(it, startAt: startAt);
      return;
    }
    _automixKick(it);

    // Prepared on the other deck already → instant, gap-free start — unless
    // that link has gone stale (prepared hours ago, expired, or it broke).
    if (_preparedOnIdle?.id == it.id && startAt == null && _preparedIsStale()) {
      resolver.forget(it.id); // and don't hand back the same old link
      _preparedOnIdle = null;
    }
    if (_preparedOnIdle?.id == it.id && startAt == null) {
      final old = _cur;
      _cur = _idle;
      _idle = old;
      _preparedOnIdle = null;
      await old.stop();
      await _cur.setVolume(_gainFor(it));
      await _cur.setSpeed(settings.speed);
      _startLoaded(token);
      _broadcast(_cur);
      return;
    }
    loading.value = true;
    try {
      await _idle.stop();
      _preparedOnIdle = null;
      // A deck that ended still counts as "playing" and would start the new
      // song the moment it loads: hold it for the gap (or a paused load).
      if (token == _gapToken) await _cur.pause();
      final src = await _sourceFor(it);
      if (token != _loadToken) return; // user moved on meanwhile
      await _load(_cur, src, initialPosition: startAt).timeout(loadTimeout);
      if (token != _loadToken) return;
      await _cur.setVolume(_gainFor(it));
      await _cur.setSpeed(settings.speed);
      _startLoaded(token);
    } catch (e) {
      if (token != _loadToken) return;
      await _handleLoadError(it, e, startAt);
    } finally {
      if (token == _loadToken) loading.value = false;
    }
  }

  /// Recovery attempts for the song that's playing (a fresh song starts at 0).
  int _attempts = 0;
  bool _recovering = false;
  int _healthyFromMs = 0;

  /// How many times a broken song is re-fetched before Byte moves on.
  int maxAttempts = 3;

  /// The pause before each retry (tests shorten it).
  Duration Function(int attempt) retryBackoff = (n) => Duration(milliseconds: n <= 1 ? 0 : (n == 2 ? 800 : 2000));

  /// "Couldn't play X, skipped" and similar one-off notes for the screen.
  final ValueNotifier<String?> notice = ValueNotifier(null);

  /// A song broke (failed to load, refused mid-song, stalled, or ended far
  /// too early): fetch a fresh link — from another client after the first
  /// try — and carry on from the same spot. Only when every try fails does
  /// Byte skip, and then it says so.
  Future<void> _handleLoadError(Item it, Object e, Duration? startAt) async {
    if (_recovering) return; // the same failure is often reported twice
    _recovering = true;
    final token = _loadToken;
    Object err = e;
    try {
      while (!it.isLocal && _attempts < maxAttempts) {
        _attempts++;
        if (_attempts > 1) {
          // A dropped connection: wait for it instead of burning the retries.
          if (_friendly(err) == 'No internet connection' || !await _online()) break;
          await Future<void>.delayed(retryBackoff(_attempts));
        }
        if (token != _loadToken || current.value?.id != it.id) return;
        final failed = currentStream.value?.client;
        resolver.forget(it.id);
        try {
          final src = await _sourceFor(it, avoid: _attempts > 1 && failed != null && failed.isNotEmpty ? {failed} : const {});
          if (token != _loadToken) return;
          await _idle.stop();
          await _load(_cur, src, initialPosition: startAt);
          if (token != _loadToken) return;
          await _cur.setVolume(_gainFor(it));
          await _cur.setSpeed(settings.speed);
          unawaited(_cur.play());
          _healthyFromMs = startAt?.inMilliseconds ?? 0;
          error.value = null;
          _broadcast(_cur);
          return;
        } catch (e2) {
          err = e2;
        }
      }
      if (token != _loadToken) return;
      final msg = _friendly(err);
      if (msg == 'No internet connection' || !await _online()) {
        // The connection dropped: don't skip through the whole queue. Wait for
        // it to come back, then carry on from the same spot.
        error.value = 'No internet connection — resumes when you\'re back online';
        _broadcast(_cur);
        final id = it.id;
        final at = startAt;
        _recovering = false;
        await waitOnline();
        if (current.value?.id == id && token == _loadToken && error.value != null) {
          error.value = null;
          await _playCurrent(startAt: at);
          if (!_cur.playing) unawaited(_cur.play());
        }
        return;
      }
      error.value = msg;
      _broadcast(_cur);
      // Don't get stuck on one broken song: move on after a beat, and say so.
      final id = it.id;
      Future.delayed(const Duration(milliseconds: 1800), () {
        if (current.value?.id == id && token == _loadToken && error.value != null && queueModel.peekNext(userInitiated: true) != null) {
          notice.value = 'Couldn\'t play ${it.title}, skipped';
          skipToNext();
        }
      });
    } finally {
      _recovering = false;
    }
  }

  String _friendly(Object e) {
    final s = '$e';
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('Network')) return 'No internet connection';
    if (s.contains('not a bot') || s.contains('LOGIN_REQUIRED')) return 'The music server is asking you to sign in for this song';
    if (s.contains('unavailable') || s.contains('UNPLAYABLE')) return 'This song isn\'t available';
    return 'Couldn\'t play this song';
  }

  void _onPlayerError(AudioPlayer p, Object e) {
    if (p != _cur) return;
    final it = current.value;
    if (it == null) return;
    _handleLoadError(it, e, _cur.position);
  }

  void _onPlayerState(AudioPlayer p, PlayerState s) {
    if (p == _cur) {
      clock.set(p.position.inMilliseconds, playing: s.playing && s.processingState == ProcessingState.ready, speed: p.speed);
      if (s.processingState == ProcessingState.completed && !_fading) {
        final it = current.value;
        if (it != null && _endedEarly(p)) {
          _handleLoadError(it, StateError('the stream ended early'), p.position);
        } else {
          _onTrackEnded();
        }
      }
    }
  }

  /// The next two songs' covers, fetched while this one plays (list size and
  /// player size), so they show at once when their turn comes.
  void _prefetchCovers() {
    final order = queueModel.playOrder;
    final at = queueModel.position;
    for (var k = 1; k <= 2 && at + k < order.length; k++) {
      final t = order[at + k].thumb;
      for (final px in const [226, 1080]) {
        unawaited(CoverCache.prefetch(resizeThumb(t, px)));
      }
      unawaited(squareArtFor(order[at + k])); // lock-screen picture ready before its turn
    }
  }


  // ── Android Auto / car and watch browsing ─────────────────────────────
  static const _folders = {'recent': 'Recently played', 'liked': 'Liked songs', 'playlists': 'Playlists', 'downloads': 'Downloads'};

  MediaItem _folder(String id, String title) => MediaItem(id: id, title: title, playable: false);
  MediaItem _carItem(String folder, Item it) {
    final m = mediaItemFor(it);
    return m.copyWith(id: 'item:$folder:${it.id}', playable: true);
  }

  List<Item> _carList(String folder) {
    if (folder == 'recent') {
      final seen = <String>{};
      return [for (final h in library.history) if (seen.add(h.item.id)) h.item].take(50).toList();
    }
    if (folder == 'liked') return library.likes.take(200).toList();
    if (folder == 'downloads') return [for (final d in library.downloads) d.item];
    if (folder.startsWith('pl:')) return library.playlist(folder.substring(3))?.items ?? const [];
    return const [];
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    if (parentMediaId == AudioService.browsableRootId) {
      return [for (final e in _folders.entries) _folder(e.key, e.value)];
    }
    if (parentMediaId == AudioService.recentRootId) {
      return [for (final it in _carList('recent').take(10)) _carItem('recent', it)];
    }
    if (parentMediaId == 'playlists') {
      return [
        for (final p in library.playlists)
          MediaItem(id: 'pl:${p.id}', title: p.name, playable: false, artUri: p.artwork == null ? null : Uri.tryParse(resizeThumb(p.artwork, 544) ?? '')),
      ];
    }
    return [for (final it in _carList(parentMediaId)) _carItem(parentMediaId, it)];
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    if (!mediaId.startsWith('item:')) return;
    final rest = mediaId.substring(5);
    final cut = rest.lastIndexOf(':');
    final folder = rest.substring(0, cut), id = rest.substring(cut + 1);
    final list = _carList(folder);
    final at = list.indexWhere((i) => i.id == id);
    if (at < 0) return;
    await playItems(list, start: at, from: folder.startsWith('pl:') ? library.playlist(folder.substring(3))?.name : _folders[folder]);
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    if (query.trim().isEmpty) {
      final recent = _carList('recent');
      if (recent.isNotEmpty) await playItems(recent);
      return;
    }
    try {
      final r = await yt.search(query, SearchFilter.songs);
      final songs = r.where((i) => i.isPlayable).toList();
      if (songs.isNotEmpty) await playItems([songs.first], radio: true);
    } catch (_) {}
  }

  // ── keeping a song alive ─────────────────────────────────────────────
  DateTime? _stallSince;

  /// A link that doesn't start within this long is treated as broken.
  Duration loadTimeout = const Duration(seconds: 25);

  /// How long the player may sit buffering mid-song before Byte fetches a fresh link.
  Duration stallTimeout = const Duration(seconds: 12);

  /// The song's real length as YouTube reports it (null when unknown).
  int? _expectedMs(Item it) {
    final s = currentStream.value;
    if (s?.durationMs != null && s!.durationMs! > 0 && it.id == current.value?.id) return s.durationMs;
    return it.durationSec != null && it.durationSec! > 0 ? it.durationSec! * 1000 : null;
  }

  void _watchdog(AudioPlayer p) {
    final it = current.value;
    if (it == null || remote != null || _fading || _recovering || it.isLocal || it.isDav || it.isAddon || it.isSmb) {
      _stallSince = null;
      return;
    }
    final buffering = p.playing && (p.processingState == ProcessingState.buffering || p.processingState == ProcessingState.loading);
    if (!buffering || loading.value) {
      _stallSince = null;
    } else {
      _stallSince ??= DateTime.now();
      if (DateTime.now().difference(_stallSince!) > stallTimeout) {
        _stallSince = null;
        unawaited(_handleLoadError(it, StateError('stream stalled'), p.position));
        return;
      }
    }
    // A good stretch of playback earns the retries back.
    if (_attempts > 0 && p.playing && p.processingState == ProcessingState.ready && p.position.inMilliseconds - _healthyFromMs > 20000) _attempts = 0;
  }

  /// "Completed" long before the end means the connection gave out.
  bool _endedEarly(AudioPlayer p) {
    final it = current.value;
    if (it == null || it.isLocal || remote != null || _attempts >= maxAttempts) return false;
    final pos = p.position.inMilliseconds;
    final want = _expectedMs(it);
    final known = p.duration?.inMilliseconds ?? want;
    if (want == null || known == null) return false;
    return pos < known - 5000 && pos < want - 5000;
  }

  bool _ending = false;
  Future<void> _onTrackEnded() async {
    if (_ending) return;
    _ending = true;
    try {
      if (sleep.value.$1 == SleepMode.endOfTrack) {
        sleep.value = (SleepMode.off, null);
        await _cur.pause();
        await _cur.seek(Duration.zero);
        return;
      }
      final ended = current.value;
      if (queueModel.repeat == q.RepeatMode.one) {
        final gap = _gapBetween(ended, ended);
        if (gap == null) {
          await _cur.seek(Duration.zero);
          await _cur.play();
        } else {
          // the same song again, after the same short silence
          await _cur.pause();
          await _cur.seek(Duration.zero);
          _beginGap(gap, _loadToken);
          _gapLoaded = true;
          _broadcast(_cur);
        }
        return;
      }
      if (queueModel.next()) {
        await _playCurrent(afterGap: _gapBetween(ended, queueModel.current));
      } else if (settings.autoplay && current.value != null && !current.value!.isLocal) {
        await _extendWithRadio(current.value!, force: true);
        if (queueModel.next()) {
          await _playCurrent(afterGap: _gapBetween(ended, queueModel.current));
        } else {
          await _cur.pause();
        }
      } else {
        await _cur.pause();
        await _cur.seek(Duration.zero);
      }
    } finally {
      _ending = false;
    }
  }

  // ── 4 times a second: prepare next deck, run crossfades, sleep timer ──
  Future<void> _onTick() async {
    _maybeSaveResume(); // 1.4.5: last song + spot survive Byte being closed
    final p = _cur;
    if (p.playing) clock.set(p.position.inMilliseconds, playing: p.processingState == ProcessingState.ready, speed: p.speed);
    _watchdog(p);
    _sleepTick();
    _easeTick();
    topUpRadio(); // 1.4.5: similar songs ahead from the song's start
    if (_fading) return; // the fade timer runs the blend
    final dur = p.duration;
    if (dur == null || !p.playing || queueModel.repeat == q.RepeatMode.one) return;
    final ms = dur.inMilliseconds;
    final pos = p.position.inMilliseconds;
    if (_automixOn) {
      _automixTick(ms, pos);
      return;
    }
    final upcoming = queueModel.nextItem;
    final together = upcoming != null && current.value != null && keepTogether(current.value!, upcoming);
    final plan = CrossfadePlan(together ? 0 : settings.crossfadeSeconds);
    final nextIdx = queueModel.peekNext();
    // Near the end of the queue with autoplay on: fetch more first.
    if (nextIdx == null && settings.autoplay && current.value != null && !current.value!.isLocal && pos > ms - 30000 && !_extendingRadio) {
      unawaited(_extendWithRadio(current.value!));
      return;
    }
    final next = queueModel.nextItem;
    if (next == null) return;
    // "Load the next song early" (Settings → Performance); crossfade always needs it.
    if ((settings.preloadNext || plan.effectiveMs(ms) > 0) && pos >= plan.prepareAt(ms) && _preparedOnIdle?.id != next.id && !_preparing) {
      unawaited(_prepareNext(next));
    }
    if (plan.effectiveMs(ms) > 0 && pos >= plan.startNextAt(ms) && _preparedOnIdle?.id == next.id && sleep.value.$1 != SleepMode.endOfTrack) {
      _startTransition(null, plan.effectiveMs(ms));
    }
  }

  // ── Automix ───────────────────────────────────────────────────────────
  TransitionPlan? _activePlan;
  String? _nextPrepFor;
  String? _orderedFor;
  Timer? _startTimer;
  Timer? _fadeTimer;

  /// Gets the song now playing analysed (its outro decides the blend).
  void _automixKick(Item it) {
    if (!_automixOn || it.isDav) return;
    unawaited(automix!.prepare(it, preferMp4: _needsMp4));
    // Automix performance "Best": the next two songs are fetched and read ahead too.
    if (settings.automixPerformance >= 2) {
      for (final n in queueModel.playOrder.skip(queueModel.position + 1).take(2)) {
        if (!n.isLocal) unawaited(automix!.prepare(n, preferMp4: _needsMp4));
      }
    }
    final keep = {it.id, ...queueModel.playOrder.skip(queueModel.position + 1).take(4).map((e) => e.id)};
    unawaited(automix!.trim(keep));
  }

  /// The plan for handing the current song over to [next], from whatever
  /// is known right now (falls back to a plain crossfade).
  TransitionPlan planFor(Item cur, Item next, int durMs) {
    final a = automix?.analysisOf(cur.id);
    final b = automix?.analysisOf(next.id);
    final norm = _normalizeNow;
    final plan = planTransition(
      outDurationMs: durMs,
      out: a,
      inDurationMs: next.durationSec == null ? null : next.durationSec! * 1000,
      inn: b,
      seconds: settings.automixSeconds,
      mode: settings.automixSmart ? AutomixMode.smart : AutomixMode.simple,
      outFallbackGain: _gains[cur.id] ?? 1,
      inFallbackGain: _gains[next.id] ?? 1,
    );
    if (!norm) {
      return TransitionPlan(
        startAtMs: plan.startAtMs,
        incomingFromMs: plan.incomingFromMs,
        fadeMs: plan.fadeMs,
        tempoRatio: plan.tempoRatio,
        beatMatched: plan.beatMatched,
        bassSwap: plan.bassSwap,
        outFadesItself: plan.outFadesItself,
        kind: plan.kind,
      );
    }
    return plan;
  }

  void _automixTick(int ms, int pos) {
    final cur = current.value;
    if (cur == null) return;
    final next0 = queueModel.nextItem;
    // Near the end of the queue with autoplay on: fetch more first.
    if (next0 == null) {
      final endA = automix!.analysisOf(cur.id)?.audioEndMs ?? ms;
      if (settings.autoplay && !cur.isLocal && pos > endA - 45000 && !_extendingRadio) unawaited(_extendWithRadio(cur));
      return;
    }
    // Smart shuffle: among the next few, play the one that blends best.
    if (queueModel.shuffle && settings.automixSmart && settings.automixSmartShuffle && _orderedFor != cur.id && pos >= 2000) {
      _orderedFor = cur.id;
      _smartOrder(cur);
    }
    final next = queueModel.nextItem!;
    // Fetch + analyse the next song early (a few seconds in, or right away for short songs).
    if (_nextPrepFor != next.id && (pos >= 4000 || ms - pos < 60000) && !next.isDav) {
      _nextPrepFor = next.id;
      unawaited(automix!.prepare(next, preferMp4: _needsMp4));
    }
    // 1.4.5 (Apurba: "pichle wale version mah automix sahi tha, aise hi
    // karna bas 2-3 wait karna uske bad"): Automix keeps its matched
    // loudness and trims dead air, but never overlaps. The song plays out
    // (silence at its very end cut with a short fade), then the gap, then
    // the next song from where its music starts.
    final endA = automix!.analysisOf(cur.id)?.audioEndMs ?? ms;
    final endAt = min(endA, ms);
    final from = automix!.analysisOf(next.id)?.audioStartMs ?? 0;
    final fetching = automix!.isPreparing(next.id);
    if (pos >= endAt - 20000 &&
        (!fetching || pos >= endAt - 8000) &&
        (_preparedOnIdle?.id != next.id || (_idleFrom ?? 0) != from) &&
        !_preparing &&
        _prepTries < 3) {
      _prepTries++;
      unawaited(_prepareNext(next, from: from));
      return;
    }
    if (sleep.value.$1 == SleepMode.endOfTrack && endAt >= ms - 300) return;
    // Dead air at the end (more than a second): fade out and end there.
    if (endAt < ms - 1000 && pos >= endAt - tailFadeMs && _tailFor != cur.id) {
      _tailFor = cur.id;
      _fadeOutAndEnd(cur.id);
    }
  }

  /// The short fade where Automix cuts a song's silent ending.
  int tailFadeMs = 600;
  String? _tailFor;
  int _prepTries = 0;
  Timer? _tailTimer;

  void _fadeOutAndEnd(String id) {
    final token = _loadToken;
    final deck = _cur;
    final from = deck.volume;
    final started = DateTime.now().millisecondsSinceEpoch;
    _tailTimer?.cancel();
    _tailTimer = Timer.periodic(const Duration(milliseconds: 40), (t) async {
      if (token != _loadToken || current.value?.id != id || deck != _cur || !deck.playing) {
        t.cancel();
        if (deck.volume < from) unawaited(deck.setVolume(_gainFor(current.value)));
        return;
      }
      final k = ((DateTime.now().millisecondsSinceEpoch - started) / max(1, tailFadeMs)).clamp(0.0, 1.0);
      unawaited(deck.setVolume(from * (1 - k)));
      if (k < 1) return;
      t.cancel();
      _tailTimer = null;
      await deck.pause();
      await deck.setVolume(_gainFor(current.value));
      if (token != _loadToken) return;
      await _onTrackEnded();
    });
  }

  void _smartOrder(Item cur) {
    final a = automix!.analysisOf(cur.id);
    final start = queueModel.position + 1;
    final upcoming = queueModel.playOrder.skip(start).take(4).toList();
    if (upcoming.length < 2) return;
    final pick = pickSmoothestNext(a, [for (final u in upcoming) automix!.analysisOf(u.id)]);
    if (pick > 0) {
      queueModel.move(start + pick, start);
      _preparedOnIdle = null;
      _queueChanged();
    }
    // On Wi-Fi, get the next few analysed so the following picks can be smart too.
    if (_onWifi) {
      () async {
        for (final u in upcoming.skip(1)) {
          if (u.isDav || automix!.analysisOf(u.id) != null) continue;
          await automix!.prepare(u, preferMp4: _needsMp4);
        }
      }();
    }
  }

  bool _preparing = false;
  int? _idleFrom;
  DateTime? _preparedAt;
  AudioStream? _preparedStream;

  /// A prepared next song older than this is fetched afresh when it starts.
  Duration preparedMaxAge = const Duration(hours: 5);

  bool _preparedIsStale() {
    if (_idle.processingState == ProcessingState.idle) return true; // its link broke while waiting
    final at = _preparedAt;
    if (at == null || DateTime.now().difference(at) > preparedMaxAge) return true;
    return _preparedStream?.expired ?? false;
  }
  Future<void> _prepareNext(Item next, {int? from}) async {
    _preparing = true;
    try {
      final src = await _sourceFor(next);
      if (queueModel.nextItem?.id != next.id) return;
      await _load(_idle, src, preload: true, initialPosition: from == null || from <= 0 ? null : Duration(milliseconds: from));
      _idleFrom = from ?? 0;
      _preparedAt = DateTime.now();
      _preparedStream = resolver.cached(next.id);
      await _idle.setVolume(0);
      await _idle.setSpeed(settings.speed);
      _preparedOnIdle = next;
    } catch (_) {
      _preparedOnIdle = null;
    } finally {
      _preparing = false;
    }
  }

  Future<void> _startTransition(TransitionPlan? plan, int fadeMs) async {
    final incoming = queueModel.nextItem;
    if (_fading || incoming == null || !queueModel.next()) return;
    ++_loadToken; // a new play (stats, pending loads)
    _startTimer?.cancel();
    _startTimer = null;
    _fading = true;
    _fadeStartAt = DateTime.now().millisecondsSinceEpoch;
    _activePlan = plan;
    _fadeMs = max(1, fadeMs);
    _fadingOut = _cur;
    _outGain = _gainFor(current.value) / (_duck == 0 ? 1 : _duck);
    if (plan != null && _normalizeNow) _gains[incoming.id] = plan.inGain;
    _cur = _idle;
    _idle = _fadingOut!;
    _preparedOnIdle = null;
    current.value = incoming;
    _publish(mediaItemFor(incoming));
    _publishArt(incoming);
    if (settings.saveHistory) unawaited(library.addHistory(incoming));
    _automixKick(incoming);
    currentStream.value = null;
    final incomingDeck = _cur;
    unawaited(incomingDeck.setVolume(0));
    final from = plan?.incomingFromMs ?? 0;
    if (plan != null && (_idleFrom ?? 0) != from) {
      // loaded before the plan settled: jump to the planned entry point first
      try {
        await incomingDeck.seek(Duration(milliseconds: from));
      } catch (_) {}
    }
    if (!_fading || _cur != incomingDeck) return; // cancelled meanwhile
    if (plan != null && plan.tempoRatio != 1) {
      unawaited(incomingDeck.setSpeed(settings.speed * plan.tempoRatio));
      _ease = (plan, DateTime.now().millisecondsSinceEpoch);
    } else {
      _ease = null;
    }
    if (plan != null && plan.bassSwap) {
      final (_, inCut) = plan.lowCut(0);
      _setLowCut(incomingDeck, inCut);
    }
    _fadeStartAt = DateTime.now().millisecondsSinceEpoch;
    unawaited(incomingDeck.play());
    clock.set(from, playing: true, speed: settings.speed * (plan?.tempoRatio ?? 1));
    _broadcast(_cur);
    _fadeTimer?.cancel();
    _fadeTimer = Timer.periodic(const Duration(milliseconds: 40), (_) => _fadeTick());
  }

  final Map<AudioPlayer, double> _cutNow = {};

  /// Every bass-swap step (deck 0 = outgoing at the time, for tests).
  @visibleForTesting
  final List<double> lowCutTrace = [];

  void _setLowCut(AudioPlayer p, double amount) {
    final eq = equalizer;
    if (eq == null) return;
    final a = (amount * 20).round() / 20; // steps of 5 %
    if ((_cutNow[p] ?? 0) == a) return;
    _cutNow[p] = a;
    lowCutTrace.add(a);
    if (eq.ios) {
      final f = _deckFile[p];
      if (f != null) unawaited(eq.setIosLowCut(f.split('/').last, a));
    } else {
      final de = _deckEq[p];
      if (de != null) unawaited(eq.setDeckLowCut(de, a));
    }
  }

  void _fadeTick() {
    if (!_fading) return;
    final t = (DateTime.now().millisecondsSinceEpoch - _fadeStartAt) / _fadeMs;
    final plan = _activePlan;
    final (outV, inV) = plan?.volumes(t) ?? CrossfadePlan.volumes(t);
    _fadingOut?.setVolume(outV * _outGain * _duck);
    _cur.setVolume(inV * _gainFor(current.value));
    if (plan != null && plan.bassSwap) {
      final (outCut, inCut) = plan.lowCut(t);
      final out = _fadingOut;
      if (out != null) _setLowCut(out, outCut);
      _setLowCut(_cur, inCut);
    }
    if (t >= 1) _cancelFade(finishIncoming: true, natural: true);
  }

  /// Tempo nudge of the incoming song, eased back to normal after the blend.
  (TransitionPlan, int)? _ease;
  void _easeTick() {
    final e = _ease;
    if (e == null) return;
    final (plan, started) = e;
    final ms = DateTime.now().millisecondsSinceEpoch - started;
    final want = settings.speed * plan.speedAt(ms);
    if ((_cur.speed - want).abs() > 0.0015) unawaited(_cur.setSpeed(want));
    if (ms >= plan.fadeMs + TransitionPlan.tempoEaseMs) {
      _ease = null;
      if (_cur.speed != settings.speed) unawaited(_cur.setSpeed(settings.speed));
    }
  }

  void _cancelFade({required bool finishIncoming, bool natural = false}) {
    _startTimer?.cancel();
    _startTimer = null;
    if (!_fading) {
      if (!natural && _ease != null) {
        _ease = null;
        unawaited(_cur.setSpeed(settings.speed));
      }
      return;
    }
    _fading = false;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final out = _fadingOut;
    _fadingOut = null;
    if (out != null) {
      _setLowCut(out, 0);
      out.stop();
      unawaited(out.setSpeed(settings.speed));
    }
    _setLowCut(_cur, 0);
    if (!natural && _ease != null) {
      // interrupted (skip / seek / pause): no half-finished tempo nudge
      _ease = null;
      unawaited(_cur.setSpeed(settings.speed));
    }
    _activePlan = null;
    if (finishIncoming) _cur.setVolume(_gainFor(current.value));
  }

  void _sleepTick() {
    final (mode, at) = sleep.value;
    if (mode != SleepMode.timer || at == null) return;
    final left = at.difference(DateTime.now()).inMilliseconds;
    if (left <= 0) {
      sleep.value = (SleepMode.off, null);
      _holdGap();
      _cur.pause().then((_) => _cur.setVolume(_gainFor(current.value)));
    } else if (left < 10000) {
      _cur.setVolume(sleepFadeVolume(left) * _gainFor(current.value));
    }
  }

  // ── what the notification / lock screen shows ─────────────────────────
  void _broadcast(AudioPlayer p) {
    if (p != _cur) return;
    if (remote != null) {
      remoteChanged();
      return;
    }
    final playingNow = p.playing || inGap;
    playbackState.add(
      PlaybackState(
        controls: [MediaControl.skipToPrevious, if (playingNow) MediaControl.pause else MediaControl.play, MediaControl.skipToNext],
        systemActions: lockScreenActions,
        androidCompactActionIndices: const [0, 1, 2],
        processingState: lockScreenState(
          error.value != null
              ? AudioProcessingState.error
              : (loading.value
                    ? AudioProcessingState.loading
                    : const {
                        ProcessingState.idle: AudioProcessingState.idle,
                        ProcessingState.loading: AudioProcessingState.loading,
                        ProcessingState.buffering: AudioProcessingState.buffering,
                        ProcessingState.ready: AudioProcessingState.ready,
                        ProcessingState.completed: AudioProcessingState.completed,
                      }[p.processingState]!),
          hasSong: current.value != null,
          stopped: _userStopped,
          playing: playingNow,
        ),
        playing: playingNow,
        updatePosition: _restoredAt ?? p.position,
        bufferedPosition: p.bufferedPosition,
        // during the pause between songs the next one waits at 0:00
        speed: inGap && !p.playing ? 0 : p.speed,
        queueIndex: queueModel.position < 0 ? null : queueModel.position,
        shuffleMode: queueModel.shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
        repeatMode: switch (queueModel.repeat) {
          q.RepeatMode.off => AudioServiceRepeatMode.none,
          q.RepeatMode.one => AudioServiceRepeatMode.one,
          q.RepeatMode.all => AudioServiceRepeatMode.all,
        },
        errorMessage: error.value,
      ),
    );
    // the real duration once the stream is open
    final d = p.duration;
    final mi = mediaItem.value;
    if (d != null && mi != null && mi.duration != d && mi.id == current.value?.id) {
      _publish(mi.copyWith(duration: d));
    }
  }

  @override
  Future<void> onTaskRemoved() async {
    // Settings → Miscellaneous → "Stop music on close from recents".
    // 1.4.5: otherwise a paused song stays on the lock screen / notification
    // too (it used to be stopped and vanish when Byte was swiped away).
    saveResumePoint();
    if (settings.stopOnClose) await stop();
  }

  // ── 1.4.5: the lock screen keeps the song; last song survives a close ──
  // Apurba: "song off ho phir bhi lock screen mein show karna chahiye".
  bool _userStopped = false; // Stop pressed / notification swiped
  Duration? _restoredAt; // restored after Byte was closed, not loaded yet
  int _resumeSavedAt = 0;
  String? _resumeSavedId;
  bool _resumeSavedPlaying = false;

  /// The library key the resume point is kept under.
  static const resumeKey = 'resume_point';

  /// What the lock screen / notification is told. A paused song (after
  /// Pause, at the end of the queue, a deck that went idle, or restored after
  /// a close) is "ready, paused": Android keeps the media notification and
  /// lock-screen controls with a play button. Only Stop gives "idle", which
  /// removes them.
  @visibleForTesting
  static AudioProcessingState lockScreenState(AudioProcessingState s, {required bool hasSong, required bool stopped, required bool playing}) {
    if (!hasSong || stopped) return s;
    if (s == AudioProcessingState.idle) return AudioProcessingState.ready;
    if (s == AudioProcessingState.completed && !playing) return AudioProcessingState.ready;
    return s;
  }

  void _maybeSaveResume() {
    final it = current.value;
    if (it == null || remote != null || _restoredAt != null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final pl = playing;
    if (it.id == _resumeSavedId && pl == _resumeSavedPlaying && (!pl || now - _resumeSavedAt < 5000)) return;
    _resumeSavedId = it.id;
    _resumeSavedPlaying = pl;
    _resumeSavedAt = now;
    saveResumePoint();
  }

  /// Writes the queue, the song and its spot (Byte may be closed any time).
  void saveResumePoint() {
    final it = current.value;
    if (it == null || _restoredAt != null) return;
    try {
      final r = ResumePoint.of(
        queueModel.playOrder,
        queueModel.position,
        positionMs: inGap ? 0 : _cur.position.inMilliseconds,
        from: playingFrom.value,
      );
      if (r != null) unawaited(library.put(resumeKey, r.encode()).catchError((Object _) {}));
    } catch (_) {}
  }

  /// Opened again after Byte was closed or killed: the last song comes back
  /// paused at its spot, on the player and the lock screen (nothing loads
  /// until Play).
  Future<bool> restoreLast() async {
    if (current.value != null || remote != null) return false;
    final r = ResumePoint.decode(library.get(resumeKey));
    if (r == null || r.items.isEmpty) return false;
    final playable = r.items.where((i) => i.isPlayable).toList();
    if (playable.isEmpty) return false;
    final at = r.index.clamp(0, playable.length - 1);
    queueModel.load(playable, start: at, shuffle: false);
    final it = queueModel.current;
    if (it == null) return false;
    _userStopped = false;
    _restoredAt = Duration(milliseconds: r.positionMs);
    playingFrom.value = r.from;
    current.value = it;
    _queueChanged();
    clock.set(r.positionMs, playing: false);
    _publish(mediaItemFor(it));
    _publishArt(it);
    _broadcast(_cur);
    return true;
  }

  Future<void> disposeAll() async {
    _tick?.cancel();
    _fadeTimer?.cancel();
    _startTimer?.cancel();
    _duckTimer?.cancel();
    _gapT?.cancel();
    _tailTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    await _cur.dispose();
    await _idle.dispose();
  }
}
