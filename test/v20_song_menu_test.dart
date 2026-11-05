import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:byte/app.dart';
import 'package:byte/automix/automix_service.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/innertube_parse.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/streams.dart';
import 'package:byte/data/cache_ops.dart';
import 'package:byte/data/library.dart';
import 'package:byte/data/settings.dart';
import 'package:byte/player/resume_point.dart';
import 'package:byte/player/stop_on_close_native.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart' show lyricsNowMs;
import 'package:byte/ui/now_playing.dart' show NowPlayingScreen, SeekBar;
import 'package:byte/ui/player_parts.dart';
import 'package:byte/ui/screens/audio_lab_screen.dart';
import 'package:byte/ui/screens/browse_screen.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;
import 'v13_round3b_test.dart' show nextWithVersions;

// Byte 2.0.0+2004: the player's song menu has everything the other music
// players' menus have, working, and keeps every entry Byte had.

Map<String, dynamic> _fmt(int itag, String mime, int bitrate) => {
  'itag': itag,
  'mimeType': mime,
  'bitrate': bitrate,
  'url': 'https://media.example/x/$itag?expire=4102444800',
};

class _QualityYt extends InnerTube {
  final List<Map<String, dynamic>> formats;
  _QualityYt(super.net, this.formats);
  @override
  Future<Map<String, dynamic>> player(String videoId, {List<ClientSpec> clients = playerClients}) async => {
    'playabilityStatus': {'status': 'OK'},
    'streamingData': {'adaptiveFormats': formats},
    '_client': clients.first.name,
  };

  @override
  Future<SongVersions?> versions(String videoId) async => parseVersions(nextWithVersions(), videoId);
}

const _two = Item(
  kind: ItemKind.song,
  id: 'menuSong001',
  title: 'Two Artists',
  artists: [ArtistRef('Artist One', 'UCartist00001'), ArtistRef('Artist Two', 'UCartist00002')],
  album: 'Menu Album',
  albumId: 'MPREb_E4GfUXfDfhy',
);

void main() {
  late Services sv;
  final shared = <String>[];
  String? clipboard;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
    final m = TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/share'), (call) async {
      shared.add('${call.arguments}');
      return call.method == 'shareWithResult' ? 'dev.fluttercommunity.plus/share/unavailable' : null;
    });
    m.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      return null;
    });
  });

  Future<void> openMenu(WidgetTester tester, Item it) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
      await sv.player.playItems(album.tracks);
    });
    await tester.pumpWidget(const ByteApp());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('mini')));
    await settle(tester);
    final ctx = tester.element(find.byType(SeekBar).first);
    unawaited(showPlayerMore(ctx, it));
    await settle(tester);
  }

  Future<void> show(WidgetTester tester, Finder f) async {
    final list = find.byKey(const ValueKey('song-menu-list'));
    for (var i = 0; i < 40; i++) {
      if (f.evaluate().isNotEmpty) {
        final r = tester.getRect(f.first);
        if (r.bottom <= 820 && r.top >= 90) return;
      }
      await tester.drag(list, const Offset(0, -150));
      await tester.pump();
    }
  }

  Future<void> tapRow(WidgetTester tester, String key) async {
    final f = find.byKey(ValueKey(key));
    await show(tester, f);
    await tester.tap(f);
    await settle(tester);
  }

  Future<void> end(WidgetTester tester) async {
    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  group('the menu: layout', () {
    testWidgets('has every new entry and every old one, in groups, with album / artist subtitles', (tester) async {
      await openMenu(tester, _two);
      final titles = <String>[];
      final list = find.byKey(const ValueKey('song-menu-list'));
      expect(find.byKey(const ValueKey('menu-share')), findsOneWidget, reason: 'Share is the big tile at the top');
      var sawAlbum = false, sawArtists = false;
      for (var i = 0; i < 14; i++) {
        titles.addAll(tester.widgetList<ListTile>(find.descendant(of: list, matching: find.byType(ListTile))).map((l) => (l.title as Text).data ?? ''));
        sawAlbum = sawAlbum || find.text('Menu Album').evaluate().isNotEmpty;
        sawArtists = sawArtists || find.text('Artist One, Artist Two').evaluate().isNotEmpty;
        await tester.drag(list, const Offset(0, -240));
        await tester.pump();
      }
      const wanted = [
        'Upgrade quality', 'Start radio', 'Play next', 'Add to queue', 'Add to playlist', 'Remove from cache', 'Open album',
        'Open artist', 'Song info', 'Sleep timer', 'Playback speed', 'Audio Lab', 'Lyrics offset', 'Listen together', 'Copy log', 'More options',
      ];
      final have = titles.toSet();
      expect(wanted.where((w) => !have.contains(w)).toList(), isEmpty);
      expect(have.contains('Like') || have.contains('Remove from Liked'), isTrue);
      expect(have.contains('Start DJ') || have.contains('DJ'), isTrue);
      expect(have.contains('Download') || have.contains('Downloaded'), isTrue);
      expect(sawAlbum && sawArtists, isTrue, reason: 'Open album shows the album name, Open artist the artists');
      expect(find.descendant(of: list, matching: find.byType(Divider)), findsWidgets);
      expect(find.descendant(of: list, matching: find.byType(BackdropFilter)), findsNothing);
      await end(tester);
    });

    testWidgets('Audio Lab stays right after Playback speed (the 2003 request)', (tester) async {
      await openMenu(tester, sv.player.current.value!);
      await show(tester, find.widgetWithText(ListTile, 'Audio Lab'));
      final titles = tester.widgetList<ListTile>(find.byType(ListTile)).map((l) => (l.title as Text).data).toList();
      expect(titles[titles.indexOf('Playback speed') + 1], 'Audio Lab');
      await tester.tap(find.widgetWithText(ListTile, 'Audio Lab'));
      await settle(tester);
      expect(find.byType(AudioLabScreen), findsOneWidget);
      Navigator.of(tester.element(find.byType(AudioLabScreen)), rootNavigator: true).pop();
      await settle(tester);
      expect(find.byType(SeekBar), findsWidgets);
      await end(tester);
    });
  });

  group('the menu: actions', () {
    testWidgets('Share hands the song and its link to the share sheet', (tester) async {
      shared.clear();
      await openMenu(tester, sv.player.current.value!);
      await tapRow(tester, 'menu-share');
      expect(shared, isNotEmpty);
      expect(shared.first, contains('music.youtube.com/watch?v=${sv.player.current.value!.id}'));
      await end(tester);
    });

    testWidgets('Play next puts the song right after the current one; Add to queue puts it last', (tester) async {
      await openMenu(tester, _two);
      await tapRow(tester, 'menu-play-next');
      var order = sv.player.queueModel.playOrder.map((i) => i.id).toList();
      expect(order[sv.player.queueModel.position + 1], 'menuSong001');
      expect(find.text('Playing next'), findsWidgets);
      await tester.pump(const Duration(seconds: 5));
      await end(tester);

      const other = Item(kind: ItemKind.song, id: 'menuSong002', title: 'Queue Me');
      await openMenu(tester, other);
      await tapRow(tester, 'menu-add-queue');
      order = sv.player.queueModel.playOrder.map((i) => i.id).toList();
      expect(order.last, 'menuSong002');
      expect(find.text('Added to queue'), findsWidgets);
      await tester.pump(const Duration(seconds: 5));
      await end(tester);
    });

    testWidgets('Open album closes the player and opens the album page', (tester) async {
      await openMenu(tester, _two);
      expect(find.byType(NowPlayingScreen), findsOneWidget);
      await tapRow(tester, 'menu-album');
      await settle(tester);
      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(find.byType(BrowseScreen), findsOneWidget);
      await end(tester);
    });

    testWidgets('Open artist with two artists asks which one, then opens that page', (tester) async {
      await openMenu(tester, _two);
      await tapRow(tester, 'menu-artist');
      expect(find.byKey(const ValueKey('artist-UCartist00002')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('artist-UCartist00002')));
      await settle(tester);
      expect(find.byType(NowPlayingScreen), findsNothing);
      final page = tester.widget<BrowseScreen>(find.byType(BrowseScreen));
      expect(page.item.id, 'UCartist00002');
      expect(page.item.title, 'Artist Two');
      await end(tester);
    });

    testWidgets('Open artist with one artist opens it straight away', (tester) async {
      const one = Item(kind: ItemKind.song, id: 'menuSong003', title: 'Solo', artists: [ArtistRef('Only Artist', 'UConly000001')], albumId: 'MPREb_E4GfUXfDfhy', album: 'A');
      await openMenu(tester, one);
      await tapRow(tester, 'menu-artist');
      expect(tester.widget<BrowseScreen>(find.byType(BrowseScreen)).item.id, 'UConly000001');
      await end(tester);
    });

    testWidgets('Copy log puts the app log on the clipboard and says so', (tester) async {
      clipboard = null;
      await openMenu(tester, sv.player.current.value!);
      await tapRow(tester, 'menu-copy-log');
      expect(clipboard, isNotNull);
      expect(clipboard, startsWith('Byte 2.0.0'));
      expect(clipboard, contains('No errors recorded.'));
      expect(find.text('Log copied'), findsWidgets);
      await tester.pump(const Duration(seconds: 5));
      await end(tester);
    });

    testWidgets('Lyrics offset: stepper and slider move it, it is saved for this song only, Reset clears it', (tester) async {
      final it = sv.player.current.value!;
      sv.settings.setLyricsOffsetFor(it.id, 0);
      await openMenu(tester, it);
      await tapRow(tester, 'menu-lyrics-offset');
      expect(find.text('In time'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('offset-plus')));
      await tester.tap(find.byKey(const ValueKey('offset-plus')));
      await tester.pump();
      expect(sv.settings.lyricsOffsetFor(it.id), 100);
      expect(find.text('+100 ms · lyrics earlier'), findsOneWidget);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('offset-minus')));
      }
      await tester.pump();
      expect(sv.settings.lyricsOffsetFor(it.id), -50);
      expect(find.text('−50 ms · lyrics later'), findsOneWidget);
      await tester.drag(find.byKey(const ValueKey('offset-slider')), const Offset(600, 0));
      await tester.pump();
      expect(sv.settings.lyricsOffsetFor(it.id), 5000);
      expect(sv.settings.lyricsOffsetFor('another-song'), 0);
      await tester.tap(find.byKey(const ValueKey('offset-reset')));
      await tester.pump();
      expect(sv.settings.lyricsOffsetFor(it.id), 0);
      await end(tester);
    });

    testWidgets('Song info and Sleep timer still open their sheets from the menu', (tester) async {
      await openMenu(tester, sv.player.current.value!);
      await show(tester, find.widgetWithText(ListTile, 'Song info'));
      await tester.tap(find.widgetWithText(ListTile, 'Song info'));
      await settle(tester);
      expect(find.text('You'), findsOneWidget);
      Navigator.of(tester.element(find.text('You')), rootNavigator: true).pop();
      await settle(tester);
      unawaited(showPlayerMore(tester.element(find.byType(SeekBar).first), sv.player.current.value!));
      await settle(tester);
      await show(tester, find.widgetWithText(ListTile, 'Sleep timer'));
      await tester.tap(find.widgetWithText(ListTile, 'Sleep timer'));
      await settle(tester);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Sleep timer'), findsNothing);
      await end(tester);
    });
  });

  group('engine', () {
    test('lyrics offset is saved per song and moves the lyrics clock', () async {
      final id = sv.player.current.value?.id ?? 'x';
      sv.settings.setLyricsOffsetFor(id, 0);
      final base = lyricsNowMs();
      sv.settings.setLyricsOffsetFor(id, 800);
      expect(lyricsNowMs() - base, closeTo(800, 120));
      sv.settings.setLyricsOffsetFor(id, 99999);
      expect(sv.settings.lyricsOffsetFor(id), 10000, reason: 'stays inside ±10 s');
      sv.settings.setLyricsOffsetFor(id, 0);
      expect(sv.settings.lyricsOffsetFor(id), 0);
    });

    test('upgrade quality: picks the best stream, switches at the same spot, then says it is already the best', () async {
      sv.settings.wifiQuality = AudioQuality.normal;
      final yt = _QualityYt(sv.net, [
        _fmt(140, 'audio/mp4; codecs="mp4a.40.2"', 130000),
        _fmt(251, 'audio/webm; codecs="opus"', 160000),
      ]);
      final h = ByteAudioHandler(resolver: StreamResolver(yt, retryPause: Duration.zero), yt: yt, library: sv.library, settings: sv.settings);
      await h.playItems([const Item(kind: ItemKind.song, id: 'upgradeSng1', title: 'Upgrade Me')]);
      expect(h.currentStream.value!.itag, 140, reason: 'Normal quality plays AAC 128');
      await h.seek(const Duration(seconds: 42));
      final r = await h.upgradeCurrentQuality();
      expect(r.kind, QualityUpgradeKind.upgraded);
      expect(r.message, 'Now playing at Opus · 160 kbps');
      expect(h.currentStream.value!.itag, 251);
      expect(h.isUpgraded('upgradeSng1'), isTrue);
      final loads = fakeAudio.players.values.expand((p) => p.loads).toList();
      expect(loads.last, contains('/251'));
      expect(h.position.inSeconds, closeTo(42, 2), reason: 'same spot, no restart');
      final again = await h.upgradeCurrentQuality();
      expect(again.kind, QualityUpgradeKind.alreadyBest);
      expect(again.message, 'Already the best quality: Opus · 160 kbps');
      await h.stop();
      await h.disposeAll();
    });

    test('upgrade quality: a paused song stays paused; files on the phone and nothing playing say why not', () async {
      sv.settings.wifiQuality = AudioQuality.normal;
      final yt = _QualityYt(sv.net, [_fmt(140, 'audio/mp4; codecs="mp4a.40.2"', 130000), _fmt(251, 'audio/webm; codecs="opus"', 160000)]);
      final h = ByteAudioHandler(resolver: StreamResolver(yt, retryPause: Duration.zero), yt: yt, library: sv.library, settings: sv.settings);
      expect((await h.upgradeCurrentQuality()).kind, QualityUpgradeKind.nothingPlaying);
      await h.playItems([const Item(kind: ItemKind.song, id: 'upgradeSng2', title: 'Paused')]);
      await h.pause();
      expect((await h.upgradeCurrentQuality()).kind, QualityUpgradeKind.upgraded);
      expect(h.playing, isFalse);
      await h.playItems([const Item(kind: ItemKind.song, id: 'local:/music/a.mp3', title: 'On phone')]);
      final r = await h.upgradeCurrentQuality();
      expect(r.kind, QualityUpgradeKind.unavailable);
      expect(r.message, isNotEmpty);
      await h.stop();
      await h.disposeAll();
    });

    test('shouldUpgrade: more bitrate, or a better codec at the same bitrate; never a step down', () {
      AudioStream s(int itag, int br) => AudioStream(itag: itag, url: 'u', mime: itag == 251 ? 'audio/webm; codecs="opus"' : 'audio/mp4', bitrate: br, expiresAt: DateTime(2100), client: 'c');
      expect(shouldUpgrade(null, s(251, 160000)), isTrue);
      expect(shouldUpgrade(s(140, 130000), s(251, 160000)), isTrue);
      expect(shouldUpgrade(s(251, 160000), s(251, 160000)), isFalse);
      expect(shouldUpgrade(s(251, 160000), s(140, 130000)), isFalse);
      expect(shouldUpgrade(s(140, 160000), s(251, 160000)), isTrue);
      expect(streamLabel(s(251, 160000)), 'Opus · 160 kbps');
      expect(streamLabel(s(140, 130000)), 'AAC · 130 kbps');
    });

    test('Start radio keeps the song playing and fills the queue behind it with similar songs', () async {
      await sv.player.playItems([
        const Item(kind: ItemKind.song, id: 'SONG0000002', title: 'Channa Mereya'),
        const Item(kind: ItemKind.song, id: 'manualQueue1', title: 'Manual'),
      ]);
      final cur = sv.player.current.value!;
      await sv.player.startRadio(cur);
      expect(sv.player.current.value!.id, cur.id, reason: 'the song is not restarted');
      expect(sv.player.queueModel.playOrder.any((i) => i.id == 'manualQueue1'), isFalse, reason: 'the old up-next list is replaced');
      expect(sv.player.playingFrom.value, endsWith('Radio'));
      await sv.player.stop();
    });

    test('Remove from cache deletes the download and the fetched copy, frees the space, keeps the library', () async {
      final dir = Directory.systemTemp.createTempSync('byte_cache_');
      addTearDown(() => dir.deleteSync(recursive: true));
      const it = Item(kind: ItemKind.song, id: 'cacheSong001', title: 'Cached');
      final dl = File('${dir.path}/cacheSong001.m4a')..writeAsBytesSync(List.filled(4096, 1));
      await sv.library.putDownload(DownloadRecord(item: it, path: dl.path, bytes: 4096, mime: 'audio/mp4', at: DateTime.now()));
      await sv.library.setLiked(it, true);
      final autoDir = Directory('${dir.path}/automix')..createSync();
      File('${autoDir.path}/cacheSong001.webm').writeAsBytesSync(List.filled(2048, 2));
      File('${autoDir.path}/other0000002.webm').writeAsBytesSync(List.filled(100, 3));
      final automix = AutomixService(resolver: sv.resolver, settings: sv.settings, library: sv.library)..cacheDir = () async => autoDir;
      expect(sv.library.isDownloaded(it.id), isTrue);
      expect(hasCachedAudio(sv, it), isTrue);

      expect(await automix.evict(it.id), 2048);
      expect(File('${autoDir.path}/cacheSong001.webm').existsSync(), isFalse);
      expect(File('${autoDir.path}/other0000002.webm').existsSync(), isTrue, reason: 'other songs stay');

      final r = await removeSongCache(sv, it);
      expect(r.hadDownload, isTrue);
      expect(r.bytes, 4096);
      expect(r.message, 'Removed from cache · 4 KB freed');
      expect(dl.existsSync(), isFalse);
      expect(sv.library.isDownloaded(it.id), isFalse);
      expect(sv.library.isLiked(it.id), isTrue, reason: 'the song stays in the library');
      final nothing = await removeSongCache(sv, it);
      expect(nothing.nothing, isTrue);
      expect(nothing.message, 'Nothing saved on this phone for this song');
      expect(formatBytes(3 * 1024 * 1024), '3.0 MB');
    });
  });

  group('swiping Byte away from recents', () {
    test('default: music STOPS and the lock screen player goes; Byte remembers the song and spot', () async {
      expect(sv.settings.stopOnClose, isTrue, reason: 'ON by default');
      await sv.player.playItems([const Item(kind: ItemKind.song, id: 'SONG0000002', title: 'Channa Mereya')]);
      expect(sv.player.playing, isTrue);
      await sv.player.seek(const Duration(seconds: 20));
      await sv.player.onTaskRemoved();
      expect(sv.player.playing, isFalse);
      expect(sv.player.playbackState.value.processingState, AudioProcessingState.idle, reason: 'no media notification / lock-screen controls');
      final r = ResumePoint.decode(sv.library.get(ByteAudioHandler.resumeKey));
      expect(r?.item.id, 'SONG0000002', reason: 'saved before stopping, so reopening restores it');
    });

    test('with "Stop music on close from recents" off, a playing song keeps going', () async {
      sv.settings.stopOnClose = false;
      await sv.player.playItems([const Item(kind: ItemKind.song, id: 'SONG0000002', title: 'Channa Mereya')]);
      await sv.player.onTaskRemoved();
      expect(sv.player.playing, isTrue);
      sv.settings.stopOnClose = true;
      await sv.player.stop();
    });

    test('a choice saved under the old key is not kept: everybody starts ON', () {
      final box = Hive.box('settings');
      unawaited(box.put('stopOnClose', false)); // what an earlier 2.0 build saved
      unawaited(box.delete('stopOnClose2'));
      expect(sv.settings.stopOnClose, isTrue);
    });

    test('the setting is pushed to the Android service (byte/playback), on Android only', () async {
      final calls = <MethodCall>[];
      final m = TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
      m.setMockMethodCallHandler(StopOnCloseNative.channel, (c) async {
        calls.add(c);
        return true;
      });
      addTearDown(() => m.setMockMethodCallHandler(StopOnCloseNative.channel, null));
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await StopOnCloseNative.push(true);
      expect(calls, isEmpty, reason: 'iPhone: nothing to push (iOS cannot tell a swipe-away)');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      Settings.onStopOnCloseChanged = StopOnCloseNative.push;
      sv.settings.stopOnClose = false;
      await Future<void>.delayed(Duration.zero);
      expect(calls.single.method, 'stopOnClose');
      expect(calls.single.arguments, false);
      sv.settings.stopOnClose = true;
      await Future<void>.delayed(Duration.zero);
      expect(calls.last.arguments, true);
      Settings.onStopOnCloseChanged = null;
      debugDefaultTargetPlatformOverride = null;
    });

    test('Android wiring: the service ends everything when the task goes (stop_on_close), the app writes the flag, the main file pushes it at start', () {
      final java = File('packages/audio_service/android/src/main/java/com/ryanheise/audioservice/AudioService.java').readAsStringSync();
      expect(java, contains('"stop_on_close", true'), reason: 'ON when nothing was written yet');
      expect(java, contains('STOP_FOREGROUND_REMOVE'));
      expect(java, contains('getNotificationManager().cancel(NOTIFICATION_ID)'));
      expect(java, contains('killProcess'));
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final service = RegExp(r'<service[^>]*com\.ryanheise\.audioservice\.AudioService[^>]*>').firstMatch(manifest)!.group(0)!;
      expect(service, contains('foregroundServiceType="mediaPlayback"'));
      expect(service, isNot(contains('stopWithTask="true"')), reason: 'the service handles it itself (onTaskRemoved), and only when the setting is on');
      final kt = File('android/app/src/main/kotlin/com/apurbalaskar/byteapp/MainActivity.kt').readAsStringSync();
      expect(kt, contains('"byte/playback"'));
      expect(kt, contains('stop_on_close'));
      expect(File('lib/main.dart').readAsStringSync(), contains('StopOnCloseNative.push(settings.stopOnClose)'));
    });

    test('background and screen-off playback keep working: foreground media service, wake lock and Wi-Fi lock while playing', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('FOREGROUND_SERVICE_MEDIA_PLAYBACK'));
      expect(manifest, contains('android.permission.WAKE_LOCK'));
      final java = File('packages/audio_service/android/src/main/java/com/ryanheise/audioservice/AudioService.java').readAsStringSync();
      expect(java, contains('createWifiLock'));
      expect(java, contains('wifiLock.acquire()'));
      expect(java, contains('wifiLock.release()'));
    });
  });
}
