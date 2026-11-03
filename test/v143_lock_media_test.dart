// © 2026 Apurba Laskar
//
// 1.4.3: the phone's own lock-screen media panel (and the notification) gets
// a big square picture as a file on the phone, title / artist / album /
// length, a seek bar that moves and can be dragged, and prev / play / next.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_service/audio_service.dart';
import 'package:byte/app.dart';
import 'package:byte/core/cover_cache.dart';
import 'package:byte/core/lock_art.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/lock/lock_screen_view.dart' show defaultLockImage;
import 'package:byte/player/byte_handler.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/now_playing.dart';
import 'package:byte/ui/shell.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

Item song(String id, {int sec = 190}) => Item(
  kind: ItemKind.song,
  id: id,
  title: 'Song $id',
  artists: const [ArtistRef('Singer A'), ArtistRef('Singer B')],
  album: 'Album $id',
  durationSec: sec,
  thumb: 'https://lh3.googleusercontent.com/$id=w120-h120',
);

Item video(String id) => Item(kind: ItemKind.video, id: id, title: 'Video $id', artists: const [ArtistRef('Band')], durationSec: 190, thumb: 'https://i.ytimg.com/vi/$id/hqdefault.jpg');

FutureOr<NetResponse?> net30(NetRequest r, String body) {
  if (r.url.toString().contains('/player')) {
    final id = (jsonDecode(body) as Map)['videoId'] as String;
    return jsonRes(fakePlayer(id, durationMs: 190000));
  }
  return catalogue(r, body);
}

/// A [w]×[h] PNG: red middle square, blue sides (to see what was cropped).
Future<Uint8List> picture(int w, int h) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), ui.Paint()..color = const ui.Color(0xFF0000FF));
  final s = w < h ? w : h;
  c.drawRect(ui.Rect.fromLTWH((w - s) / 2, (h - s) / 2, s.toDouble(), s.toDouble()), ui.Paint()..color = const ui.Color(0xFFFF0000));
  final img = await rec.endRecording().toImage(w, h);
  return (await img.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
}

Future<ui.Image> decode(File f) async => (await (await ui.instantiateImageCodec(await f.readAsBytes())).getNextFrame()).image;

void main() {
  late Services sv;
  late ByteAudioHandler p;
  late Directory dir;
  final fetched = <String>[];
  late Uint8List sq1080, frame1280, sq544;
  final defaultRead = LockArt.read;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sq1080 = await picture(1080, 1080);
    frame1280 = await picture(1280, 720);
    sq544 = await picture(544, 544);
  });

  setUp(() async {
    sv = await makeServices(net: FakeNet(net30));
    p = sv.player;
    sv.settings.autoplay = false;
    sv.settings.crossfadeSeconds = 0;
    sv.settings.preloadNext = false;
    fakeAudio.durationFor = (_) => const Duration(minutes: 3, seconds: 10);
    dir = Directory.systemTemp.createTempSync('lockart_');
    await CoverCache.init(dir);
    LockArt.pinned.clear();
    LockArt.keep = 20;
    fetched.clear();
    // the web: big square music covers and 1280×720 video frames
    CoverCache.fetch = (u) async {
      fetched.add(u);
      if (u.contains('=w1080-h1080')) return sq1080;
      if (u.contains('/maxresdefault.jpg') || u.contains('/hq720.jpg')) return frame1280;
      return null;
    };
  });

  tearDown(() async {
    await p.stop();
    CoverCache.dir = null;
    CoverCache.fetch = (u) async => null;
    LockArt.read = defaultRead;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> until(bool Function() ok, {int ms = 6000, String what = ''}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out: $what');
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
  }

  bool artIsFile() => p.mediaItem.value?.artUri?.isScheme('file') ?? false;

  test('lock screen art: a local square file of at least 720 px, plus title, artist, album and length', () async {
    await p.playItems([song('sahiba00001')]);
    await until(artIsFile, what: 'art becomes a file on the phone');
    final m = p.mediaItem.value!;
    final f = File(m.artUri!.toFilePath());
    expect(f.existsSync(), isTrue);
    expect(f.path, startsWith(dir.path), reason: 'kept with Byte\'s own files');
    final img = await decode(f);
    expect(img.width, greaterThanOrEqualTo(720));
    expect(img.width, img.height, reason: 'square');
    expect(fetched.first, contains('=w1080-h1080'), reason: 'the 1080 px cover, not the 120 px one');
    expect(m.title, 'Song sahiba00001');
    expect(m.artist, 'Singer A, Singer B');
    expect(m.album, 'Album sahiba00001');
    expect(m.duration, const Duration(minutes: 3, seconds: 10), reason: 'lock-screen seek bar shows 03:10');
  });

  test('a YouTube frame: the best file (maxres first), centre-cropped to a 1080 square', () async {
    await p.playItems([video('vframe00001')]);
    await until(artIsFile, what: 'square frame file');
    expect(fetched.first, contains('/maxresdefault.jpg'));
    final img = await decode(File(p.mediaItem.value!.artUri!.toFilePath()));
    expect((img.width, img.height), (1080, 1080));
    final px = (await img.toByteData())!;
    expect(px.getUint8(0), greaterThan(200), reason: 'corner comes from the red middle, not the blue sides');
    expect(px.getUint8(2), lessThan(50));
    expect(LockArt.sources(video('x')).map((u) => u.split('/').last), ['maxresdefault.jpg', 'hq720.jpg', 'sddefault.jpg', 'hqdefault.jpg']);
  });

  test('while the picture downloads the big web cover shows, then the file replaces it', () async {
    final gate = Completer<void>();
    final real = CoverCache.fetch;
    CoverCache.fetch = (u) async {
      await gate.future;
      return real(u);
    };
    await p.playItems([song('slowcover01')]);
    final first = p.mediaItem.value!.artUri.toString();
    expect(first, contains('=w1080-h1080'), reason: 'never empty, never the 120 px one');
    gate.complete();
    await until(artIsFile, what: 'file swapped in');
    expect(p.mediaItem.value!.duration, isNotNull, reason: 'swapping the art keeps the length');
  });

  test('offline: a smaller cached cover stands in, and the sharp one replaces it later', () async {
    final real = CoverCache.fetch;
    var online = false;
    CoverCache.fetch = (u) async {
      if (!online && u.contains('=w1080-h1080')) return null;
      if (u.contains('=w544-h544')) return sq544;
      return real(u);
    };
    final it = song('offline0001');
    final lo = await LockArt.make(it);
    expect(lo, isNotNull);
    expect(LockArt.isFull(lo!), isFalse);
    final img = await decode(lo);
    expect((img.width, img.height), (1080, 1080), reason: 'still a big square for the card');
    online = true;
    final hi = await LockArt.make(it);
    expect(LockArt.isFull(hi!), isTrue);
    expect(lo.existsSync(), isFalse, reason: 'the stand-in is gone');
    expect(LockArt.existing(it)!.path, hi.path);
  });

  test('every track change publishes that song\'s own art file', () async {
    await p.playItems([song('trackone001'), song('tracktwo001')]);
    await until(artIsFile);
    final a = p.mediaItem.value!.artUri!;
    await p.skipToNext();
    await until(() => p.mediaItem.value!.id == 'tracktwo001' && artIsFile(), what: 'second song art');
    final b = p.mediaItem.value!.artUri!;
    expect(b, isNot(a));
    expect(File(a.toFilePath()).existsSync(), isTrue, reason: 'the previous picture is still there while the system may be loading it');
    expect(LockArt.pinned, containsAll([a.toFilePath(), b.toFilePath()]));
  });

  test('the picture folder keeps the last 20 and never deletes the one on screen', () async {
    LockArt.read = (u) async => sq1080;
    final files = <File>[];
    for (var i = 0; i < 25; i++) {
      final f = await LockArt.make(song('keep${i.toString().padLeft(7, '0')}'));
      if (i == 0) LockArt.use(f!.path); // the first one is on screen the whole time (and the oldest)
      f!.setLastModifiedSync(DateTime(2026, 1, 1).add(Duration(minutes: i)));
      files.add(f);
    }
    await LockArt.prune();
    final left = LockArt.dir!.listSync().whereType<File>().map((f) => f.path).toSet();
    expect(left.length, 21, reason: '20 newest + the one on screen');
    expect(left, contains(files.first.path));
    for (var i = 1; i <= 4; i++) {
      expect(left.contains(files[i].path), isFalse, reason: 'old file $i trimmed');
    }
    expect(left, contains(files[5].path));
    // the cover cache's own clean-up never touches these
    CoverCache.maxBytes = 1;
    await CoverCache.trim();
    CoverCache.maxBytes = 150 * 1024 * 1024;
    expect(files.first.existsSync(), isTrue);
  });

  test('playback state: seek bar moves on its own and can be dragged; prev / play-pause / next', () async {
    await p.playItems([song('seekbar0001')]);
    await until(() => p.playbackState.value.playing, what: 'playing');
    var st = p.playbackState.value;
    expect(st.systemActions, contains(MediaAction.seek), reason: 'draggable lock-screen seek bar');
    expect(st.controls.map((c) => c.action), [MediaAction.skipToPrevious, MediaAction.pause, MediaAction.skipToNext]);
    expect(st.androidCompactActionIndices, [0, 1, 2]);
    expect(st.speed, 1.0, reason: 'the system moves the bar from position + speed');
    expect(st.bufferedPosition, greaterThan(Duration.zero));
    await p.seek(const Duration(minutes: 1, seconds: 37));
    await until(() => (p.playbackState.value.updatePosition - const Duration(minutes: 1, seconds: 37)).abs() < const Duration(milliseconds: 500), what: 'position published after seek');
    expect(p.position.inSeconds, inInclusiveRange(97, 98));
    await p.pause();
    await until(() => !p.playbackState.value.playing);
    st = p.playbackState.value;
    expect(st.controls.map((c) => c.action), [MediaAction.skipToPrevious, MediaAction.play, MediaAction.skipToNext]);
    expect(st.updatePosition.inSeconds, inInclusiveRange(97, 98), reason: 'paused bar stays where it is');
    await p.setSpeed(1.5);
    await until(() => p.playbackState.value.speed == 1.5, what: 'speed published');
  });

  test('notification / lock-screen config: full-size art, opens Byte, public on the lock screen', () {
    expect(byteAudioConfig.artDownscaleWidth, isNull, reason: 'no shrinking the lock-screen card');
    expect(byteAudioConfig.artDownscaleHeight, isNull);
    expect(byteAudioConfig.androidNotificationClickStartsActivity, isTrue);
    expect(byteAudioConfig.androidNotificationOngoing, isTrue);
    expect(byteAudioConfig.androidStopForegroundOnPause, isTrue);
    // the channel Byte makes first is the one the media service uses, public on the lock screen
    final kt = File('android/app/src/main/kotlin/com/apurbalaskar/byteapp/ByteMediaChannel.kt').readAsStringSync();
    expect(kt, contains('const val ID = "${byteAudioConfig.androidNotificationChannelId}"'));
    expect(kt, contains('lockscreenVisibility = Notification.VISIBILITY_PUBLIC'));
    expect(File('android/app/src/main/kotlin/com/apurbalaskar/byteapp/MainActivity.kt').readAsStringSync(), contains('ByteMediaChannel.ensure(this)'));
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('com.ryanheise.audioservice.AudioService'));
    expect(manifest, contains('android:foregroundServiceType="mediaPlayback"'));
    expect(manifest, contains('com.ryanheise.audioservice.MediaButtonReceiver'));
    // the media library's own notification is public too
    final pkgs = jsonDecode(File('.dart_tool/package_config.json').readAsStringSync()) as Map;
    final as = (pkgs['packages'] as List).cast<Map>().firstWhere((e) => e['name'] == 'audio_service');
    final java = File('${Uri.parse(as['rootUri'] as String).toFilePath()}/android/src/main/java/com/ryanheise/audioservice/AudioService.java');
    expect(java.existsSync(), isTrue); expect(java.readAsStringSync(), contains('setVisibility(NotificationCompat.VISIBILITY_PUBLIC)'));
  });

  test('Byte\'s own lock-screen player draws the same picture file', () {
    final f = File('${dir.path}/x.png')..writeAsBytesSync(sq1080);
    final img = defaultLockImage(Uri.file(f.path).toString());
    expect(img, isA<FileImage>());
    expect((img as FileImage).file.path, f.path);
    expect(defaultLockImage('https://lh3.googleusercontent.com/a=w1080-h1080'), isA<NetworkImage>());
  });

  testWidgets('tapping the media notification opens Now Playing (once)', (tester) async {
    final taps = StreamController<bool>.broadcast();
    final before = ShellState.notificationTaps;
    ShellState.notificationTaps = () => taps.stream;
    addTearDown(() => ShellState.notificationTaps = before);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.runAsync(() => sv.player.playItems([song('notiftap001')]));
    await tester.pumpWidget(const ByteApp());
    await settle(tester);
    expect(find.byType(NowPlayingScreen), findsNothing);
    taps.add(true);
    await settle(tester);
    expect(find.byType(NowPlayingScreen), findsOneWidget);
    taps.add(true);
    await settle(tester);
    expect(find.byType(NowPlayingScreen), findsOneWidget, reason: 'not stacked twice');
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await taps.close();
  });
}
