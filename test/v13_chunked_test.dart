import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:byte/player/chunked_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tiny server that honours Range, and can drop a connection or refuse.
class _Server {
  late HttpServer http;
  final Uint8List body;
  final List<String> ranges = [];
  final List<String?> agents = [];
  int dropNext = 0; // drop this many requests half-way
  bool refuse = false;
  _Server(this.body);
  Future<Uri> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      final r = req.headers.value(HttpHeaders.rangeHeader) ?? '';
      ranges.add(r);
      agents.add(req.headers.value(HttpHeaders.userAgentHeader));
      if (refuse) {
        req.response.statusCode = 403;
        await req.response.close();
        return;
      }
      final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(r)!;
      final a = int.parse(m.group(1)!), b = int.parse(m.group(2)!);
      final part = body.sublist(a, b + 1);
      req.response.statusCode = 206;
      req.response.contentLength = part.length;
      if (dropNext > 0) {
        dropNext--;
        final sock = await req.response.detachSocket(writeHeaders: true);
        sock.add(part.sublist(0, part.length ~/ 2));
        await sock.flush();
        sock.destroy();
        return;
      }
      req.response.add(part);
      await req.response.close();
    });
    return Uri.parse('http://127.0.0.1:${http.port}/videoplayback?id=x');
  }
}

void main() {
  final body = Uint8List.fromList(List.generate(3500000, (i) => (i * 31 + 7) & 0xff));

  Future<Uint8List> collect(Stream<List<int>> s) async {
    final b = BytesBuilder(copy: false);
    await for (final d in s) {
      b.add(d);
    }
    return b.takeBytes();
  }

  test('fetches the stream in bounded pieces with its own user agent', () async {
    final srv = _Server(body);
    final url = await srv.start();
    addTearDown(() => srv.http.close(force: true));
    final src = ChunkedHttpSource(url, length: body.length, mime: 'audio/webm; codecs="opus"', userAgent: 'TestAgent/1');
    final r = await src.request();
    expect(r.contentType, 'audio/webm');
    expect(r.contentLength, body.length);
    final got = await collect(r.stream);
    expect(got, body);
    expect(srv.ranges, ['bytes=0-1048575', 'bytes=1048576-2097151', 'bytes=2097152-3145727', 'bytes=3145728-3499999']);
    expect(srv.agents.toSet(), {'TestAgent/1'});
  });

  test('a range request from the player (seek) returns exactly that part', () async {
    final srv = _Server(body);
    final url = await srv.start();
    addTearDown(() => srv.http.close(force: true));
    final src = ChunkedHttpSource(url, length: body.length, mime: 'audio/mp4');
    final r = await src.request(2000000, 2100000);
    expect(r.offset, 2000000);
    expect(r.sourceLength, body.length);
    expect(await collect(r.stream), body.sublist(2000000, 2100000));
  });

  test('a connection dropped mid-piece is resumed where it stopped (no gap, no repeat)', () async {
    final srv = _Server(body)..dropNext = 2;
    final url = await srv.start();
    addTearDown(() => srv.http.close(force: true));
    final src = ChunkedHttpSource(url, length: body.length, mime: 'audio/mp4');
    final got = await collect((await src.request()).stream);
    expect(got.length, body.length);
    expect(got, body);
  });

  test('a refusal (403) is passed on at once so a fresh link is fetched', () async {
    final srv = _Server(body)..refuse = true;
    final url = await srv.start();
    addTearDown(() => srv.http.close(force: true));
    final src = ChunkedHttpSource(url, length: body.length, mime: 'audio/mp4');
    await expectLater(collect((await src.request()).stream), throwsA(isA<StreamRefused>()));
    expect(srv.ranges.length, 1, reason: 'not retried');
  });
}
