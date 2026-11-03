import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/innertube.dart';
import '../core/models.dart';
import 'library.dart';

/// One signed-in YouTube Music account kept on this phone.
class SavedAccount {
  final String key;
  String name;
  String? email;
  String? handle;
  String? photo;
  String cookie;
  SavedAccount({required this.key, required this.name, this.email, this.handle, this.photo, required this.cookie});
  String get initial => name.trim().isEmpty ? '?' : String.fromCharCode(name.trim().runes.first).toUpperCase();
  Map<String, dynamic> toJson() => {'k': key, 'n': name, 'e': email, 'h': handle, 'p': photo, 'c': cookie};
  factory SavedAccount.fromJson(Map m) => SavedAccount(
    key: m['k'] as String,
    name: m['n'] as String? ?? '',
    email: m['e'] as String?,
    handle: m['h'] as String?,
    photo: m['p'] as String?,
    cookie: m['c'] as String? ?? '',
  );
}

/// YouTube Music sign-in (cookies from the in-app Google login page), several
/// accounts with quick switching, and the automatic copy of the active
/// account's playlists into Byte's library. Cookies stay in the phone's
/// secure storage and only ever go to YouTube.
class Account extends ChangeNotifier {
  final InnerTube yt;
  final Library library;
  final FlutterSecureStorage _secure;
  final List<SavedAccount> accounts = [];
  String? activeKey;
  bool syncing = false;
  String? syncMessage;
  DateTime? lastSync;
  Account(this.yt, this.library, {FlutterSecureStorage? secure}) : _secure = secure ?? const FlutterSecureStorage();

  bool get signedIn => yt.session != null;
  SavedAccount? get active => accounts.where((a) => a.key == activeKey).firstOrNull;
  String? get name => active?.name;
  String? get email => active?.email;

  Future<void> _persist() async {
    await _secure.write(key: 'yt_accounts', value: jsonEncode(accounts.map((a) => a.toJson()).toList()));
    if (activeKey == null) {
      await _secure.delete(key: 'yt_active');
    } else {
      await _secure.write(key: 'yt_active', value: activeKey);
    }
  }

  Future<void> restore() async {
    try {
      final raw = await _secure.read(key: 'yt_accounts');
      if (raw != null && raw.isNotEmpty) {
        accounts
          ..clear()
          ..addAll((jsonDecode(raw) as List).map((e) => SavedAccount.fromJson(e as Map)));
        activeKey = await _secure.read(key: 'yt_active');
      } else {
        // Byte 1.0 kept a single account under these keys.
        final c = await _secure.read(key: 'yt_cookie');
        if (c != null && c.isNotEmpty) {
          final n = await _secure.read(key: 'yt_name') ?? 'Music account';
          final a = SavedAccount(key: _keyFor(c, null, n), name: n, cookie: c);
          accounts.add(a);
          activeKey = a.key;
          await _persist();
          await _secure.delete(key: 'yt_cookie');
          await _secure.delete(key: 'yt_name');
        }
      }
      final a = active ?? accounts.firstOrNull;
      activeKey = a?.key;
      yt.session = a == null ? null : YtSession(a.cookie);
      final t = library.get('account_last_sync');
      if (t is int) lastSync = DateTime.fromMillisecondsSinceEpoch(t);
    } catch (_) {}
    notifyListeners();
  }

  static String _keyFor(String cookie, String? email, String name) {
    if (email != null && email.isNotEmpty) return email.toLowerCase();
    final sid = RegExp(r'(?:^|;\s*)(?:__Secure-3PAPISID|SAPISID)=([^;]+)').firstMatch(cookie)?.group(1) ?? name;
    return sha1.convert(utf8.encode(sid)).toString().substring(0, 16);
  }

  /// Called by the login page once Google has signed the user in.
  Future<bool> signInWithCookies(String cookie) async {
    final s = YtSession(cookie);
    if (!s.looksValid) return false;
    final previous = yt.session;
    yt.session = s;
    final info = await yt.accountInfo();
    final name = info?.name ?? await yt.accountName() ?? 'Music account';
    final key = _keyFor(cookie, info?.email, name);
    final existing = accounts.where((a) => a.key == key).firstOrNull;
    if (existing != null) {
      existing
        ..cookie = cookie
        ..name = name
        ..email = info?.email ?? existing.email
        ..handle = info?.handle ?? existing.handle
        ..photo = info?.photo ?? existing.photo;
    } else {
      accounts.add(SavedAccount(key: key, name: name, email: info?.email, handle: info?.handle, photo: info?.photo, cookie: cookie));
    }
    final switched = activeKey != key && previous != null;
    activeKey = key;
    await _persist();
    if (switched) await _dropAccountPlaylists();
    notifyListeners();
    sync(); // playlists appear automatically
    return true;
  }

  /// Make another saved account the active one (its playlists replace the old ones).
  Future<void> switchTo(String key) async {
    final a = accounts.where((x) => x.key == key).firstOrNull;
    if (a == null || key == activeKey) return;
    activeKey = key;
    yt.session = YtSession(a.cookie);
    await _persist();
    await _dropAccountPlaylists();
    lastSync = null;
    notifyListeners();
    sync();
  }

  /// Forget one account on this phone.
  Future<void> remove(String key, {bool removePlaylists = true}) async {
    final wasActive = key == activeKey;
    accounts.removeWhere((a) => a.key == key);
    if (wasActive) {
      final next = accounts.firstOrNull;
      activeKey = next?.key;
      yt.session = next == null ? null : YtSession(next.cookie);
      if (removePlaylists) await _dropAccountPlaylists();
      if (next != null) sync();
    }
    await _persist();
    notifyListeners();
  }

  /// Sign the active account out (kept for the old settings flow).
  Future<void> signOut({bool removePlaylists = false}) async {
    final k = activeKey;
    if (k != null) {
      await remove(k, removePlaylists: removePlaylists);
    } else {
      yt.session = null;
      notifyListeners();
    }
  }

  Future<void> _dropAccountPlaylists() async {
    for (final p in library.playlists.where((p) => p.source?.startsWith('account:') == true).toList()) {
      await library.deletePlaylist(p.id);
    }
  }

  /// Fill in name/e-mail for accounts saved before Byte knew them.
  Future<void> refreshInfo() async {
    final a = active;
    if (a == null) return;
    final info = await yt.accountInfo();
    if (info == null) return;
    a
      ..name = info.name.isEmpty ? a.name : info.name
      ..email = info.email ?? a.email
      ..handle = info.handle ?? a.handle
      ..photo = info.photo ?? a.photo;
    await _persist();
    notifyListeners();
  }

  /// Sync on app start at most every 6 hours.
  Future<void> maybeAutoSync() async {
    if (!signedIn) return;
    if (active?.email == null) refreshInfo();
    if (lastSync != null && DateTime.now().difference(lastSync!) < const Duration(hours: 6)) return;
    await sync();
  }

  Future<void> sync() async {
    if (!signedIn || syncing) return;
    syncing = true;
    syncMessage = 'Getting your playlists…';
    notifyListeners();
    final forKey = activeKey;
    try {
      final lists = await yt.libraryPlaylists();
      // Liked songs live in the special "LM" playlist.
      final all = [const Item(kind: ItemKind.playlist, id: 'VLLM', title: 'Liked songs (account)'), ...lists.where((l) => l.id != 'VLLM' && l.id != 'VLSE')];
      var done = 0;
      for (final pl in all) {
        if (forKey != activeKey) break; // switched account meanwhile
        try {
          final page = await yt.playlist(pl.id);
          final tracks = page.tracks.where((t) => t.isPlayable).toList();
          if (pl.id == 'VLLM') {
            // The account's liked songs also become Byte likes (newest on top).
            final base = DateTime.now().millisecondsSinceEpoch;
            var k = 0;
            for (final it in tracks.reversed) {
              k++;
              if (!library.isLiked(it.id)) await library.setLiked(it, true, at: base + k);
            }
          }
          final src = 'account:${pl.id}';
          final existing = library.playlistBySource(src);
          if (existing != null) {
            existing.items
              ..clear()
              ..addAll(tracks);
            existing.cover = page.header.thumb ?? pl.thumb;
            await library.savePlaylist(existing);
          } else if (tracks.isNotEmpty) {
            await library.createPlaylist(pl.title, items: tracks, source: src, cover: page.header.thumb ?? pl.thumb);
          }
        } catch (_) {}
        done++;
        syncMessage = 'Synced $done of ${all.length} playlists';
        notifyListeners();
      }
      lastSync = DateTime.now();
      await library.put('account_last_sync', lastSync!.millisecondsSinceEpoch);
      syncMessage = 'Synced ${all.length} playlists';
    } catch (e) {
      syncMessage = 'Sync failed — check your internet and try again';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }
}
