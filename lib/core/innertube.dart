import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'models.dart';
import 'net.dart';
import 'innertube_parse.dart';
import 'search_rank.dart';

/// Search filters as YouTube Music encodes them.
const searchParams = {
  SearchFilter.songs: 'EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D',
  SearchFilter.videos: 'EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D',
  SearchFilter.albums: 'EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D',
  SearchFilter.artists: 'EgWKAQIgAWoKEAkQChAFEAMQBA%3D%3D',
  SearchFilter.playlists: 'EgeKAQQoADgBagoQCRAKEAUQAxAE', // featured
  SearchFilter.podcasts: 'EgWKAQJQAWoOEBEQEBAEEAMQCRAVEAo%3D',
  SearchFilter.episodes: 'EgWKAQJIAWoOEBEQEBAEEAMQCRAVEAo%3D',
};
const communityPlaylistsParam = 'EgeKAQQoAEABagoQCRAKEAUQAxAE';

class ClientSpec {
  final String name;
  final String version;
  final String userAgent;
  final Map<String, dynamic> extra;
  const ClientSpec(this.name, this.version, this.userAgent, [this.extra = const {}]);
}

const webRemix = ClientSpec(
  'WEB_REMIX',
  '1.20251020.01.00',
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
);
const androidVr = ClientSpec(
  'ANDROID_VR',
  '1.65.10',
  'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
  {'deviceMake': 'Oculus', 'deviceModel': 'Quest 3', 'androidSdkVersion': 32, 'osName': 'Android', 'osVersion': '12L'},
);
const visionOs = ClientSpec(
  'VISIONOS',
  '1.02',
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
  {'deviceMake': 'Apple', 'deviceModel': 'RealityDevice17,1', 'osName': 'visionOS', 'osVersion': '26.5.23O471'},
);
const iosClient = ClientSpec('IOS', '20.10.4', 'com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)', {
  'deviceMake': 'Apple',
  'deviceModel': 'iPhone16,2',
  'osName': 'iPhone',
  'osVersion': '18.3.2.22D82',
});

/// YouTube Music's phone app: its lyrics page carries line timings.
const androidMusic = ClientSpec(
  'ANDROID_MUSIC',
  '7.27.52',
  'com.google.android.apps.youtube.music/7.27.52 (Linux; U; Android 14) gzip',
  {'androidSdkVersion': 34, 'osName': 'Android', 'osVersion': '14'},
);

/// A signed-in YouTube Music session (cookies taken from the login web view).
class YtSession {
  final String cookie;
  YtSession(this.cookie);
  String? _cookieValue(String name) {
    for (final part in cookie.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      if (part.substring(0, i).trim() == name) return part.substring(i + 1).trim();
    }
    return null;
  }

  bool get looksValid => _cookieValue('SAPISID') != null || _cookieValue('__Secure-3PAPISID') != null;

  /// The Authorization header YouTube's own web app sends for a signed-in user.
  String authorization({int? nowSeconds, String origin = 'https://music.youtube.com'}) {
    final ts = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String h(String v) => sha1.convert(utf8.encode('$ts $v $origin')).toString();
    final parts = <String>[];
    final s = _cookieValue('SAPISID') ?? _cookieValue('__Secure-3PAPISID');
    if (s != null) parts.add('SAPISIDHASH ${ts}_${h(s)}');
    final p1 = _cookieValue('__Secure-1PAPISID');
    if (p1 != null) parts.add('SAPISID1PHASH ${ts}_${h(p1)}');
    final p3 = _cookieValue('__Secure-3PAPISID');
    if (p3 != null) parts.add('SAPISID3PHASH ${ts}_${h(p3)}');
    return parts.join(' ');
  }
}

/// Clients tried in order when resolving a song's audio. YouTube keeps
/// tightening some of them, so the resolver also checks that a stream really
/// serves past its first megabyte before handing it to the player.
const playerClients = [visionOs, androidVr, iosClient];

class InnerTube {
  final Net net;
  String hl;
  String gl;
  YtSession? session;

  /// The signed-in session was refused at least once (it has expired).
  bool authFailed = false;
  String? _visitorData;
  InnerTube(this.net, {this.hl = 'en', this.gl = 'IN', this.session});

  String? get visitorData => _visitorData;

  Map<String, dynamic> _context(ClientSpec c) => {
    'client': {'clientName': c.name, 'clientVersion': c.version, 'hl': hl, 'gl': gl, 'visitorData': ?_visitorData, ...c.extra},
    'user': {'lockedSafetyMode': false},
  };

  Future<String?> ensureVisitorData() async {
    if (_visitorData != null) return _visitorData;
    try {
      final r = await net.get(Uri.parse('https://music.youtube.com/sw.js_data'), headers: {'User-Agent': webRemix.userAgent});
      final m = RegExp(r'"(Cg[A-Za-z0-9_\-%]{20,})"').firstMatch(r.text);
      _visitorData = m?.group(1);
    } catch (_) {}
    return _visitorData;
  }

  Future<dynamic> call(String endpoint, Map<String, dynamic> body, {ClientSpec client = webRemix, String? query, bool auth = true}) async {
    final url = Uri.parse('https://music.youtube.com/youtubei/v1/$endpoint?prettyPrint=false${query ?? ''}');
    final headers = <String, String>{
      'User-Agent': client.userAgent,
      'Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'X-Goog-Api-Format-Version': '1',
      'X-Goog-Visitor-Id': ?_visitorData,
    };
    if (auth && session != null && client.name == 'WEB_REMIX') {
      headers['Cookie'] = session!.cookie;
      headers['Authorization'] = session!.authorization();
      headers['X-Goog-AuthUser'] = '0';
      headers['X-Origin'] = 'https://music.youtube.com';
    }
    var r = await net.postJson(url, {...body, 'context': _context(client)}, headers: headers);
    if ((r.status == 401 || r.status == 403) && headers.containsKey('Cookie')) {
      // A signed-in session that has gone stale must not break search, import
      // or playback: ask again as a guest.
      authFailed = true;
      headers
        ..remove('Cookie')
        ..remove('Authorization')
        ..remove('X-Goog-AuthUser')
        ..remove('X-Origin');
      r = await net.postJson(url, {...body, 'context': _context(client)}, headers: headers);
    }
    if (!r.ok) throw NetException('The music server answered ${r.status}', r.status);
    final j = r.json;
    final vd = dig(j, ['responseContext', 'visitorData']);
    if (_visitorData == null && vd is String) _visitorData = vd;
    return j;
  }

  // ── catalogue ──────────────────────────────────────────────────────────
  Future<HomeFeed> home({String? continuation}) async {
    if (continuation != null) {
      final j = await call('browse', {}, query: '&ctoken=$continuation&continuation=$continuation&type=next');
      return parseHome(j);
    }
    return parseHome(await call('browse', {'browseId': 'FEmusic_home'}));
  }

  Future<List<Shelf>> charts() async => parseShelves(await call('browse', {'browseId': 'FEmusic_charts'}));
  Future<List<Shelf>> newReleases() async => parseShelves(await call('browse', {'browseId': 'FEmusic_new_releases'}));
  Future<List<Shelf>> moodsAndGenres() async => parseShelves(await call('browse', {'browseId': 'FEmusic_moods_and_genres'}));

  /// The coloured "Moods & genres" buttons (Explore grid).
  Future<List<MoodCategory>> moods() async => parseMoods(await call('browse', {'browseId': 'FEmusic_moods_and_genres'}));

  /// One mood/genre page: shelves of playlists.
  Future<List<Shelf>> moodPage(String params) async =>
      parseShelves(await call('browse', {'browseId': 'FEmusic_moods_and_genres_category', 'params': params}));

  /// Podcasts home (popular shows, episodes, categories).
  Future<List<Shelf>> podcasts() async => parseShelves(await call('browse', {'browseId': 'FEmusic_non_music_audio'}));

  /// A podcast show with its newest episodes.
  Future<BrowsePage> podcast(String id) => browse(id);

  Future<List<Item>> search(String query, SearchFilter filter) async {
    if (filter == SearchFilter.all) {
      return rankSearchItems(query, parseSearchItems(await call('search', {'query': query})));
    }
    final j = await call('search', {'query': query, 'params': Uri.decodeComponent(searchParams[filter]!)});
    var items = parseSearchItems(j);
    if (filter == SearchFilter.playlists) {
      final c = parseSearchItems(await call('search', {'query': query, 'params': communityPlaylistsParam}));
      final ids = items.map((e) => e.id).toSet();
      items = [...items, ...c.where((e) => !ids.contains(e.id))];
    }
    final want = switch (filter) {
      SearchFilter.songs => {ItemKind.song},
      SearchFilter.videos => {ItemKind.video, ItemKind.song},
      SearchFilter.albums => {ItemKind.album},
      SearchFilter.artists => {ItemKind.artist},
      SearchFilter.playlists => {ItemKind.playlist},
      SearchFilter.podcasts => {ItemKind.podcast},
      SearchFilter.episodes => {ItemKind.episode},
      SearchFilter.all => ItemKind.values.toSet(),
    };
    return rankSearchItems(query, items.where((i) => want.contains(i.kind)).toList());
  }

  /// Search returning the "all" shelves (Top result, Songs, Albums …).
  Future<List<Shelf>> searchShelves(String query) async {
    final j = await call('search', {'query': query});
    final shelves = parseShelves(j);
    // Newer layouts return one flat mixed list instead of titled shelves.
    final inShelves = shelves.expand((s) => s.items).map((i) => '${i.kind.name}:${i.id}').toSet();
    final rest = parseSearchItems(j).where((i) => !inShelves.contains('${i.kind.name}:${i.id}')).toList();
    return rankSearchShelves(query, [...shelves, if (rest.isNotEmpty) Shelf('Results', rest)]);
  }

  Future<List<String>> suggestions(String query) async {
    if (query.trim().isEmpty) return const [];
    return parseSuggestions(await call('music/get_search_suggestions', {'input': query}));
  }

  Future<BrowsePage> browse(String browseId, {String? params}) async {
    final j = await call('browse', {'browseId': browseId, 'params': ?params});
    return parseBrowsePage(browseId, j);
  }

  Future<BrowsePage> album(String id) => browse(id);
  Future<BrowsePage> artist(String id) => browse(id);

  /// A playlist with ALL its tracks (follows continuations up to [maxTracks]).
  Future<BrowsePage> playlist(String id, {int maxTracks = 5000}) async {
    final bid = id.startsWith('VL') || id.startsWith('MPRE') ? id : 'VL$id';
    final first = await browse(bid);
    final tracks = [...first.tracks];
    var token = first.continuation;
    var guard = 0;
    while (token != null && tracks.length < maxTracks && guard++ < 100) {
      final j = await call('browse', {'continuation': token});
      final (more, next) = parseTrackContinuation(j);
      if (more.isEmpty) break;
      tracks.addAll(more);
      token = next;
    }
    return BrowsePage(id: bid, kind: first.kind, header: first.header, tracks: tracks, shelves: first.shelves);
  }

  /// Up-next radio for a song (+ the lyrics/related tab ids).
  Future<NextInfo> next(String videoId, {String? playlistId}) async {
    final j = await call('next', {
      'videoId': videoId,
      'playlistId': playlistId ?? 'RDAMVM$videoId',
      'isAudioOnly': true,
      'enablePersistentPlaylistPanel': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
    });
    return parseNext(j);
  }

  /// The song's audio track and music video, when it has both (for the
  /// player's Song | Video switch and version switching).
  Future<SongVersions?> versions(String videoId) async {
    final j = await call('next', {
      'videoId': videoId,
      'isAudioOnly': true,
      'enablePersistentPlaylistPanel': true,
      'tunerSettingValue': 'AUTOMIX_SETTING_NORMAL',
    });
    return parseVersions(j, videoId);
  }

  Future<String?> plainLyrics(String videoId) async {
    final n = await next(videoId);
    if (n.lyricsBrowseId == null) return null;
    return parsePlainLyrics(await call('browse', {'browseId': n.lyricsBrowseId}));
  }

  /// The song's lyrics page as YouTube Music's phone app sees it (with line
  /// timings when YouTube has them); null when the song has no lyrics page.
  Future<dynamic> lyricsPage(String videoId) async {
    final n = await next(videoId);
    if (n.lyricsBrowseId == null) return null;
    return call('browse', {'browseId': n.lyricsBrowseId}, client: androidMusic, auth: false);
  }

  /// The caption tracks of an upload (language, kind "asr" for captions
  /// YouTube made from the audio, and the json3 URL).
  Future<List<({String lang, bool asr, String url})>> captionTracks(String videoId) async {
    await ensureVisitorData();
    final j = await call('player', {'videoId': videoId, 'contentCheckOk': true, 'racyCheckOk': true}, client: iosClient, auth: false);
    final list = (dig(j, ['captions', 'playerCaptionsTracklistRenderer', 'captionTracks']) as List?) ?? const [];
    return [
      for (final t in list.whereType<Map>())
        if (t['baseUrl'] is String) (lang: '${t['languageCode'] ?? ''}', asr: t['kind'] == 'asr', url: '${t['baseUrl']}&fmt=json3'),
    ];
  }

  Future<List<Shelf>> related(String videoId) async {
    final n = await next(videoId);
    if (n.relatedBrowseId == null) return const [];
    return parseShelves(await call('browse', {'browseId': n.relatedBrowseId}));
  }

  // ── signed-in library ─────────────────────────────────────────────────
  Future<List<Item>> libraryPlaylists() async {
    if (session == null) return const [];
    final j = await call('browse', {'browseId': 'FEmusic_liked_playlists'});
    final items = parseSearchItems(j).where((i) => i.kind == ItemKind.playlist).toList();
    // The grid often lives in a gridRenderer.
    for (final g in findAll(j, 'gridRenderer')) {
      for (final c in ((g as Map)['items'] as List? ?? const [])) {
        final it = parseTwoRowItem((c as Map)['musicTwoRowItemRenderer']);
        if (it != null && it.kind == ItemKind.playlist && !items.contains(it)) items.add(it);
      }
    }
    return items;
  }

  /// Name, e-mail and channel handle of the signed-in account.
  Future<AccountInfo?> accountInfo() async {
    if (session == null) return null;
    try {
      final j = await call('account/account_menu', {});
      final h = findAll(j, 'activeAccountHeaderRenderer').firstOrNull;
      if (h == null) return null;
      final name = runsText(h['accountName']).trim();
      final email = runsText(h['email']).trim();
      final handle = runsText(h['channelHandle']).trim();
      return AccountInfo(name: name, email: email.isEmpty ? null : email, handle: handle.isEmpty ? null : handle, photo: bestThumb(h['accountPhoto']));
    } catch (_) {
      return null;
    }
  }

  Future<String?> accountName() async {
    if (session == null) return null;
    try {
      final j = await call('account/account_menu', {});
      final n = findAll(j, 'accountName');
      if (n.isNotEmpty) return runsText(n.first);
    } catch (_) {}
    return null;
  }

  // ── playback ──────────────────────────────────────────────────────────
  /// Raw player response for [videoId] from the first client that is allowed to play it.
  Future<Map<String, dynamic>> player(String videoId, {List<ClientSpec> clients = playerClients}) async {
    await ensureVisitorData();
    String? lastReason;
    for (final c in clients) {
      try {
        final j = await call(
          'player',
          {
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            'playbackContext': {
              'contentPlaybackContext': {'html5Preference': 'HTML5_PREF_WANTS'},
            },
          },
          client: c,
          auth: false,
        ) as Map<String, dynamic>;
        final status = dig(j, ['playabilityStatus', 'status']);
        final formats = dig(j, ['streamingData', 'adaptiveFormats']);
        if (status == 'OK' && formats is List && formats.any((f) => f is Map && f['url'] is String)) {
          j['_client'] = c.name;
          return j;
        }
        lastReason = (dig(j, ['playabilityStatus', 'reason']) as String?) ?? status?.toString();
      } on NetException catch (e) {
        lastReason = e.message;
      }
    }
    throw NetException(lastReason ?? 'This song cannot be played');
  }
}
