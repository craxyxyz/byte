import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../core/models.dart';
import 'library.dart';
import 'playlist_import.dart';
import 'spotify_account.dart';

// Byte © 2026 Apurba Laskar.
//
// Keeps the connected music account's Liked Songs and playlists in Byte:
// the first sync brings everything; later syncs (on start, then every few
// hours, or "Sync now") only look up songs that are new, so they are quick.
// Liked songs become Byte likes; each playlist becomes a Byte playlist that
// is updated in place.

typedef TrackMatcher = Future<List<Item?>> Function(List<ExtTrack> tracks, void Function(int done, int total) onProgress);

String trackKey(ExtTrack t) {
  String n(String s) => s.toLowerCase().replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), '').replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim();
  final first = t.artists.split(',').first;
  return '${n(t.title)}|${n(first)}';
}

class SpotifySyncResult {
  final int liked;
  final int playlists;
  final int newSongs;
  final int notFound;
  const SpotifySyncResult(this.liked, this.playlists, this.newSongs, this.notFound);
}

class SpotifySync extends ChangeNotifier {
  final SpotifyAccount account;
  final Library library;
  final TrackMatcher matcher;
  Box? _b;
  SpotifySync({required this.account, required this.library, required this.matcher});

  Future<void> open() async => _b = await Hive.openBox('spotify_sync');

  /// Shown under the Spotify row while a sync runs ("Finding songs… 40 of 312").
  String? status;
  double? progress;
  bool get running => _running;
  bool _running = false;
  String? lastError;

  bool get auto => (_b?.get('auto') as bool?) ?? true;
  Future<void> setAuto(bool v) async {
    await _b?.put('auto', v);
    notifyListeners();
  }

  DateTime? get lastSync {
    final ms = _b?.get('last') as int?;
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  int get likedCount => (_b?.get('likedCount') as int?) ?? 0;
  int get playlistCount => (_b?.get('playlistCount') as int?) ?? 0;

  /// Sync on start / resume when connected, auto is on and it's been a while.
  Future<void> maybeSync({Duration every = const Duration(hours: 6)}) async {
    if (!account.connected || !auto || _running) return;
    final l = lastSync;
    if (l != null && DateTime.now().difference(l) < every) return;
    await syncNow();
  }

  void _set(String? s, [double? p]) {
    status = s;
    progress = p;
    notifyListeners();
  }

  Item? _cached(String key) {
    final v = _b?.get('m:$key') as String?;
    if (v == null || v == 'none') return null;
    try {
      return Item.fromJson(jsonDecode(v) as Map);
    } catch (_) {
      return null;
    }
  }

  bool _known(String key) => _b?.get('m:$key') != null;

  // ---- 1.4.4: the account's playlist LIST, kept on the phone -------------
  // Home shows every playlist of the logged-in account (imported or not)
  // from this list, so Home never goes empty when the service is slow,
  // busy or refuses a sync for a while.

  static Map<String, Object?> _infoJson(SpotifyPlaylistInfo p) => {'id': p.id, 'n': p.name, 'c': p.cover, 'k': p.count, 'o': p.owner};
  static SpotifyPlaylistInfo? _infoFrom(Object? o) {
    if (o is! Map || o['id'] == null) return null;
    return SpotifyPlaylistInfo('${o['id']}', '${o['n'] ?? 'Playlist'}', o['c'] as String?, (o['k'] as num?)?.toInt() ?? -1, '${o['o'] ?? ''}');
  }

  /// The account's playlists as last read (Liked Songs first). Empty until
  /// the first successful read.
  List<SpotifyPlaylistInfo> get lists {
    final v = _b?.get('lists') as String?;
    if (v == null) return const [];
    try {
      final out = (jsonDecode(v) as List).map(_infoFrom).whereType<SpotifyPlaylistInfo>().toList();
      out.sort((a, b) => (a.id == 'liked' ? 0 : 1).compareTo(b.id == 'liked' ? 0 : 1));
      return out;
    } catch (_) {
      return const [];
    }
  }

  DateTime? get listsRead {
    final ms = _b?.get('listsAt') as int?;
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// Songs known for one playlist (from the last read), else its own count.
  int countOf(SpotifyPlaylistInfo p) => (_b?.get('n:${p.id}') as int?) ?? p.count;

  Future<void> _keepLists(List<SpotifyPlaylistInfo> ls) async {
    // a read never forgets a count we already learned
    await _b?.put('lists', jsonEncode([for (final p in ls) _infoJson(p)]));
    await _b?.put('listsAt', DateTime.now().millisecondsSinceEpoch);
    notifyListeners();
  }

  bool _listing = false;
  bool get listing => _listing;

  /// Reads the account's playlist list again (quietly). On failure the last
  /// list stays and a quiet retry is scheduled.
  Future<List<SpotifyPlaylistInfo>> refreshLists() async {
    if (!account.connected) return const [];
    if (_listing) return lists;
    _listing = true; // (no notify here: callers may be building)
    try {
      final ls = await account.playlists();
      // (the box takes it at once; the disk write finishes on its own)
      unawaited(_keepLists(ls).catchError((Object _) {}));
      return ls;
    } catch (e) {
      _note(e);
      _scheduleRetry();
      return lists;
    } finally {
      _listing = false;
      notifyListeners();
    }
  }

  /// What really went wrong last time (for the help sheet / bug reports).
  String? lastErrorDetail;
  void _note(Object e) {
    lastErrorDetail = '$e';
    debugPrint('Byte music-account sync: $e');
  }

  /// Quiet retries after a failed sync: 2 min, 10 min, 30 min, then hourly.
  /// Tests set [retryDelays] to const [] to switch them off.
  static List<Duration> retryDelays = const [Duration(minutes: 2), Duration(minutes: 10), Duration(minutes: 30), Duration(hours: 1)];
  Timer? _retry;
  int _fails = 0;
  void _scheduleRetry() {
    _fails++;
    if (retryDelays.isEmpty || (_retry?.isActive ?? false)) return;
    final d = retryDelays[(_fails - 1).clamp(0, retryDelays.length - 1)];
    _retry = Timer(d, () {
      _retry = null;
      if (account.connected) unawaited(syncNow());
    });
  }

  void _clearRetry() {
    _fails = 0;
    _retry?.cancel();
    _retry = null;
  }

  /// Matches [tracks] (only songs Byte hasn't matched before) and returns
  /// the Byte songs in order, each once.
  Future<(List<Item>, int, int)> _match(List<ExtTrack> tracks) async {
    final todo = <String, ExtTrack>{};
    for (final t in tracks) {
      final k = trackKey(t);
      if (!_known(k)) todo[k] = t;
    }
    var notFound = 0;
    if (todo.isNotEmpty) {
      final keys = todo.keys.toList();
      _set('Finding ${keys.length} songs…', 0);
      final found = await matcher(todo.values.toList(), (d, t) => _set('Finding songs… $d of $t', t == 0 ? null : d / t));
      for (var i = 0; i < keys.length; i++) {
        final it = i < found.length ? found[i] : null;
        if (it == null) notFound++;
        await _b?.put('m:${keys[i]}', it == null ? 'none' : jsonEncode(it.toJson()));
      }
    }
    final items = <Item>[];
    final seen = <String>{};
    for (final t in tracks) {
      final it = _cached(trackKey(t));
      if (it != null && seen.add(it.id)) items.add(it);
    }
    return (items, todo.length, notFound);
  }

  Future<void> _saveLiked(List<Item> items) async {
    // oldest first so the newest like ends up on top (distinct times,
    // so the order holds even when they all land in one millisecond)
    final base = DateTime.now().millisecondsSinceEpoch;
    var k = 0;
    for (final it in items.reversed) {
      k++;
      if (!library.isLiked(it.id)) await library.setLiked(it, true, at: base + k);
    }
    await _b?.put('liked:in', true);
  }

  Future<LocalPlaylist> _savePlaylist(SpotifyPlaylistInfo p, List<Item> items) async {
    final source = 'spotify:${p.id}';
    final have = library.playlistBySource(source);
    if (have == null) return library.createPlaylist(p.name, items: items, source: source, cover: p.cover);
    // an empty read never wipes a list that has songs
    if (items.isEmpty && have.items.isNotEmpty) return have;
    have.items
      ..clear()
      ..addAll(items);
    await library.savePlaylist(have);
    return have;
  }

  /// Whether Liked Songs from the account have been brought in.
  bool get likedImported => (_b?.get('liked:in') as bool?) ?? false;

  /// The Byte playlist for one of the account's playlists, once imported.
  LocalPlaylist? imported(SpotifyPlaylistInfo p) => p.id == 'liked' ? null : library.playlistBySource('spotify:${p.id}');

  /// Brings ONE playlist (or Liked Songs) in right now — Home's "tap to
  /// open" on a playlist that isn't in Byte yet. Returns its songs.
  Future<List<Item>> importOne(SpotifyPlaylistInfo p, {void Function(String)? onStatus}) async {
    final ext = await account.read(p, onStatus: onStatus);
    await _b?.put('n:${p.id}', ext.tracks.length);
    onStatus?.call('Finding songs…');
    final (items, _, _) = await _match(ext.tracks);
    if (p.id == 'liked') {
      await _saveLiked(items);
    } else {
      await _savePlaylist(p, items);
    }
    notifyListeners();
    return items;
  }

  Future<SpotifySyncResult?> syncNow() async {
    if (_running || !account.connected) return null;
    _running = true;
    lastError = null;
    _set('Reading your library…');
    try {
      List<SpotifyPlaylistInfo> ls;
      try {
        ls = await account.playlists();
        await _keepLists(ls);
      } catch (e) {
        // the list couldn't be read now: work from the last one we have
        _note(e);
        ls = lists;
        if (ls.isEmpty) rethrow;
      }
      final read = <(SpotifyPlaylistInfo, List<ExtTrack>)>[];
      Object? firstProblem;
      for (var i = 0; i < ls.length; i++) {
        final p = ls[i];
        _set('Reading ${p.name}… (${i + 1} of ${ls.length})');
        try {
          final ext = await account.read(p);
          await _b?.put('n:${p.id}', ext.tracks.length);
          read.add((p, ext.tracks));
        } catch (e) {
          // one playlist failing never stops the others
          _note(e);
          firstProblem ??= e;
        }
      }
      if (read.isEmpty && firstProblem != null) throw firstProblem;
      final (_, newSongs, notFound) = await _match([for (final (_, ts) in read) ...ts]);
      _set('Saving…');
      var likedN = 0, plN = 0;
      for (final (p, tracks) in read) {
        final (items, _, _) = await _match(tracks);
        if (p.id == 'liked') {
          likedN = items.length;
          await _saveLiked(items);
        } else {
          plN++;
          await _savePlaylist(p, items);
        }
      }
      await _b?.put('likedCount', likedN);
      await _b?.put('playlistCount', plN);
      await _b?.put('last', DateTime.now().millisecondsSinceEpoch);
      if (firstProblem != null) {
        lastError = 'Brought in ${read.length} of ${ls.length}. Byte will try the rest again by itself.';
        _scheduleRetry();
      } else {
        _clearRetry();
      }
      _set(null);
      return SpotifySyncResult(likedN, plN, newSongs, notFound);
    } catch (e) {
      _note(e);
      lastError = e is SpotifyProblem ? e.message : 'Couldn\'t sync right now. Byte will try again by itself.';
      _scheduleRetry();
      _set(null);
      return null;
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// Forget what was matched (on log out). Byte playlists and likes stay.
  Future<void> forget() async {
    _clearRetry();
    await _b?.clear();
    notifyListeners();
  }
}
