// Byte © 2026 Apurba Laskar.
// 1.4.6 web playback: when the Byte web server can't fetch songs (the
// catalogue's robot check on its address), the web app says so once and
// stops, instead of "Couldn't play …, skipped" through the whole queue.
import 'dart:async';

import 'package:byte/core/models.dart';
import 'package:byte/core/net_proxy.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'helpers.dart';

Item s(String id) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: 200);

void main() {
  group('the web server says why a song did not play', () {
    final ep = Uri.parse('https://p.supabase.co/functions/v1/byte-proxy');
    WebProxyNet net(int status, String body, {void Function(http.Request)? seen}) => WebProxyNet(
          ep,
          client: MockClient((r) async {
            seen?.call(r);
            return http.Response(body, status);
          }),
        );

    test('1.4.6 server: 503 "blocked: bot check" → the blocked message', () async {
      http.Request? req;
      final n = net(503, '{"error":"blocked: bot check. The music service is blocking this server\'s address","proxy":"byte-proxy"}', seen: (r) => req = r);
      expect(await n.playProblem('dQw4w9WgXcQ'), WebProxyNet.playBlockedMessage);
      expect(req!.url.queryParameters['play'], 'dQw4w9WgXcQ');
      expect(req!.headers['range'], 'bytes=0-1', reason: 'a two-byte read, not the whole song');
    });

    test('1.4.5 server (deployed today): 502 JSON parse error on the robot page → the blocked message', () async {
      final n = net(502, '{"error":"SyntaxError: Unexpected token \'<\', \\"<html><hea\\"... is not valid JSON","proxy":"byte-proxy"}');
      expect(await n.playProblem('dQw4w9WgXcQ'), WebProxyNet.playBlockedMessage);
    });

    testWidgets('the live server answers only after ~25 s: still the blocked message (it used to time out at 15 s)', (tester) async {
      final n = WebProxyNet(
        ep,
        client: MockClient((r) => Future.delayed(const Duration(seconds: 25), () => http.Response('{"error":"SyntaxError: Unexpected token \'<\', \\"<html><hea\\"... is not valid JSON","proxy":"byte-proxy"}', 502))),
      );
      String? why;
      var done = false;
      unawaited(n.playProblem('dQw4w9WgXcQ').then((v) {
        why = v;
        done = true;
      }));
      await tester.pump(const Duration(seconds: 26));
      expect(done, isTrue);
      expect(why, WebProxyNet.playBlockedMessage);
    });

    test('a song that plays (206), or another error, is not "blocked"', () async {
      expect(await net(206, 'ab').playProblem('dQw4w9WgXcQ'), isNull);
      expect(await net(502, '{"error":"This video is unavailable"}').playProblem('dQw4w9WgXcQ'), isNull);
    });
  });

  group('player', () {
    late Services sv;
    late ByteAudioHandler p;
    setUp(() async {
      sv = await makeServices();
      p = sv.player;
      sv.settings.autoplay = false;
      p.retryBackoff = (_) => Duration.zero;
    });
    tearDown(() async {
      ByteAudioHandler.webPlayProblem = null;
      fakeAudio.failLoad = (_) => false;
      await p.stop();
    });

    test('blocked: one clear message, no skipping through the queue', () async {
      final asked = <String>[];
      ByteAudioHandler.webPlayProblem = (id) async {
        asked.add(id);
        return WebProxyNet.playBlockedMessage;
      };
      fakeAudio.failLoad = (_) => true;
      await p.playItems([s('w0'), s('w1'), s('w2')]);
      final end = DateTime.now().add(const Duration(seconds: 4));
      while (p.error.value == null && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(p.error.value, WebProxyNet.playBlockedMessage);
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(p.current.value?.id, 'w0', reason: '1.4.5 skipped every song, one after another');
      expect(p.notice.value ?? '', isNot(contains('skipped')));
      expect(asked, ['w0']);
    });

    test('not blocked (one bad song): the old retry-then-skip still works', () async {
      ByteAudioHandler.webPlayProblem = (id) async => null;
      fakeAudio.failLoad = (uri) => uri.contains('/w0/');
      await p.playItems([s('w0'), s('w1')]);
      final end = DateTime.now().add(const Duration(seconds: 6));
      while (p.current.value?.id != 'w1' && DateTime.now().isBefore(end)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(p.current.value?.id, 'w1');
    });
  });
}
