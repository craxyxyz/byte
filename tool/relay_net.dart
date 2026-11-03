// Test-only transport: sends each request through a real browser on a mobile
// network (this build box's own IP is a data-centre address that YouTube
// refuses to play for), so the app's own resolver code can be exercised here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:byte/core/net.dart';

class RelayNet extends Net {
  final Uri relay;
  RelayNet([String url = 'http://127.0.0.1:8787/']) : relay = Uri.parse(url);
  @override
  Future<NetResponse> send(NetRequest r, {Duration timeout = const Duration(seconds: 20)}) async {
    final c = HttpClient();
    try {
      final req = await c.postUrl(relay);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'url': r.url.toString(), 'method': r.method, 'headers': r.headers, if (r.body != null) 'bodyB64': base64Encode(r.body!)}));
      final res = await req.close().timeout(timeout * 4);
      final txt = await res.transform(utf8.decoder).join();
      final j = jsonDecode(txt) as Map<String, dynamic>;
      if (j['error'] != null) throw NetException('relay: ${j['error']}');
      return NetResponse(j['status'] as int, (j['headers'] as Map).cast<String, String>(), Uint8List.fromList(base64Decode(j['bodyB64'] as String)));
    } finally {
      c.close();
    }
  }
}
