import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../data/library.dart';
import '../data/settings.dart';
import '../player/byte_handler.dart';
import 'dj_lines.dart';
import 'dj_session.dart';
import 'recommender.dart';
import 'request_parser.dart';

/// Personal DJ: a non-stop session in segments blended with Automix. 1.4.3:
/// the DJ never speaks (Apurba: the talk-over interrupted the songs); its
/// line for each section only shows on screen. Byte © 2026 Apurba Laskar.
class DjController extends ChangeNotifier {
  final ByteAudioHandler player;
  final DjBrain brain;
  final Settings settings;
  final DjLines lines;
  DateTime Function() now;

  /// Picks songs for what the listener asks for (DJ chat / hold to talk).
  final DjRecommender? recommender;

  /// For noticing likes during a requested mix.
  final Library? library;

  DjController({
    required this.player,
    required this.brain,
    required this.settings,
    DjLines? lines,
    DateTime Function()? now,
    this.recommender,
    this.library,
  }) : lines = lines ?? DjLines(),
       now = now ?? DateTime.now {
    player.current.addListener(_onCurrent);
    _stateSub = player.playbackState.listen(_onState);
    _posSub = player.positionStream.listen((p) {
      final id = player.current.value?.id;
      if (id != null) _heard[id] = p;
    });
    library?.addListener(_onLibrary);
  }

  StreamSubscription<PlaybackState>? _stateSub;
  StreamSubscription<Duration>? _posSub;

  // ── requested mix (DJ chat) ──
  /// The mix playing for a request ("sad Hindi"), or null for the radio show.
  DjMix? mix;
  DjRequest? request;
  bool get inRequest => active && mix != null;

  /// Why each song was picked ("Because you play Kesariya").
  final Map<String, String> reasons = {};

  /// How far each song got (for spotting skips).
  final Map<String, Duration> _heard = {};
  String? _lastId;
  final Set<String> _likedSeen = {};

  /// Skips and likes heard during this mix (shown as "learning" on screen).
  int skipsLearned = 0, likesLearned = 0;

  bool active = false;
  bool starting = false;
  bool switching = false;
  String? error;

  /// What the DJ said last (shown on the DJ screen).
  String? lastLine;

  /// Every segment of this session, in order.
  final List<DjSegment> segments = [];

  /// Index into [segments] of the one playing now.
  int currentSegment = -1;

  final Map<String, int> _segmentOfItem = {};
  final Set<String> _segmentStarts = {};
  final Set<String> _announced = {};
  String? _switchLineFor;
  bool _opening = false;
  bool _appending = false;

  DjSegment? get segment => currentSegment >= 0 && currentSegment < segments.length ? segments[currentSegment] : null;
  List<DjSegment> get upcoming => currentSegment < 0 ? segments : segments.skip(currentSegment + 1).toList();

  String get listenerName => settings.djName;

  /// Starts a fresh DJ session.
  Future<void> start() async {
    if (starting) return;
    starting = true;
    error = null;
    notifyListeners();
    try {
      _reset();
      brain.reset();
      final first = await brain.next();
      if (first == null || first.items.isEmpty) {
        error = 'Couldn\'t reach online music. Check the internet and try again.';
        return;
      }
      _addSegment(first);
      _opening = true;
      active = true;
      await player.playItems(first.items, shuffle: false, rememberShuffle: false);
      unawaited(_ensureAhead());
    } catch (_) {
      error = 'Couldn\'t start the DJ. Try again.';
      active = false;
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  void _reset() {
    mix = null;
    request = null;
    reasons.clear();
    _heard.clear();
    _lastId = null;
    _likedSeen.clear();
    skipsLearned = 0;
    likesLearned = 0;
    segments.clear();
    _segmentOfItem.clear();
    _segmentStarts.clear();
    _announced.clear();
    currentSegment = -1;
    lastLine = null;
    _switchLineFor = null;
  }

  void _addSegment(DjSegment s) {
    segments.add(s);
    final idx = segments.length - 1;
    for (final it in s.items) {
      _segmentOfItem[it.id] = idx;
    }
    if (s.items.isNotEmpty) _segmentStarts.add(s.items.first.id);
  }

  Set<String> get _usedIds => _segmentOfItem.keys.toSet();

  /// Keeps at least one more segment queued after the current one.
  Future<void> _ensureAhead() async {
    if (_appending || !active) return;
    final q = player.queueModel;
    final left = q.length - q.position - 1;
    // keep one whole segment queued after the one playing
    if (mix != null) {
      if (left >= 4) return;
      _appending = true;
      try {
        final more = await mix!.more(count: 10);
        if (!active || mix == null || more.isEmpty) return;
        _addToRequest(more);
        player.addToQueue(more.map((p) => p.item));
        notifyListeners();
      } finally {
        _appending = false;
      }
      return;
    }
    if (left >= 3 && segments.length - 1 > max(0, currentSegment)) return;
    _appending = true;
    try {
      final s = await brain.next(exclude: _usedIds);
      if (s == null || !active) return;
      _addSegment(s);
      player.addToQueue(s.items);
      notifyListeners();
    } finally {
      _appending = false;
    }
  }

  void _onCurrent() {
    if (!active) return;
    final it = player.current.value;
    if (it == null) return;
    final prev = _lastId;
    _lastId = it.id;
    if (mix != null && prev != null && prev != it.id && _segmentOfItem.containsKey(it.id)) _learnFrom(prev, it);
    final seg = _segmentOfItem[it.id];
    if (seg == null) {
      // something else is playing now: the DJ steps aside
      stop(silent: true);
      return;
    }
    if (seg != currentSegment) {
      currentSegment = seg;
      notifyListeners();
    }
    if (_segmentStarts.contains(it.id) && !_announced.contains(it.id)) {
      _announced.add(it.id);
      _announce(it, segments[seg]);
    }
    unawaited(_ensureAhead());
  }

  void _onState(PlaybackState s) {}

  void _announce(Item first, DjSegment seg) {
    final opening = _opening;
    _opening = false;
    final switching = _switchLineFor == first.id;
    if (switching) _switchLineFor = null;
    final text = lines.line(
      switching && seg.vibe != null ? DjMoment.switchUp : seg.moment,
      name: listenerName,
      hinglish: settings.djLanguage != 'english',
      now: now(),
      artist: first.artists.isEmpty ? null : first.artists.first.name,
      vibe: seg.vibe?.spoken ?? seg.title.toLowerCase(),
      language: seg.language,
      period: seg.period,
      opening: opening,
    );
    lastLine = text;
    notifyListeners();
  }

  /// Brings the music back up if anything left it dipped (older builds
  /// ducked it under the DJ's voice). Nothing is ever spoken.
  Future<void> _quiet() async {
    if (player.duckLevel < 1) await player.duck(1.0, ms: 300);
  }

  /// "Switch it up": a different vibe, straight away.
  Future<void> switchItUp() async {
    if (!active || switching) return;
    switching = true;
    notifyListeners();
    try {
      await _quiet();
      // a requested mix hands back to the show's sections
      mix = null;
      request = null;
      final v = brain.nextVibe(segment?.vibe?.id);
      final s = await brain.build(SegmentKind.vibe, vibe: v, exclude: _usedIds);
      if (s == null || s.items.isEmpty || !active) {
        error = 'Couldn\'t find songs for that vibe. Try again.';
        return;
      }
      error = null;
      // the rest of this segment and anything queued after it make way
      segments.removeRange(currentSegment + 1, segments.length);
      _segmentOfItem.removeWhere((_, seg) => seg > currentSegment);
      player.replaceUpcoming(s.items);
      _addSegment(s);
      _switchLineFor = s.items.first.id;
      await player.blendToNext();
      unawaited(_ensureAhead());
    } finally {
      switching = false;
      notifyListeners();
    }
  }

  // ── requests ──
  void _addToRequest(List<DjPick> picks) {
    final idx = segments.length - 1;
    if (idx < 0) return;
    final seg = segments[idx];
    for (final p in picks) {
      if (_segmentOfItem.containsKey(p.item.id) && _segmentOfItem[p.item.id] == idx && seg.items.any((e) => e.id == p.item.id)) {
        reasons[p.item.id] = p.reason;
        continue;
      }
      seg.items.add(p.item);
      _segmentOfItem[p.item.id] = idx;
      reasons[p.item.id] = p.reason;
    }
  }

  /// Plays what was asked for ("sad Hindi", "Arijit jaisa", "mere liye mix").
  /// Returns the picks (empty when nothing could be found).
  Future<List<DjPick>> playRequest(DjRequest req) async {
    final rec = recommender;
    if (rec == null) return const [];
    starting = true;
    error = null;
    notifyListeners();
    try {
      final exclude = <String>{};
      final m = await rec.mix(req, size: 20, exclude: exclude);
      if (m.picks.isEmpty) {
        error = 'Couldn\'t find songs for that. Try other words, or check the internet.';
        return const [];
      }
      await _quiet();
      _reset();
      mix = m;
      request = req;
      final seg = DjSegment(
        kind: SegmentKind.request,
        title: _cap(req.summary),
        subtitle: 'Picked from your listening',
        items: <Item>[],
        vibe: DjVibe('request', _cap(req.summary), req.summary, req.queries.isEmpty ? req.summary : req.queries.first),
      );
      segments.add(seg);
      _addToRequest(m.picks);
      _segmentStarts.add(m.picks.first.item.id);
      // the chat says its own line; no second intro over the first song
      _announced.add(m.picks.first.item.id);
      active = true;
      currentSegment = 0;
      await player.playItems(m.picks.map((p) => p.item).toList(), shuffle: false, rememberShuffle: false, from: 'DJ · ${_cap(req.summary)}');
      _lastId = player.current.value?.id;
      return m.picks;
    } catch (_) {
      error = 'Couldn\'t start that. Try again.';
      return const [];
    } finally {
      starting = false;
      notifyListeners();
    }
  }

  static String _cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  /// The songs coming up in this mix, with their reasons.
  List<DjPick> get upcomingPicks {
    if (mix == null) return const [];
    final order = player.queueModel.playOrder;
    final pos = player.queueModel.position;
    return [
      for (final it in order.skip(pos + 1))
        if (_segmentOfItem.containsKey(it.id)) DjPick(it, reasons[it.id] ?? '', 0, false),
    ];
  }

  /// Learns from how [prevId] ended when [now] started.
  void _learnFrom(String prevId, Item now) {
    final m = mix;
    if (m == null) return;
    final order = player.queueModel.playOrder;
    final iPrev = order.indexWhere((e) => e.id == prevId);
    final iNow = order.indexWhere((e) => e.id == now.id);
    if (iPrev < 0 || iNow <= iPrev) return; // went back: not a skip
    final heard = _heard[prevId] ?? Duration.zero;
    final prev = order[iPrev];
    final dur = prev.durationSec == null ? null : Duration(seconds: prev.durationSec!);
    if (heard < const Duration(seconds: 30) && (dur == null || heard < dur * 0.5)) {
      onSkipped(prev);
    } else if (dur != null && heard >= dur * 0.8) {
      m.feedback(prev, DjFeedback.complete);
    }
  }

  /// A song in the mix was skipped: the rest of the queue is re-ranked now.
  void onSkipped(Item it) {
    final m = mix;
    if (m == null) return;
    m.feedback(it, DjFeedback.skip);
    skipsLearned++;
    _rerank();
  }

  /// A song in the mix was liked: more like it, sooner.
  void onLiked(Item it) {
    final m = mix;
    if (m == null || !_likedSeen.add(it.id)) return;
    m.feedback(it, DjFeedback.like);
    likesLearned++;
    _rerank();
  }

  void _onLibrary() {
    final it = player.current.value;
    if (mix == null || it == null || library == null) return;
    if (library!.isLiked(it.id) && _segmentOfItem.containsKey(it.id)) onLiked(it);
  }

  void _rerank() {
    final m = mix;
    if (m == null || !active) return;
    final order = player.queueModel.playOrder;
    final pos = player.queueModel.position;
    final played = order.take(pos + 1).where((i) => _segmentOfItem.containsKey(i.id)).toList();
    final up = m.rerank(played, count: max(10, order.length - pos - 1));
    if (up.isEmpty) return;
    // songs that dropped out of the mix are forgotten
    final keep = {...played.map((e) => e.id), ...up.map((p) => p.item.id)};
    final seg = segments.isEmpty ? null : segments.last;
    seg?.items.removeWhere((i) => !keep.contains(i.id));
    _segmentOfItem.removeWhere((id, _) => !keep.contains(id));
    _addToRequest(up);
    player.replaceUpcoming(up.map((p) => p.item).toList());
    notifyListeners();
  }

  /// Ends the session (the music keeps playing).
  void stop({bool silent = false}) {
    if (!active) return;
    active = false;
    unawaited(_quiet());
    notifyListeners();
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    active = false;
    player.current.removeListener(_onCurrent);
    _stateSub?.cancel();
    _posSub?.cancel();
    library?.removeListener(_onLibrary);
    super.dispose();
  }
}
