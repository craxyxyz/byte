import 'dart:async';
import 'dart:io';
import 'dart:math';

/// What the speaker should play: a link Byte already has (a song stream) or a
/// file on this phone (downloads, Local Music).
class RelaySource {
  final Uri? url;
  final String? filePath;
  final String contentType;
  final Map<String, String> headers;

  /// Any other byte source (an SMB share): total length + a ranged reader.
  final int? length;
  final Future<Stream<List<int>>> Function(int start, int endExclusive)? reader;
  const RelaySource.url(Uri this.url, this.contentType, {this.headers = const {}}) : filePath = null, length = null, reader = null;
  const RelaySource.file(String this.filePath, this.contentType)
    : url = null,
      headers = const {},
      length = null,
      reader = null;
  const RelaySource.custom({required int this.length, required this.reader, required this.contentType})
    : url = null,
      filePath = null,
      headers = const {};
}

/// A tiny web server on the phone that hands the current song to a Cast
/// device on the same Wi-Fi, with seeking (Range) support. Every song gets a
/// random one-time path, and only the last few stay valid.
class CastRelay {
  HttpServer? _server;
  final Map<String, RelaySource> _routes = {};
  final List<String> _order = [];
  final Random _rng = Random.secure();
  late final HttpClient _client = HttpClient(); // made on first use (none on the web)
  String? host;

  int? get port => _server?.port;

  /// [loopbackOnly]: serves this phone's own player (SMB songs), not the Wi-Fi.
  Future<void> start({String? bindHost, bool loopbackOnly = false}) async {
    if (_server != null) return;
    host = loopbackOnly ? '127.0.0.1' : (bindHost ?? await lanAddress());
    _server = await HttpServer.bind(loopbackOnly ? InternetAddress.loopbackIPv4 : InternetAddress.anyIPv4, 0);
    _server!.listen(_handle);
  }

  /// The phone's Wi-Fi address (a private IPv4).
  static Future<String?> lanAddress() async {
    try {
      final ifs = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifs) {
        for (final a in i.addresses) {
          final s = a.address;
          if (s.startsWith('192.168.') || s.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(s)) return s;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Registers [src] and returns the address the speaker should fetch.
  Uri publish(RelaySource src) {
    final token = List.generate(16, (_) => _rng.nextInt(36).toRadixString(36)).join();
    _routes[token] = src;
    _order.add(token);
    while (_order.length > 4) {
      _routes.remove(_order.removeAt(0));
    }
    return Uri(scheme: 'http', host: host ?? '127.0.0.1', port: port, path: '/s/$token');
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final seg = req.uri.pathSegments;
      final src = seg.length == 2 && seg[0] == 's' ? _routes[seg[1]] : null;
      if (src == null || (req.method != 'GET' && req.method != 'HEAD')) {
        res.statusCode = HttpStatus.notFound;
        await res.close();
        return;
      }
      res.headers.set('Access-Control-Allow-Origin', '*');
      res.headers.set('Accept-Ranges', 'bytes');
      final range = req.headers.value(HttpHeaders.rangeHeader);
      if (src.reader != null) {
        await _serveRanged(req, res, src.length!, src.reader!, src.contentType, range);
      } else if (src.filePath != null) {
        await _serveFile(req, res, File(src.filePath!), src.contentType, range);
      } else {
        await _proxy(req, res, src, range);
      }
    } catch (_) {
      try {
        res.statusCode = HttpStatus.badGateway;
        await res.close();
      } catch (_) {}
    }
  }

  Future<void> _serveFile(HttpRequest req, HttpResponse res, File f, String type, String? range) async =>
      _serveRanged(req, res, await f.length(), (s, e) async => f.openRead(s, e), type, range);

  Future<void> _serveRanged(
    HttpRequest req,
    HttpResponse res,
    int len,
    Future<Stream<List<int>>> Function(int, int) read,
    String type,
    String? range,
  ) async {
    var start = 0, end = len - 1;
    final m = range == null ? null : RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    if (m != null) {
      if (m.group(1)!.isNotEmpty) start = int.parse(m.group(1)!);
      if (m.group(2)!.isNotEmpty) end = min(int.parse(m.group(2)!), len - 1);
      if (m.group(1)!.isEmpty && m.group(2)!.isNotEmpty) {
        start = max(0, len - int.parse(m.group(2)!));
        end = len - 1;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(HttpHeaders.contentRangeHeader, 'bytes $start-$end/$len');
    }
    res.headers.contentType = ContentType.parse(type);
    res.headers.contentLength = end - start + 1;
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }
    await res.addStream(await read(start, end + 1));
    await res.close();
  }

  Future<void> _proxy(HttpRequest req, HttpResponse res, RelaySource src, String? range) async {
    final up = await _client.openUrl(req.method, src.url!);
    src.headers.forEach(up.headers.set);
    if (range != null) up.headers.set(HttpHeaders.rangeHeader, range);
    final r = await up.close();
    res.statusCode = r.statusCode;
    for (final h in [HttpHeaders.contentLengthHeader, HttpHeaders.contentRangeHeader]) {
      final v = r.headers.value(h);
      if (v != null) res.headers.set(h, v);
    }
    res.headers.contentType = ContentType.parse(src.contentType);
    await res.addStream(r);
    await res.close();
  }

  Future<void> stop() async {
    _routes.clear();
    _order.clear();
    await _server?.close(force: true);
    _server = null;
  }
}
