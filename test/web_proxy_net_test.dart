import 'dart:convert';

import 'package:byte/core/net.dart';
import 'package:byte/core/net_proxy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final ep = Uri.parse('https://proj.supabase.co/functions/v1/byte-proxy');

  test('builds proxy and play addresses', () {
    final n = WebProxyNet(ep, client: MockClient((_) async => http.Response('', 200)));
    final target = Uri.parse('https://music.youtube.com/youtubei/v1/search?prettyPrint=false&q=a b&x=1');
    final p = n.proxied(target);
    expect(p.host, 'proj.supabase.co');
    expect(p.path, '/functions/v1/byte-proxy');
    expect(Uri.parse(p.queryParameters['u']!), target);
    final play = n.playUrl('zAiIgYOH4Ys', low: true, mp4: true);
    expect(play.queryParameters, {'play': 'zAiIgYOH4Ys', 'q': 'low', 'f': 'mp4'});
    expect(n.playUrl('zAiIgYOH4Ys').queryParameters, {'play': 'zAiIgYOH4Ys'});
  });

  test('carries the original headers as JSON, never cookies', () async {
    late http.BaseRequest seen;
    late List<int> body;
    final n = WebProxyNet(
      ep,
      client: MockClient((r) async {
        seen = r;
        body = r.bodyBytes;
        return http.Response('{"ok":1}', 200, headers: {'x-byte-final-url': 'https://music.youtube.com/'});
      }),
    );
    final res = await n.postJson(Uri.parse('https://music.youtube.com/youtubei/v1/browse'), {'a': 1}, headers: {'User-Agent': 'UA', 'X-Goog-Visitor-Id': 'V', 'Cookie': 'SID=1', 'Range': 'bytes=0-1'});
    expect(res.json, {'ok': 1});
    expect(seen.method, 'POST');
    expect(seen.url.queryParameters['u'], 'https://music.youtube.com/youtubei/v1/browse');
    final carried = jsonDecode(seen.headers['x-byte-h']!) as Map;
    expect(carried, {'User-Agent': 'UA', 'X-Goog-Visitor-Id': 'V'});
    expect(seen.headers['Range'], 'bytes=0-1');
    expect(seen.headers['content-type'] ?? seen.headers['Content-Type'], startsWith('application/json'));
    expect(seen.headers.keys.map((k) => k.toLowerCase()), isNot(contains('cookie')));
    expect(utf8.decode(body), '{"a":1}');
    expect(n.state.value, WebProxyState.online);
  });

  test('hosts that allow web pages are called directly, minus forbidden headers', () async {
    late http.BaseRequest seen;
    final n = WebProxyNet(ep, client: MockClient((r) async => (seen = r, http.Response('[]', 200)).$2));
    await n.get(Uri.parse('https://proj.supabase.co/rest/v1/x'), headers: {'User-Agent': 'UA', 'apikey': 'k'});
    expect(seen.url.host, 'proj.supabase.co');
    expect(seen.url.path, '/rest/v1/x');
    expect(seen.headers.keys.map((k) => k.toLowerCase()), isNot(contains('user-agent')));
    expect(seen.headers['apikey'], 'k');
  });

  test('a refused host becomes a clear NetException', () async {
    final n = WebProxyNet(
      ep,
      client: MockClient((_) async => http.Response('{"error":"host not allowed: evil.example","proxy":"byte-proxy"}', 403, headers: {'x-byte-proxy': 'refused'})),
    );
    await expectLater(
      n.get(Uri.parse('https://evil.example/')),
      throwsA(isA<NetException>().having((e) => e.message, 'message', contains('host not allowed')).having((e) => e.status, 'status', 403)),
    );
  });

  test('upstream errors pass through as responses (e.g. no lyrics = 404)', () async {
    final n = WebProxyNet(ep, client: MockClient((_) async => http.Response('nf', 404, headers: {'x-byte-final-url': 'https://lrclib.net/api/get'})));
    final r = await n.get(Uri.parse('https://lrclib.net/api/get?x=1'));
    expect(r.status, 404);
    expect(n.state.value, WebProxyState.online);
  });

  test('server not deployed: offline state + honest message', () async {
    final n = WebProxyNet(ep, client: MockClient((_) async => throw http.ClientException('XMLHttpRequest error.')));
    await expectLater(n.get(Uri.parse('https://music.youtube.com/sw.js_data')), throwsA(isA<NetException>().having((e) => e.message, 'm', WebProxyNet.offlineMessage)));
    expect(n.state.value, WebProxyState.offline);
    final n404 = WebProxyNet(ep, client: MockClient((_) async => http.Response('{"code":"NOT_FOUND","message":"Requested function was not found"}', 404)));
    await expectLater(n404.get(Uri.parse('https://music.youtube.com/sw.js_data')), throwsA(isA<NetException>()));
    expect(n404.state.value, WebProxyState.offline);
  });

  test('while switched off, calls fail at once (no network) until the backoff ends', () async {
    var calls = 0;
    final n = WebProxyNet(ep, offlineBackoff: const Duration(milliseconds: 200), client: MockClient((_) async {
      calls++;
      throw http.ClientException('XMLHttpRequest error.');
    }));
    await expectLater(n.get(Uri.parse('https://music.youtube.com/a')), throwsA(isA<NetException>()));
    await expectLater(n.get(Uri.parse('https://music.youtube.com/b')), throwsA(isA<NetException>()));
    expect(calls, 1);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await expectLater(n.get(Uri.parse('https://music.youtube.com/c')), throwsA(isA<NetException>()));
    expect(calls, 2);
  });

  test('calls made while the first ping is pending wait for its answer', () async {
    var proxied = 0;
    final n = WebProxyNet(ep, client: MockClient((r) async {
      if (r.url.queryParameters['ping'] == '1') {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        throw http.ClientException('XMLHttpRequest error.');
      }
      proxied++;
      return http.Response('', 200);
    }));
    final p = n.ping();
    await expectLater(n.get(Uri.parse('https://music.youtube.com/a')), throwsA(isA<NetException>()));
    expect(await p, isFalse);
    expect(proxied, 0);
  });

  test('ping reads the server', () async {
    final on = WebProxyNet(ep, client: MockClient((r) async => http.Response(r.url.queryParameters['ping'] == '1' ? '{"ok":true,"name":"byte-proxy","v":1}' : '', 200)));
    expect(await on.ping(), isTrue);
    expect(on.state.value, WebProxyState.online);
    final off = WebProxyNet(ep, client: MockClient((_) async => http.Response('nope', 404)));
    expect(await off.ping(), isFalse);
    expect(off.state.value, WebProxyState.offline);
  });
}
