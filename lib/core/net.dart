import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class NetRequest {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final List<int>? body;
  /// false: hand back a 3xx as it is (used to read where a short link points).
  final bool followRedirects;
  const NetRequest(this.method, this.url, {this.headers = const {}, this.body, this.followRedirects = true});
}

class NetResponse {
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
  const NetResponse(this.status, this.headers, this.body);
  String get text => utf8.decode(body, allowMalformed: true);
  dynamic get json => jsonDecode(text);
  bool get ok => status >= 200 && status < 300;
}

class NetException implements Exception {
  final String message;
  final int? status;
  NetException(this.message, [this.status]);
  @override
  String toString() => 'NetException($status): $message';
}

/// The single door every network call goes through, so tests can swap it.
abstract class Net {
  Future<NetResponse> send(NetRequest r, {Duration timeout = const Duration(seconds: 20)});

  Future<NetResponse> get(Uri url, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 20)}) =>
      send(NetRequest('GET', url, headers: headers), timeout: timeout);

  Future<NetResponse> postJson(Uri url, Object body, {Map<String, String> headers = const {}, Duration timeout = const Duration(seconds: 20)}) => send(
    NetRequest('POST', url, headers: {'Content-Type': 'application/json', ...headers}, body: utf8.encode(jsonEncode(body))),
    timeout: timeout,
  );
}

class HttpNet extends Net {
  final http.Client _c;
  HttpNet([http.Client? c]) : _c = c ?? http.Client();
  @override
  Future<NetResponse> send(NetRequest r, {Duration timeout = const Duration(seconds: 20)}) async {
    final req = http.Request(r.method, r.url)
      ..headers.addAll(r.headers)
      ..followRedirects = r.followRedirects;
    if (r.body != null) req.bodyBytes = r.body!;
    final res = await _c.send(req).timeout(timeout);
    final bytes = await res.stream.toBytes().timeout(timeout * 3);
    return NetResponse(res.statusCode, res.headers, bytes);
  }

  void close() => _c.close();
}
