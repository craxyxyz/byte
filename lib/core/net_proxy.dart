import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'net.dart';

/// Whether the Byte web server (the `byte-proxy` function) answers.
enum WebProxyState { unknown, online, offline }

/// The web build's network door: a browser page may not call the catalogue,
/// lyrics or import sites itself (CORS) nor set headers like User-Agent, so
/// every call to those hosts goes through the Byte web server instead, with
/// the original headers carried as JSON in `x-byte-h`.
class WebProxyNet extends Net {
  /// e.g. `https://PROJECT.supabase.co/functions/v1/byte-proxy`
  final Uri endpoint;
  final http.Client _c;

  /// Up/down as seen by the last call (the web app's banner listens).
  final ValueNotifier<WebProxyState> state;

  /// After the server was found switched off, calls fail at once for this
  /// long (no pile of browser errors), then it is tried again.
  final Duration offlineBackoff;
  DateTime? _offlineAt;

  WebProxyNet(this.endpoint, {http.Client? client, ValueNotifier<WebProxyState>? state, this.offlineBackoff = const Duration(seconds: 20)})
    : _c = client ?? http.Client(),
      state = state ?? ValueNotifier(WebProxyState.unknown);

  void _offline() {
    _offlineAt = DateTime.now();
    state.value = WebProxyState.offline;
  }

  bool get _backingOff => state.value == WebProxyState.offline && _offlineAt != null && DateTime.now().difference(_offlineAt!) < offlineBackoff;

  static const offlineMessage = 'Online songs need the Byte web server switched on';

  /// Hosts that answer web pages themselves (CORS), called directly.
  static bool direct(Uri u) {
    final h = u.host.toLowerCase();
    return h.endsWith('.supabase.co') || h.endsWith('.supabase.in') || h == 'localhost' || h == '127.0.0.1';
  }

  /// Headers a browser refuses to let a page set (they'd only log errors).
  static const _forbidden = {
    'user-agent', 'cookie', 'origin', 'referer', 'host', 'connection', 'content-length', 'accept-encoding', //
    'accept-charset', 'dnt', 'keep-alive', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'via', 'date', 'expect',
  };

  /// The proxy address that fetches [target].
  Uri proxied(Uri target) => endpoint.replace(queryParameters: {...endpoint.queryParameters, 'u': target.toString()});

  /// What the browser actually sends to the proxy for [r].
  Map<String, String> proxyHeaders(NetRequest r) {
    final out = <String, String>{};
    final carried = <String, String>{};
    r.headers.forEach((k, v) {
      final l = k.toLowerCase();
      if (l == 'range' || l == 'content-type') {
        out[k] = v;
      } else if (l != 'cookie') {
        carried[k] = v;
      }
    });
    if (carried.isNotEmpty) out['x-byte-h'] = jsonEncode(carried);
    return out;
  }

  /// Address of [videoId]'s audio, found and streamed by the server in one call.
  Uri playUrl(String videoId, {bool low = false, bool mp4 = false}) =>
      endpoint.replace(queryParameters: {...endpoint.queryParameters, 'play': videoId, if (low) 'q': 'low', if (mp4) 'f': 'mp4'});

  Future<bool>? _pinging;

  /// Asks the server whether it is switched on (sets [state]). Calls made
  /// while the first answer is pending wait for it instead of piling up.
  Future<bool> ping({Duration timeout = const Duration(seconds: 8)}) => _pinging = _ping(timeout).whenComplete(() => _pinging = null);

  Future<bool> _ping(Duration timeout) async {
    try {
      final res = await _c.get(endpoint.replace(queryParameters: {...endpoint.queryParameters, 'ping': '1'})).timeout(timeout);
      final ok = res.statusCode == 200 && res.body.contains('byte-proxy');
      ok ? state.value = WebProxyState.online : _offline();
      return ok;
    } catch (_) {
      _offline();
      return false;
    }
  }

  @override
  Future<NetResponse> send(NetRequest r, {Duration timeout = const Duration(seconds: 20)}) async {
    final viaProxy = !direct(r.url);
    if (viaProxy && state.value == WebProxyState.unknown && _pinging != null) await _pinging;
    if (viaProxy && _backingOff) throw NetException(offlineMessage);
    final url = viaProxy ? proxied(r.url) : r.url;
    final headers = viaProxy
        ? proxyHeaders(r)
        : {
            for (final e in r.headers.entries)
              if (!_forbidden.contains(e.key.toLowerCase())) e.key: e.value,
          };
    final req = http.Request(r.method, url)..headers.addAll(headers);
    if (r.body != null) req.bodyBytes = r.body!;
    final http.StreamedResponse res;
    final List<int> bytes;
    try {
      res = await _c.send(req).timeout(timeout);
      bytes = await res.stream.toBytes().timeout(timeout * 3);
    } on http.ClientException catch (e) {
      // A browser reports a missing/refusing server as a bare network error.
      if (viaProxy) {
        _offline();
        throw NetException(offlineMessage);
      }
      throw NetException(e.message);
    }
    if (viaProxy) {
      if (res.headers['x-byte-proxy'] == 'refused') {
        String why = 'refused';
        try {
          why = (jsonDecode(utf8.decode(bytes)) as Map)['error']?.toString() ?? why;
        } catch (_) {}
        state.value = WebProxyState.online;
        throw NetException('Byte web server: $why', res.statusCode);
      }
      // A project without the function answers 404 from the platform itself.
      if (res.statusCode == 404 && !res.headers.containsKey('x-byte-final-url')) {
        _offline();
        throw NetException(offlineMessage, 404);
      }
      state.value = WebProxyState.online;
    }
    return NetResponse(res.statusCode, res.headers, Uint8List.fromList(bytes));
  }

  void close() => _c.close();
}
