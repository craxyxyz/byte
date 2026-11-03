// Byte © 2026 Apurba Laskar.
//
// "Log in" for every music app: the app's OWN web sign-in page opens inside
// Byte. Once the person is signed in, Byte reads THEIR library (liked songs
// and playlists, titles and artists only) from the signed-in web app's own
// data calls, in the web view, and imports it: liked songs become Byte likes,
// each playlist becomes a Byte playlist kept up to date by "Sync now".
// Songs play through Byte's usual sources (matched on YouTube Music).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../core/models.dart';
import 'library.dart';
import 'playlist_import.dart';
import 'spotify_sync.dart' show trackKey, TrackMatcher;

enum LibService { spotify, youtubeMusic, apple, amazon, jiosaavn, gaana, soundcloud, deezer }

/// How Byte gets at a service's library once its page has signed the person in.
enum LibReadMode {
  /// The web app's own JSON calls, run inside its page.
  api,

  /// The web app's own pages, read row by row (Amazon Music).
  pages,

  /// Handled by Byte's own code elsewhere (Spotify, YouTube Music).
  builtIn,
}

class LibServiceSpec {
  final LibService service;
  final String name;
  final String loginUrl;
  /// A page of the signed-in web app where the reader runs.
  final String readUrl;
  /// Hosts that belong to the web app (the reader runs only on these).
  final List<String> hosts;
  /// Hosts whose cookies "Log out" clears.
  final List<String> cookieHosts;
  final LibReadMode mode;
  /// One honest line shown on the service's page.
  final String note;
  /// What the person sees as "liked" on that service.
  final String likedLabel;
  const LibServiceSpec({
    required this.service,
    required this.name,
    required this.loginUrl,
    required this.readUrl,
    required this.hosts,
    required this.cookieHosts,
    required this.mode,
    required this.note,
    this.likedLabel = 'Liked songs',
  });
}

String _amazonHost(String region) => region.toUpperCase() == 'IN' ? 'music.amazon.in' : 'music.amazon.com';
String _amazonSignIn(String region) {
  final inIndia = region.toUpperCase() == 'IN';
  final host = inIndia ? 'www.amazon.in' : 'www.amazon.com';
  final ret = Uri.encodeComponent('https://${_amazonHost(region)}/my/playlists');
  final handle = inIndia ? 'amzn_webamp_in' : 'amzn_webamp_us';
  return 'https://$host/ap/signin?openid.pape.max_auth_age=0&openid.return_to=$ret'
      '&openid.identity=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select&openid.assoc_handle=$handle'
      '&openid.mode=checkid_setup&openid.claimed_id=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0%2Fidentifier_select'
      '&openid.ns=http%3A%2F%2Fspecs.openid.net%2Fauth%2F2.0';
}

/// Every music app Byte can log in to, in the order the picker shows them.
List<LibServiceSpec> libServices({String region = 'IN'}) => [
  const LibServiceSpec(
    service: LibService.spotify,
    name: 'Spotify',
    loginUrl: 'https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com%2F',
    readUrl: 'https://open.spotify.com/collection/tracks',
    hosts: ['open.spotify.com'],
    cookieHosts: ['spotify.com', 'accounts.spotify.com', 'open.spotify.com'],
    mode: LibReadMode.builtIn,
    note: 'Liked Songs and your saved playlists. Log in with email or phone; Google login may be blocked inside apps.',
  ),
  const LibServiceSpec(
    service: LibService.youtubeMusic,
    name: 'YouTube Music',
    loginUrl: 'https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F',
    readUrl: 'https://music.youtube.com/',
    hosts: ['music.youtube.com'],
    cookieHosts: ['music.youtube.com', 'youtube.com', 'google.com', 'accounts.google.com'],
    mode: LibReadMode.builtIn,
    note: 'Your liked songs and playlists. Songs play straight away, no matching needed.',
  ),
  LibServiceSpec(
    service: LibService.amazon,
    name: 'Amazon Music',
    loginUrl: _amazonSignIn(region),
    readUrl: 'https://${_amazonHost(region)}/my/playlists',
    hosts: [_amazonHost(region)],
    cookieHosts: ['amazon.in', 'www.amazon.in', 'music.amazon.in', 'amazon.com', 'www.amazon.com', 'music.amazon.com'],
    mode: LibReadMode.pages,
    note: 'Byte reads your playlists from Amazon Music\'s own pages after you log in. Your "Liked songs" list comes in when Amazon shows it among your playlists.',
  ),
  const LibServiceSpec(
    service: LibService.apple,
    name: 'Apple Music',
    loginUrl: 'https://music.apple.com/login',
    readUrl: 'https://music.apple.com/library/songs',
    hosts: ['music.apple.com'],
    cookieHosts: ['music.apple.com', 'apple.com', 'idmsa.apple.com', 'authorize.music.apple.com'],
    mode: LibReadMode.api,
    note: 'Songs in your library (or your Favourite Songs list) and your playlists. Needs an Apple Music subscription; Apple\'s sign-in window may not finish inside some phones, then use a playlist link.',
    likedLabel: 'Favourite / library songs',
  ),
  const LibServiceSpec(
    service: LibService.jiosaavn,
    name: 'JioSaavn',
    loginUrl: 'https://www.jiosaavn.com/login',
    readUrl: 'https://www.jiosaavn.com/my-music',
    hosts: ['www.jiosaavn.com', 'jiosaavn.com'],
    cookieHosts: ['jiosaavn.com', 'www.jiosaavn.com'],
    mode: LibReadMode.api,
    note: 'Songs in your library (the ones you hearted) and your playlists. Log in with your mobile number.',
  ),
  const LibServiceSpec(
    service: LibService.gaana,
    name: 'Gaana',
    loginUrl: 'https://gaana.com/myzone',
    readUrl: 'https://gaana.com/myfavoritetracks',
    hosts: ['gaana.com'],
    cookieHosts: ['gaana.com', 'api.gaana.com'],
    mode: LibReadMode.api,
    note: 'Your favourite songs and playlists. Tap Login on Gaana\'s page, then sign in with your mobile number.',
    likedLabel: 'Favourite songs',
  ),
  const LibServiceSpec(
    service: LibService.soundcloud,
    name: 'SoundCloud',
    loginUrl: 'https://soundcloud.com/signin',
    readUrl: 'https://m.soundcloud.com/you/library',
    hosts: ['soundcloud.com', 'm.soundcloud.com'],
    cookieHosts: ['soundcloud.com', 'm.soundcloud.com', 'secure.soundcloud.com'],
    mode: LibReadMode.api,
    note: 'Your liked tracks and your playlists.',
    likedLabel: 'Liked tracks',
  ),
  const LibServiceSpec(
    service: LibService.deezer,
    name: 'Deezer',
    loginUrl: 'https://www.deezer.com/login',
    readUrl: 'https://www.deezer.com/en/',
    hosts: ['www.deezer.com', 'deezer.com'],
    cookieHosts: ['deezer.com', 'www.deezer.com', 'account.deezer.com'],
    mode: LibReadMode.api,
    note: 'Your Favourite tracks and playlists.',
    likedLabel: 'Favourite tracks',
  ),
];

LibServiceSpec libSpec(LibService s, {String region = 'IN'}) => libServices(region: region).firstWhere((x) => x.service == s);

// ── What the page hands back ──────────────────────────────────────────────

class LibPlaylist {
  final String id;
  final String name;
  final List<ExtTrack> tracks;
  const LibPlaylist(this.id, this.name, this.tracks);
}

class LibSnapshot {
  final String user;
  final List<ExtTrack> liked;
  final List<LibPlaylist> playlists;
  const LibSnapshot(this.user, this.liked, this.playlists);
  int get songCount => liked.length + playlists.fold(0, (a, p) => a + p.tracks.length);
}

class LibProblem implements Exception {
  final String message;
  final bool needLogin;
  /// The page navigated away while Byte was reading: read again.
  final bool retry;
  /// What Byte saw, for "Copy details".
  final String? details;
  const LibProblem(this.message, {this.needLogin = false, this.retry = false, this.details});
  @override
  String toString() => message;
}

/// A short, readable copy of what a page answered (for "Copy details").
String _brief(Object? j) {
  var t = '';
  try {
    t = jsonEncode(j);
  } catch (_) {
    t = '$j';
  }
  return t.length > 1500 ? '${t.substring(0, 1500)}… (${t.length} chars)' : t;
}

String _s(Object? o) => o == null ? '' : unescapeHtml('$o').trim();
int? _ms(Object? v, {bool seconds = false}) {
  final n = num.tryParse('${v ?? ''}');
  if (n == null || n <= 0) return null;
  return seconds ? (n * 1000).round() : n.round();
}

/// Apple Music (JSON:API): data[].attributes {name, artistName, albumName, durationInMillis}.
List<ExtTrack> appleTracks(List pages) => [
  for (final p in pages.whereType<Map>())
    for (final d in (p['data'] as List? ?? const []).whereType<Map>())
      if (d['attributes'] is Map && _s((d['attributes'] as Map)['name']).isNotEmpty)
        ExtTrack(
          _s((d['attributes'] as Map)['name']),
          _s((d['attributes'] as Map)['artistName']),
          album: (d['attributes'] as Map)['albumName'] == null ? null : _s((d['attributes'] as Map)['albumName']),
          durationMs: _ms((d['attributes'] as Map)['durationInMillis']),
        ),
];

/// Deezer's web app (gw-light pagePlaylist): results.SONGS.data[] {SNG_TITLE, ART_NAME, DURATION}.
List<ExtTrack> deezerTracks(List pages) => [
  for (final p in pages.whereType<Map>())
    for (final t in (((p['results'] as Map?)?['SONGS'] as Map?)?['data'] as List? ?? const []).whereType<Map>())
      if (_s(t['SNG_TITLE']).isNotEmpty)
        ExtTrack(
          [_s(t['SNG_TITLE']), if (_s(t['VERSION']).isNotEmpty) _s(t['VERSION'])].join(' '),
          _s(t['ART_NAME']),
          album: t['ALB_TITLE'] == null ? null : _s(t['ALB_TITLE']),
          durationMs: _ms(t['DURATION'], seconds: true),
        ),
];

/// JioSaavn (api_version 4) song objects anywhere in a response: {title, more_info{artistMap, album, duration}}.
List<ExtTrack> saavnTracks(Object? json) {
  final out = <ExtTrack>[];
  final seen = <String>{};
  void walk(Object? o) {
    if (o is Map) {
      final mi = o['more_info'];
      if (o['title'] is String && mi is Map && (o['type'] == 'song' || mi['artistMap'] != null || mi['duration'] != null)) {
        final id = '${o['id'] ?? o['title']}';
        if (seen.add(id)) {
          final prim = ((mi['artistMap'] as Map?)?['primary_artists'] as List?)?.whereType<Map>().map((a) => a['name']).join(', ');
          out.add(
            ExtTrack(
              _s(o['title']),
              _s(prim?.isNotEmpty == true ? prim : (mi['music'] ?? o['subtitle'] ?? '')),
              album: mi['album'] == null ? null : _s(mi['album']),
              durationMs: _ms(mi['duration'], seconds: true),
            ),
          );
        }
        return;
      }
      o.values.forEach(walk);
    } else if (o is List) {
      o.forEach(walk);
    }
  }

  walk(json);
  return out;
}

/// Gaana track objects anywhere in a response: {track_title, artist[{name}], duration, album_title}.
List<ExtTrack> gaanaTracks(Object? json) {
  final out = <ExtTrack>[];
  final seen = <String>{};
  void walk(Object? o) {
    if (o is Map) {
      if (o['track_title'] is String) {
        final id = '${o['track_id'] ?? o['track_title']}';
        if (seen.add(id)) {
          final artists = o['artist'] is List ? (o['artist'] as List).whereType<Map>().map((a) => a['name']).join(', ') : _s(o['artist'] ?? o['artist_name']);
          out.add(ExtTrack(_s(o['track_title']), _s(artists), album: o['album_title'] == null ? null : _s(o['album_title']), durationMs: _ms(o['duration'], seconds: true)));
        }
        return;
      }
      o.values.forEach(walk);
    } else if (o is List) {
      o.forEach(walk);
    }
  }

  walk(json);
  return out;
}

/// SoundCloud api-v2: likes pages (collection[].track) and full track objects.
List<ExtTrack> soundCloudLikes(List pages) => [
  for (final p in pages.whereType<Map>())
    for (final c in (p['collection'] as List? ?? const []).whereType<Map>())
      if (c['track'] is Map && _s((c['track'] as Map)['title']).isNotEmpty) soundCloudTrack(c['track'] as Map),
];

/// Turns what the page's reader posted into a snapshot.
LibSnapshot parseLibraryMessage(LibService s, Map j) {
  if (j['ok'] != true) {
    throw LibProblem('${j['error'] ?? 'The page didn\'t answer'}', needLogin: j['needLogin'] == true, retry: j['retry'] == true, details: _brief(j));
  }
  final user = _s(j['user']).isEmpty ? libSpec(s).name : _s(j['user']);
  final liked = (j['liked'] as Map?)?['pages'] as List? ?? const [];
  final lists = (j['playlists'] as List? ?? const []).whereType<Map>();
  List<ExtTrack> tracks(List pages) => switch (s) {
    LibService.apple => appleTracks(pages),
    LibService.deezer => deezerTracks(pages),
    LibService.jiosaavn => saavnTracks(pages),
    LibService.gaana => gaanaTracks(pages),
    LibService.amazon => [for (final h in pages.whereType<String>()) ...?parseAmazonMusic(h, 'amazon')?.tracks],
    _ => const [],
  };
  if (s == LibService.soundcloud) {
    final full = <int, Map>{};
    for (final p in (j['tracks'] as List? ?? const []).whereType<List>()) {
      for (final t in p.whereType<Map>()) {
        if (t['id'] is num && t['title'] is String) full[(t['id'] as num).toInt()] = t;
      }
    }
    final pls = <LibPlaylist>[];
    for (final p in lists) {
      final pl = p['playlist'] as Map? ?? const {};
      final ts = <ExtTrack>[];
      for (final t in (pl['tracks'] as List? ?? const []).whereType<Map>()) {
        final whole = t['title'] is String ? t : full[(t['id'] as num?)?.toInt()];
        if (whole != null) ts.add(soundCloudTrack(whole));
      }
      pls.add(LibPlaylist('${p['id']}', _s(p['name']).isEmpty ? 'SoundCloud playlist' : _s(p['name']), ts));
    }
    return LibSnapshot(user, soundCloudLikes(liked), pls);
  }
  return LibSnapshot(user, tracks(liked), [
    for (final p in lists) LibPlaylist('${p['id']}', _s(p['name']).isEmpty ? 'Playlist' : _s(p['name']), tracks(p['pages'] as List? ?? const [])),
  ]);
}

// ── The readers (run inside the service's own signed-in page) ─────────────
//
// Each posts ONE message to the ByteLib channel: {ok, user, liked:{pages},
// playlists:[{id, name, pages}]} with the web app's own answers, which Byte
// parses above. `opts.test` reads a public list instead of "me" (used to
// check a reader against the real site without an account).

const _jsHelpers = r"""
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
const J = async (u, o = {}) => { const r = await fetch(u, Object.assign({ credentials: 'include' }, o)); const t = await r.text(); try { return JSON.parse(t.trim()); } catch (e) { return { __status: r.status, __text: t.slice(0, 200) }; } };
const needLogin = (m) => { const e = new Error(m || 'not signed in'); e.needLogin = true; return e; };
""";

const Map<LibService, String> _readers = {
  LibService.apple: r"""
async (opts) => {
  for (let i = 0; i < 60 && !(window.MusicKit && MusicKit.getInstance && MusicKit.getInstance()); i++) await sleep(250);
  const mk = window.MusicKit && MusicKit.getInstance();
  if (!mk) throw new Error('Apple Music page did not load');
  if (!opts.test && !mk.isAuthorized) throw needLogin('Sign in to Apple Music first');
  const h = { Authorization: 'Bearer ' + mk.developerToken };
  if (mk.musicUserToken) h['Music-User-Token'] = mk.musicUserToken;
  const pages = async (path, max) => { const out = []; let next = path; let n = 0; while (next && n < (max || 50)) { const j = await J('https://amp-api.music.apple.com' + next + (next.includes('?') ? '&' : '?') + 'l=en-US', { headers: h, credentials: 'omit' }); out.push(j); if (j.errors || j.__status) break; next = j.next; n++; } return out; };
  if (opts.test) return { user: 'test', liked: { pages: await pages('/v1/catalog/in/playlists/' + opts.test + '/tracks?limit=100') }, playlists: [] };
  const lists = (await pages('/v1/me/library/playlists?limit=100', 10)).flatMap(j => j.data || []);
  const fav = lists.find(p => /^favou?rite songs$/i.test(((p.attributes || {}).name || '').trim()));
  const liked = fav ? await pages('/v1/me/library/playlists/' + fav.id + '/tracks?limit=100', 100) : await pages('/v1/me/library/songs?limit=100', 100);
  const playlists = [];
  for (const p of lists) { if (fav && p.id === fav.id) continue; playlists.push({ id: p.id, name: (p.attributes || {}).name || 'Playlist', pages: await pages('/v1/me/library/playlists/' + p.id + '/tracks?limit=100', 50) }); }
  return { user: 'Apple Music', liked: { pages: liked }, playlists };
}
""",
  LibService.deezer: r"""
async (opts) => {
  const gw = (m, body, tok) => J('/ajax/gw-light.php?method=' + m + '&input=3&api_version=1.0&api_token=' + (tok || ''), body ? { method: 'POST', body: JSON.stringify(body) } : {});
  const u = await gw('deezer.getUserData');
  const R = u.results || {}; const U = R.USER || {}; const tok = R.checkForm;
  if (!opts.test && (!U.USER_ID || String(U.USER_ID) === '0')) throw needLogin('Log in to Deezer first');
  const pl = async (id) => { const out = []; for (let start = 0; start < 10000; start += 2000) { const j = await gw('deezer.pagePlaylist', { playlist_id: String(id), nb: 2000, start: start, lang: 'en', header: true, tab: 0 }, tok); out.push(j); const s = (j.results || {}).SONGS || {}; if (!s.data || s.data.length < 2000) break; } return out; };
  if (opts.test) return { user: 'test', liked: { pages: await pl(opts.test) }, playlists: [] };
  const lovedId = U.LOVEDTRACKS_ID && String(U.LOVEDTRACKS_ID) !== '0' ? String(U.LOVEDTRACKS_ID) : null;
  const liked = lovedId ? await pl(lovedId) : [];
  const prof = await gw('deezer.pageProfile', { user_id: String(U.USER_ID), tab: 'playlists', nb: 500 }, tok);
  let lists = ((((prof.results || {}).TAB || {}).playlists || {}).data) || [];
  if (!lists.length) { const pub = await J('https://api.deezer.com/user/' + U.USER_ID + '/playlists?limit=500', { credentials: 'omit' }); lists = (pub.data || []).map(p => ({ PLAYLIST_ID: String(p.id), TITLE: p.title, LOVED: p.is_loved_track })); }
  const playlists = [];
  for (const p of lists) { if (String(p.PLAYLIST_ID) === lovedId || p.LOVED || p.IS_LOVED_TRACK) continue; playlists.push({ id: String(p.PLAYLIST_ID), name: p.TITLE, pages: await pl(p.PLAYLIST_ID) }); }
  return { user: U.BLOG_NAME || 'Deezer', liked: { pages: liked }, playlists };
}
""",
  LibService.jiosaavn: r"""
async (opts) => {
  const A = (p) => J('/api.php?' + new URLSearchParams(Object.assign({}, p, { api_version: 4, _format: 'json', _marker: 0, ctx: 'web6dot0' })).toString());
  const plPages = async (id) => { const pages = []; for (let p = 1; p <= 30; p++) { const j = await A({ __call: 'playlist.getDetails', listid: id, p: p, n: 100 }); pages.push(j); if (!Array.isArray(j.list) || j.list.length < 100) break; } return pages; };
  if (opts.test) { const pages = await plPages(opts.test); return { user: 'test', liked: { pages: [] }, playlists: [{ id: opts.test, name: (pages[0] || {}).title || 'Playlist', pages }] }; }
  const lib = await A({ __call: 'library.getAll' });
  if (!lib || lib.error) throw needLogin((lib && lib.error && lib.error.msg) || 'Log in to JioSaavn first');
  const ids = (x) => (Array.isArray(x) ? x : (x && typeof x === 'object' ? Object.values(x) : [])).map(v => (v && typeof v === 'object') ? (v.id || v.listid) : v).filter(Boolean).map(String);
  const songIds = ids(lib.song || lib.songs);
  const liked = [];
  for (let i = 0; i < songIds.length; i += 50) liked.push(await A({ __call: 'library.getDetails', entity_ids: songIds.slice(i, i + 50).join(','), entity_type: 'song', n: 50 }));
  const mine = await A({ __call: 'playlist.list', all_playlists: true, contents: 1, onlypids: true });
  const plIds = [...new Set([...ids(Array.isArray(mine) ? mine : (mine.playlists || mine.list || mine.data || [])), ...ids(lib.playlist || lib.playlists)])];
  const playlists = [];
  for (const id of plIds) { const pages = await plPages(id); playlists.push({ id, name: (pages[0] || {}).title || (pages[0] || {}).listname || 'Playlist', pages }); }
  return { user: 'JioSaavn', liked: { pages: liked }, playlists };
}
""",
  LibService.gaana: r"""
async (opts) => {
  const t = localStorage.getItem('uToken');
  if (!t) throw needLogin('Log in to Gaana first');
  const A = (path) => J('https://api.gaana.com' + path + '&token=' + encodeURIComponent(t), { credentials: 'include' });
  const liked = [await A('/mymusic.php?type=get_entities_meta&subtype=track&limit=0,2500')];
  if (liked[0] && /login needed/i.test(liked[0].message || liked[0].msg || '')) throw needLogin('Log in to Gaana first');
  const mine = await A('/user.php?type=myplaylists&subtype=myplaylists&limit=0,500');
  const fav = await A('/mymusic.php?type=get_entities_meta&subtype=playlist&limit=0,500');
  const arr = (o) => Array.isArray(o) ? o : (o && typeof o === 'object' ? (o.playlist || o.playlists || o.entities || o.data || []) : []);
  const lists = [...arr(mine), ...arr(fav)];
  const playlists = [];
  for (const p of lists) {
    const seo = p.seokey; const id = String(p.playlist_id || p.entity_id || p.id || seo || '');
    let j = seo ? await J('/apiv2?seokey=' + encodeURIComponent(seo) + '&type=playlistDetail', { method: 'POST' }) : null;
    if (!j || !(j.tracks || []).length) j = await A('/user.php?type=myplaylists&subtype=playlist_detail&playlist_id=' + encodeURIComponent(id));
    playlists.push({ id, name: p.title || p.name || 'Playlist', pages: [j] });
  }
  let user = 'Gaana'; try { const ui = JSON.parse(localStorage.getItem('userInfo') || '{}'); user = ui.username || ui.name || user; } catch (e) {}
  return { user, liked: { pages: liked }, playlists };
}
""",
  LibService.soundcloud: r"""
async (opts) => {
  const tok = (document.cookie.match(/(?:^|;\s*)oauth_token=([^;]+)/) || [])[1];
  let cid = null;
  for (let i = 0; i < 20 && !cid; i++) {
    const hit = performance.getEntriesByType('resource').map(e => e.name).find(n => /api-(v2|mobi)\.soundcloud\.com\/.*[?&]client_id=/.test(n));
    if (hit) cid = new URL(hit).searchParams.get('client_id'); else await sleep(500);
  }
  if (!cid) for (const s of [...document.scripts].map(s => s.src).filter(s => /sndcdn\.com\/assets\/.*\.js/.test(s)).reverse()) { try { const t = await (await fetch(s)).text(); const m = t.match(/client_id\s*[:=]\s*"([A-Za-z0-9]{32})"/) || t.match(/client_id=([A-Za-z0-9]{32})/); if (m) { cid = m[1]; break; } } catch (e) {} }
  if (!cid) throw new Error('SoundCloud page did not give its app id');
  const h = tok ? { Authorization: 'OAuth ' + tok } : {};
  // The phone site signs its calls with its cookie (api-mobi), the desktop one with the OAuth token (api-v2).
  const host = tok ? 'https://api-v2.soundcloud.com' : 'https://api-mobi.soundcloud.com';
  const A = (path) => J(host + path + (path.includes('?') ? '&' : '?') + 'client_id=' + cid, { headers: h, credentials: tok ? 'omit' : 'include' });
  const me = opts.test ? { id: opts.test, username: 'test' } : await A('/me');
  if (!me || !me.id) throw needLogin('Sign in to SoundCloud first');
  const all = async (path, max) => { const out = []; let j = await A(path); let n = 0; while (j && n < (max || 40)) { out.push(j); if (!j.next_href) break; const u = new URL(j.next_href); u.searchParams.delete('client_id'); j = await A(u.pathname + u.search); n++; } return out; };
  const liked = await all('/users/' + me.id + '/track_likes?limit=200');
  const pls = (await all('/users/' + me.id + '/playlists_without_albums?limit=50', 10)).flatMap(j => j.collection || []);
  const missing = []; for (const p of pls) for (const t of (p.tracks || [])) if (!t.title && t.id) missing.push(t.id);
  const tracks = []; for (let i = 0; i < missing.length; i += 50) { const r = await A('/tracks?ids=' + missing.slice(i, i + 50).join(',')); if (Array.isArray(r)) tracks.push(r); }
  return { user: me.username || 'SoundCloud', liked: { pages: liked }, playlists: pls.map(p => ({ id: String(p.id), name: p.title, playlist: { tracks: (p.tracks || []) } })), tracks };
}
""",
};

/// Collects the rows of the Amazon Music page on screen (it loads more as it
/// scrolls, so this scrolls until no new rows appear) and returns their tags.
const amazonRowsJs = r"""
(async () => {
  const seen = new Map();
  const grab = () => { for (const el of document.querySelectorAll('music-image-row, music-text-row')) { const k = (el.getAttribute('primary-text') || '') + '|' + (el.getAttribute('secondary-text-1') || '') + '|' + (el.getAttribute('primary-href') || ''); if (el.getAttribute('primary-text') && !seen.has(k)) seen.set(k, el.outerHTML.replace(/>[\s\S]*$/, '>')); } };
  let last = -1, still = 0;
  for (let i = 0; i < 400 && still < 5; i++) { grab(); window.scrollBy(0, window.innerHeight * 0.9); await new Promise(r => setTimeout(r, 400)); if (seen.size === last) still++; else still = 0; last = seen.size; }
  grab();
  const head = document.querySelector('music-detail-header');
  return (head ? head.outerHTML.replace(/>[\s\S]*$/, '>') : '') + '\n' + [...seen.values()].join('\n');
})()
""";

/// The playlists on Amazon Music's "your playlists" page: [{name, href}].
const amazonListsJs = r"""
(async () => {
  const out = new Map();
  for (let i = 0; i < 60; i++) {
    for (const el of document.querySelectorAll('[primary-href]')) { const href = el.getAttribute('primary-href') || ''; const name = el.getAttribute('primary-text') || ''; if (/\/(my\/playlists|user-playlists|playlists)\/[A-Za-z0-9]+/.test(href) && name) out.set(href, name); }
    window.scrollBy(0, window.innerHeight * 0.9); await new Promise(r => setTimeout(r, 300));
  }
  return JSON.stringify([...out.entries()].map(([href, name]) => ({ href, name })));
})()
""";

/// Whether the person is signed in on the page (a quick, read-only check).
const Map<LibService, String> _probes = {
  LibService.apple: "!!(window.MusicKit && MusicKit.getInstance && MusicKit.getInstance() && MusicKit.getInstance().isAuthorized)",
  LibService.deezer: "(async()=>{try{const r=await fetch('/ajax/gw-light.php?method=deezer.getUserData&input=3&api_version=1.0&api_token=',{credentials:'include'});const j=await r.json();return String(((j.results||{}).USER||{}).USER_ID||'0')!=='0';}catch(e){return false;}})()",
  LibService.jiosaavn: "(async()=>{try{const r=await fetch('/api.php?__call=library.getAll&api_version=4&_format=json&_marker=0&ctx=web6dot0',{credentials:'include'});const j=await r.json();return !j.error;}catch(e){return false;}})()",
  LibService.gaana: "!!localStorage.getItem('uToken')",
  LibService.soundcloud: "(async()=>{try{if(/(?:^|;\\s*)oauth_token=/.test(document.cookie))return true;const n=performance.getEntriesByType('resource').map(e=>e.name).find(n=>/api-(v2|mobi)\\.soundcloud\\.com\\/.*client_id=/.test(n));if(!n)return false;const c=new URL(n).searchParams.get('client_id');const r=await fetch('https://api-mobi.soundcloud.com/me?client_id='+c,{credentials:'include'});return r.ok;}catch(e){return false;}})()",
  LibService.amazon: "location.pathname.indexOf('/my/')===0",
};

/// The whole script for [s]: runs the reader and posts its answer to `ByteLib`.
String libraryReaderScript(LibService s, {String? test, String channel = 'ByteLib'}) {
  final r = _readers[s];
  if (r == null) throw ArgumentError('No page reader for $s');
  final opts = jsonEncode({'test': ?test});
  return '(async () => { $_jsHelpers\n'
      'let out; try { const r = await ($r)($opts); out = Object.assign({ ok: true }, r); }\n'
      'catch (e) { out = { ok: false, error: String((e && e.message) || e), needLogin: !!(e && e.needLogin) }; }\n'
      '$channel.postMessage(JSON.stringify(out)); })();';
}

String? signedInProbe(LibService s) => _probes[s];

/// Where the phone keeps the app's sign-in cookie (read natively, so the
/// HttpOnly session cookies count too). Null: no cookie check for [s].
String? sessionCookieUrl(LibService s, {String region = 'IN'}) => switch (s) {
  LibService.amazon => region.toUpperCase() == 'IN' ? 'https://www.amazon.in' : 'https://www.amazon.com',
  LibService.deezer => 'https://www.deezer.com',
  LibService.soundcloud => 'https://soundcloud.com',
  _ => null,
};

final Map<LibService, RegExp> _sessionCookies = {
  // Amazon sets these only once an account is signed in (at-/sess-at- = auth tokens, x- = session).
  LibService.amazon: RegExp(r'(?:^|;\s*)(?:at-acbin|sess-at-acbin|x-acbin|at-main|sess-at-main|x-main|at-acbuk|at-acbde)='),
  LibService.deezer: RegExp(r'(?:^|;\s*)arl='),
  LibService.soundcloud: RegExp(r'(?:^|;\s*)oauth_token='),
};

/// What the log-in page does next (checked every 4 s, after each page load,
/// and when the person taps "I'm logged in").
enum LoginNext { wait, openLibrary, read, stillSigningIn }

/// [onService]: the page is on the music app itself (not its account page).
/// [cookie]: the app's session cookie is there (null = can't tell).
/// [probe]: the page's own signed-in check (null = not asked / none).
LoginNext nextLoginStep({required bool onService, bool? cookie, bool? probe, required bool force, bool afterOpening = false}) {
  if (!onService) {
    if (afterOpening) return force ? LoginNext.stillSigningIn : LoginNext.wait;
    return cookie == true || force ? LoginNext.openLibrary : LoginNext.wait;
  }
  if (force || cookie == true || probe == true) return LoginNext.read;
  return LoginNext.wait;
}

/// True when [cookies] (a Cookie header) carries [s]'s signed-in session.
bool? hasSessionCookie(LibService s, String? cookies) {
  final re = _sessionCookies[s];
  if (re == null || cookies == null) return null;
  return re.hasMatch(cookies);
}

// ── Importing a snapshot into Byte ────────────────────────────────────────

class LibSyncResult {
  final int liked;
  final int playlists;
  final int newSongs;
  final int notFound;
  /// Playlists read from the app where none of the songs could be found.
  final List<String> emptyPlaylists;
  const LibSyncResult(this.liked, this.playlists, this.newSongs, this.notFound, {this.emptyPlaylists = const []});
}

/// Per-service connection state + the import (liked → likes, playlists →
/// playlists updated in place; only songs Byte hasn't matched before are
/// looked up again).
class LibrarySync extends ChangeNotifier {
  final Library library;
  final TrackMatcher matcher;
  Box? _b;
  LibrarySync({required this.library, required this.matcher});

  Future<void> open() async => _b = await Hive.openBox('music_app_sync');

  String? status;
  double? progress;
  LibService? runningFor;
  bool get running => runningFor != null;

  bool connected(LibService s) => (_b?.get('${s.name}:on') as bool?) ?? false;
  String? user(LibService s) => _b?.get('${s.name}:user') as String?;
  int likedCount(LibService s) => (_b?.get('${s.name}:liked') as int?) ?? 0;
  int playlistCount(LibService s) => (_b?.get('${s.name}:lists') as int?) ?? 0;
  String? lastError(LibService s) => _b?.get('${s.name}:err') as String?;
  DateTime? lastSync(LibService s) {
    final ms = _b?.get('${s.name}:last') as int?;
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  Future<void> setError(LibService s, String? e) async {
    if (e == null) {
      await _b?.delete('${s.name}:err');
    } else {
      await _b?.put('${s.name}:err', e);
    }
    notifyListeners();
  }

  void _set(String? s, [double? p]) {
    status = s;
    progress = p;
    notifyListeners();
  }

  Item? _cached(String key) {
    final v = _b?.get('m:$key') as String?;
    if (v == null || v == 'none') return null;
    try {
      return Item.fromJson(jsonDecode(v) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> _queue = Future.value();

  /// Imports one app's library. Each app's items are its own: importing (or
  /// re-syncing) one app never replaces another app's playlists, and liked
  /// songs from every app merge into Byte likes (each song once). Two imports
  /// at once (two apps) run one after the other.
  Future<LibSyncResult> importSnapshot(LibService s, LibSnapshot snap) {
    final run = _queue.then((_) => _import(s, snap));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<LibSyncResult> _import(LibService s, LibSnapshot snap) async {
    if (snap.songCount == 0) {
      // Logged in but nothing came back: say so instead of "0 songs imported".
      throw LibProblem(
        'Logged in, but Byte couldn\'t read any songs or playlists from ${libSpec(s).name}. Open your library on that page, then tap "I\'m logged in" again.',
        details: 'service=${s.name} user=${snap.user} liked=${snap.liked.length} playlists=${snap.playlists.length} (${snap.playlists.map((p) => '${p.name}:${p.tracks.length}').join(', ')})',
      );
    }
    runningFor = s;
    try {
      final todo = <String, ExtTrack>{};
      for (final t in [...snap.liked, for (final p in snap.playlists) ...p.tracks]) {
        final k = trackKey(t);
        if (_b?.get('m:$k') == null) todo[k] = t;
      }
      var notFound = 0;
      if (todo.isNotEmpty) {
        final keys = todo.keys.toList();
        _set('Finding ${keys.length} songs…', 0);
        final found = await matcher(todo.values.toList(), (d, t) => _set('Finding songs… $d of $t', t == 0 ? null : d / t));
        for (var i = 0; i < keys.length; i++) {
          final it = i < found.length ? found[i] : null;
          if (it == null) notFound++;
          await _b?.put('m:${keys[i]}', it == null ? 'none' : jsonEncode(it.toJson()));
        }
      }
      _set('Saving…');
      List<Item> items(List<ExtTrack> ts) {
        final out = <Item>[];
        final seen = <String>{};
        for (final t in ts) {
          final it = _cached(trackKey(t));
          if (it != null && seen.add(it.id)) out.add(it);
        }
        return out;
      }

      final likedItems = items(snap.liked);
      final base = DateTime.now().millisecondsSinceEpoch;
      var k = 0;
      for (final it in likedItems.reversed) {
        k++;
        if (!library.isLiked(it.id)) await library.setLiked(it, true, at: base + k);
      }
      var saved = 0;
      final empty = <String>[];
      for (final p in snap.playlists) {
        final its = items(p.tracks);
        // tagged with its app: same-named lists from two apps stay separate
        final source = '${s.name}:${p.id}';
        final have = library.playlistBySource(source);
        if (have == null) {
          if (its.isEmpty) {
            if (p.tracks.isNotEmpty) empty.add(p.name);
            continue;
          }
          await library.createPlaylist(p.name, items: its, source: source);
        } else {
          // re-sync: only this app's own playlist changes (an empty read never wipes it)
          if (its.isEmpty && have.items.isNotEmpty) continue;
          have.items
            ..clear()
            ..addAll(its);
          await library.savePlaylist(have);
        }
        saved++;
      }
      await _b?.put('${s.name}:on', true);
      await _b?.put('${s.name}:user', snap.user);
      await _b?.put('${s.name}:liked', likedItems.length);
      await _b?.put('${s.name}:lists', saved);
      await _b?.put('${s.name}:last', DateTime.now().millisecondsSinceEpoch);
      await _b?.delete('${s.name}:err');
      return LibSyncResult(likedItems.length, saved, todo.length, notFound, emptyPlaylists: empty);
    } finally {
      runningFor = null;
      _set(null);
    }
  }

  /// Log out: forget the connection (Byte's playlists and likes stay).
  Future<void> forget(LibService s) async {
    for (final k in ['on', 'user', 'liked', 'lists', 'last', 'err']) {
      await _b?.delete('${s.name}:$k');
    }
    notifyListeners();
  }
}
