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

  Future<SpotifySyncResult?> syncNow() async {
    if (_running || !account.connected) return null;
    _running = true;
    lastError = null;
    _set('Reading your library…');
    try {
      final lists = await account.playlists();
      final read = <(SpotifyPlaylistInfo, List<ExtTrack>)>[];
      for (var i = 0; i < lists.length; i++) {
        final p = lists[i];
        _set('Reading ${p.name}… (${i + 1} of ${lists.length})');
        final ext = await account.read(p);
        read.add((p, ext.tracks));
      }
      // Look up only songs Byte hasn't matched before.
      final todo = <String, ExtTrack>{};
      for (final (_, tracks) in read) {
        for (final t in tracks) {
          final k = trackKey(t);
          if (!_known(k)) todo[k] = t;
        }
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
      _set('Saving…');
      var likedN = 0, plN = 0;
      for (final (p, tracks) in read) {
        final items = <Item>[];
        final seen = <String>{};
        for (final t in tracks) {
          final it = _cached(trackKey(t));
          if (it != null && seen.add(it.id)) items.add(it);
        }
        if (p.id == 'liked') {
          likedN = items.length;
          // oldest first so the newest like ends up on top (distinct times,
          // so the order holds even when they all land in one millisecond)
          final base = DateTime.now().millisecondsSinceEpoch;
          var k = 0;
          for (final it in items.reversed) {
            k++;
            if (!library.isLiked(it.id)) await library.setLiked(it, true, at: base + k);
          }
        } else {
          plN++;
          final source = 'spotify:${p.id}';
          final have = library.playlistBySource(source);
          if (have == null) {
            await library.createPlaylist(p.name, items: items, source: source, cover: p.cover);
          } else {
            have.items
              ..clear()
              ..addAll(items);
            await library.savePlaylist(have);
          }
        }
      }
      await _b?.put('likedCount', likedN);
      await _b?.put('playlistCount', plN);
      await _b?.put('last', DateTime.now().millisecondsSinceEpoch);
      _set(null);
      return SpotifySyncResult(likedN, plN, todo.length, notFound);
    } catch (e) {
      lastError = e is SpotifyProblem ? e.message : 'Couldn\'t sync right now. Byte will try again later.';
      _set(null);
      return null;
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// Forget what was matched (on log out). Byte playlists and likes stay.
  Future<void> forget() async {
    await _b?.clear();
    notifyListeners();
  }
}
