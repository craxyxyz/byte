import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../core/models.dart';

class LocalPlaylist {
  final String id;
  String name;
  final List<Item> items;
  final DateTime created;
  DateTime updated;

  /// Where it came from: null (made in Byte), `youtube:ID`, `spotify:ID` or `account:ID`.
  String? source;
  String? cover;
  LocalPlaylist({required this.id, required this.name, List<Item>? items, DateTime? created, DateTime? updated, this.source, this.cover})
    : items = items ?? [],
      created = created ?? DateTime.now(),
      updated = updated ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'id': id,
    'n': name,
    'i': items.map((e) => e.toJson()).toList(),
    'c': created.millisecondsSinceEpoch,
    'u': updated.millisecondsSinceEpoch,
    if (source != null) 's': source,
    if (cover != null) 'cv': cover,
  };
  factory LocalPlaylist.fromJson(Map m) => LocalPlaylist(
    id: m['id'] as String,
    name: m['n'] as String,
    items: ((m['i'] as List?) ?? const []).map((e) => Item.fromJson(e as Map)).toList(),
    created: DateTime.fromMillisecondsSinceEpoch(m['c'] as int),
    updated: DateTime.fromMillisecondsSinceEpoch(m['u'] as int),
    source: m['s'] as String?,
    cover: m['cv'] as String?,
  );
  String? get artwork => cover ?? (items.isNotEmpty ? items.first.thumb : null);
}

class HistoryEntry {
  final Item item;
  final DateTime at;
  const HistoryEntry(this.item, this.at);
}

class DownloadRecord {
  final Item item;
  final String path;
  final String? coverPath;
  final int bytes;
  final String mime;
  final DateTime at;
  const DownloadRecord({required this.item, required this.path, this.coverPath, required this.bytes, required this.mime, required this.at});
  Map<String, dynamic> toJson() => {'i': item.toJson(), 'p': path, 'cp': coverPath, 'b': bytes, 'm': mime, 'a': at.millisecondsSinceEpoch};
  factory DownloadRecord.fromJson(Map m) => DownloadRecord(
    item: Item.fromJson(m['i'] as Map),
    path: m['p'] as String,
    coverPath: m['cp'] as String?,
    bytes: m['b'] as int,
    mime: m['m'] as String,
    at: DateTime.fromMillisecondsSinceEpoch(m['a'] as int),
  );
}

/// Likes, playlists, history, downloads and search history, stored on the
/// device (Hive: files on Android/iOS, IndexedDB on the web).
class Library extends ChangeNotifier {
  late Box _likes, _playlists, _history, _downloads, _misc, _local;
  bool _ready = false;
  bool get ready => _ready;

  /// Playlists the person downloaded as a whole (kept up to date).
  Set<String> get downloadedPlaylists => ((_misc.get('dl_playlists') as List?) ?? const []).cast<String>().toSet();
  Future<void> setPlaylistDownloaded(String id, bool on) async {
    final s = downloadedPlaylists;
    on ? s.add(id) : s.remove(id);
    await _misc.put('dl_playlists', s.toList());
    notifyListeners();
  }

  /// Tell listeners the boxes changed underneath (backup import).
  void changed() => notifyListeners();

  Future<void> open() async {
    _likes = await Hive.openBox('likes');
    _playlists = await Hive.openBox('playlists');
    _history = await Hive.openBox('history');
    _downloads = await Hive.openBox('downloads');
    _misc = await Hive.openBox('library_misc');
    _local = await Hive.openBox('local_tracks');
    _ready = true;
  }

  // ── likes ──
  bool isLiked(String id) => _likes.containsKey(id);
  List<Item> get likes {
    final entries = _likes.values.map((v) => jsonDecode(v as String) as Map).toList()..sort((a, b) => (b['at'] as int).compareTo(a['at'] as int));
    return entries.map((m) => Item.fromJson(m['item'] as Map)).toList();
  }

  Future<void> setLiked(Item it, bool liked, {int? at}) async {
    if (liked) {
      await _likes.put(it.id, jsonEncode({'item': it.toJson(), 'at': at ?? DateTime.now().millisecondsSinceEpoch}));
    } else {
      await _likes.delete(it.id);
    }
    notifyListeners();
  }

  Future<bool> toggleLike(Item it) async {
    final now = !isLiked(it.id);
    await setLiked(it, now);
    return now;
  }

  // ── playlists ──
  /// Playlists pinned to the top of the Library.
  Set<String> get pinnedPlaylists => ((_misc.get('pinned_playlists') as List?) ?? const []).cast<String>().toSet();
  bool isPinned(String id) => pinnedPlaylists.contains(id);
  Future<void> setPinned(String id, bool on) async {
    final s = pinnedPlaylists;
    on ? s.add(id) : s.remove(id);
    await _misc.put('pinned_playlists', s.toList());
    notifyListeners();
  }

  List<LocalPlaylist> get playlists {
    final l = _playlists.values.map((v) => LocalPlaylist.fromJson(jsonDecode(v as String) as Map)).toList();
    final order = (_misc.get('playlist_order') as List?)?.cast<String>() ?? const [];
    final pins = pinnedPlaylists;
    l.sort((a, b) {
      final pa = pins.contains(a.id), pb = pins.contains(b.id);
      if (pa != pb) return pa ? -1 : 1; // pinned first
      final ia = order.indexOf(a.id), ib = order.indexOf(b.id);
      if (ia >= 0 && ib >= 0) return ia.compareTo(ib);
      if (ia >= 0) return -1;
      if (ib >= 0) return 1;
      return b.created.compareTo(a.created);
    });
    return l;
  }

  LocalPlaylist? playlist(String id) {
    final v = _playlists.get(id);
    return v == null ? null : LocalPlaylist.fromJson(jsonDecode(v as String) as Map);
  }

  LocalPlaylist? playlistBySource(String source) {
    for (final p in playlists) {
      if (p.source == source) return p;
    }
    return null;
  }

  Future<LocalPlaylist> createPlaylist(String name, {List<Item> items = const [], String? source, String? cover}) async {
    final id = 'pl_${DateTime.now().microsecondsSinceEpoch}';
    final p = LocalPlaylist(id: id, name: name.trim().isEmpty ? 'My playlist' : name.trim(), items: [...items], source: source, cover: cover);
    await _savePlaylist(p);
    final order = [(id), ...((_misc.get('playlist_order') as List?)?.cast<String>() ?? const <String>[])];
    await _misc.put('playlist_order', order);
    notifyListeners();
    return p;
  }

  Future<void> _savePlaylist(LocalPlaylist p) async {
    p.updated = DateTime.now();
    await _playlists.put(p.id, jsonEncode(p.toJson()));
  }

  Future<void> savePlaylist(LocalPlaylist p) async {
    await _savePlaylist(p);
    notifyListeners();
  }

  Future<void> renamePlaylist(String id, String name) async {
    final p = playlist(id);
    if (p == null || name.trim().isEmpty) return;
    p.name = name.trim();
    await savePlaylist(p);
  }

  Future<void> deletePlaylist(String id) async {
    await _playlists.delete(id);
    final order = ((_misc.get('playlist_order') as List?)?.cast<String>() ?? <String>[])..remove(id);
    await _misc.put('playlist_order', order);
    notifyListeners();
  }

  /// Adds songs, skipping ones already in the playlist. Returns how many were added.
  Future<int> addToPlaylist(String id, List<Item> items) async {
    final p = playlist(id);
    if (p == null) return 0;
    final have = p.items.map((e) => e.id).toSet();
    var n = 0;
    for (final i in items) {
      if (have.add(i.id)) {
        p.items.add(i);
        n++;
      }
    }
    await savePlaylist(p);
    return n;
  }

  Future<void> removeFromPlaylist(String id, int index) async {
    final p = playlist(id);
    if (p == null || index < 0 || index >= p.items.length) return;
    p.items.removeAt(index);
    await savePlaylist(p);
  }

  Future<void> reorderPlaylistItem(String id, int from, int to) async {
    final p = playlist(id);
    if (p == null) return;
    final it = p.items.removeAt(from);
    p.items.insert(to.clamp(0, p.items.length), it);
    await savePlaylist(p);
  }

  Future<void> reorderPlaylists(int from, int to) async {
    final ids = playlists.map((p) => p.id).toList();
    final id = ids.removeAt(from);
    ids.insert(to.clamp(0, ids.length), id);
    await _misc.put('playlist_order', ids);
    notifyListeners();
  }

  // ── recently used playlists (1.4.5: Home → "Your playlists") ──
  /// When each playlist was last played from Home or its own page (ms).
  Map<String, int> get playlistPlayed {
    final m = _misc.get('playlist_played');
    if (m is! Map) return const {};
    return {for (final e in m.entries) if (e.value is int) '${e.key}': e.value as int};
  }

  Future<void> notePlaylistPlayed(String id, {int? at}) async {
    final m = {...playlistPlayed, id: at ?? DateTime.now().millisecondsSinceEpoch};
    // keep it small: the 200 most recent
    if (m.length > 200) {
      final keep = (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(200);
      m
        ..clear()
        ..addEntries(keep);
    }
    await _misc.put('playlist_played', m);
    notifyListeners();
  }

  /// Most recent of "edited" and "played", for sorting.
  int playlistRecency(LocalPlaylist p, [Map<String, int>? played]) {
    final pl = (played ?? playlistPlayed)[p.id] ?? 0;
    final ed = p.updated.millisecondsSinceEpoch;
    return pl > ed ? pl : ed;
  }

  // ── history ──
  List<HistoryEntry> get history {
    final l = _history.values.map((v) => jsonDecode(v as String) as Map).toList()..sort((a, b) => (b['at'] as int).compareTo(a['at'] as int));
    return l.map((m) => HistoryEntry(Item.fromJson(m['item'] as Map), DateTime.fromMillisecondsSinceEpoch(m['at'] as int))).toList();
  }

  Future<void> addHistory(Item it) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _history.put(it.id, jsonEncode({'item': it.toJson(), 'at': now}));
    if (_history.length > 500) {
      final oldest = history.last;
      await _history.delete(oldest.item.id);
    }
    notifyListeners();
  }

  Future<void> removeHistory(String id) async {
    await _history.delete(id);
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await _history.clear();
    notifyListeners();
  }

  // ── search history ──
  List<String> get searches => ((_misc.get('searches') as List?) ?? const []).cast<String>();
  Future<void> addSearch(String q) async {
    q = q.trim();
    if (q.isEmpty) return;
    final l = [q, ...searches.where((s) => s.toLowerCase() != q.toLowerCase())].take(20).toList();
    await _misc.put('searches', l);
    notifyListeners();
  }

  Future<void> removeSearch(String q) async {
    await _misc.put('searches', searches.where((s) => s != q).toList());
    notifyListeners();
  }

  Future<void> clearSearches() async {
    await _misc.put('searches', <String>[]);
    await _misc.put('recentItems', <String>[]);
    notifyListeners();
  }

  /// Songs/albums/artists opened from search ("Recent searches" with pictures).
  List<Item> get recentItems => ((_misc.get('recentItems') as List?) ?? const []).cast<String>().map(Item.decode).toList();
  Future<void> addRecentItem(Item it) async {
    final l = [it, ...recentItems.where((x) => x.id != it.id)].take(20).map((x) => x.encode()).toList();
    await _misc.put('recentItems', l);
    notifyListeners();
  }

  Future<void> removeRecentItem(String id) async {
    await _misc.put('recentItems', recentItems.where((x) => x.id != id).map((x) => x.encode()).toList());
    notifyListeners();
  }

  // ── podcasts ──
  /// "Episodes for Later": episodes saved to listen to later, newest first.
  List<Item> get laterEpisodes => ((_misc.get('later') as List?) ?? const []).cast<String>().map(Item.decode).toList();
  bool isLater(String id) => laterEpisodes.any((e) => e.id == id);
  Future<void> setLater(Item ep, bool later) async {
    final rest = laterEpisodes.where((e) => e.id != ep.id);
    await _misc.put('later', [if (later) ep, ...rest].map((x) => x.encode()).toList());
    notifyListeners();
  }

  /// Podcast shows saved to the library.
  List<Item> get savedPodcasts => ((_misc.get('podcasts') as List?) ?? const []).cast<String>().map(Item.decode).toList();
  bool isPodcastSaved(String id) => savedPodcasts.any((e) => e.id == id);
  Future<void> setPodcastSaved(Item show, bool saved) async {
    final rest = savedPodcasts.where((e) => e.id != show.id);
    await _misc.put('podcasts', [if (saved) show, ...rest].map((x) => x.encode()).toList());
    notifyListeners();
  }

  // ── downloads ──
  List<DownloadRecord> get downloads =>
      _downloads.values.map((v) => DownloadRecord.fromJson(jsonDecode(v as String) as Map)).toList()..sort((a, b) => b.at.compareTo(a.at));
  DownloadRecord? download(String id) {
    final v = _downloads.get(id);
    return v == null ? null : DownloadRecord.fromJson(jsonDecode(v as String) as Map);
  }

  bool isDownloaded(String id) => _downloads.containsKey(id);
  Future<void> putDownload(DownloadRecord r) async {
    await _downloads.put(r.item.id, jsonEncode(r.toJson()));
    notifyListeners();
  }

  Future<void> removeDownloadRecord(String id) async {
    await _downloads.delete(id);
    notifyListeners();
  }

  // ── local device music ──
  List<Item> get localTracks =>
      _local.values.map((v) => Item.decode(v as String)).toList()..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  Future<void> setLocalTracks(List<Item> items) async {
    await _local.clear();
    await _local.putAll({for (final i in items) i.id: i.encode()});
    notifyListeners();
  }

  Future<void> addLocalTracks(List<Item> items) async {
    await _local.putAll({for (final i in items) i.id: i.encode()});
    notifyListeners();
  }

  Future<void> removeLocalTrack(String id) async {
    await _local.delete(id);
    notifyListeners();
  }

  // ── misc key/value ──
  dynamic get(String k) => _misc.get(k);
  Future<void> put(String k, dynamic v) async {
    await _misc.put(k, v);
    notifyListeners();
  }
}
