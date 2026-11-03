import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../lyrics/lrc.dart';

/// Audio quality a source states for a song (only what it really says).
class SourceFormat {
  final String? codec; // flac, alac, aac, mp3, opus, eac3-joc…
  final int? bitDepth;
  final int? sampleRate;
  final int? channels;
  final int? bitrate;
  const SourceFormat({this.codec, this.bitDepth, this.sampleRate, this.channels, this.bitrate});

  static const _lossless = {'flac', 'alac', 'wav', 'aiff', 'aif', 'pcm', 'ape', 'wv'};
  static const _atmos = {'eac3-joc', 'ec-3-joc', 'ac4', 'ac-4', 'truehd-atmos', 'atmos'};

  bool get lossless => codec != null && _lossless.contains(codec!.toLowerCase());
  bool get hiRes => lossless && ((bitDepth ?? 16) > 16 || (sampleRate ?? 44100) > 48000);
  bool get atmos => codec != null && _atmos.contains(codec!.toLowerCase());

  /// "Lossless", "Hi-Res Lossless", "Dolby Atmos" or null.
  String? get badge => atmos ? 'Spatial surround' : (hiRes ? 'Hi-Res Lossless' : (lossless ? 'Lossless' : null));

  /// "24-bit/96 kHz" (only what is known).
  String? get detail {
    if (sampleRate == null && bitDepth == null) return null;
    final khz = sampleRate == null ? null : (sampleRate! % 1000 == 0 ? '${sampleRate! ~/ 1000}' : (sampleRate! / 1000).toStringAsFixed(1));
    return [if (bitDepth != null) '$bitDepth-bit', if (khz != null) '$khz kHz'].join('/');
  }

  /// "Lossless · 24-bit/96 kHz" — null for lossy files and streams.
  String? get label {
    final b = badge;
    if (b == null) return null;
    final d = lossless ? detail : null;
    return d == null ? b : '$b · $d';
  }

  factory SourceFormat.fromJson(Map m) => SourceFormat(
    codec: (m['codec'] ?? m['format']) as String?,
    bitDepth: (m['bitDepth'] as num?)?.toInt(),
    sampleRate: (m['sampleRate'] as num?)?.toInt(),
    channels: (m['channels'] as num?)?.toInt(),
    bitrate: (m['bitrate'] as num?)?.toInt(),
  );

  /// From a file name: `.flac` → lossless, etc.
  static SourceFormat? fromPath(String p) {
    final ext = p.split('?').first.split('.').last.toLowerCase();
    const map = {'flac': 'flac', 'alac': 'alac', 'wav': 'wav', 'aiff': 'aiff', 'aif': 'aiff', 'mp3': 'mp3', 'm4a': 'aac', 'aac': 'aac', 'ogg': 'vorbis', 'opus': 'opus', 'ec3': 'eac3-joc'};
    final c = map[ext];
    return c == null ? null : SourceFormat(codec: c);
  }
}

/// A source someone added to Byte by link: a small web service (their own
/// server, a friend's NAS…) that answers Byte's addon protocol.
class Addon {
  final String id;
  final String name;
  final Uri base;
  final String? token;
  final List<String> resources; // search, stream, lyrics
  final String? description;
  final bool enabled;
  const Addon({required this.id, required this.name, required this.base, this.token, this.resources = const ['search', 'stream'], this.description, this.enabled = true});

  bool can(String r) => resources.contains(r);
  Addon copyWith({bool? enabled, String? name}) =>
      Addon(id: id, name: name ?? this.name, base: base, token: token, resources: resources, description: description, enabled: enabled ?? this.enabled);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'base': base.toString(), 'token': token, 'res': resources, 'desc': description, 'on': enabled};
  factory Addon.fromJson(Map m) => Addon(
    id: m['id'] as String,
    name: m['name'] as String? ?? 'Addon',
    base: Uri.parse(m['base'] as String),
    token: m['token'] as String?,
    resources: ((m['res'] as List?) ?? const ['search', 'stream']).cast<String>(),
    description: m['desc'] as String?,
    enabled: m['on'] != false,
  );
}

class AddonProblem implements Exception {
  final String message;
  const AddonProblem(this.message);
  @override
  String toString() => message;
}

/// One addon's answer to a search.
class AddonResult {
  final Addon addon;
  final List<Item> items;
  final String? error;
  const AddonResult(this.addon, this.items, {this.error});
}

/// What playing an addon song needs: where the audio is and what it is.
class AddonStream {
  final Uri url;
  final Map<String, String> headers;
  final SourceFormat format;
  const AddonStream(this.url, this.headers, this.format);
}

/// Addons: add by link, turn on/off, reorder, remove; search all at once;
/// play and fetch lyrics through them. Byte ships none; you add your own.
///
/// The protocol (all JSON over HTTPS or your LAN):
///   GET  `base/manifest.json` → {id, name, version, resources:[search,stream,lyrics], description}
///   GET  `base/search?q=…` → {tracks:[{id,title,artist,album,duration,artwork,codec,bitDepth,sampleRate}]}
///   GET  `base/stream/ID` → {url, codec, bitDepth, sampleRate, channels}
///   GET  `base/lyrics?title=&artist=&duration=` → {synced:"[mm:ss.xx] …", plain:"…"}
/// An optional key is sent as `Authorization: Bearer KEY`.
class Addons extends ChangeNotifier {
  final Net net;
  Box? _b;
  List<Addon> _list = [];
  final Map<String, SourceFormat> formats = {};

  /// Settings → Dolby Atmos (on and the output can play it).
  bool Function() preferAtmos = () => false;
  Addons(this.net);

  static const itemPrefix = 'addon:';

  Future<void> open() async {
    _b = await Hive.openBox('addons_private');
    final raw = _b?.get('list') as String?;
    if (raw != null) {
      try {
        _list = [for (final m in jsonDecode(raw) as List) Addon.fromJson(m as Map)];
      } catch (_) {}
    }
  }

  List<Addon> get all => List.unmodifiable(_list);
  List<Addon> get enabled => _list.where((a) => a.enabled).toList();
  Addon? byId(String id) => _list.where((a) => a.id == id).firstOrNull;

  Future<void> _save() async {
    await _b?.put('list', jsonEncode([for (final a in _list) a.toJson()]));
    notifyListeners();
  }

  Map<String, String> _auth(String? token) => token == null || token.isEmpty ? const {} : {'Authorization': 'Bearer $token'};

  static Uri normalizeBase(String link) {
    var s = link.trim();
    if (s.isEmpty) throw const AddonProblem('Paste the addon\'s link');
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'https://$s';
    s = s.replaceFirst(RegExp(r'/manifest\.json$'), '');
    if (s.endsWith('/')) s = s.substring(0, s.length - 1);
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) throw const AddonProblem('That doesn\'t look like a link');
    return u;
  }

  /// A relative link from the addon (art, files) resolved under its folder.
  static Uri resolveUnder(Uri base, String ref) => base.replace(path: base.path.endsWith('/') ? base.path : '${base.path}/').resolve(ref);

  Uri _at(Uri base, String path, [Map<String, String>? q]) {
    final p = '${base.path}/$path'.replaceAll(RegExp(r'/+'), '/');
    return base.replace(path: p, queryParameters: q);
  }

  /// Reads the addon's manifest and adds it.
  Future<Addon> add(String link, {String? token}) async {
    final base = normalizeBase(link);
    final NetResponse r;
    try {
      r = await net.get(_at(base, 'manifest.json'), headers: _auth(token), timeout: const Duration(seconds: 12));
    } catch (_) {
      throw const AddonProblem('Couldn\'t reach that address');
    }
    if (r.status == 401 || r.status == 403) throw const AddonProblem('The addon wants a key');
    if (!r.ok) throw AddonProblem('The addon answered ${r.status}');
    final Map m;
    try {
      m = r.json as Map;
    } catch (_) {
      throw const AddonProblem('That address isn\'t a Byte addon');
    }
    final res = ((m['resources'] as List?) ?? const []).whereType<String>().where((x) => const {'search', 'stream', 'lyrics'}.contains(x)).toList();
    if (res.isEmpty) throw const AddonProblem('That addon offers nothing Byte can use');
    final id = ((m['id'] as String?)?.trim().isNotEmpty == true ? m['id'] as String : base.host).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final a = Addon(id: id, name: (m['name'] as String?)?.trim().isNotEmpty == true ? m['name'] as String : base.host, base: base, token: token, resources: res, description: m['description'] as String?);
    _list.removeWhere((x) => x.id == id);
    _list.add(a);
    await _save();
    return a;
  }

  Future<void> remove(String id) async {
    _list.removeWhere((a) => a.id == id);
    await _save();
  }

  Future<void> setEnabled(String id, bool on) async {
    _list = [for (final a in _list) a.id == id ? a.copyWith(enabled: on) : a];
    await _save();
  }

  Future<void> move(int from, int to) async {
    if (from < 0 || from >= _list.length) return;
    final a = _list.removeAt(from);
    _list.insert(to.clamp(0, _list.length), a);
    await _save();
  }

  static String itemId(Addon a, String trackId) => '$itemPrefix${a.id}:$trackId';
  static (String, String)? parseId(String id) {
    if (!id.startsWith(itemPrefix)) return null;
    final rest = id.substring(itemPrefix.length);
    final i = rest.indexOf(':');
    if (i <= 0) return null;
    return (rest.substring(0, i), rest.substring(i + 1));
  }

  /// Searches every turned-on addon at once; each answers on its own.
  Future<List<AddonResult>> searchAll(String q) async {
    final list = enabled.where((a) => a.can('search')).toList();
    return Future.wait(list.map((a) => search(a, q)));
  }

  Future<AddonResult> search(Addon a, String q) async {
    try {
      final r = await net.get(_at(a.base, 'search', {'q': q}), headers: _auth(a.token), timeout: const Duration(seconds: 12));
      if (!r.ok) return AddonResult(a, const [], error: 'Answered ${r.status}');
      final tracks = ((r.json as Map)['tracks'] as List?) ?? const [];
      final out = <Item>[];
      for (final t in tracks.whereType<Map>()) {
        final id = '${t['id'] ?? ''}';
        if (id.isEmpty) continue;
        final art = t['artwork'] as String?;
        final iid = itemId(a, id);
        final f = SourceFormat.fromJson(t);
        if (f.codec != null) formats[iid] = f;
        out.add(
          Item(
            kind: ItemKind.song,
            id: iid,
            title: '${t['title'] ?? id}',
            artists: [
              for (final n in '${t['artist'] ?? ''}'.split(RegExp(r',\s*')).where((n) => n.trim().isNotEmpty)) ArtistRef(n.trim()),
            ],
            album: t['album'] as String?,
            durationSec: (t['duration'] as num?)?.round(),
            thumb: art == null ? null : resolveUnder(a.base, art).toString(),
            subtitle: a.name,
          ),
        );
      }
      return AddonResult(a, out);
    } catch (e) {
      return AddonResult(a, const [], error: 'Didn\'t answer');
    }
  }

  /// Where to play an addon song from.
  Future<AddonStream> stream(String itemId) async {
    final p = parseId(itemId);
    final a = p == null ? null : byId(p.$1);
    if (p == null || a == null) throw const AddonProblem('That addon was removed');
    // Settings → Dolby Atmos: ask for the Atmos version (the addon decides if it has one).
    final r = await net.get(
      _at(a.base, 'stream/${Uri.encodeComponent(p.$2)}', preferAtmos() ? const {'prefer': 'atmos'} : null),
      headers: _auth(a.token),
      timeout: const Duration(seconds: 15),
    );
    if (!r.ok) throw AddonProblem('${a.name} answered ${r.status}');
    final m = r.json as Map;
    final url = resolveUnder(a.base, '${m['url']}');
    final f = SourceFormat.fromJson(m);
    if (f.codec != null) formats[itemId] = f;
    // the key goes along only to the addon's own server
    final h = url.host == a.base.host ? _auth(a.token) : const <String, String>{};
    return AddonStream(url, h, f);
  }

  /// Lyrics from the first turned-on addon that has them.
  Future<(List<LyricLine>?, String?, String)?> lyrics(Item song) async {
    for (final a in enabled.where((a) => a.can('lyrics'))) {
      try {
        final r = await net.get(
          _at(a.base, 'lyrics', {'title': song.title, 'artist': song.artistLine, if (song.durationSec != null) 'duration': '${song.durationSec}'}),
          headers: _auth(a.token),
          timeout: const Duration(seconds: 10),
        );
        if (!r.ok) continue;
        final m = r.json as Map;
        final synced = m['synced'] as String?;
        if (synced != null && synced.trim().isNotEmpty) {
          final lines = parseLrc(synced);
          if (lines.isNotEmpty) return (lines, null, a.name);
        }
        final plain = m['plain'] as String?;
        if (plain != null && plain.trim().isNotEmpty) return (null, plain, a.name);
      } catch (_) {}
    }
    return null;
  }
}
