import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../core/models.dart';
import '../core/net.dart';

/// One listen waiting to be sent.
class Listen {
  final String title;
  final String artist;
  final String? album;
  final int? durationSec;
  final int at; // unix seconds, when the song started
  final String id;
  const Listen(this.title, this.artist, this.at, {this.album, this.durationSec, this.id = ''});
  factory Listen.of(Item it, DateTime started) =>
      Listen(it.title, it.artists.isEmpty ? (it.subtitle ?? '') : it.artists.first.name, started.millisecondsSinceEpoch ~/ 1000, album: it.album, durationSec: it.durationSec, id: it.id);
  Map<String, dynamic> toJson() => {'t': title, 'a': artist, 'al': album, 'd': durationSec, 'at': at, 'id': id};
  factory Listen.fromJson(Map j) => Listen('${j['t']}', '${j['a']}', (j['at'] as num).toInt(), album: j['al'] as String?, durationSec: (j['d'] as num?)?.toInt(), id: '${j['id'] ?? ''}');
}

/// Sends what you listen to, to your own ListenBrainz and/or Last.fm account
/// ("scrobbling"). Both are free; you paste your own token / key. A song counts
/// after half of it (or 4 minutes) was heard; offline listens wait in a queue.
class Scrobbler extends ChangeNotifier {
  final Net net;
  Box? _b;
  Scrobbler(this.net);

  static const lbApi = 'https://api.listenbrainz.org';
  static const lfmApi = 'https://ws.audioscrobbler.com/2.0/';
  static const client = 'Byte';
  static const version = '1.4.5';

  Future<void> open() async => _b = await Hive.openBox('scrobble_private');
  T _get<T>(String k, T def) {
    final v = _b?.get(k);
    return v is T ? v : def;
  }

  Future<void> _set(String k, Object? v) async {
    if (v == null) {
      await _b?.delete(k);
    } else {
      await _b?.put(k, v);
    }
    notifyListeners();
  }

  // ── accounts ────────────────────────────────────────────────────────
  String get lbToken => _get('lbToken', '');
  String get lbUser => _get('lbUser', '');
  bool get lbOn => lbToken.isNotEmpty;
  String get lfmKey => _get('lfmKey', '');
  String get lfmSecret => _get('lfmSecret', '');
  String get lfmSession => _get('lfmSk', '');
  String get lfmUser => _get('lfmUser', '');
  bool get lfmOn => lfmSession.isNotEmpty && lfmKey.isNotEmpty && lfmSecret.isNotEmpty;
  bool get enabled => _get('on', true);
  set enabled(bool v) => _set('on', v);
  bool get nowPlaying => _get('np', true);
  set nowPlaying(bool v) => _set('np', v);
  List<Listen> get queue => [for (final j in (_get<List>('queue', const []))) if (j is Map) Listen.fromJson(j)];
  String? lastError;

  /// Checks the ListenBrainz user token and remembers it.
  Future<String> connectListenBrainz(String token) async {
    token = token.trim();
    final r = await net.get(Uri.parse('$lbApi/1/validate-token'), headers: {'Authorization': 'Token $token'});
    final j = r.ok ? r.json : null;
    if (j is! Map || j['valid'] != true) throw const ScrobbleProblem('That token didn\'t work. Copy it again from the website\'s Settings page.');
    await _set('lbToken', token);
    await _set('lbUser', '${j['user_name'] ?? ''}');
    unawaited(flush());
    return lbUser;
  }

  Future<void> disconnectListenBrainz() async {
    await _set('lbToken', null);
    await _set('lbUser', null);
  }

  /// Last.fm: your own free API account (key + shared secret from
  /// last.fm/api/account/create) and your Last.fm login. Only the session key
  /// is kept, never the password.
  Future<String> connectLastFm({required String apiKey, required String secret, required String user, required String password}) async {
    final p = {'method': 'auth.getMobileSession', 'username': user.trim(), 'password': password, 'api_key': apiKey.trim()};
    final j = await _lfmPost(p, secret.trim());
    final sk = (j['session'] as Map?)?['key'] as String?;
    if (sk == null) throw ScrobbleProblem(_lfmError(j) ?? 'The listening log didn\'t accept that login');
    await _set('lfmKey', apiKey.trim());
    await _set('lfmSecret', secret.trim());
    await _set('lfmSk', sk);
    await _set('lfmUser', '${(j['session'] as Map?)?['name'] ?? user}');
    unawaited(flush());
    return lfmUser;
  }

  /// Byte's own Last.fm API account (set when building with
  /// --dart-define=LASTFM_KEY=… --dart-define=LASTFM_SECRET=…). With it,
  /// "Tap to sign in" is just Last.fm's own sign-in page inside Byte.
  static const builtInLfmKey = String.fromEnvironment('LASTFM_KEY');
  static const builtInLfmSecret = String.fromEnvironment('LASTFM_SECRET');
  static bool get hasBuiltInLfm => builtInLfmKey.length == 32 && builtInLfmSecret.length == 32;

  /// Last.fm's web sign-in: the person approved Byte on last.fm and the page
  /// handed back [token]; swap it for a session (auth.getSession).
  Future<String> connectLastFmToken({required String apiKey, required String secret, required String token}) async {
    final j = await _lfmPost({'method': 'auth.getSession', 'token': token, 'api_key': apiKey.trim()}, secret.trim());
    final sk = (j['session'] as Map?)?['key'] as String?;
    if (sk == null) throw ScrobbleProblem(_lfmError(j) ?? 'Last.fm didn\'t finish the sign-in');
    await _set('lfmKey', apiKey.trim());
    await _set('lfmSecret', secret.trim());
    await _set('lfmSk', sk);
    await _set('lfmUser', '${(j['session'] as Map?)?['name'] ?? ''}');
    unawaited(flush());
    return lfmUser;
  }

  /// The listening log's user token, as shown on its settings page.
  static String? listenBrainzTokenIn(String html) {
    final near = RegExp(r'(?:auth_token|user_token|authToken|token)[^0-9a-fA-F]{1,40}([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})');
    final m = near.firstMatch(html);
    return m?.group(1);
  }

  Future<void> disconnectLastFm() async {
    for (final k in ['lfmKey', 'lfmSecret', 'lfmSk', 'lfmUser']) {
      await _set(k, null);
    }
  }

  static String lastFmSignature(Map<String, String> params, String secret) {
    final keys = params.keys.where((k) => k != 'format' && k != 'callback').toList()..sort();
    final raw = StringBuffer();
    for (final k in keys) {
      raw
        ..write(k)
        ..write(params[k]);
    }
    raw.write(secret);
    return md5.convert(utf8.encode(raw.toString())).toString();
  }

  Future<Map> _lfmPost(Map<String, String> p, String secret) async {
    final all = {...p, 'api_sig': lastFmSignature(p, secret), 'format': 'json'};
    final body = all.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final r = await net.send(
      NetRequest('POST', Uri.parse(lfmApi), headers: {'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': '$client/$version'}, body: utf8.encode(body)),
    );
    try {
      final j = r.json;
      return j is Map ? j : {'error': r.status, 'message': r.text};
    } catch (_) {
      return {'error': r.status, 'message': 'The listening log answered ${r.status}'};
    }
  }

  static String? _lfmError(Map j) => j['error'] == null ? null : 'Listening log: ${j['message'] ?? 'error ${j['error']}'}';

  // ── listening ───────────────────────────────────────────────────────
  String? _session;
  bool _sentNow = false, _counted = false;
  int _heard = 0;
  DateTime? _started;

  /// A song counts once this much of it was heard.
  static int thresholdMs(int? durationSec) {
    if (durationSec == null || durationSec <= 0) return 120000; // unknown length: 2 min
    return (durationSec * 500).clamp(0, 240000);
  }

  /// Called every second or so while music plays ([session] changes on every new play).
  void tick(Item it, int ms, String session, DateTime at) {
    if (!enabled || (!lbOn && !lfmOn) || it.kind == ItemKind.episode) return;
    if (session != _session) {
      _session = session;
      _heard = 0;
      _sentNow = false;
      _counted = false;
      _started = at;
    }
    _heard += ms;
    if (!_sentNow && _heard >= 5000 && nowPlaying) {
      _sentNow = true;
      unawaited(_nowPlaying(Listen.of(it, _started!)));
    }
    if (!_counted && (it.durationSec == null || it.durationSec! > 30) && _heard >= thresholdMs(it.durationSec)) {
      _counted = true;
      unawaited(add(Listen.of(it, _started!)));
    }
  }

  Future<void> add(Listen l) async {
    final q = [...queue, l];
    // Keep at most 2000 waiting listens.
    await _set('queue', [for (final x in q.skip(q.length > 2000 ? q.length - 2000 : 0)) x.toJson()]);
    await flush();
  }

  bool _flushing = false;

  /// Sends everything waiting. Listens stay queued until every connected service took them.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      while (true) {
        final q = queue;
        if (q.isEmpty || (!lbOn && !lfmOn)) break;
        final batch = q.take(50).toList();
        final lbDone = _get<int>('lbDone', 0), lfmDone = _get<int>('lfmDone', 0);
        var ok = true;
        if (lbOn && lbDone < batch.length) {
          ok = await _lbSend(batch.skip(lbDone).toList()) && ok;
          if (ok) await _set('lbDone', batch.length);
        }
        if (ok && lfmOn && lfmDone < batch.length) {
          ok = await _lfmScrobble(batch.skip(lfmDone).toList()) && ok;
          if (ok) await _set('lfmDone', batch.length);
        }
        if (!ok) break;
        final rest = queue.skip(batch.length).map((e) => e.toJson()).toList();
        await _set('queue', rest);
        await _set('lbDone', 0);
        await _set('lfmDone', 0);
        lastError = null;
      }
    } finally {
      _flushing = false;
      notifyListeners();
    }
  }

  Map<String, dynamic> _lbTrack(Listen l) => {
    'artist_name': l.artist,
    'track_name': l.title,
    if (l.album != null && l.album!.isNotEmpty) 'release_name': l.album,
    'additional_info': {
      'media_player': client,
      'submission_client': client,
      'submission_client_version': version,
      if (l.durationSec != null) 'duration_ms': l.durationSec! * 1000,
      if (l.id.isNotEmpty && !l.id.contains(':')) 'origin_url': 'https://music.youtube.com/watch?v=${l.id}',
    },
  };

  Future<bool> _lbSend(List<Listen> ls) async {
    try {
      final r = await net.postJson(Uri.parse('$lbApi/1/submit-listens'), {
        'listen_type': ls.length == 1 ? 'single' : 'import',
        'payload': [for (final l in ls) {'listened_at': l.at, 'track_metadata': _lbTrack(l)}],
      }, headers: {'Authorization': 'Token $lbToken'});
      if (r.status == 401) lastError = 'The listening log token stopped working. Connect again.';
      if (!r.ok && r.status != 401 && r.status != 400) lastError = 'The listening log is busy (${r.status}); will retry';
      // A 400 means that listen can never be accepted; drop it instead of retrying forever.
      return r.ok || r.status == 400;
    } catch (_) {
      lastError = 'Offline: listens will be sent later';
      return false;
    }
  }

  Future<bool> _lfmScrobble(List<Listen> ls) async {
    final p = <String, String>{'method': 'track.scrobble', 'api_key': lfmKey, 'sk': lfmSession};
    for (final (i, l) in ls.indexed) {
      p['artist[$i]'] = l.artist;
      p['track[$i]'] = l.title;
      p['timestamp[$i]'] = '${l.at}';
      if (l.album != null && l.album!.isNotEmpty) p['album[$i]'] = l.album!;
      if (l.durationSec != null) p['duration[$i]'] = '${l.durationSec}';
    }
    try {
      final j = await _lfmPost(p, lfmSecret);
      if (j['scrobbles'] != null) return true;
      final code = j['error'];
      lastError = _lfmError(j);
      // 9 = session expired / revoked, 11/16 = try later, 29 = rate limit.
      return !(code == 9 || code == 11 || code == 16 || code == 29 || code is! num);
    } catch (_) {
      lastError = 'Offline: listens will be sent later';
      return false;
    }
  }

  Future<void> _nowPlaying(Listen l) async {
    try {
      if (lbOn) {
        await net.postJson(Uri.parse('$lbApi/1/submit-listens'), {
          'listen_type': 'playing_now',
          'payload': [{'track_metadata': _lbTrack(l)}],
        }, headers: {'Authorization': 'Token $lbToken'});
      }
      if (lfmOn) {
        final p = <String, String>{'method': 'track.updateNowPlaying', 'api_key': lfmKey, 'sk': lfmSession, 'artist': l.artist, 'track': l.title};
        if (l.album != null && l.album!.isNotEmpty) p['album'] = l.album!;
        if (l.durationSec != null) p['duration'] = '${l.durationSec}';
        await _lfmPost(p, lfmSecret);
      }
    } catch (_) {}
  }
}

class ScrobbleProblem implements Exception {
  final String message;
  const ScrobbleProblem(this.message);
  @override
  String toString() => message;
}
