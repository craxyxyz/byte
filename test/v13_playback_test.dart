import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:byte/core/cover_cache.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Item s(String id, {int sec = 30}) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: sec, thumb: 'https://lh3.googleusercontent.com/$id=w120-h120');

/// Every stream link names the client it came from (…&c=IOS), like YouTube's.
FutureOr<NetResponse?> perClient(NetRequest r, String body) {
  final u = r.url.toString();
  if (u.contains('/player')) {
    final j = jsonDecode(body) as Map;
    final id = j['videoId'] as String;
    final client = ((j['context'] as Map)['client'] as Map)['clientName'] as String;
    final p = fakePlayer(id, durationMs: 30000);
    for (final f in (p['streamingData'] as Map)['adaptiveFormats'] as List) {
      (f as Map)['url'] = '${f['url']}&c=$client';
    }
    return jsonRes(p);
  }
  return catalogue(r, body);
}

/// Playback that keeps going: links refused mid-song, stalled streams,
/// streams that end early, stale prepared songs and slow covers.
void main() {
  late Services sv;
  late ByteAudioHandler p;
  late FakeNet net;
  setUp(() async {
    net = FakeNet(perClient);
    sv = await makeServices(net: net);
    p = sv.player;
    sv.settings.autoplay = false;
    sv.settings.normalizeVolume = false;
    sv.settings.crossfadeSeconds = 0;
    sv.settings.preloadNext = false;
    p.retryBackoff = (n) => Duration(milliseconds: n <= 1 ? 0 : 100);
    p.stallTimeout = const Duration(milliseconds: 900);
    fakeAudio.durationFor = (_) => const Duration(seconds: 30);
  });
  tearDown(() async => p.stop());

  Future<void> until(bool Function() ok, {int ms = 8000, String what = ''}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out: $what');
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  FakePlayerPlatform deckPlaying(String id) => fakeAudio.players.values.firstWhere((x) => x.playing && (x.uri ?? '').contains(id));
  bool isPlaying(String id) => fakeAudio.players.values.any((x) => x.playing && (x.uri ?? '').contains(id));
  int playerCalls(String id) => net.log.where((r) => r.url.toString().contains('/player') && utf8.decode(r.body ?? Uint8List(0)).contains(id)).length;

  test('each stream is fetched with its own client\'s user agent (no player-wide agent over it)', () async {
    await p.playItems([s('uagent00001')]);
    await until(() => isPlaying('uagent00001'), what: 'playing');
    final deck = deckPlaying('uagent00001');
    expect(deck.uri, contains('c=VISIONOS'));
    expect(deck.headers?['User-Agent'], visionOs.userAgent);
  });

  test('a 403 mid-song: fresh link from another client, same spot, no skip', () async {
    await p.playItems([s('refused0001'), s('refused0002')]);
    await until(() => isPlaying('refused0001'), what: 'playing');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    // the first client's links are now refused
    fakeAudio.failLoad = (u) => u.contains('refused0001') && u.contains('c=VISIONOS');
    deckPlaying('refused0001').failNow('Response code: 403');
    await until(() => isPlaying('refused0001') && fakeAudio.players.values.any((x) => x.playing && (x.uri ?? '').contains('c=ANDROID_VR')), what: 'resumed on another client');
    expect(p.current.value!.id, 'refused0001');
    expect(p.position.inMilliseconds, greaterThan(900), reason: 'resumed where it broke, not from 0');
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(p.current.value!.id, 'refused0001', reason: 'no late skip after a good retry');
    expect(p.error.value, isNull);
  });

  test('one failure reported twice still means one quiet retry (no skip 2 s later)', () async {
    await p.playItems([s('twicerep001'), s('twicerep002')]);
    await until(() => isPlaying('twicerep001'), what: 'playing');
    deckPlaying('twicerep001').failNow('Response code: 403');
    await until(() => isPlaying('twicerep001'), what: 'retry');
    await Future<void>.delayed(const Duration(milliseconds: 2600));
    expect(p.current.value!.id, 'twicerep001');
    expect(p.playing, isTrue);
  });

  test('a stream that stalls mid-song is re-fetched and carries on', () async {
    await p.playItems([s('stalled0001'), s('stalled0002')]);
    await until(() => isPlaying('stalled0001'), what: 'playing');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final before = playerCalls('stalled0001');
    final deck = deckPlaying('stalled0001');
    final loads = deck.loads.length;
    deck.stallNow();
    await until(() => fakeAudio.players.values.any((x) => x.loads.length > loads || (x != deck && (x.uri ?? '').contains('stalled0001') && x.playing)), what: 'reloaded');
    await until(() => isPlaying('stalled0001') && fakeAudio.players.values.any((x) => x.playing && x.state.name == 'ready'), what: 'playing again');
    expect(playerCalls('stalled0001'), greaterThan(before), reason: 'a fresh link was fetched');
    expect(p.current.value!.id, 'stalled0001');
  });

  test('"finished" halfway through (connection ended) resumes instead of moving on', () async {
    await p.playItems([s('earlyend001'), s('earlyend002')]);
    await until(() => isPlaying('earlyend001'), what: 'playing');
    await Future<void>.delayed(const Duration(milliseconds: 1000));
    deckPlaying('earlyend001').endEarlyNow();
    await until(() => isPlaying('earlyend001'), what: 'resumed');
    expect(p.current.value!.id, 'earlyend001');
    expect(p.position.inMilliseconds, greaterThan(700));
  });

  test('a song that really ends still moves on to the next', () async {
    fakeAudio.durationFor = (_) => const Duration(milliseconds: 1500);
    await p.playItems([Item(kind: ItemKind.song, id: 'realend0001', title: 'x', artists: const [ArtistRef('A')], durationSec: 2), s('realend0002')]);
    await until(() => p.current.value?.id == 'realend0002', what: 'next song');
  });

  test('an old prepared next song is fetched afresh when it starts', () async {
    sv.settings.preloadNext = true;
    fakeAudio.durationFor = (_) => const Duration(seconds: 30);
    await p.playItems([s('prepold0001'), s('prepold0002')]);
    await until(() => fakeAudio.players.values.any((x) => !x.playing && (x.uri ?? '').contains('prepold0002')), what: 'next prepared', ms: 40000);
    final callsBefore = playerCalls('prepold0002');
    p.preparedMaxAge = Duration.zero; // pretend hours went by
    await p.skipToNext();
    await until(() => isPlaying('prepold0002'), what: 'next playing');
    expect(playerCalls('prepold0002'), greaterThan(callsBefore), reason: 're-resolved instead of using the stale link');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('every retry failing: skips with a note saying so', () async {
    fakeAudio.failLoad = (u) => u.contains('deadsong001');
    await p.playItems([s('deadsong001'), s('deadsong002')]);
    await until(() => p.current.value?.id == 'deadsong002', what: 'skipped', ms: 12000);
    expect(p.notice.value, 'Couldn\'t play Song deadsong001, skipped');
    // it really tried more than once, and other clients too
    final tried = fakeAudio.players.values.expand((x) => x.loads).where((u) => u.contains('deadsong001')).toList();
    expect(tried.length, greaterThanOrEqualTo(3));
    expect(tried.any((u) => !u.contains('c=VISIONOS')), isTrue);
  });

  test('covers: one download for many askers, then straight from the phone; next two prefetched', () async {
    final dir = Directory.systemTemp.createTempSync('covers_');
    await CoverCache.init(dir);
    addTearDown(() {
      CoverCache.dir = null;
      CoverCache.fetch = (u) async => null;
    });
    final fetched = <String>[];
    CoverCache.fetch = (u) async {
      fetched.add(u);
      await Future<void>.delayed(const Duration(milliseconds: 300)); // a slow cover
      return Uint8List.fromList(List.filled(100, 7));
    };
    final r = await Future.wait([CoverCache.bytes('https://x/a.jpg'), CoverCache.bytes('https://x/a.jpg'), CoverCache.bytes('https://x/a.jpg')]);
    expect(fetched.length, 1);
    expect(r.every((b) => b!.length == 100), isTrue);
    final sw = Stopwatch()..start();
    await CoverCache.bytes('https://x/a.jpg');
    expect(fetched.length, 1, reason: 'second time comes from the disk');
    expect(sw.elapsedMilliseconds, lessThan(250));
    // playing a queue prefetches the next two songs' covers
    fetched.clear();
    await p.playItems([s('coverq00001'), s('coverq00002'), s('coverq00003'), s('coverq00004')]);
    await until(() => fetched.length >= 4, what: 'prefetch');
    expect(fetched.any((u) => u.contains('coverq00002')), isTrue);
    expect(fetched.any((u) => u.contains('coverq00003')), isTrue);
    expect(fetched.any((u) => u.contains('coverq00004')), isFalse);
    expect(fetched.where((u) => u.contains('coverq00002')).any((u) => u.contains('=w226-h226')), isTrue, reason: 'the small one too, not just max size');
    // trimming keeps the folder under its cap
    CoverCache.maxBytes = 250;
    await CoverCache.trim();
    final total = dir.listSync().whereType<File>().fold<int>(0, (a, f) => a + f.lengthSync());
    expect(total, lessThanOrEqualTo(250));
    CoverCache.maxBytes = 150 * 1024 * 1024;
  });

  test('lock screen / notification art: square and at least 1000 px', () async {
    await p.playItems([s('lockart0001')]);
    final art = p.mediaItem.value!.artUri.toString();
    expect(art, contains('=w1080-h1080'), reason: 'music art asked square at 1080');
    // YouTube video frames: the centre of the picture, never the black bars
    expect(CoverCache.squareCrop(1280, 720), const ui.Rect.fromLTWH(280, 0, 720, 720));
    expect(CoverCache.squareCrop(480, 360, letterboxed: true), const ui.Rect.fromLTWH(105, 45, 270, 270));
  });

  test('a video frame becomes a 1080×1080 square file used as the media art', () async {
    final dir = Directory.systemTemp.createTempSync('sq_');
    await CoverCache.init(dir);
    addTearDown(() {
      CoverCache.dir = null;
      CoverCache.fetch = (u) async => null;
    });
    // a 1280×720 frame: red centre, blue sides
    final rec = ui.PictureRecorder();
    final c = ui.Canvas(rec);
    c.drawRect(const ui.Rect.fromLTWH(0, 0, 1280, 720), ui.Paint()..color = const ui.Color(0xFF0000FF));
    c.drawRect(const ui.Rect.fromLTWH(280, 0, 720, 720), ui.Paint()..color = const ui.Color(0xFFFF0000));
    final png = (await (await rec.endRecording().toImage(1280, 720)).toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
    CoverCache.fetch = (u) async => u.contains('hq720') ? png : null;
    final video = Item(kind: ItemKind.video, id: 'vidframe001', title: 'v', artists: const [ArtistRef('A')], durationSec: 30, thumb: 'https://i.ytimg.com/vi/vidframe001/hqdefault.jpg');
    final f = await squareArtFor(video);
    expect(f, isNotNull);
    final img = (await (await ui.instantiateImageCodec(await f!.readAsBytes())).getNextFrame()).image;
    expect(img.width, 1080);
    expect(img.height, 1080);
    final px = (await img.toByteData())!;
    // corners are from the red centre, not the blue sides
    expect(px.getUint8(0), greaterThan(200));
    expect(px.getUint8(2), lessThan(50));
    expect(mediaItemFor(video).artUri!.scheme, 'file');
  });
}
