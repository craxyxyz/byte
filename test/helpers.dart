import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/net.dart';
import 'package:byte/core/streams.dart';
import 'package:byte/data/account.dart';
import 'package:byte/data/downloads.dart';
import 'package:byte/data/library.dart';
import 'package:byte/data/link_import.dart';
import 'package:byte/data/local_music.dart';
import 'package:byte/data/settings.dart';
import 'package:byte/data/stats.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/lyrics/lyrics_service.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/equalizer.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/page.dart' show SubPage;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

String fixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// Network double: answers by matching URL / body, records every request.
class FakeNet extends Net {
  final List<NetRequest> log = [];
  final FutureOr<NetResponse?> Function(NetRequest r, String body) handler;
  FakeNet(this.handler);
  @override
  Future<NetResponse> send(NetRequest r, {Duration timeout = const Duration(seconds: 20)}) async {
    log.add(r);
    final body = r.body == null ? '' : utf8.decode(r.body!);
    final res = await handler(r, body);
    return res ?? NetResponse(404, const {}, Uint8List(0));
  }
}

NetResponse jsonRes(Object o, [int status = 200]) =>
    NetResponse(status, const {'content-type': 'application/json'}, Uint8List.fromList(utf8.encode(o is String ? o : jsonEncode(o))));

/// A synthetic player response (what YouTube returns for a playable song).
Map<String, dynamic> fakePlayer(String id, {int durationMs = 200000, double loudness = 3.0}) => {
  'playabilityStatus': {'status': 'OK'},
  'streamingData': {
    'adaptiveFormats': [
      {
        'itag': 140,
        'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
        'bitrate': 130000,
        'contentLength': '900000',
        'approxDurationMs': '$durationMs',
        'loudnessDb': loudness,
        'url': 'https://media.example/$id/140?expire=4102444800',
      },
      {
        'itag': 251,
        'mimeType': 'audio/webm; codecs="opus"',
        'bitrate': 160000,
        'contentLength': '1000000',
        'approxDurationMs': '$durationMs',
        'loudnessDb': loudness,
        'url': 'https://media.example/$id/251?expire=4102444800',
      },
      {
        'itag': 249,
        'mimeType': 'audio/webm; codecs="opus"',
        'bitrate': 60000,
        'contentLength': '400000',
        'approxDurationMs': '$durationMs',
        'url': 'https://media.example/$id/249?expire=4102444800',
      },
      {'itag': 137, 'mimeType': 'video/mp4; codecs="avc1"', 'bitrate': 4000000, 'url': 'https://media.example/$id/137'},
    ],
  },
};

/// Default fake catalogue: fixtures for browse/search, synthetic players.
FutureOr<NetResponse?> catalogue(NetRequest r, String body) {
  final u = r.url.toString();
  if (r.method == 'PROPFIND') return NetResponse(207, const {'content-type': 'application/xml'}, Uint8List.fromList(utf8.encode(davListing(r.url))));
  if (u.contains('sw.js_data')) return NetResponse(200, const {}, Uint8List.fromList(utf8.encode(')]}\'\n[["CgtFakeVisitorDataXXXXXXXXXXXX"]]')));
  if (u.contains('/player')) {
    final id = (jsonDecode(body) as Map)['videoId'] as String;
    return jsonRes(fakePlayer(id));
  }
  if (u.contains('/search')) {
    final b = jsonDecode(body) as Map;
    final p = b['params'] as String?;
    if (p == null) return jsonRes(fixture('s_all.json'));
    if (p.startsWith('EgWKAQIIAW')) return jsonRes(fixture('s_songs.json'));
    if (p.startsWith('EgWKAQJQAW')) return jsonRes(fixture('s_podcasts.json'));
    if (p.startsWith('EgWKAQJIAW')) return jsonRes(fixture('s_episodes.json'));
    if (p.startsWith('EgWKAQIQAW')) return jsonRes(fixture('s_videos.json'));
    if (p.startsWith('EgWKAQIYAW')) return jsonRes(fixture('s_albums.json'));
    if (p.startsWith('EgWKAQIgAW')) return jsonRes(fixture('s_artists.json'));
    return jsonRes(fixture('s_fplaylists.json'));
  }
  if (u.contains('get_search_suggestions')) return jsonRes(fixture('suggest.json'));
  if (u.contains('/next')) return jsonRes(fixture('next.json'));
  if (u.contains('/browse')) {
    final b = jsonDecode(body) as Map;
    final id = b['browseId'] as String?;
    if (b['continuation'] != null || u.contains('ctoken=')) return jsonRes(fixture('pl_cont.json'));
    if (id == 'FEmusic_home') return jsonRes(fixture('home.json'));
    if (id == 'FEmusic_moods_and_genres') return jsonRes(fixture('moods.json'));
    if (id == 'FEmusic_moods_and_genres_category') return jsonRes(fixture('mood_cat.json'));
    if (id == 'FEmusic_non_music_audio') return jsonRes(fixture('podcasts.json'));
    if (id != null && id.startsWith('MPSP')) return jsonRes(fixture('podcast_show.json'));
    if (id == 'FEmusic_new_releases' || id == 'FEmusic_charts') return jsonRes(fixture('newrel.json'));
    if (id != null && id.startsWith('MPRE')) return jsonRes(fixture('album.json'));
    if (id != null && id.startsWith('MPLY')) return jsonRes(fixture('lyrics_tab.json'));
    if (id != null && id.startsWith('UC')) return jsonRes(fixture('artist.json'));
    if (id != null && id.startsWith('VL')) return jsonRes(fixture('pl_big.json'));
    return jsonRes({});
  }
  if (u.contains('lrclib.net/api/get')) {
    return jsonRes({
      'id': 1,
      'trackName': 'Tum Hi Ho',
      'artistName': 'Arijit Singh',
      'duration': 262,
      'syncedLyrics': '[00:01.00] Hum tere bin ab reh nahi sakte\n[00:05.50] Tere bina kya wajood mera\n[00:10.00] Tujh se juda agar ho jaayenge\n[00:15.00] Toh khud se hi ho jaayenge juda\n[00:20.00] Kyun ki tum hi ho\n[00:24.00] Ab tum hi ho\n[00:28.00] Zindagi ab tum hi ho\n[00:33.00] Chain bhi, mera dard bhi\n[00:38.00] Meri aashiqui ab tum hi ho\n[00:44.00] ',
      'plainLyrics': 'Hum tere bin ab reh nahi sakte',
    });
  }
  return null;
}

// ── just_audio double: plays in (real) time, completes at the end ──────────
class FakeJustAudio extends JustAudioPlatform with MockPlatformInterfaceMixin {
  final Map<String, FakePlayerPlatform> players = {};
  Duration Function(String uri) durationFor = (_) => const Duration(seconds: 200);

  /// Loads of matching links fail (like a 403 from the server).
  bool Function(String uri) failLoad = (_) => false;
  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = FakePlayerPlatform(request.id, this);
    players[request.id] = p;
    return p;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    players.remove(request.id)?.close();
    return DisposePlayerResponse();
  }

  @override
  Future<DisposeAllPlayersResponse> disposeAllPlayers(DisposeAllPlayersRequest request) async {
    for (final p in players.values) {
      p.close();
    }
    players.clear();
    return DisposeAllPlayersResponse();
  }
}

class FakePlayerPlatform extends AudioPlayerPlatform {
  final FakeJustAudio owner;

  /// 1.4.5: report an Android audio session per platform player, like the
  /// phone (a deck that is stopped and loaded again gets a new one).
  static bool androidSessions = false;
  static int _nextSession = 100;
  final int session = ++_nextSession;
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  final _data = StreamController<PlayerDataMessage>.broadcast();
  String? uri;
  Duration? duration;
  Duration _pos = Duration.zero;
  DateTime _at = DateTime.now();
  bool playing = false;
  double speed = 1, volume = 1;
  ProcessingStateMessage state = ProcessingStateMessage.idle;
  Timer? _end;
  final List<String> loads = [];
  Map<String, String>? headers;

  FakePlayerPlatform(super.id, this.owner);

  Duration get position => playing && state == ProcessingStateMessage.ready ? _pos + DateTime.now().difference(_at) * speed : _pos;

  void _emit() {
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: _at,
        updatePosition: _pos,
        bufferedPosition: duration ?? Duration.zero,
        duration: duration,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: androidSessions ? session : null,
      ),
    );
  }

  void _schedule() {
    _end?.cancel();
    if (!playing || duration == null || state != ProcessingStateMessage.ready) return;
    final left = duration! - position;
    _end = Timer(left < Duration.zero ? Duration.zero : left * (1 / speed), () {
      _pos = duration!;
      _at = DateTime.now();
      state = ProcessingStateMessage.completed;
      _emit();
    });
  }

  /// The stream breaks mid-song (like the connection dropping).
  void failNow([String message = 'SocketException: Connection reset by peer']) {
    _end?.cancel();
    _pos = position;
    playing = false;
    state = ProcessingStateMessage.idle;
    // how just_audio 0.10 platforms report a broken stream
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: _pos,
        bufferedPosition: Duration.zero,
        duration: duration,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
        errorCode: 1000 + _errors++,
        errorMessage: message,
      ),
    );
  }

  int _errors = 0;

  /// 1.4.5: the backend reports a wrong position for a moment (desktop: a
  /// coarse or briefly-zero position) while the sound carries on.
  void reportPosition(Duration p) {
    _events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: p,
        bufferedPosition: duration ?? Duration.zero,
        duration: duration,
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  /// The stream comes back after [stallNow].
  void resumeNow() {
    state = ProcessingStateMessage.ready;
    _at = DateTime.now();
    _emit();
    _schedule();
  }

  /// The stream hangs mid-song: buffering forever, no error.
  void stallNow() {
    _end?.cancel();
    _pos = position;
    _at = DateTime.now();
    state = ProcessingStateMessage.buffering;
    _emit();
  }

  /// The connection ends early and the platform reports the song as finished.
  void endEarlyNow() {
    _end?.cancel();
    _pos = position;
    _at = DateTime.now();
    state = ProcessingStateMessage.completed;
    _emit();
  }

  void close() {
    _end?.cancel();
    _events.close();
    _data.close();
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;
  @override
  Stream<PlayerDataMessage> get playerDataMessageStream => _data.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    uri = _uriOf(request.audioSourceMessage);
    headers = _headersOf(request.audioSourceMessage);
    loads.add(uri ?? '?');
    if (owner.failLoad(uri ?? '')) {
      state = ProcessingStateMessage.idle;
      throw PlatformException(code: 'abort', message: 'Response code: 403');
    }
    duration = owner.durationFor(uri ?? '');
    _pos = request.initialPosition ?? Duration.zero;
    _at = DateTime.now();
    state = ProcessingStateMessage.ready;
    _emit();
    _schedule();
    return LoadResponse(duration: duration);
  }

  static Map<String, String>? _headersOf(AudioSourceMessage m) {
    if (m is UriAudioSourceMessage) return m.headers?.cast<String, String>();
    if (m is ClippingAudioSourceMessage) return m.child.headers?.cast<String, String>();
    if (m is ConcatenatingAudioSourceMessage && m.children.isNotEmpty) return _headersOf(m.children.first);
    return null;
  }

  static String? _uriOf(AudioSourceMessage m) {
    if (m is UriAudioSourceMessage) return m.uri;
    if (m is ClippingAudioSourceMessage) return m.child.uri;
    if (m is ConcatenatingAudioSourceMessage && m.children.isNotEmpty) return _uriOf(m.children.first);
    return null;
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _pos = position;
    _at = DateTime.now();
    playing = true;
    _data.add(PlayerDataMessage(playing: true));
    _emit();
    _schedule();
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _pos = position;
    _at = DateTime.now();
    playing = false;
    _end?.cancel();
    _data.add(PlayerDataMessage(playing: false));
    _emit();
    return PauseResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _pos = request.position ?? Duration.zero;
    _at = DateTime.now();
    if (state == ProcessingStateMessage.completed) state = ProcessingStateMessage.ready;
    _emit();
    _schedule();
    return SeekResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async {
    volume = request.volume;
    return SetVolumeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async {
    _pos = position;
    _at = DateTime.now();
    speed = request.speed;
    _emit();
    _schedule();
    return SetSpeedResponse();
  }

  @override
  Future<SetSkipSilenceResponse> setSkipSilence(SetSkipSilenceRequest request) async => SetSkipSilenceResponse();
  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async => SetLoopModeResponse();
  @override
  Future<SetShuffleModeResponse> setShuffleMode(SetShuffleModeRequest request) async => SetShuffleModeResponse();
  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    close();
    return DisposeResponse();
  }
}

class MemSecureStorage extends FlutterSecureStorage {
  final Map<String, String> m = {};
  MemSecureStorage();
  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => m[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      m.remove(key);
    } else {
      m[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => m.remove(key);
}

late FakeJustAudio fakeAudio;
Directory? _hiveDir;

/// Builds the whole app's services against fakes. Call once per test file.
Future<Services> makeServices({FakeNet? net, ByteEqualizer? equalizer, ListenTogether Function(Settings settings)? party}) async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  final m = binding.defaultBinaryMessenger;
  for (final ch in ['com.ryanheise.audio_session', 'com.ryanheise.android_audio_manager', 'com.ryanheise.av_audio_session']) {
    m.setMockMethodCallHandler(MethodChannel(ch), (call) async => null);
  }
  m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
  fakeAudio = FakeJustAudio();
  JustAudioPlatform.instance = fakeAudio;
  SubPage.forgetScroll();
  _hiveDir ??= Directory.systemTemp.createTempSync('byte_test_');
  Hive.init(_hiveDir!.path);
  final settings = Settings();
  await settings.open();
  final library = Library();
  await library.open();
  final stats = ListeningStats();
  await stats.open();
  final n = net ?? FakeNet(catalogue);
  final yt = InnerTube(n);
  final resolver = StreamResolver(yt);
  final handler = ByteAudioHandler(resolver: resolver, yt: yt, library: library, settings: settings, equalizer: equalizer);
  final s = Services(
    net: n,
    yt: yt,
    resolver: resolver,
    library: library,
    settings: settings,
    lyrics: LyricsService(n, yt),
    downloads: Downloads(resolver, library, settings, n),
    local: LocalMusic(library),
    account: Account(yt, library, secure: MemSecureStorage()),
    importer: LinkImporter(yt, n),
    player: handler,
    stats: stats,
    party: party?.call(settings) ?? ListenTogether(player: NullSyncPlayer(), deviceId: settings.deviceId, displayName: () => 'Test listener'),
  );
  Services.i = s;
  await s.scrobbler.open();
  await s.webdav.open();
  await s.spotify.open();
  await s.wireSources();
  return s;
}

/// A WebDAV folder: two sub-folders, three songs (one with a long Bengali name) and a text file.
String davListing(Uri folder) {
  final base = folder.path.endsWith('/') ? folder.path : '${folder.path}/';
  String resp(String href, {bool dir = false, int size = 0, String? name}) =>
      '<d:response><d:href>$href</d:href><d:propstat><d:prop>${name == null ? '' : '<d:displayname>$name</d:displayname>'}<d:resourcetype>${dir ? '<d:collection/>' : ''}</d:resourcetype>${dir ? '' : '<d:getcontentlength>$size</d:getcontentlength>'}</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>';
  return '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">'
      '${resp(base, dir: true)}'
      '${resp('${base}Bollywood/', dir: true)}'
      '${resp('${base}Rabindrasangeet%20%E2%80%94%20%E0%A6%B0%E0%A6%AC%E0%A7%80%E0%A6%A8%E0%A7%8D%E0%A6%A6%E0%A7%8D%E0%A6%B0%E0%A6%B8%E0%A6%99%E0%A7%8D%E0%A6%97%E0%A7%80%E0%A6%A4/', dir: true)}'
      '${resp('${base}01%20-%20Arijit%20Singh%20-%20Tum%20Hi%20Ho.mp3', size: 4200000)}'
      '${resp('${base}Shreya%20Ghoshal%20-%20%E0%A6%86%E0%A6%AE%E0%A6%BF%20%E0%A6%A4%E0%A7%8B%E0%A6%AE%E0%A6%BE%E0%A6%B0%20%E0%A6%B8%E0%A6%99%E0%A7%8D%E0%A6%97%E0%A7%87%20%E0%A6%AC%E0%A7%87%E0%A6%81%E0%A6%A7%E0%A7%87%E0%A6%9B%E0%A6%BF%20%E0%A6%86%E0%A6%AE%E0%A6%BE%E0%A6%B0%20%E0%A6%AA%E0%A7%8D%E0%A6%B0%E0%A6%BE%E0%A6%A3%20(%E0%A6%B2%E0%A6%BE%E0%A6%87%E0%A6%AD).flac', size: 31000000)}'
      '${resp('${base}notes.txt', size: 12)}'
      '${resp('${base}Kesariya.m4a', size: 3900000, name: 'Kesariya.m4a')}'
      '</d:multistatus>';
}


/// Listen together's player hook, doing nothing (widget tests).
class NullSyncPlayer implements SyncPlayer {
  final ValueNotifier<int> _c = ValueNotifier(0);
  @override
  Listenable get changes => _c;
  @override
  Item? get item => null;
  @override
  Duration get position => Duration.zero;
  @override
  bool get isPlaying => false;
  @override
  Future<void> load(Item item, Duration at, {required bool play}) async {}
  @override
  Future<void> seekTo(Duration d) async {}
  @override
  Future<void> setPlaying(bool play) async {}
}
