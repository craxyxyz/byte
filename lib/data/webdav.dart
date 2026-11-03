import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:xml/xml.dart';

import '../core/models.dart';
import '../core/net.dart';

/// One entry in a WebDAV folder.
class DavEntry {
  final String name;
  final Uri url;
  final bool folder;
  final int? size;
  const DavEntry(this.name, this.url, this.folder, {this.size});
  bool get isAudio => !folder && WebDav.audioExt.any((e) => name.toLowerCase().endsWith('.$e'));
}

class DavProblem implements Exception {
  final String message;
  const DavProblem(this.message);
  @override
  String toString() => message;
}

/// Your own music server over WebDAV (Nextcloud, ownCloud, Synology / QNAP
/// NAS, a router's USB share, rclone serve webdav…). Byte lists the folders and
/// streams the files straight from your server; nothing goes anywhere else.
class WebDav extends ChangeNotifier {
  final Net net;
  Box? _b;
  WebDav(this.net);

  static const audioExt = ['mp3', 'm4a', 'aac', 'flac', 'wav', 'ogg', 'oga', 'opus', 'wma', 'alac', 'aiff', 'aif', 'webm', 'mka'];

  /// The player asks this for the login header of a `dav:` song.
  static Map<String, String> Function(Uri url)? headersFor;

  Future<void> open() async {
    _b = await Hive.openBox('own_server_private');
    headersFor = (u) => isOwn(u) ? authHeaders : const {};
  }

  String get url => (_b?.get('url') as String?) ?? '';
  String get user => (_b?.get('user') as String?) ?? '';
  String get _pass => (_b?.get('pass') as String?) ?? '';
  bool get configured => url.isNotEmpty;

  Map<String, String> get authHeaders => user.isEmpty && _pass.isEmpty ? const {} : {'Authorization': 'Basic ${base64.encode(utf8.encode('$user:$_pass'))}'};

  bool isOwn(Uri u) {
    final base = Uri.tryParse(url);
    return base != null && base.host == u.host && base.port == u.port && base.scheme == u.scheme;
  }

  /// Checks the server answers, then remembers it.
  Future<List<DavEntry>> connect(String serverUrl, String user, String password) async {
    var u = serverUrl.trim();
    if (!u.startsWith('http://') && !u.startsWith('https://')) u = 'https://$u';
    if (!u.endsWith('/')) u = '$u/';
    final base = Uri.parse(u);
    final auth = user.isEmpty && password.isEmpty ? <String, String>{} : {'Authorization': 'Basic ${base64.encode(utf8.encode('$user:$password'))}'};
    final list = await _propfind(base, auth);
    await _b?.put('url', u);
    await _b?.put('user', user);
    await _b?.put('pass', password);
    notifyListeners();
    return list;
  }

  Future<void> forget() async {
    await _b?.clear();
    notifyListeners();
  }

  Future<List<DavEntry>> list([Uri? folder]) => _propfind(folder ?? Uri.parse(url), authHeaders);

  Future<List<DavEntry>> _propfind(Uri folder, Map<String, String> auth) async {
    const body = '<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:resourcetype/><d:getcontentlength/><d:getcontenttype/></d:prop></d:propfind>';
    final NetResponse r;
    try {
      r = await net.send(
        NetRequest('PROPFIND', folder, headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8', ...auth}, body: utf8.encode(body)),
        timeout: const Duration(seconds: 20),
      );
    } catch (e) {
      throw DavProblem('Couldn\'t reach the server. Check the address and your internet. ($e)'.replaceAll(RegExp(r'\(.*\)$'), '').trim());
    }
    if (r.status == 401 || r.status == 403) throw const DavProblem('The server said the user name or password is wrong');
    if (r.status == 404) throw const DavProblem('That folder isn\'t on the server');
    if (r.status != 207 && !r.ok) throw DavProblem('The server answered ${r.status}. Is it a WebDAV address?');
    return parseMultistatus(r.text, folder);
  }

  /// Parses a PROPFIND answer; the folder itself is left out. Folders first, then A–Z.
  static List<DavEntry> parseMultistatus(String xmlText, Uri folder) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xmlText);
    } catch (_) {
      throw const DavProblem('The server\'s answer wasn\'t WebDAV');
    }
    final out = <DavEntry>[];
    String norm(String p) => Uri.decodeFull(p).replaceAll(RegExp(r'/+$'), '');
    for (final resp in doc.findAllElements('response', namespace: 'DAV:')) {
      final href = resp.findElements('href', namespace: 'DAV:').firstOrNull?.innerText.trim();
      if (href == null || href.isEmpty) continue;
      final u = folder.resolve(href);
      if (norm(u.path) == norm(folder.path)) continue;
      final prop = resp.findAllElements('prop', namespace: 'DAV:').firstOrNull;
      final isFolder = prop?.findAllElements('collection', namespace: 'DAV:').isNotEmpty ?? href.endsWith('/');
      final segs = u.pathSegments.where((s) => s.isNotEmpty).toList();
      final display = prop?.findElements('displayname', namespace: 'DAV:').firstOrNull?.innerText.trim();
      final name = (display != null && display.isNotEmpty) ? display : (segs.isEmpty ? href : segs.last);
      final size = int.tryParse(prop?.findElements('getcontentlength', namespace: 'DAV:').firstOrNull?.innerText.trim() ?? '');
      out.add(DavEntry(name, u, isFolder, size: size));
    }
    out.sort((a, b) => a.folder == b.folder ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : (a.folder ? -1 : 1));
    return out;
  }

  /// A server file as a Byte song: "Artist - Title.mp3" names are split; the
  /// folder name is used as the album.
  static Item itemFor(DavEntry e, {String? folderName}) {
    var base = e.name.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,5}$'), '');
    base = base.replaceFirst(RegExp(r'^\d{1,3}[\s._-]+'), ''); // "01 - " track numbers
    String title = base, artist = '';
    final m = RegExp(r'^(.+?)\s+[-–]\s+(.+)$').firstMatch(base);
    if (m != null) {
      artist = m.group(1)!.trim();
      title = m.group(2)!.trim();
    }
    return Item(
      kind: ItemKind.song,
      id: 'dav:${e.url}',
      title: title,
      artists: artist.isEmpty ? const [] : [ArtistRef(artist)],
      album: folderName,
      subtitle: folderName,
    );
  }
}
