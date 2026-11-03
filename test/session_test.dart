import 'dart:convert';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test('signed-in requests carry YouTube\'s SAPISIDHASH header and the cookie', () async {
    const cookie = 'SID=s; SAPISID=abc123; __Secure-3PAPISID=xyz789; HSID=h';
    final s = YtSession(cookie);
    expect(s.looksValid, isTrue);
    final h = s.authorization(nowSeconds: 1700000000);
    final want1 = sha1.convert(utf8.encode('1700000000 abc123 https://music.youtube.com')).toString();
    final want3 = sha1.convert(utf8.encode('1700000000 xyz789 https://music.youtube.com')).toString();
    expect(h, 'SAPISIDHASH 1700000000_$want1 SAPISID3PHASH 1700000000_$want3');

    final net = FakeNet(catalogue);
    final yt = InnerTube(net, session: s);
    await yt.home();
    final r = net.log.last;
    expect(r.headers['Cookie'], cookie);
    expect(r.headers['Authorization'], startsWith('SAPISIDHASH '));
    expect(r.headers['X-Goog-AuthUser'], '0');
  });

  test('signed-out sessions send no account headers; player never sends cookies', () async {
    final net = FakeNet(catalogue);
    final yt = InnerTube(net);
    await yt.search('x', SearchFilter.all);
    expect(net.log.last.headers.containsKey('Cookie'), isFalse);
    yt.session = YtSession('SAPISID=a');
    await yt.player('dQw4w9WgXcQ');
    final p = net.log.lastWhere((r) => r.url.path.endsWith('/player'));
    expect(p.headers.containsKey('Cookie'), isFalse);
    expect(jsonDecode(utf8.decode(p.body!))['context']['client']['clientName'], 'VISIONOS');
  });

  test('cookie without SAPISID is rejected', () {
    expect(YtSession('SID=1; HSID=2').looksValid, isFalse);
  });
}
