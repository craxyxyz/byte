import 'dart:convert';

import '../core/net.dart';
import 'playlist_import.dart';

// Byte © 2026 Apurba Laskar.
//
// Reading the signed-in person's OWN music library after they sign in on the
// music service's own web page inside Byte (no developer setup). Byte keeps
// the sign-in the web page gives to its own web player and asks the same
// library questions that web player asks: Liked Songs, saved playlists and
// their songs. Only titles/artists/albums are read; songs then play through
// Byte's usual matching, never from the service's own audio.

class SpotifyWebProblem implements Exception {
  final String message;
  final bool signedOut;
  const SpotifyWebProblem(this.message, {this.signedOut = false});
  @override
  String toString() => message;
}

class WebPlaylist {
  final String uri; // spotify:playlist:<id> or 'liked'
  final String name;
  final String? cover;
  final int count; // -1 = unknown
  final String owner;
  const WebPlaylist(this.uri, this.name, this.cover, this.count, this.owner);
  String get id => uri == 'liked' ? 'liked' : uri.split(':').last;
}

class SpotifyWebApi {
  final Net net;
  final Future<String> Function() token;
  SpotifyWebApi(this.net, this.token);

  static const pathfinder = 'https://api-partner.spotify.com/pathfinder/v2/query';
  static const v1 = 'https://api.spotify.com/v1';
  static const desktopUa = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

  /// The web player's own question ids (read from its script at run time;
  /// these are the ones seen on 2 Nov 2026, used if that read fails).
  static const fallbackHashes = {
    'fetchLibraryTracks': '087278b20b743578a6262c2b0b4bcd20d879c503cc359a2285baf083ef944240',
    'libraryV3': '390c78e5b951029bad359785e69b07b536a509c581cbcd0aded5e5067f187455',
    'fetchPlaylist': '21ea11a6ac75a5f3e01fd365d29c18e0a4a8b7dc09f89bbb5d73910190c6acaf',
    'profileAttributes': '08ffb4730af3746e04a8301396f20875dbbce10c75243803091a9274eacc8ac0',
  };
  Map<String, String> hashes = Map.of(fallbackHashes);
  bool _discovered = false;

  /// Finds the current question ids in the web player's script.
  static Map<String, String> hashesIn(String js) {
    final out = <String, String>{};
    for (final m in RegExp(r'"(\w+)","query","([0-9a-f]{64})"').allMatches(js)) {
      out[m.group(1)!] = m.group(2)!;
    }
    return out;
  }

  Future<void> discover() async {
    if (_discovered) return;
    _discovered = true;
    try {
      final home = await net.get(Uri.parse('https://open.spotify.com/'), headers: {'User-Agent': desktopUa});
      final scripts = RegExp(r'https://open\.spotifycdn\.com/cdn/build/web-player/web-player\.[0-9a-f]+\.js').allMatches(home.text).map((m) => m.group(0)!).toSet();
      for (final s in scripts.take(2)) {
        final r = await net.get(Uri.parse(s), headers: {'User-Agent': desktopUa}, timeout: const Duration(seconds: 30));
        if (r.ok) hashes.addAll(hashesIn(r.text));
      }
    } catch (_) {
      // keep the known ids
    }
  }

  Future<Map> query(String op, Map<String, Object?> vars, {bool retried = false}) async {
    final tok = await token();
    final body = jsonEncode({
      'variables': vars,
      'operationName': op,
      'extensions': {
        'persistedQuery': {'version': 1, 'sha256Hash': hashes[op] ?? fallbackHashes[op]},
      },
    });
    NetResponse r;
    for (var attempt = 0;; attempt++) {
      r = await net.send(
        NetRequest('POST', Uri.parse(pathfinder), headers: {
          'Authorization': 'Bearer $tok',
          'Content-Type': 'application/json;charset=UTF-8',
          'app-platform': 'WebPlayer',
          'Accept': 'application/json',
        }, body: utf8.encode(body)),
      );
      if ((r.status == 429 || r.status >= 500) && attempt < 3) {
        await Future<void>.delayed(Duration(seconds: attempt + 1));
        continue;
      }
      break;
    }
    if (r.status == 401) throw const SpotifyWebProblem('Signed out. Tap to connect again.', signedOut: true);
    Map? j;
    try {
      j = r.json as Map?;
    } catch (_) {}
    final errs = (j?['errors'] as List?) ?? const [];
    final notFound = errs.any((e) => '$e'.contains('PersistedQueryNotFound')) || r.status == 404;
    if (notFound && !retried) {
      _discovered = false;
      await discover();
      return query(op, vars, retried: true);
    }
    if (!r.ok || j == null || j['data'] == null) throw SpotifyWebProblem('The music service answered ${r.status}');
    return j['data'] as Map;
  }

  Future<Map> _v1(String url) async {
    final tok = await token();
    for (var attempt = 0; attempt < 4; attempt++) {
      final r = await net.get(Uri.parse(url), headers: {'Authorization': 'Bearer $tok'});
      if (r.ok) return r.json as Map;
      if (r.status == 401) throw const SpotifyWebProblem('Signed out. Tap to connect again.', signedOut: true);
      if (r.status == 429 || r.status >= 500) {
        await Future<void>.delayed(Duration(seconds: attempt + 1));
        continue;
      }
      throw SpotifyWebProblem('The music service answered ${r.status}');
    }
    throw const SpotifyWebProblem('The music service is busy. Byte will try again later.');
  }

  /// The signed-in person's name (null when the page was not signed in).
  Future<String?> me() async {
    try {
      final d = await query('profileAttributes', const {});
      final p = (d['me'] as Map?)?['profile'] as Map?;
      final n = p?['name'] ?? p?['username'];
      if (n != null && '$n'.isNotEmpty) return '$n';
    } on SpotifyWebProblem catch (e) {
      if (e.signedOut) rethrow;
    }
    try {
      final j = await _v1('$v1/me');
      return '${j['display_name'] ?? j['id']}';
    } on SpotifyWebProblem catch (e) {
      if (e.signedOut) rethrow;
      return null;
    }
  }

  static String? _img(Map? m) {
    if (m == null) return null;
    final items = (m['items'] as List?) ?? (m['sources'] != null ? [m] : const []);
    for (final i in items.whereType<Map>()) {
      final srcs = (i['sources'] as List?) ?? const [];
      for (final s in srcs.whereType<Map>()) {
        if (s['url'] != null) return '${s['url']}';
      }
    }
    return null;
  }

  /// One song from any of the web player's answers.
  static ExtTrack? trackFrom(Map? d) {
    if (d == null) return null;
    if (d['__typename'] != null && d['__typename'] != 'Track') return null;
    final name = d['name'];
    if (name == null || '$name'.isEmpty) return null;
    final artists = (((d['artists'] as Map?)?['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((a) => (a['profile'] as Map?)?['name'])
        .whereType<Object>()
        .join(', ');
    final album = (d['albumOfTrack'] as Map?)?['name'];
    final dur = ((d['duration'] ?? d['trackDuration']) as Map?)?['totalMilliseconds'];
    return ExtTrack('$name', artists, album: album == null ? null : '$album', durationMs: (dur as num?)?.toInt());
  }

  static ExtTrack? _v1Track(Map? t) {
    if (t == null || t['name'] == null || t['type'] == 'episode') return null;
    final artists = ((t['artists'] as List?) ?? const []).whereType<Map>().map((a) => a['name']).join(', ');
    return ExtTrack('${t['name']}', artists, album: (t['album'] as Map?)?['name'] as String?, durationMs: (t['duration_ms'] as num?)?.toInt());
  }

  /// Every Liked Song, newest first.
  Future<List<ExtTrack>> likedSongs({void Function(int done, int total)? onProgress}) async {
    await discover();
    final out = <ExtTrack>[];
    try {
      var offset = 0;
      while (true) {
        final d = await query('fetchLibraryTracks', {'offset': offset, 'limit': 50});
        final t = ((d['me'] as Map?)?['library'] as Map?)?['tracks'] as Map?;
        if (t == null) throw const SpotifyWebProblem('No library in the answer');
        final items = ((t['items'] as List?) ?? const []).whereType<Map>().toList();
        for (final it in items) {
          final tr = trackFrom(((it['track'] as Map?)?['data']) as Map?);
          if (tr != null) out.add(tr);
        }
        final total = (t['totalCount'] as num?)?.toInt() ?? out.length;
        offset += 50;
        onProgress?.call(out.length, total);
        if (items.isEmpty || offset >= total) break;
      }
      return out;
    } on SpotifyWebProblem catch (e) {
      if (e.signedOut || out.isNotEmpty) rethrow;
    }
    String? next = '$v1/me/tracks?limit=50';
    while (next != null) {
      final j = await _v1(next);
      for (final it in ((j['items'] as List?) ?? const []).whereType<Map>()) {
        final t = _v1Track(it['track'] as Map?);
        if (t != null) out.add(t);
      }
      onProgress?.call(out.length, (j['total'] as num?)?.toInt() ?? out.length);
      next = j['next'] as String?;
    }
    return out;
  }

  /// The person's saved playlists (their own and followed ones).
  Future<List<WebPlaylist>> playlists() async {
    await discover();
    final out = <WebPlaylist>[];
    try {
      var offset = 0;
      while (true) {
        final d = await query('libraryV3', {
          'filters': ['Playlists'],
          'order': null,
          'textFilter': '',
          'features': ['LIKED_SONGS', 'YOUR_EPISODES'],
          'limit': 50,
          'offset': offset,
          'flatten': true,
          'expandedFolders': <String>[],
          'folderUri': null,
          'includeFoldersWhenFlattening': true,
        });
        final lib = (d['me'] as Map?)?['libraryV3'] as Map?;
        if (lib == null) throw const SpotifyWebProblem('No library in the answer');
        final items = ((lib['items'] as List?) ?? const []).whereType<Map>().toList();
        for (final e in items) {
          final w = e['item'] as Map?;
          final data = w?['data'] as Map?;
          final uri = '${w?['_uri'] ?? data?['uri'] ?? ''}';
          if (data == null || !uri.startsWith('spotify:playlist:')) continue;
          final owner = ((data['ownerV2'] as Map?)?['data'] as Map?)?['name'];
          out.add(WebPlaylist(uri, '${data['name'] ?? 'Playlist'}', _img(data['images'] as Map?), -1, owner == null ? '' : '$owner'));
        }
        final total = (lib['totalCount'] as num?)?.toInt() ?? 0;
        offset += 50;
        if (items.isEmpty || offset >= total) break;
      }
      return out;
    } on SpotifyWebProblem catch (e) {
      if (e.signedOut || out.isNotEmpty) rethrow;
    }
    String? next = '$v1/me/playlists?limit=50';
    while (next != null) {
      final j = await _v1(next);
      for (final p in ((j['items'] as List?) ?? const []).whereType<Map>()) {
        final imgs = (p['images'] as List?) ?? const [];
        final tracks = (p['tracks'] ?? p['items']) as Map?;
        out.add(WebPlaylist('spotify:playlist:${p['id']}', '${p['name']}', imgs.isEmpty ? null : (imgs.first as Map)['url'] as String?, (tracks?['total'] as num?)?.toInt() ?? -1, '${(p['owner'] as Map?)?['display_name'] ?? ''}'));
      }
      next = j['next'] as String?;
    }
    return out;
  }

  /// Every song of one playlist.
  Future<List<ExtTrack>> playlistTracks(String uri, {void Function(int done, int total)? onProgress}) async {
    await discover();
    final out = <ExtTrack>[];
    try {
      var offset = 0;
      while (true) {
        final d = await query('fetchPlaylist', {'uri': uri, 'offset': offset, 'limit': 100, 'enableWatchFeedEntrypoint': false});
        final c = (d['playlistV2'] as Map?)?['content'] as Map?;
        if (c == null) throw const SpotifyWebProblem('No playlist in the answer');
        final items = ((c['items'] as List?) ?? const []).whereType<Map>().toList();
        for (final it in items) {
          final tr = trackFrom(((it['itemV2'] as Map?)?['data']) as Map?);
          if (tr != null) out.add(tr);
        }
        final total = (c['totalCount'] as num?)?.toInt() ?? out.length;
        offset += 100;
        onProgress?.call(out.length, total);
        if (items.isEmpty || offset >= total) break;
      }
      return out;
    } on SpotifyWebProblem catch (e) {
      if (e.signedOut || out.isNotEmpty) rethrow;
    }
    final id = uri.split(':').last;
    String? next = '$v1/playlists/$id/tracks?limit=100';
    while (next != null) {
      final j = await _v1(next);
      for (final it in ((j['items'] as List?) ?? const []).whereType<Map>()) {
        final t = _v1Track((it['track'] ?? it['item']) as Map?);
        if (t != null) out.add(t);
      }
      next = j['next'] as String?;
    }
    return out;
  }
}

/// The script Byte puts into the music service's web page (before the page's
/// own script runs) to hear the sign-in the page gives its own player. It
/// only listens; it changes nothing on the page.
const spotifyTokenHook = r"""
(function(){
  if (window.__byteHook) return; window.__byteHook = true;
  var q = [];
  function flush(){ try { if (window.ByteSpot && ByteSpot.postMessage) { while (q.length) ByteSpot.postMessage(q.shift()); } } catch(e) {} }
  function post(o){ q.push(JSON.stringify(o)); flush(); }
  setInterval(flush, 400);
  var of = window.fetch;
  if (of) window.fetch = function(input, init){
    var url = (typeof input === 'string') ? input : (input && input.url) || '';
    var p = of.apply(this, arguments);
    if (/\/api\/token|get_access_token/.test(url)) {
      p.then(function(r){ try { r.clone().json().then(function(j){ if (j && j.accessToken) post({k:'token', t:j.accessToken, exp:j.accessTokenExpirationTimestampMs||0, anon:!!j.isAnonymous}); }); } catch(e) {} });
    }
    try {
      var h = (init && init.headers) || (input && input.headers); var a = null;
      if (h) { a = (typeof h.get === 'function') ? h.get('authorization') : (h.authorization || h.Authorization); }
      if (a && /^Bearer /.test(a) && /api\.spotify\.com|api-partner\.spotify\.com|spclient/.test(url)) post({k:'bearer', t:a.slice(7)});
    } catch(e) {}
    return p;
  };
  var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.setRequestHeader;
  XMLHttpRequest.prototype.open = function(m, u){ this.__u = u; return oo.apply(this, arguments); };
  XMLHttpRequest.prototype.setRequestHeader = function(k, v){
    try { if (/^authorization$/i.test(k) && /^Bearer /.test(v)) post({k:'bearer', t:v.slice(7)}); } catch(e) {}
    return os.apply(this, arguments);
  };
})();
""";

/// What the page told Byte (null if it isn't a sign-in message).
({String token, int expMs, bool anonymous})? parseHookMessage(String msg, {DateTime? now}) {
  try {
    final j = jsonDecode(msg) as Map;
    final t = j['t'];
    if (t is! String || t.length < 40) return null;
    final at = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final exp = (j['exp'] as num?)?.toInt() ?? 0;
    return (token: t, expMs: exp > at ? exp : at + 50 * 60 * 1000, anonymous: j['anon'] == true);
  } catch (_) {
    return null;
  }
}
