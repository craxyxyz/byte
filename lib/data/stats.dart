import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../core/models.dart';

/// One song's numbers for a year.
class SongStat {
  final Item item;
  int ms;
  int plays;
  SongStat(this.item, this.ms, this.plays);
  Map<String, dynamic> toJson() => {'i': item.toJson(), 'ms': ms, 'p': plays};
  factory SongStat.fromJson(Map m) => SongStat(Item.fromJson(m['i'] as Map), (m['ms'] as num?)?.toInt() ?? 0, (m['p'] as num?)?.toInt() ?? 0);
}

/// An artist or album, added up from its songs.
class GroupStat {
  final String name;
  final String? id;
  final String? thumb;
  final int ms;
  final int plays;
  final String? detail; // album: its artists
  const GroupStat(this.name, this.id, this.thumb, this.ms, this.plays, {this.detail});
  int get minutes => ms ~/ 60000;
}

class YearStats {
  final int year;
  final List<SongStat> songs; // most played first
  final List<GroupStat> artists;
  final List<GroupStat> albums;
  const YearStats(this.year, this.songs, this.artists, this.albums);
  int get totalMs => songs.fold(0, (a, s) => a + s.ms);
  int get minutes => totalMs ~/ 60000;
  int get plays => songs.fold(0, (a, s) => a + s.plays);
  bool get isEmpty => songs.isEmpty;
}

/// Listening time and plays, counted on this phone only (nothing is uploaded).
class ListeningStats extends ChangeNotifier {
  /// A play counts once a song has been heard for this long in one go.
  static const playThreshold = Duration(seconds: 30);

  Box? _box;
  final Map<int, Map<String, SongStat>> _years = {};

  /// Listening on the person's other devices (synced), per year: added to
  /// this phone's own numbers when shown, never saved as this phone's.
  final Map<int, Map<String, SongStat>> _others = {};

  Map<String, SongStat> _all(int y) {
    final own = _years[y], other = _others[y];
    if (other == null || other.isEmpty) return own ?? const {};
    final m = <String, SongStat>{for (final e in (own ?? const <String, SongStat>{}).entries) e.key: SongStat(e.value.item, e.value.ms, e.value.plays)};
    for (final e in other.entries) {
      final c = m[e.key];
      if (c == null) {
        m[e.key] = SongStat(e.value.item, e.value.ms, e.value.plays);
      } else {
        c.ms += e.value.ms;
        c.plays += e.value.plays;
      }
    }
    return m;
  }
  final Set<int> _dirty = {};
  Timer? _flush;
  String? _sessionKey;
  int _sessionMs = 0;
  bool _sessionCounted = false;

  /// Read the box again (after a backup import).
  Future<void> reload() async {
    _years.clear();
    _others.clear();
    await open(box: _box);
    notifyListeners();
  }

  Future<void> open({Box? box}) async {
    _box = box ?? await Hive.openBox('stats');
    for (final k in _box!.keys) {
      if (k is! String) continue;
      // "y2026" = this phone; "r:<device>:y2026" = another device (synced)
      final other = k.startsWith('r:');
      final yk = other ? k.substring(k.lastIndexOf(':') + 1) : k;
      if (!yk.startsWith('y')) continue;
      final y = int.tryParse(yk.substring(1));
      final raw = _box!.get(k);
      if (y == null || raw is! Map) continue;
      final m = {
        for (final e in raw.entries)
          if (e.value is Map) '${e.key}': SongStat.fromJson(e.value as Map),
      };
      if (!other) {
        _years[y] = m;
        continue;
      }
      final into = _others.putIfAbsent(y, () => {});
      for (final e in m.entries) {
        final c = into[e.key];
        if (c == null) {
          into[e.key] = e.value;
        } else {
          c.ms += e.value.ms;
          c.plays += e.value.plays;
        }
      }
    }
  }

  /// Adds [ms] of listening to [it]. [session] changes whenever a new play starts
  /// (a new song, or the same song again), so repeats count as plays.
  void add(Item it, int ms, {required String session, DateTime? at}) {
    if (ms <= 0) return;
    final y = (at ?? DateTime.now()).year;
    final m = _years.putIfAbsent(y, () => {});
    final s = m.putIfAbsent(it.id, () => SongStat(it, 0, 0));
    s.ms += ms;
    if (session != _sessionKey) {
      _sessionKey = session;
      _sessionMs = 0;
      _sessionCounted = false;
    }
    _sessionMs += ms;
    if (!_sessionCounted && _sessionMs >= playThreshold.inMilliseconds) {
      _sessionCounted = true;
      s.plays++;
    }
    _dirty.add(y);
    _flush ??= Timer(const Duration(seconds: 15), save);
    notifyListeners();
  }

  Future<void> save() async {
    _flush?.cancel();
    _flush = null;
    final b = _box;
    if (b == null) return;
    for (final y in _dirty.toList()) {
      await b.put('y$y', {for (final e in _years[y]!.entries) e.key: e.value.toJson()});
    }
    _dirty.clear();
  }

  Future<void> reset() async {
    _years.clear();
    _others.clear();
    _dirty.clear();
    await _box?.clear();
    notifyListeners();
  }

  List<int> get years => {..._years.keys, ..._others.keys}.toList()..sort((a, b) => b.compareTo(a));

  YearStats year(int y) {
    final songs = _all(y).values.toList()..removeWhere((s) => s.ms < 1000);
    songs.sort((a, b) => b.plays != a.plays ? b.plays.compareTo(a.plays) : b.ms.compareTo(a.ms));
    final art = <String, (String?, String?, int, int)>{};
    final alb = <String, (String?, String?, int, int, String)>{};
    for (final s in songs) {
      final it = s.item;
      for (final a in it.artists.take(3)) {
        if (a.name.trim().isEmpty) continue;
        final k = a.name.trim().toLowerCase();
        final o = art[k];
        art[k] = (a.id ?? o?.$1, o?.$2 ?? it.thumb, (o?.$3 ?? 0) + s.ms, (o?.$4 ?? 0) + s.plays);
      }
      final album = it.album?.trim();
      if (album != null && album.isNotEmpty && it.kind != ItemKind.episode) {
        final k = album.toLowerCase();
        final o = alb[k];
        alb[k] = (it.albumId ?? o?.$1, o?.$2 ?? it.thumb, (o?.$3 ?? 0) + s.ms, (o?.$4 ?? 0) + s.plays, o?.$5 ?? it.artistLine);
      }
    }
    String nameOf(String key, Iterable<SongStat> ss, bool album) {
      for (final s in ss) {
        if (album) {
          if (s.item.album?.trim().toLowerCase() == key) return s.item.album!.trim();
        } else {
          for (final a in s.item.artists) {
            if (a.name.trim().toLowerCase() == key) return a.name.trim();
          }
        }
      }
      return key;
    }

    final artists = [for (final e in art.entries) GroupStat(nameOf(e.key, songs, false), e.value.$1, e.value.$2, e.value.$3, e.value.$4)]
      ..sort((a, b) => b.ms.compareTo(a.ms));
    final albums = [
      for (final e in alb.entries) GroupStat(nameOf(e.key, songs, true), e.value.$1, e.value.$2, e.value.$3, e.value.$4, detail: e.value.$5),
    ]..sort((a, b) => b.ms.compareTo(a.ms));
    return YearStats(y, songs, artists, albums);
  }

  YearStats get thisYear => year(DateTime.now().year);

  /// One song's plays and listening time across every year.
  (int plays, int ms) song(String id) {
    var p = 0, ms = 0;
    for (final y in years) {
      final s = _all(y)[id];
      if (s != null) {
        p += s.plays;
        ms += s.ms;
      }
    }
    return (p, ms);
  }

  @override
  void dispose() {
    _flush?.cancel();
    super.dispose();
  }
}

/// Feeds [ListeningStats] once a second while music is actually playing.
class StatsTicker {
  final ListeningStats stats;
  final bool Function() isPlaying;
  final Item? Function() current;
  final int Function() playToken; // changes on every new play
  /// Also told about every second heard (scrobbling).
  final void Function(Item it, int ms, String session, DateTime at)? onHeard;
  Timer? _t;
  DateTime? _last;
  StatsTicker(this.stats, {required this.isPlaying, required this.current, required this.playToken, this.onHeard});

  void start() {
    _t?.cancel();
    _last = DateTime.now();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => tick());
  }

  void tick([DateTime? now]) {
    final n = now ?? DateTime.now();
    final last = _last ?? n;
    _last = n;
    final it = current();
    if (it == null || !isPlaying()) return;
    // Cap the step so a phone waking from sleep doesn't add hours.
    final ms = n.difference(last).inMilliseconds.clamp(0, 2000);
    final session = '${it.id}#${playToken()}';
    stats.add(it, ms, session: session, at: n);
    onHeard?.call(it, ms, session, n);
  }

  void stop() {
    _t?.cancel();
    _t = null;
    stats.save();
  }
}
