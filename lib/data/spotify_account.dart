import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../core/net.dart';
import 'playlist_import.dart';
import 'spotify_web.dart';

class SpotifyPlaylistInfo {
  final String id; // 'liked' for Liked Songs
  final String name;
  final String? cover;
  final int count;
  final String owner;
  const SpotifyPlaylistInfo(this.id, this.name, this.cover, this.count, this.owner);
}

class SpotifyProblem implements Exception {
  final String message;
  const SpotifyProblem(this.message);
  @override
  String toString() => message;
}

/// "Log in with Spotify" to see your own playlists (private ones and Liked
/// Songs too), using Spotify's official sign-in with YOUR free developer app's
/// Client ID (PKCE: no secret, nothing stored anywhere but this phone). Songs
/// are then matched on YouTube Music like any import.
class SpotifyAccount extends ChangeNotifier {
  final Net net;
  Box? _b;
  SpotifyAccount(this.net);

  static const redirectUri = 'byte://spotify-callback';

  /// Byte's own Spotify app (set when building:
  /// --dart-define=SPOTIFY_CLIENT_ID=<32 hex>). When set, people just tap
  /// "Log in with Spotify"; no developer steps.
  static const builtInClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static bool get hasBuiltIn => RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(builtInClientId);
  static const scopes = 'playlist-read-private playlist-read-collaborative user-library-read';
  static const api = 'https://api.spotify.com/v1';

  Future<void> open() async => _b = await Hive.openBox('spotify_private');
  String _g(String k) => (_b?.get(k) as String?) ?? '';
  Future<void> _s(String k, String? v) async => v == null ? await _b?.delete(k) : await _b?.put(k, v);

  String get clientId => _g('clientId');
  String get userName => _g('user');

  /// 'web' = signed in on Spotify's own page inside Byte (no setup);
  /// 'app' = the older developer Client ID login.
  String get mode => _g('mode').isEmpty && _g('refresh').isNotEmpty ? 'app' : _g('mode');
  bool get isWeb => mode == 'web';
  bool get connected => isWeb ? _g('user').isNotEmpty : _g('refresh').isNotEmpty;

  /// Gets a fresh web sign-in by opening Spotify's page quietly in the
  /// background (set by the app; the page keeps the person signed in).
  static Future<({String token, int expMs})?> Function()? webRefresher;

  late final SpotifyWebApi web = SpotifyWebApi(net, _access);

  /// The person signed in on Spotify's page inside Byte and the page handed
  /// its player a sign-in: keep it and learn whose library it is.
  Future<String?> finishWeb(String token, int expMs) async {
    await _s('webToken', token);
    await _s('webExp', '$expMs');
    final prevMode = _g('mode');
    await _s('mode', 'web');
    String? name;
    try {
      // Check this very sign-in (not a stored one) belongs to a signed-in person.
      name = await SpotifyWebApi(net, () async => token).me();
    } catch (_) {
      name = null;
    }
    if (name == null) {
      await _s('mode', prevMode.isEmpty ? null : prevMode);
      return null;
    }
    await _s('user', name);
    await _s('refresh', null);
    notifyListeners();
    return name;
  }

  /// A newer web sign-in arrived (background refresh).
  Future<void> updateWebToken(String token, int expMs) async {
    await _s('webToken', token);
    await _s('webExp', '$expMs');
  }

  String? _verifier;

  static String _b64(List<int> b) => base64Url.encode(b).replaceAll('=', '');

  /// The Spotify sign-in page to open in the web view.
  Uri authorizeUrl(String clientId, {Random? rnd}) {
    final r = rnd ?? Random.secure();
    _verifier = _b64(List.generate(48, (_) => r.nextInt(256)));
    final challenge = _b64(sha256.convert(ascii.encode(_verifier!)).bytes);
    _pendingClient = clientId.trim();
    return Uri.https('accounts.spotify.com', '/authorize', {
      'client_id': clientId.trim(),
      'response_type': 'code',
      'redirect_uri': redirectUri,
      'code_challenge_method': 'S256',
      'code_challenge': challenge,
      'scope': scopes,
    });
  }

  String? _pendingClient;
  String? get pendingVerifier => _verifier;

  /// The web view landed on [redirectUri]: swap the code for tokens.
  Future<void> finish(Uri callback) async {
    final err = callback.queryParameters['error'];
    if (err != null) throw SpotifyProblem(err == 'access_denied' ? 'Sign-in was cancelled' : 'The music app said: $err');
    final code = callback.queryParameters['code'];
    if (code == null || _verifier == null || _pendingClient == null) throw const SpotifyProblem('Sign-in didn\'t finish. Try again.');
    final j = await _token({'grant_type': 'authorization_code', 'code': code, 'redirect_uri': redirectUri, 'client_id': _pendingClient!, 'code_verifier': _verifier!});
    await _s('clientId', _pendingClient);
    await _save(j);
    final me = await _getJson('$api/me');
    await _s('user', '${me['display_name'] ?? me['id'] ?? 'Music app'}');
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _b?.clear();
    notifyListeners();
  }

  Future<Map> _token(Map<String, String> form) async {
    final body = form.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final r = await net.send(NetRequest('POST', Uri.parse('https://accounts.spotify.com/api/token'), headers: {'Content-Type': 'application/x-www-form-urlencoded'}, body: utf8.encode(body)));
    final j = (() {
      try {
        return r.json;
      } catch (_) {
        return null;
      }
    })();
    if (!r.ok || j is! Map || j['access_token'] == null) {
      final d = j is Map ? (j['error_description'] ?? j['error']) : null;
      throw SpotifyProblem('Sign-in failed${d == null ? ' (${r.status})' : ': $d'}');
    }
    return j;
  }

  Future<void> _save(Map j) async {
    await _s('access', '${j['access_token']}');
    if (j['refresh_token'] != null) await _s('refresh', '${j['refresh_token']}');
    final exp = DateTime.now().add(Duration(seconds: ((j['expires_in'] as num?) ?? 3600).toInt() - 60));
    await _s('exp', exp.toIso8601String());
  }

  Future<String> _access() async {
    if (isWeb) {
      final exp = int.tryParse(_g('webExp')) ?? 0;
      if (_g('webToken').isNotEmpty && exp - 60000 > DateTime.now().millisecondsSinceEpoch) return _g('webToken');
      final f = webRefresher;
      final fresh = f == null ? null : await f();
      if (fresh == null) throw const SpotifyProblem('Spotify signed you out. Tap to connect again.');
      await updateWebToken(fresh.token, fresh.expMs);
      return fresh.token;
    }
    final exp = DateTime.tryParse(_g('exp'));
    if (_g('access').isNotEmpty && exp != null && exp.isAfter(DateTime.now())) return _g('access');
    if (!connected) throw const SpotifyProblem('Log in to your music app first');
    final j = await _token({'grant_type': 'refresh_token', 'refresh_token': _g('refresh'), 'client_id': clientId});
    await _save(j);
    return _g('access');
  }

  Future<Map> _getJson(String url) async {
    final tok = await _access();
    for (var attempt = 0; attempt < 4; attempt++) {
      final r = await net.get(Uri.parse(url), headers: {'Authorization': 'Bearer $tok'});
      if (r.ok) return r.json as Map;
      if (r.status == 429 || r.status >= 500) {
        final wait = int.tryParse(r.headers['retry-after'] ?? '') ?? (attempt + 1);
        await Future<void>.delayed(Duration(seconds: wait.clamp(1, 10)));
        continue;
      }
      if (r.status == 401) throw const SpotifyProblem('The music app logged you out. Log in again.');
      if (r.status == 403) throw const SpotifyProblem('Refused: add your music app email under "User Management" in your developer app.');
      throw SpotifyProblem('The music app answered ${r.status}');
    }
    throw const SpotifyProblem('The music app is busy. Try again in a minute.');
  }

  /// Liked Songs first, then every playlist you own or follow.
  Future<List<SpotifyPlaylistInfo>> playlists() async {
    if (isWeb) {
      try {
        final lists = await web.playlists();
        return [
          SpotifyPlaylistInfo('liked', 'Liked Songs', null, -1, userName),
          for (final p in lists) SpotifyPlaylistInfo(p.id, p.name, p.cover, p.count, p.owner),
        ];
      } on SpotifyWebProblem catch (e) {
        throw SpotifyProblem(e.message);
      }
    }
    final out = <SpotifyPlaylistInfo>[];
    final liked = await _getJson('$api/me/tracks?limit=1');
    out.add(SpotifyPlaylistInfo('liked', 'Liked Songs', null, (liked['total'] as num?)?.toInt() ?? 0, userName));
    String? next = '$api/me/playlists?limit=50';
    while (next != null) {
      final j = await _getJson(next);
      for (final p in ((j['items'] as List?) ?? const []).whereType<Map>()) {
        final imgs = (p['images'] as List?) ?? const [];
        final tracks = (p['tracks'] ?? p['items']) as Map?;
        out.add(SpotifyPlaylistInfo('${p['id']}', '${p['name']}', imgs.isEmpty ? null : (imgs.first as Map)['url'] as String?, (tracks?['total'] as num?)?.toInt() ?? 0, '${(p['owner'] as Map?)?['display_name'] ?? ''}'));
      }
      next = j['next'] as String?;
    }
    return out;
  }

  static ExtTrack? _track(Map? t) {
    if (t == null || t['name'] == null || t['type'] == 'episode') return null;
    final artists = ((t['artists'] as List?) ?? const []).whereType<Map>().map((a) => a['name']).join(', ');
    return ExtTrack('${t['name']}', artists, album: (t['album'] as Map?)?['name'] as String?, durationMs: (t['duration_ms'] as num?)?.toInt());
  }

  /// Every song of one playlist (or Liked Songs), ready for matching.
  Future<ExtList> read(SpotifyPlaylistInfo p, {void Function(String)? onStatus}) async {
    if (isWeb) {
      try {
        void prog(int d, int t) => onStatus?.call('Reading songs… $d of $t');
        final tracks = p.id == 'liked' ? await web.likedSongs(onProgress: prog) : await web.playlistTracks('spotify:playlist:${p.id}', onProgress: prog);
        return ExtList(p.name, p.cover, tracks, MusicService.spotify, 'spotify:${p.id}', total: tracks.length);
      } on SpotifyWebProblem catch (e) {
        throw SpotifyProblem(e.message);
      }
    }
    final tracks = <ExtTrack>[];
    String? next = p.id == 'liked' ? '$api/me/tracks?limit=50' : '$api/playlists/${p.id}/tracks?limit=100';
    var usedItems = false;
    while (next != null) {
      Map j;
      try {
        j = await _getJson(next);
      } on SpotifyProblem {
        // Newer API name for playlist songs.
        if (p.id != 'liked' && !usedItems && tracks.isEmpty) {
          usedItems = true;
          next = '$api/playlists/${p.id}/items?limit=100';
          continue;
        }
        rethrow;
      }
      for (final it in ((j['items'] as List?) ?? const []).whereType<Map>()) {
        final t = _track((it['track'] ?? it['item']) as Map?);
        if (t != null) tracks.add(t);
      }
      onStatus?.call('Reading songs… ${tracks.length} of ${p.count}');
      next = j['next'] as String?;
    }
    return ExtList(p.name, p.cover, tracks, MusicService.spotify, 'spotify:${p.id == 'liked' ? 'liked' : p.id}', total: p.count);
  }
}
