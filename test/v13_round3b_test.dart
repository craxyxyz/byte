import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/innertube_parse.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/streams.dart';
import 'package:byte/data/addons.dart';
import 'package:byte/data/audio_format.dart';
import 'package:byte/data/settings.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/home_widget_sync.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/widgets.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';

import 'helpers.dart';

Map<String, dynamic> _panel(String id, String title, String type) => {
  'videoId': id,
  'title': {
    'runs': [
      {'text': title},
    ],
  },
  'longBylineText': {
    'runs': [
      {'text': 'Arijit Singh'},
    ],
  },
  'lengthText': {
    'runs': [
      {'text': '4:22'},
    ],
  },
  'navigationEndpoint': {
    'watchEndpoint': {
      'videoId': id,
      'watchEndpointMusicSupportedConfigs': {
        'watchEndpointMusicConfig': {'musicVideoType': type},
      },
    },
  },
};

/// A `next` answer whose first entry is a song with a music video (the
/// video starts with a 12 s intro), then two plain songs.
Map<String, dynamic> nextWithVersions() => {
  'contents': {
    'playlistPanelRenderer': {
      'contents': [
        {
          'playlistPanelVideoWrapperRenderer': {
            'primaryRenderer': {'playlistPanelVideoRenderer': _panel('AUDIO000001', 'Tum Hi Ho', 'MUSIC_VIDEO_TYPE_ATV')},
            'counterpart': [
              {
                'counterpartRenderer': {'playlistPanelVideoRenderer': _panel('VIDEO000001', 'Tum Hi Ho (Video)', 'MUSIC_VIDEO_TYPE_OMV')},
                'segmentMap': {
                  'segment': [
                    {'primaryVideoStartTimeMilliseconds': '0', 'counterpartVideoStartTimeMilliseconds': '12000', 'durationMilliseconds': '250000'},
                  ],
                },
              },
            ],
          },
        },
        {'playlistPanelVideoRenderer': _panel('SONG0000002', 'Channa Mereya', 'MUSIC_VIDEO_TYPE_ATV')},
        {'playlistPanelVideoRenderer': _panel('SONG0000003', 'Kesariya', 'MUSIC_VIDEO_TYPE_ATV')},
      ],
    },
  },
};

Map<String, dynamic> _fmt(int itag, String mime, int bitrate, {int? height}) => {
  'itag': itag,
  'mimeType': mime,
  'bitrate': bitrate,
  'url': 'https://media.example/x/$itag?expire=4102444800',
  'height': ?height,
};

class _VersionsYt extends InnerTube {
  _VersionsYt(super.net);
  @override
  Future<SongVersions?> versions(String videoId) async => parseVersions(nextWithVersions(), videoId);
}

/// A client-by-client player double for stream selection.
class _ClientsYt extends InnerTube {
  final Map<String, List<Object>> answers; // client name → answers in order (Map = player, Exception = fail)
  final List<String> calls = [];
  _ClientsYt(super.net, this.answers);
  @override
  Future<Map<String, dynamic>> player(String videoId, {List<ClientSpec> clients = playerClients}) async {
    final c = clients.first.name;
    calls.add(c);
    final q = answers[c] ?? const [];
    final i = calls.where((x) => x == c).length - 1;
    final a = i < q.length ? q[i] : (q.isEmpty ? Exception('no answer') : q.last);
    if (a is Exception) throw a;
    return {...(a as Map<String, dynamic>), '_client': c};
  }
}

Map<String, dynamic> _player(List<Map<String, dynamic>> fmts) => {
  'playabilityStatus': {'status': 'OK'},
  'streamingData': {'adaptiveFormats': fmts},
};

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
  });

  group('versions (audio ⇄ music video)', () {
    test('finds both versions and lines up the time (12 s video intro)', () {
      final v = parseVersions(nextWithVersions(), 'AUDIO000001')!;
      expect(v.hasBoth, isTrue);
      expect(v.audio!.item.id, 'AUDIO000001');
      expect(v.video!.item.id, 'VIDEO000001');
      expect(v.other('AUDIO000001')!.item.id, 'VIDEO000001');
      expect(v.map(const Duration(seconds: 60), fromId: 'AUDIO000001'), const Duration(seconds: 72));
      expect(v.map(const Duration(seconds: 72), fromId: 'VIDEO000001'), const Duration(seconds: 60));
      // in the video's intro: the song's start
      expect(v.map(const Duration(seconds: 5), fromId: 'VIDEO000001'), Duration.zero);
      // looked up from the video's id too
      expect(parseVersions(nextWithVersions(), 'VIDEO000001')!.audio!.item.id, 'AUDIO000001');
      expect(parseVersions(nextWithVersions(), 'SONG0000002'), isNull);
    });

    test('the other version is not added to the queue as another song', () {
      final ids = parseNext(nextWithVersions()).queue.map((i) => i.id).toList();
      expect(ids, ['AUDIO000001', 'SONG0000002', 'SONG0000003']);
    });

    test('no segment map: same time', () {
      final v = SongVersions(
        const Rendition(Item(kind: ItemKind.song, id: 'a', title: 'a'), 'MUSIC_VIDEO_TYPE_ATV'),
        const Rendition(Item(kind: ItemKind.video, id: 'b', title: 'b'), 'MUSIC_VIDEO_TYPE_OMV'),
        const [],
      );
      expect(v.map(const Duration(seconds: 33), fromId: 'a'), const Duration(seconds: 33));
    });
  });

  group('music videos play as sound only', () {
    testWidgets('a music video plays from its official audio track; no video stream is fetched', (tester) async {
      await tester.runAsync(() async {
        final net = FakeNet(catalogue);
        final yt = _VersionsYt(net);
        final h = ByteAudioHandler(resolver: StreamResolver(yt), yt: yt, library: sv.library, settings: sv.settings);
        await h.playItems([const Item(kind: ItemKind.video, id: 'VIDEO000001', title: 'Tum Hi Ho (Official Video)')]);
        final players = net.log.where((r) => r.url.path.endsWith('/player')).map((r) => (jsonDecode(utf8.decode(r.body!)) as Map)['videoId']).toSet();
        expect(players, {'AUDIO000001'});
        expect(h.currentStream.value!.mime, startsWith('audio/'));
        // what's shown stays the item that was tapped
        expect(h.current.value!.id, 'VIDEO000001');
        // a plain song isn't looked up
        await h.playItems([const Item(kind: ItemKind.song, id: 'SONG0000002', title: 'Channa Mereya')]);
        expect(net.log.where((r) => r.url.path.endsWith('/next') && utf8.decode(r.body!).contains('SONG0000002')).length, lessThanOrEqualTo(1));
        await h.stop();
      });
    });
  });

  group('audio quality: Best by default', () {
    test('Best picks Opus 160 over AAC 128, and Opus 256 when it is there', () {
      final pool = [
        _fmt(140, 'audio/mp4; codecs="mp4a.40.2"', 130000),
        _fmt(251, 'audio/webm; codecs="opus"', 150000),
        _fmt(249, 'audio/webm; codecs="opus"', 50000),
      ];
      expect(pickAudioStream(_player(pool), AudioQuality.high)!.itag, 251);
      expect(pickAudioStream(_player([...pool, _fmt(774, 'audio/webm; codecs="opus"', 256000)]), AudioQuality.high)!.itag, 774);
      // iPhone (MP4 only): AAC 256 if there, else AAC 128
      expect(pickAudioStream(_player(pool), AudioQuality.high, preferMp4: true)!.itag, 140);
      expect(pickAudioStream(_player([...pool, _fmt(141, 'audio/mp4; codecs="mp4a.40.2"', 256000)]), AudioQuality.high, preferMp4: true)!.itag, 141);
      // data saver: the smallest
      expect(pickAudioStream(_player(pool), AudioQuality.low)!.itag, 249);
      // an odd stream with a higher bitrate doesn't beat Opus 160
      expect(bestAudioFormat([_fmt(251, 'audio/webm; codecs="opus"', 140000), _fmt(600, 'audio/webm; codecs="opus"', 170000)])['itag'], 251);
    });

    test('Wi-Fi, mobile data and downloads all default to Best', () async {
      final box = await Hive.openBox('settings');
      await box.delete('qWifi');
      await box.delete('qMobile');
      await box.delete('qDownload');
      expect(sv.settings.wifiQuality, AudioQuality.high);
      expect(sv.settings.mobileQuality, AudioQuality.high);
      expect(sv.settings.downloadQuality, AudioQuality.high);
    });

    test('the old "Normal" default is lifted to Best once; a later choice sticks', () async {
      final box = await Hive.openBox('settings');
      await box.put('qMobile', AudioQuality.normal.index);
      await box.delete('qBest13');
      final s = Settings();
      await s.open();
      expect(s.mobileQuality, AudioQuality.high);
      s.mobileQuality = AudioQuality.normal;
      await Future<void>.delayed(Duration.zero);
      final again = Settings();
      await again.open();
      expect(again.mobileQuality, AudioQuality.normal);
      await box.delete('qMobile');
    });

    test('backup client had only a low stream: the main client is tried again for Best', () async {
      final low = _player([_fmt(139, 'audio/mp4; codecs="mp4a.40.5"', 48000)]);
      final high = _player([_fmt(251, 'audio/webm; codecs="opus"', 160000), _fmt(140, 'audio/mp4; codecs="mp4a.40.2"', 130000)]);
      final yt = _ClientsYt(sv.net, {
        playerClients[0].name: [Exception('blip'), Exception('blip'), high],
        playerClients[1].name: [low],
      });
      final r = StreamResolver(yt, retryPause: Duration.zero);
      final s = await r.resolve('ABCDEFGHIJK', AudioQuality.high, probe: false);
      expect(s.itag, 251);
      expect(yt.calls, [playerClients[0].name, playerClients[0].name, playerClients[1].name, playerClients[0].name]);
    });

    test('main client still down: the low stream plays rather than nothing', () async {
      final low = _player([_fmt(139, 'audio/mp4; codecs="mp4a.40.5"', 48000)]);
      final yt = _ClientsYt(sv.net, {
        playerClients[0].name: [Exception('down')],
        playerClients[1].name: [low],
      });
      final r = StreamResolver(yt, retryPause: Duration.zero);
      expect((await r.resolve('ABCDEFGHIJK', AudioQuality.high, probe: false)).itag, 139);
    });
  });

  group('home-screen widget', () {
    test('sends the song, play state and cover; only real changes', () async {
      final cur = ValueNotifier<Item?>(null);
      final pb = StreamController<PlaybackState>.broadcast();
      final sent = <Map<String, Object?>>[];
      final w = HomeWidgetSync(current: cur, playback: pb.stream, invoke: (m, a) async => sent.add(a), artFile: (_) async => null);
      w.start();
      await Future<void>.delayed(Duration.zero);
      expect(sent.single['title'], isNull);
      cur.value = const Item(kind: ItemKind.song, id: 'x', title: 'Kesariya', artists: [ArtistRef('Arijit Singh')]);
      await Future<void>.delayed(Duration.zero);
      expect(sent.last['title'], 'Kesariya');
      expect(sent.last['artist'], 'Arijit Singh');
      expect(sent.last['playing'], false);
      pb.add(PlaybackState(playing: true));
      await Future<void>.delayed(Duration.zero);
      expect(sent.last['playing'], true);
      final n = sent.length;
      pb.add(PlaybackState(playing: true, updatePosition: const Duration(seconds: 3)));
      await Future<void>.delayed(Duration.zero);
      expect(sent.length, n);
      w.stop();
      await pb.close();
    });
  });

  group('loading skeletons and list length', () {
    test('total length reads like a person would say it', () {
      expect(fmtTotal(45 * 60), '45 min');
      expect(fmtTotal(92 * 60), '1 hr 32 min');
      expect(fmtTotal(120 * 60), '2 hr');
      final items = [for (var i = 0; i < 24; i++) Item(kind: ItemKind.song, id: 's$i', title: 's', durationSec: 230)];
      expect(listSummary(items), '24 songs • 1 hr 32 min');
      expect(listSummary(const [Item(kind: ItemKind.song, id: 'a', title: 'a')]), '1 song');
    });

    testWidgets('loading list is a skeleton', (t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: LoadingList(rows: 3))));
      expect(find.byKey(const ValueKey('skeleton-list')), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });


  group('lossless badge: only when the file really is lossless', () {
    Uint8List flac({int rate = 96000, int bits = 24, int ch = 2}) {
      final b = Uint8List(42);
      b.setAll(0, 'fLaC'.codeUnits);
      b[4] = 0x80; // last block, STREAMINFO
      b[7] = 34;
      final s = 8;
      b[s + 10] = (rate >> 12) & 0xff;
      b[s + 11] = (rate >> 4) & 0xff;
      b[s + 12] = ((rate & 0x0f) << 4) | (((ch - 1) & 0x07) << 1) | (((bits - 1) >> 4) & 0x01);
      b[s + 13] = ((bits - 1) & 0x0f) << 4;
      return b;
    }

    Uint8List wav({int fmt = 1, int rate = 44100, int bits = 16}) {
      final b = ByteData(44);
      void tag(int o, String t) => t.codeUnits.asMap().forEach((i, c) => b.setUint8(o + i, c));
      tag(0, 'RIFF');
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      b.setUint32(16, 16, Endian.little);
      b.setUint16(20, fmt, Endian.little);
      b.setUint16(22, 2, Endian.little);
      b.setUint32(24, rate, Endian.little);
      b.setUint16(34, bits, Endian.little);
      return b.buffer.asUint8List();
    }

    Uint8List mp4(String type, {int cookieBits = 0, int cookieRate = 0}) {
      final b = ByteData(120);
      void tag(int o, String t) => t.codeUnits.asMap().forEach((i, c) => b.setUint8(o + i, c));
      tag(4, 'ftyp');
      tag(20, 'stsd');
      final e = 32;
      tag(e + 4, type);
      b.setUint16(e + 24, 2);
      b.setUint16(e + 26, 16);
      b.setUint32(e + 32, 44100 << 16);
      if (cookieBits > 0) {
        final c = e + 36;
        tag(c + 4, 'alac');
        b.setUint8(c + 12 + 5, cookieBits);
        b.setUint8(c + 12 + 9, 2);
        b.setUint32(c + 12 + 20, cookieRate);
      }
      return b.buffer.asUint8List();
    }

    test('FLAC 24/96 → Hi-Res Lossless · 24-bit/96 kHz', () {
      final f = parseAudioHeader(flac())!;
      expect(f.codec, 'flac');
      expect(f.sampleRate, 96000);
      expect(f.bitDepth, 24);
      expect(f.label, 'Hi-Res Lossless · 24-bit/96 kHz');
      expect(parseAudioHeader(flac(rate: 44100, bits: 16))!.label, 'Lossless · 16-bit/44.1 kHz');
    });
    test('WAV PCM is lossless; compressed WAV is not', () {
      expect(parseAudioHeader(wav())!.label, 'Lossless · 16-bit/44.1 kHz');
      expect(parseAudioHeader(wav(fmt: 0x55))!.label, isNull); // MP3 inside a WAV
    });
    test('.m4a: ALAC is lossless, AAC is not (the name says nothing)', () {
      expect(parseAudioHeader(mp4('alac', cookieBits: 24, cookieRate: 48000))!.label, 'Hi-Res Lossless · 24-bit/48 kHz');
      expect(parseAudioHeader(mp4('mp4a'))!.label, isNull);
      expect(parseAudioHeader(mp4('mp4a'))!.codec, 'aac');
    });
    test('MP3 and Ogg: no badge', () {
      final mp3 = Uint8List.fromList([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, 0, 0xFF, 0xFB, 0x90, 0x00]);
      expect(parseAudioHeader(mp3)!.label, isNull);
      final ogg = Uint8List.fromList([...'OggS'.codeUnits, ...List.filled(24, 0), ...'OpusHead'.codeUnits]);
      expect(parseAudioHeader(ogg)!.codec, 'opus');
      expect(parseAudioHeader(ogg)!.label, isNull);
    });
    test('YouTube Music streams never get a lossless badge', () {
      expect(const SourceFormat(codec: 'opus', bitrate: 160000).label, isNull);
      expect(const SourceFormat(codec: 'aac', bitrate: 256000).label, isNull);
    });
    test('a real file on disk is read from its header', () async {
      final d = Directory.systemTemp.createTempSync('byte_ll_');
      final f = File('${d.path}/song.mp3')..writeAsBytesSync(flac()); // named .mp3, is FLAC
      expect((await AudioFormats.of(f.path))!.codec, 'flac');
      d.deleteSync(recursive: true);
    });
  });
}
