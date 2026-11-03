import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'smb_real_stub.dart' if (dart.library.io) 'smb_real_io.dart';

import '../core/models.dart';
import 'webdav.dart';

/// One entry in an SMB folder (a Windows share, a NAS, a router's USB disk).
class SmbEntry {
  final String name;
  final String path; // /share/folder/file.flac
  final bool folder;
  final int? size;
  const SmbEntry(this.name, this.path, this.folder, {this.size});
  bool get isAudio => !folder && WebDav.audioExt.any((e) => name.toLowerCase().endsWith('.$e'));
}

class SmbProblem implements Exception {
  final String message;
  const SmbProblem(this.message);
  @override
  String toString() => message;
}

/// What Byte needs from an SMB connection (a real one, or a fake in tests).
abstract class SmbBackend {
  Future<List<SmbEntry>> shares();
  Future<List<SmbEntry>> list(String path);
  Future<int> length(String path);
  Future<Stream<List<int>>> read(String path, int start, int endExclusive);
  Future<void> close();
}

class SmbSource extends ChangeNotifier {
  Box? _b;
  SmbBackend? _conn;
  final Future<SmbBackend> Function(String host, String user, String pass, String domain) connector;
  SmbSource({Future<SmbBackend> Function(String host, String user, String pass, String domain)? connector})
    : connector = connector ?? _connect;

  static Future<SmbBackend> _connect(String host, String user, String pass, String domain) => connectSmb(host, user, pass, domain);

  static const prefix = 'smb:';

  Future<void> open() async => _b = await Hive.openBox('smb_private');

  String get host => (_b?.get('host') as String?) ?? '';
  String get user => (_b?.get('user') as String?) ?? '';
  String get domain => (_b?.get('domain') as String?) ?? '';
  String get _pass => (_b?.get('pass') as String?) ?? '';
  bool get configured => host.isNotEmpty;

  Future<SmbBackend> _get() async {
    if (_conn != null) return _conn!;
    if (!configured) throw const SmbProblem('No SMB server yet');
    try {
      _conn = await connector(host, user, _pass, domain).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const SmbProblem('The server didn\'t answer. Same Wi-Fi?');
    } catch (e) {
      throw SmbProblem(_friendly(e));
    }
    return _conn!;
  }

  static String _friendly(Object e) {
    final s = '$e'.toLowerCase();
    if (s.contains('logon') || s.contains('password') || s.contains('access') || s.contains('auth')) return 'The user name or password is wrong';
    if (s.contains('refused') || s.contains('host') || s.contains('socket')) return 'Couldn\'t reach the server. Same Wi-Fi?';
    return 'Couldn\'t open the share';
  }

  /// Checks the server answers, then remembers it.
  Future<List<SmbEntry>> connect(String host, String user, String password, {String domain = ''}) async {
    var h = host.trim().replaceFirst(RegExp(r'^smb://'), '').replaceFirst(RegExp(r'^\\\\'), '');
    h = h.split(RegExp(r'[/\\]')).first;
    if (h.isEmpty) throw const SmbProblem('Type the server\'s name or address');
    await _conn?.close();
    _conn = null;
    final SmbBackend c;
    try {
      c = await connector(h, user, password, domain).timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const SmbProblem('The server didn\'t answer. Same Wi-Fi?');
    } catch (e) {
      throw SmbProblem(_friendly(e));
    }
    final shares = await c.shares();
    _conn = c;
    await _b?.put('host', h);
    await _b?.put('user', user);
    await _b?.put('pass', password);
    await _b?.put('domain', domain);
    notifyListeners();
    return shares;
  }

  Future<void> forget() async {
    await _conn?.close();
    _conn = null;
    await _b?.clear();
    notifyListeners();
  }

  Future<List<SmbEntry>> shares() async => (await _get()).shares();
  Future<List<SmbEntry>> list(String path) async {
    try {
      return await (await _get()).list(path);
    } catch (e) {
      _conn = null;
      throw e is SmbProblem ? e : SmbProblem(_friendly(e));
    }
  }

  Future<int> length(String path) async => (await _get()).length(path);
  Future<Stream<List<int>>> read(String path, int start, int endExclusive) async => (await _get()).read(path, start, endExclusive);

  /// A share file as a Byte song ("Artist - Title.flac" names are split; the folder is the album).
  static Item itemFor(SmbEntry e) {
    final segs = e.path.split('/').where((s) => s.isNotEmpty).toList();
    final album = segs.length >= 2 ? segs[segs.length - 2] : null;
    var base = e.name.replaceFirst(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '');
    base = base.replaceFirst(RegExp(r'^\d{1,3}\s*[-.]\s*'), '');
    String title = base;
    List<ArtistRef> artists = const [];
    final dash = base.indexOf(' - ');
    if (dash > 0) {
      artists = [ArtistRef(base.substring(0, dash).trim())];
      title = base.substring(dash + 3).trim();
    }
    return Item(kind: ItemKind.song, id: '$prefix${e.path}', title: title, artists: artists, album: album, subtitle: 'SMB');
  }

  static String? pathOf(String itemId) => itemId.startsWith(prefix) ? itemId.substring(prefix.length) : null;
}
