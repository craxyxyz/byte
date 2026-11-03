import 'dart:async';
import 'package:flutter/foundation.dart';

import 'automix/automix_service.dart';
import 'core/innertube.dart';
import 'dj/dj_controller.dart';
import 'dj/dj_session.dart';
import 'dj/recommender.dart';
import 'dj/up_next.dart';
import 'dj/speech_input.dart';
import 'core/net.dart';
import 'core/streams.dart';
import 'data/account.dart';
import 'data/downloads.dart';
import 'data/library.dart';
import 'data/link_import.dart';
import 'data/listen_together.dart';
import 'data/local_music.dart';
import 'data/scrobble.dart';
import 'data/settings.dart';
import 'data/party_sound.dart';
import 'data/spotify_account.dart';
import 'data/spotify_sync.dart';
import 'data/service_library.dart';
import 'audiolab/audio_lab.dart';
import 'data/playlist_import.dart' show PlaylistMatcher;
import 'data/stats.dart';
import 'data/play_log.dart';
import 'data/webdav.dart';
import 'data/playlist_import.dart' show matchToleranceSec;
import 'lyrics/lyrics_service.dart';
import 'lyrics/translate.dart';
import 'cast/cast_controller.dart';
import 'cast/cast_relay.dart';
import 'data/addons.dart';
import 'data/smb_source.dart';
import 'player/audio_route.dart';
import 'package:just_audio/just_audio.dart' show AudioSource;
import 'dart:io' show File, Platform;
import 'data/usage.dart';
import 'player/byte_handler.dart';
import 'data/cloud_sync.dart';

/// Everything the screens talk to, created once at start-up.
class Services {
  static late Services i;

  final Net net;
  final InnerTube yt;
  final StreamResolver resolver;
  final Library library;
  final Settings settings;
  final LyricsService lyrics;

  /// Lyrics translation (made on first use).
  late final LyricsTranslator translator = LyricsTranslator(lyrics.net);
  final Downloads downloads;
  final LocalMusic local;
  final Account account;
  final LinkImporter importer;
  final ByteAudioHandler player;
  final ListeningStats stats;
  final ListenTogether party;

  /// Your own ListenBrainz / Last.fm scrobbling.
  late final Scrobbler scrobbler = Scrobbler(net);

  /// Your own Spotify login (your developer app's Client ID).
  late final SpotifyAccount spotify = SpotifyAccount(net);

  /// Settings → Audio Lab (equalizer, effects, transitions).
  final AudioLab lab = AudioLab();
  AudioLabEngine? labEngine;

  /// Keeps the connected account's Liked Songs and playlists in Byte.
  late final SpotifySync spotifySync = SpotifySync(
    account: spotify,
    library: library,
    matcher: (tracks, onProgress) async {
      final m = await PlaylistMatcher(yt).matchAll(tracks, onProgress: onProgress);
      return [for (final x in m) x.chosen];
    },
  );

  /// Liked songs + playlists from every other music app you log in to.
  late final LibrarySync libSync = LibrarySync(
    library: library,
    matcher: (tracks, onProgress) async {
      final m = await PlaylistMatcher(yt).matchAll(tracks, onProgress: onProgress);
      return [for (final x in m) x.chosen];
    },
  );

  /// Your own WebDAV music server.
  late final WebDav webdav = WebDav(net);

  /// Your SMB share (Windows / NAS).
  late final SmbSource smb = SmbSource();

  /// Sources you add by link (your own server's addon).
  late final Addons addons = Addons(net);

  /// Where the sound goes (phone, headphones, Bluetooth, USB DAC) + volume.
  late final AudioRoute route = AudioRoute();

  /// Plays SMB songs to this phone's own player (loopback only).
  late final CastRelay localRelay = CastRelay();

  /// Chromecast / Google Cast speakers and TVs on the Wi-Fi.
  late final CastController cast = CastController(
    player: player,
    sourceFor: (it) async {
      if (it.isSmb) {
        final p = SmbSource.pathOf(it.id)!;
        final len = await smb.length(p);
        return RelaySource.custom(length: len, reader: (s, e) => smb.read(p, s, e), contentType: _mimeFor(p));
      }
      if (it.isAddon) {
        final s = await addons.stream(it.id);
        return RelaySource.url(s.url, _mimeFor(s.url.path), headers: s.headers);
      }
      return defaultCastSource(
        it,
        resolver: resolver,
        downloadedPath: (id) {
          final d = library.download(id);
          return d != null && File(d.path).existsSync() ? d.path : null;
        },
        quality: settings.wifiQuality,
      );
    },
  );

  static String _mimeFor(String path) {
    final ext = path.split('?').first.split('.').last.toLowerCase();
    return switch (ext) {
      'mp3' => 'audio/mpeg',
      'flac' => 'audio/flac',
      'wav' => 'audio/wav',
      'ogg' || 'opus' || 'oga' => 'audio/ogg',
      'webm' => 'audio/webm',
      'aiff' || 'aif' => 'audio/aiff',
      _ => 'audio/mp4',
    };
  }

  /// Hooks the player up to addons, SMB and the audio route (called once at start-up).
  String _usbMode = '';

  /// USB DAC: its own best rate, or bit-perfect (Playback settings).
  Future<void> applyUsbMixer() async {
    if (route.info.outputType != 'usb') {
      _usbMode = '';
      return;
    }
    final want = settings.bitPerfect ? 'bitperfect' : (settings.preferUsbDac ? 'best' : 'off');
    if (want == _usbMode) return;
    _usbMode = want;
    await route.usbMixer(want);
  }

  Future<void> wireSources() async {
    AudioRouteInfo.ownerName = () => settings.djName;
    addons.preferAtmos = () => settings.dolbyAtmos && route.info.atmos;
    matchToleranceSec = settings.trackLengthTolerance;
    settings.addListener(() => matchToleranceSec = settings.trackLengthTolerance);
    route.addListener(applyUsbMixer);
    settings.addListener(applyUsbMixer);
    await smb.open();
    await addons.open();
    await spotifySync.open();
    await libSync.open();

    lyrics
      ..order = (() => settings.lyricsOrder)
      ..off = (() => settings.lyricsOff)
      ..musixmatchKey = (() => settings.musixmatchKey)
      ..addonLyrics = addons.lyrics
      ..localPath = ((it) => it.id.startsWith('local:') ? it.id.substring(6) : null);
    player.onPhoneSpeaker = () => route.info.onPhoneSpeaker;
    player.externalSource = (it) async {
      if (it.isAddon) {
        final s = await addons.stream(it.id);
        return AudioSource.uri(s.url, headers: s.headers.isEmpty ? null : s.headers);
      }
      if (it.isSmb) {
        final p = SmbSource.pathOf(it.id)!;
        await localRelay.start(loopbackOnly: true);
        final len = await smb.length(p);
        final u = localRelay.publish(RelaySource.custom(length: len, reader: (s, e) => smb.read(p, s, e), contentType: _mimeFor(p)));
        return AudioSource.uri(u);
      }
      return null;
    };
    // 1.4.1: up next / song radio ranked by the listener's own signals.
    player.personalRadio = (seed, exclude) async {
      final t = TasteProfile.build(library: library, stats: stats, log: playLog);
      if (t.isEmpty) return const [];
      return [for (final p in await PersonalRadio.forSeed(yt, seed, t, exclude: exclude)) p.item];
    };
  }

  /// Automix (fetch + analysis of upcoming songs); the player owns it.
  AutomixService? get automix => player.automix;

  /// Personal DJ (made on first use).
  DjController? _dj;
  DjController get dj => _dj ??= DjController(
    player: player,
    brain: DjBrain(library: library, stats: stats, yt: yt),
    settings: settings,
    recommender: DjRecommender.forPhone(yt: yt, library: library, stats: stats, log: playLog),
    library: library,
  );

  /// The Byte account (the person's Gmail) on Apurba's own server.
  CloudAccount? _cloud;
  CloudAccount get cloud => _cloud ??= CloudAccount(CloudAccount.makeClient(Backend.url, Backend.publishableKey));
  set cloud(CloudAccount v) => _cloud = v;

  /// Sync of everything made in Byte across devices signed in to the same Gmail.
  CloudSync? _sync;
  CloudSync get sync => _sync ??= CloudSync(
    backendFor: () => SupabaseSyncBackend(cloud.client),
    deviceId: settings.deviceId,
    deviceName: () {
      final n = route.info.deviceName;
      return n.isNotEmpty && n != 'This phone' ? n : (defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone' : 'Android phone');
    },
    onApplied: cloudApplied,
  );
  set sync(CloudSync v) => _sync = v;

  /// Data from another device arrived: everything shown reads it again.
  void cloudApplied() {
    library.changed();
    settings.changed();
    unawaited(stats.reload());
    unawaited(playLog.reload());
    feedVersion.value++;
  }

  /// Starts syncing when signed in (now or later) and keeps "what's playing"
  /// up to date for the other devices.
  Future<void> startCloud() async {
    await cloud.restore();
    Future<void> follow() async {
      final uid = cloud.uid;
      if (uid != null) {
        await sync.start(uid);
      } else if (sync.active) {
        await sync.stop();
      }
    }

    cloud.addListener(() => unawaited(follow()));
    await follow();
    void note() {
      if (!sync.active) return;
      final q = player.queueModel;
      unawaited(sync.notePlaying(q.playOrder, q.position, player.position, playing: player.playing));
    }

    player.current.addListener(note);
    player.playbackState.map((s) => s.playing).distinct().listen((_) => note());
    Timer.periodic(const Duration(seconds: 30), (_) {
      if (player.playing) note();
    });
  }

  /// Every play with how much was heard (skips, full listens) for the DJ.
  final PlayLog playLog = PlayLog();

  /// Who uses Byte and how, for the owner's Admin screen (Settings → Your
  /// data → Share usage turns it off).
  UsageReporter? _usage;
  UsageReporter get usage => _usage ??= UsageReporter(
    client: () => cloud.client,
    deviceId: settings.deviceId,
    enabled: () => settings.shareUsage,
    deviceInfo: () => {
      'device_model': route.info.model ?? (route.info.deviceName == 'This phone' ? null : route.info.deviceName),
      'platform': kIsWeb ? 'Web' : (defaultTargetPlatform == TargetPlatform.iOS ? 'iOS' : 'Android'),
      'os_version': kIsWeb ? null : _osVersion(),
    },
  );
  set usage(UsageReporter v) => _usage = v;

  static String? _osVersion() {
    try {
      final v = Platform.operatingSystemVersion;
      final m = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(v);
      return m?.group(1) ?? (v.length > 20 ? v.substring(0, 20) : v);
    } catch (_) {
      return null;
    }
  }

  /// The owner's numbers (Settings → Admin, only for his Gmail).
  AdminApi get admin => AdminApi(() => cloud.client);

  /// Starts usage reporting: a "this phone is in use" ping now and every
  /// 10 minutes while playing, and each song listened to for 30 s or more.
  void startUsage() {
    unawaited(usage.ping(force: true));
    final since = DateTime.now();
    String? lastId;
    player.current.addListener(() {
      final now = player.current.value;
      if (now?.id == lastId) return;
      lastId = now?.id;
      // the play that just ended is the newest one in the play log
      final ev = playLog.events.where((e) => e.item.id != now?.id).firstOrNull;
      if (ev != null && ev.at.isAfter(since) && !_reported.contains(ev.at)) {
        _reported.add(ev.at);
        unawaited(usage.played(ev.item, Duration(milliseconds: ev.heardMs)));
      }
      unawaited(usage.ping());
    });
  }

  final Set<DateTime> _reported = {};

  /// The mic for talking to the DJ (a fake in tests).
  SpeechInput speech = PlatformSpeechInput();
  set dj(DjController v) => _dj = v;

  /// Bumps when the home feed should reload (sign-in, region change).
  final ValueNotifier<int> feedVersion = ValueNotifier(0);

  Services({
    required this.net,
    required this.yt,
    required this.resolver,
    required this.library,
    required this.settings,
    required this.lyrics,
    required this.downloads,
    required this.local,
    required this.account,
    required this.importer,
    required this.player,
    required this.stats,
    required this.party,
  }) {
    partySound = PartySound(
      lab: lab,
      link: ListenTogetherLink(party),
      readClassicEq: () => settings.eqEnabled,
      writeClassicEq: (on) => settings.eqEnabled = on,
    );
  }

  /// Listen together → the host's sound, lent to guests who accept (1.4.2).
  late final PartySound partySound;
}
