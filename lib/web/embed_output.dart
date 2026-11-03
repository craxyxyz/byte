import 'dart:async';

import '../core/models.dart';
import '../player/byte_handler.dart';
import 'embed_bridge_stub.dart' if (dart.library.js_interop) 'embed_bridge_web.dart' as bridge;

// Byte 2.0 © 2026 Apurba Laskar.
//
// Web: songs play through the official embedded player (small and visible,
// docked above the mini player). Byte keeps the queue, the clock, lyrics and
// the buttons; the embedded player only makes the sound. No Audio Lab or
// crossfade in the browser. When a song can't play here, the mini player
// says so in a few words within seconds and the next song starts.

/// What drives the embedded player (the page's script; tests use a fake).
class EmbedBridge {
  bool available() => bridge.embedAvailable();
  void load(String id, double startSec) => bridge.embedLoad(id, startSec);
  void play() => bridge.embedPlay();
  void pause() => bridge.embedPause();
  void seek(double s) => bridge.embedSeek(s);
  void volume(double v) => bridge.embedVolume(v);
  void hide() => bridge.embedHide();
  Map<String, Object?> snap() => bridge.embedSnap();
}

class WebEmbedOutput implements RemoteOutput {
  final ByteAudioHandler player;
  final EmbedBridge b;

  /// How long a song may take to start before Byte says so.
  static Duration startLimit = const Duration(milliseconds: 4500);

  WebEmbedOutput(this.player, {EmbedBridge? bridge, this.alternates}) : b = bridge ?? EmbedBridge();

  /// Other uploads of the same song (official audio, lyric video, the
  /// artist's own): tried in turn when an upload refuses to play here.
  final Future<List<String>> Function(Item it)? alternates;
  Item? _item;
  final List<String> _tried = [];
  List<String>? _alts;

  /// How many other uploads Byte tries before it skips a song.
  static int maxAlternates = 3;

  Timer? _poll;
  bool _playing = false, _wantPlay = false, _started = false, _failed = false;
  int _pos = 0, _ended = 0;
  Duration? _dur;
  DateTime? _loadedAt;
  String? _id;

  /// Short words for the mini player (one line on the smallest phone).
  static const cantPlay = 'Can\'t play here · skipped';
  static const blocked = 'Playback blocked in this browser';
  static const tapPlay = 'Tap play to start';
  static const phoneOnly = 'Plays in the app only · skipped';
  static const noneHere = 'Songs can\'t play in this browser';

  /// Songs in a row that couldn't play; at [giveUpAfter] Byte stops skipping
  /// (the whole browser or network is refused, not one song).
  int failsInRow = 0;
  static int giveUpAfter = 3;

  @override
  String get remoteName => 'This browser';
  @override
  bool get remotePlaying => _playing;
  @override
  int get positionMs => _pos;
  @override
  Duration? get remoteDuration => _dur;

  @override
  Future<void> load(Item it, {Duration? startAt}) async {
    _failed = false;
    _started = false;
    _playing = false;
    _pos = startAt?.inMilliseconds ?? 0;
    _dur = it.durationSec == null ? null : Duration(seconds: it.durationSec!);
    if (it.isLocal || it.isDav || it.isAddon || it.isSmb) {
      _fail(phoneOnly, skip: true);
      return;
    }
    _id = it.id;
    _item = it;
    _tried
      ..clear()
      ..add(it.id);
    _alts = null;
    _ended = (b.snap()['n'] as num?)?.toInt() ?? 0;
    _wantPlay = true;
    _loadedAt = DateTime.now();
    b.load(it.id, _pos / 1000);
    _startPoll();
  }

  void _startPoll() {
    _poll ??= Timer.periodic(const Duration(milliseconds: 400), (_) => tick());
  }

  void _stopPoll() {
    _poll?.cancel();
    _poll = null;
  }

  void _fail(String msg, {required bool skip}) {
    _failed = true;
    if (skip && msg == cantPlay && ++failsInRow >= giveUpAfter) {
      msg = noneHere;
      skip = false;
      b.hide();
    }
    _playing = false;
    _wantPlay = false;
    _stopPoll();
    player.error.value = msg;
    player.remoteChanged();
    if (skip) {
      Timer(const Duration(milliseconds: 900), () {
        if (_failed) unawaited(player.remoteEnded());
      });
    }
  }

  /// Reads the embedded player once (every 400 ms while a song is on).
  void tick() {
    final s = b.snap();
    if (s.isEmpty) return;
    final e = s['e'];
    if (_looking) return;
    if (e != null && e != 0 && !_failed) {
      // 2/5/100/101/150: this video can't play embedded (or is gone)
      if (e == 'api') {
        _fail(blocked, skip: false);
      } else if (alternates != null && _item != null && _tried.length <= maxAlternates) {
        unawaited(_tryAlternate(_item!));
      } else {
        _fail(cantPlay, skip: true);
      }
      return;
    }
    final state = (s['s'] as num?)?.toInt() ?? -1;
    final t = ((s['t'] as num?)?.toDouble() ?? 0) * 1000;
    final d = (s['d'] as num?)?.toDouble() ?? 0;
    final n = (s['n'] as num?)?.toInt() ?? 0;
    final was = (_playing, _pos ~/ 1000, _dur);
    if (state == 1) {
      _started = true;
      failsInRow = 0;
      if (player.error.value == tapPlay) player.error.value = null;
    }
    _playing = state == 1 || (state == 3 && _wantPlay);
    if (_started || t > 0) _pos = t.round();
    if (d > 0) _dur = Duration(milliseconds: (d * 1000).round());
    if (!_started && _wantPlay && _loadedAt != null && DateTime.now().difference(_loadedAt!) > startLimit) {
      // the browser held the sound back (autoplay rules) or it never came
      _loadedAt = null;
      player.error.value = (state == 3) ? cantPlay : tapPlay;
      if (state == 3) {
        _fail(cantPlay, skip: true);
        return;
      }
    }
    if (n > _ended) {
      _ended = n;
      _playing = false;
      unawaited(player.remoteEnded());
      return;
    }
    if (was != (_playing, _pos ~/ 1000, _dur)) player.remoteChanged();
    if (!_wantPlay && state != 1 && state != 3) _stopPoll();
  }

  bool _looking = false;

  /// This upload refused: the next upload of the same song, or skip.
  Future<void> _tryAlternate(Item it) async {
    if (_looking) return;
    _looking = true;
    try {
      _alts ??= await alternates!(it).timeout(const Duration(seconds: 3), onTimeout: () => const <String>[]);
      if (_item?.id != it.id) return; // moved on meanwhile
      final next = _alts!.where((id) => !_tried.contains(id)).firstOrNull;
      if (next == null || _tried.length > maxAlternates) {
        _fail(cantPlay, skip: true);
        return;
      }
      _tried.add(next);
      _id = next;
      _loadedAt = DateTime.now();
      b.load(next, _pos / 1000);
      // the refusal of the last upload is forgotten by the page's script on load
    } catch (_) {
      _fail(cantPlay, skip: true);
    } finally {
      _looking = false;
    }
  }

  @override
  Future<void> remotePlay() async {
    if (_id == null) return;
    _wantPlay = true;
    _failed = false;
    b.play();
    _startPoll();
  }

  @override
  Future<void> remotePause() async {
    _wantPlay = false;
    _playing = false;
    b.pause();
    player.remoteChanged();
  }

  @override
  Future<void> remoteSeek(Duration d) async {
    _pos = d.inMilliseconds;
    b.seek(d.inMilliseconds / 1000);
    player.remoteChanged();
  }

  @override
  Future<void> remoteVolume(double v) async => b.volume(v);

  void dispose() {
    _stopPoll();
    b.hide();
  }
}
