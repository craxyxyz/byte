import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:byte/cast/cast_discovery.dart';
import 'package:byte/cast/cast_protocol.dart';
import 'package:byte/cast/cast_relay.dart';
import 'package:byte/cast/cast_session.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/data/addons.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/data/smb_source.dart';
import 'package:byte/player/audio_route.dart';
import 'package:byte/services.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class FakeLink implements CastLink {
  final _in = StreamController<List<int>>();
  final sent = <CastMessage>[];
  final _framer = CastFramer();
  void Function(CastMessage m)? onSend;
  @override
  Stream<List<int>> get input => _in.stream;
  @override
  void add(List<int> bytes) {
    for (final m in _framer.add(bytes)) {
      sent.add(m);
      onSend?.call(m);
    }
  }

  void reply(String ns, Map<String, dynamic> payload, {String from = 'receiver-0'}) =>
      _in.add(CastMessage(sourceId: from, destinationId: 'sender-0', namespace: ns, payload: jsonEncode(payload)).frame());
  @override
  Future<void> close() async => _in.close();
}

class FakeSmb implements SmbBackend {
  final files = {'/Music/Arijit Singh - Tum Hi Ho.flac': Uint8List.fromList(List.generate(1000, (i) => i % 256))};
  @override
  Future<List<SmbEntry>> shares() async => const [SmbEntry('Music', '/Music', true)];
  @override
  Future<List<SmbEntry>> list(String path) async => [
    const SmbEntry('Old', '/Music/Old', true),
    for (final f in files.keys) SmbEntry(f.split('/').last, f, false, size: files[f]!.length),
    const SmbEntry('notes.txt', '/Music/notes.txt', false),
  ];
  @override
  Future<int> length(String path) async => files[path]!.length;
  @override
  Future<Stream<List<int>>> read(String path, int start, int endExclusive) async => Stream.value(files[path]!.sublist(start, endExclusive));
  @override
  Future<void> close() async {}
}

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
  });

  group('Cast', () {
    test('messages survive encode → frame → split chunks → decode', () {
      const m = CastMessage(sourceId: 'sender-0', destinationId: 'receiver-0', namespace: CastNs.receiver, payload: '{"type":"LAUNCH","appId":"CC1AD845","t":"तुम ही हो"}');
      final f = m.frame();
      final framer = CastFramer();
      final out = [...framer.add(f.sublist(0, 3)), ...framer.add(f.sublist(3, 20)), ...framer.add(f.sublist(20))];
      expect(out.length, 1);
      expect(out.single.namespace, CastNs.receiver);
      expect(out.single.json['t'], 'तुम ही हो');
      expect(out.single.destinationId, 'receiver-0');
    });

    test('session: connect, launch the media receiver, load a song, play/pause, answer pings', () async {
      final link = FakeLink();
      link.onSend = (m) {
        final j = m.json;
        if (j['type'] == 'LAUNCH') {
          link.reply(CastNs.receiver, {
            'type': 'RECEIVER_STATUS',
            'requestId': j['requestId'],
            'status': {
              'applications': [
                {'appId': 'CC1AD845', 'transportId': 'web-7', 'sessionId': 's-1'},
              ],
            },
          });
        }
        if (j['type'] == 'LOAD') {
          link.reply(CastNs.media, {
            'type': 'MEDIA_STATUS',
            'requestId': j['requestId'],
            'status': [
              {'mediaSessionId': 3, 'playerState': 'PLAYING', 'currentTime': 0},
            ],
          }, from: 'web-7');
        }
      };
      final s = CastSession(link);
      await s.open();
      expect(s.transportId, 'web-7');
      await s.load(url: 'http://192.168.1.5:8899/a.m4a', contentType: 'audio/mp4', title: 'Tum Hi Ho', artist: 'Arijit Singh');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      s.pause();
      s.play();
      link.reply(CastNs.heartbeat, {'type': 'PING'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final types = link.sent.map((m) => m.json['type']).toList();
      expect(types, containsAllInOrder(['CONNECT', 'LAUNCH', 'CONNECT', 'LOAD', 'PAUSE', 'PLAY']));
      expect(types, contains('PONG'));
      final load = link.sent.firstWhere((m) => m.json['type'] == 'LOAD').json;
      expect((load['media'] as Map)['contentType'], 'audio/mp4');
      expect(((load['media'] as Map)['metadata'] as Map)['title'], 'Tum Hi Ho');
      await s.close();
    });

    test('relay serves a song with Range (seeking) and forgets old paths', () async {
      final relay = CastRelay();
      await relay.start(loopbackOnly: true);
      final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
      final u = relay.publish(RelaySource.custom(length: data.length, reader: (s, e) async => Stream.value(data.sublist(s, e)), contentType: 'audio/flac'));
      // flutter_test answers every HttpClient call with 400; this one must be real
      final c = HttpOverrides.runWithHttpOverrides(() => HttpClient(), _RealHttp());
      final req = await c.getUrl(u);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=1000-1999');
      final res = await req.close();
      final body = await res.fold<List<int>>([], (a, b) => a..addAll(b));
      expect(res.statusCode, 206);
      expect(body, data.sublist(1000, 2000));
      expect(res.headers.value(HttpHeaders.contentRangeHeader), 'bytes 1000-1999/5000');
      final bad = await (await c.getUrl(u.replace(path: '/nope'))).close();
      expect(bad.statusCode, 404);
      c.close(force: true);
      await relay.stop();
    });

    test('speakers found by the iPhone browser and by mDNS text records', () {
      final d = castDevicesFromMaps([
        {'id': 'a1', 'name': 'Living Room', 'host': '192.168.1.20', 'port': 8009, 'model': 'Nest Audio'},
        {'id': 'a1', 'name': 'Living Room', 'host': '192.168.1.20', 'port': 8009},
        {'name': 'No host'},
      ]);
      expect(d.length, 1);
      expect(d.single.model, 'Nest Audio');
      expect(parseCastTxt('id=x\nfn=Bedroom TV\nmd=Chromecast'), {'id': 'x', 'fn': 'Bedroom TV', 'md': 'Chromecast'});
    });
  });

  group('addons', () {
    test('add by link with a key, search, stream with real format badges, lyrics, Dolby Atmos preference', () async {
      final asked = <NetRequest>[];
      final net = FakeNet((r, _) {
        asked.add(r);
        final p = r.url.path;
        if (r.headers['Authorization'] != 'Bearer secret') return jsonRes({'error': 'key'}, 401);
        if (p.endsWith('/manifest.json')) return jsonRes({'id': 'home', 'name': 'Home NAS', 'resources': ['search', 'stream', 'lyrics']});
        if (p.endsWith('/search')) {
          return jsonRes({
            'tracks': [
              {'id': '1', 'title': 'Tum Hi Ho', 'artist': 'Arijit Singh', 'duration': 262, 'codec': 'flac', 'bitDepth': 24, 'sampleRate': 96000},
              {'id': '2', 'title': 'Kesariya', 'artist': 'Arijit Singh', 'codec': 'aac', 'bitrate': 256000},
              {'id': '3', 'title': 'Dolby Song', 'artist': 'X', 'codec': 'eac3-joc'},
            ],
          });
        }
        if (p.contains('/stream/')) return jsonRes({'url': 'files/1.flac', 'codec': 'flac', 'bitDepth': 16, 'sampleRate': 44100});
        if (p.endsWith('/lyrics')) return jsonRes({'synced': '[00:01.00] Hum tere bin'});
        return null;
      });
      final ad = Addons(net);
      await ad.open();
      await expectLater(ad.add('https://nas.local:8443/byte'), throwsA(isA<AddonProblem>()));
      final a = await ad.add('https://nas.local:8443/byte', token: 'secret');
      expect(a.name, 'Home NAS');
      final r = await ad.search(a, 'arijit');
      expect(r.items.length, 3);
      expect(r.items.first.isAddon, isTrue);
      expect(ad.formats[r.items[0].id]!.badge, 'Hi-Res Lossless');
      expect(ad.formats[r.items[1].id]!.badge, isNull, reason: 'AAC is lossy: no badge');
      expect(ad.formats[r.items[2].id]!.badge, 'Spatial surround');
      final st = await ad.stream(r.items.first.id);
      expect(st.url.toString(), 'https://nas.local:8443/byte/files/1.flac');
      expect(st.format.badge, 'Lossless');
      expect(st.headers['Authorization'], 'Bearer secret');
      expect(asked.last.url.queryParameters.containsKey('prefer'), isFalse);
      ad.preferAtmos = () => true;
      await ad.stream(r.items.first.id);
      expect(asked.last.url.queryParameters['prefer'], 'atmos');
      final l = await ad.lyrics(r.items.first);
      expect(l!.$1!.single.text, 'Hum tere bin');
      expect(l.$3, 'Home NAS');
      await ad.remove(a.id);
      expect(ad.all, isEmpty);
    });
  });

  group('SMB', () {
    test('connect, list shares and folders, songs from file names, ranged reads', () async {
      final smb = SmbSource(connector: (h, u, p, d) async => FakeSmb());
      await smb.open();
      final shares = await smb.connect('192.168.1.10', 'apurba', 'pw');
      expect(shares.single.name, 'Music');
      expect(smb.configured, isTrue);
      final es = await smb.list('/Music');
      final audio = es.where((e) => e.isAudio).toList();
      expect(audio.length, 1);
      final it = SmbSource.itemFor(audio.single);
      expect(it.title, 'Tum Hi Ho');
      expect(it.artistLine, 'Arijit Singh');
      expect(it.isSmb && it.isLocal && !it.isOnPhone, isTrue);
      expect(SmbSource.pathOf(it.id), '/Music/Arijit Singh - Tum Hi Ho.flac');
      expect(await smb.length(SmbSource.pathOf(it.id)!), 1000);
      final bytes = await (await smb.read(SmbSource.pathOf(it.id)!, 10, 20)).first;
      expect(bytes.length, 10);
      await smb.forget();
      expect(smb.configured, isFalse);
    });
  });

  group('settings that change behaviour', () {
    test('track length tolerance decides when lengths "match"', () {
      const t = ExtTrack('Tum Hi Ho', 'Arijit Singh', durationMs: 262000);
      const c = Item(kind: ItemKind.song, id: 'x', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], durationSec: 268);
      matchToleranceSec = 3;
      final strict = matchScore(t, c);
      matchToleranceSec = 8;
      final loose = matchScore(t, c);
      expect(loose, greaterThan(strict));
      matchToleranceSec = 3;
    });

    test('output info from the phone, and the USB DAC mixer follows Prefer USB DAC / Bit-perfect', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('byte/audio'), (c) async {
        calls.add(c);
        if (c.method == 'usbMixer') return (c.arguments as Map)['mode'];
        return null;
      });
      final i = AudioRouteInfo.fromMap({'deviceName': 'Apurba\'s Phone', 'outputType': 'usb', 'outputName': 'FiiO KA3', 'sampleRate': 48000, 'volume': 7, 'maxVolume': 14, 'atmos': false});
      expect(i.label, 'FiiO KA3');
      expect(i.volume, 0.5);
      expect(i.outputKind, 'USB DAC');
      sv.route.setForTest(i);
      sv.settings.preferUsbDac = true;
      sv.settings.bitPerfect = false;
      await sv.applyUsbMixer();
      expect(calls.last.arguments, {'mode': 'best'});
      sv.settings.bitPerfect = true;
      await sv.applyUsbMixer();
      expect(calls.last.arguments, {'mode': 'bitperfect'});
      sv.settings.bitPerfect = false;
      sv.route.setForTest(const AudioRouteInfo(deviceName: 'P', outputType: 'speaker'));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('byte/audio'), null);
    });
  });
}

class _RealHttp extends HttpOverrides {}
