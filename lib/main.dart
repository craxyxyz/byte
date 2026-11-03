import 'dart:async';
import 'dart:io' show Platform;
import 'package:byte_desktop_audio/byte_desktop_audio.dart';
import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

import 'app.dart';
import 'ui/screens/settings_pages.dart' show applyRefreshRate;
import 'package:path_provider/path_provider.dart';
import 'core/cover_cache.dart';
import 'core/crash_log.dart';
import 'core/frame_log.dart';
import 'core/desktop_perftest.dart';
import 'brand.dart';
import 'core/innertube.dart';
import 'core/net.dart';
import 'core/streams.dart';
import 'data/account.dart';
import 'data/downloads.dart';
import 'data/library.dart';
import 'data/link_import.dart';
import 'data/local_music.dart';
import 'data/settings.dart';
import 'data/stats.dart';
import 'data/listen_together.dart';
import 'player/sync_adapter.dart';
import 'package:supabase/supabase.dart' show SupabaseClient;
import 'lyrics/lyrics_service.dart';
import 'player/byte_handler.dart';
import 'player/equalizer.dart';
import 'services.dart';
import 'player/audio_route.dart' show AudioRoute;
import 'audiolab/audio_lab.dart';
import 'audiolab/desktop_sound_backend.dart';
import 'player/crossfade.dart' show CrossfadePlan;
import 'data/spotify_account.dart';
import 'ui/web_logins.dart';
import 'automix/automix_service.dart';
import 'lock/lock_app.dart';
import 'lock/lock_bridge.dart';
import 'ui/glass.dart';
import 'player/home_widget_sync.dart';
import 'web/no_webview.dart';
import 'web/web_proxy.dart';
import 'ui/app_fullscreen.dart' show AppFullscreen;
import 'package:window_manager/window_manager.dart';
import 'ui/smooth_wheel.dart';

class HiveLyricsCache implements LyricsCache {
  final Box box;
  HiveLyricsCache(this.box);
  @override
  String? read(String key) => box.get(key) as String?;
  @override
  void write(String key, String value) {
    box.put(key, value);
    if (box.length > 800) box.deleteAt(0);
  }
}

/// The lock-screen player's own window (Android, LockScreenActivity).
@pragma('vm:entry-point')
void lockScreenMain() => runLockScreenApp();

/// Windows and Linux: no system media session (lock screen / media keys panel).
bool get desktopNoMediaSession => !kIsWeb && (Platform.isWindows || Platform.isLinux);

/// 1.4.3: keeps the party's app-resume hook alive.
AppLifecycleListener? partyLifecycle;

Future<void> main() async {
  // 1.4.5.2: the normal binding + smooth mouse-wheel scrolling on computers.
  ByteBinding.ensureInitialized();
  // Windows/Linux: songs play through Byte's desktop audio backend.
  ByteDesktopAudio.register();
  // 1.4.5: and the Audio Lab through the computer player's filters.
  DesktopSoundBackend.register();
  if (kReleaseMode) debugPrint = (String? message, {int? wrapWidth}) {};
  // 1.4.5.1: BYTE_FRAME_LOG=1 prints frames per second and their build /
  // raster time (desktop smoothness checks).
  if (!kIsWeb && Platform.environment['BYTE_FRAME_LOG'] == '1') FrameLog.start();
  // 1.4.5: uncaught errors go to a small log on the phone (About → Report a problem).
  String? logDir;
  if (!kIsWeb) {
    try {
      logDir = (await getApplicationSupportDirectory()).path;
    } catch (_) {}
  }
  CrashLog.install(CrashLog(dir: logDir, version: () => Brand.version));
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent, statusBarColor: Colors.transparent));

  // liquid glass goes lighter by itself on low-memory phones
  unawaited(GlassPerf.init());
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    // Computers: keep Byte's data in its own app-data folder, not in Documents.
    Hive.init('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}byte');
    // 1.4.5: full-screen lyrics put the window in real full screen (title bar
    // and taskbar / dock / menu bar covered); leaving restores the window.
    try {
      await windowManager.ensureInitialized();
      AppFullscreen.desktopHook = (on) => windowManager.setFullScreen(on);
    } catch (_) {
      // No window plugin: full-screen lyrics stay inside the window.
    }
  } else {
    await Hive.initFlutter('byte');
  }
  final settings = Settings();
  await settings.open();
  final library = Library();
  await library.open();
  final lyricsBox = await Hive.openBox('lyrics');

  // Web: every catalogue/lyrics call goes through the Byte web server (CORS).
  final Net net = kIsWeb ? WebProxy.net : HttpNet();
  // Windows/Linux: no in-app browser for the sign-in pages (macOS has one).
  if (desktopNoMediaSession) NoWebViewPlatform.install();
  if (kIsWeb) {
    NoWebViewPlatform.install(); // sign-in pages need the app; say so instead of crashing
    unawaited(WebProxy.net.ping());
    ByteAudioHandler.webPlayUrl = (id, q) => WebProxy.playUrl(id, low: q == AudioQuality.low);
  }
  final yt = InnerTube(net, gl: settings.contentRegion, hl: settings.language);
  final resolver = StreamResolver(yt);
  final equalizer = ByteEqualizer(settings);
  final automix = AutomixService(resolver: resolver, library: library, settings: settings);
  await automix.open();
  ByteAudioHandler makeHandler() => ByteAudioHandler(resolver: resolver, yt: yt, library: library, settings: settings, equalizer: equalizer, automix: automix);
  // Windows/Linux have no system media session for audio_service: the player runs on its own there.
  final handler = desktopNoMediaSession ? makeHandler() : await AudioService.init(builder: makeHandler, config: byteAudioConfig);
  try {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
  } catch (_) {}

  final downloads = Downloads(resolver, library, settings, net);
  final stats = ListeningStats();
  await stats.open();
  // Byte 1.0 users: "member since" = their first played song.
  if (library.history.isNotEmpty && settings.memberSince.isAfter(library.history.last.at)) settings.memberSince = library.history.last.at;
  final account = Account(yt, library);
  Services.i = Services(
    net: net,
    yt: yt,
    resolver: resolver,
    library: library,
    settings: settings,
    lyrics: LyricsService(net, yt, cache: HiveLyricsCache(lyricsBox)),
    downloads: downloads,
    local: LocalMusic(library),
    account: account,
    importer: LinkImporter(yt, net),
    player: handler,
    stats: stats,
    party: ListenTogether(
      player: HandlerSyncPlayer(handler),
      deviceId: settings.deviceId,
      displayName: () => settings.listenName.isNotEmpty ? settings.listenName : (account.name ?? 'Byte listener'),
      client: () => settings.ltServerUrl.isNotEmpty && settings.ltServerKey.isNotEmpty
          ? SupabaseClient(settings.ltServerUrl, settings.ltServerKey)
          : SupabaseClient(Backend.url, Backend.publishableKey),
      // 1.4.3: the party survives the app being closed or killed.
      store: JsonStringPartyStore(() => settings.ltSaved, (v) => settings.ltSaved = v),
      serverLabel: () => settings.ltServerKey.isNotEmpty ? settings.ltServerUrl : '',
    ),
  );
  // 1.4.3: back in front → the party reconnects at once (it never ends on its own).
  partyLifecycle = AppLifecycleListener(onResume: () => Services.i.party.appResumed());
  await Services.i.scrobbler.open();
  try {
    await Services.i.playLog.open();
  } catch (_) {}
  await Services.i.webdav.open();
  await Services.i.spotify.open();
  SpotifyAccount.webRefresher = refreshSpotifyQuietly;
  await Services.i.wireSources();
  // A fresh install starts with the welcome (an update never does).
  ByteApp.welcome = !kIsWeb && !settings.onboarded && Services.i.library.likes.isEmpty && Services.i.library.history.isEmpty && Platform.environment['BYTE_PERFTEST'] != '1';
  if (!ByteApp.welcome) settings.onboarded = true;
  // Storage → Song cache limit.
  Services.i.automix?.maxBytes = settings.songCacheMb * 1048576;
  Services.i.automix?.maxFiles = (settings.songCacheMb / 8).ceil();
  AudioRoute.listenToHardware = !kIsWeb;
  // Audio Lab: real effects on both players.
  await Services.i.lab.open();
  final labEngine = AudioLabEngine(Services.i.lab);
  Services.i.labEngine = labEngine;
  // 1.4.5: each deck's player session is followed (a song can start on a new
  // one), so every song, deck and hand-off gets the same sound.
  labEngine.watch([for (final p in handler.decks) p.androidAudioSessionIdStream]);
  IosSoundBackend.restoreClassic = () => unawaited(equalizer.apply());
  unawaited(labEngine.start());
  // 1.4.5.2: desktop smoothness check (CI only, BYTE_PERFTEST=1)
  if (!kIsWeb && Platform.environment['BYTE_PERFTEST'] == '1') unawaited(DesktopPerfTest.run());
  handler.pauseFadeMs = () => Services.i.lab.fadeOnPause ? Services.i.lab.fadeMs : 0;
  handler.keepTogether = (a, b) => Services.i.lab.keepTogether(a.albumId ?? a.album, b.albumId ?? b.album);
  void applyPitch() => unawaited(handler.setPitch(Services.i.lab.pitchFor(settings.speed)));
  Services.i.lab.addListener(applyPitch);
  settings.addListener(applyPitch);
  applyPitch();
  // One equalizer at a time: the Audio Lab one turns the classic one off and back.
  var labEqWas = Services.i.lab.eqOn;
  Services.i.lab.addListener(() {
    final on = Services.i.lab.eqOn;
    if (on && !labEqWas && settings.eqEnabled) settings.eqEnabled = false;
    labEqWas = on;
  });
  settings.addListener(() {
    if (settings.eqEnabled && Services.i.lab.eqOn) Services.i.lab.eqOn = false;
  });
  void applyCurve() => CrossfadePlan.linear = Services.i.lab.fadeCurve == FadeCurve.linear;
  Services.i.lab.addListener(applyCurve);
  applyCurve();
  // Keep the connected music account's library in step (quietly, after start-up).
  Timer(const Duration(seconds: 25), () => unawaited(Services.i.spotifySync.maybeSync()));
  Timer.periodic(const Duration(hours: 3), (_) => unawaited(Services.i.spotifySync.maybeSync()));
  // Gmail sync: same likes, playlists, history and settings on every device.
  unawaited(Services.i.startCloud().catchError((Object e) => debugPrint('sync: $e')));
  try {
    Services.i.startUsage();
  } catch (e) {
    debugPrint('usage: $e');
  }
  // Covers kept on the phone (instant the second time, prefetched for what's next).
  if (!kIsWeb) {
    try {
      await CoverCache.init(await getApplicationSupportDirectory());
    } catch (_) {}
  }
  StatsTicker(
    stats,
    isPlaying: () => handler.playing && !handler.loading.value,
    current: () => handler.current.value,
    playToken: () => handler.playToken,
    onHeard: (it, ms, session, at) {
      Services.i.scrobbler.tick(it, ms, session, at);
      Services.i.playLog.heard(it, ms, session, at);
    },
  ).start();
  // Listens saved while offline go out when the net comes back.
  Connectivity().onConnectivityChanged.listen((_) => Services.i.scrobbler.flush());
  await account.restore();
  await handler.setSpeed(settings.speed);
  if (settings.skipSilence) await handler.applySkipSilence();
  // Downloaded playlists pick up new songs (after a sync or an edit).
  library.addListener(downloads.refreshPlaylists);
  downloads.refreshPlaylists();
  if (settings.highPerformance) unawaited(applyRefreshRate(true));
  // Byte's own lock-screen player: armed while music plays (Settings → Playback).
  if (defaultTargetPlatform == TargetPlatform.android) LockScreenBridge(settings: settings, playback: handler.playbackState).start();
  // home-screen widget: cover, song, controls
  if (defaultTargetPlatform == TargetPlatform.android) HomeWidgetSync(current: handler.current, playback: handler.playbackState).start();
  // 1.4.5: Byte was closed (by Android or a swipe): the last song comes back
  // paused at its spot, on the player and the lock screen.
  try {
    await handler.restoreLast();
  } catch (e, st) {
    CrashLog.i?.record(e, st, source: 'Restore');
  }
  runApp(kIsWeb ? const WebShell(child: ByteApp()) : const ByteApp());
  unawaited(equalizer.apply()); // iPhone: send the saved equalizer to the player
  account.maybeAutoSync();
}
