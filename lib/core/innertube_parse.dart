// Pure parsing of YouTube Music (InnerTube) JSON into Byte's models.
// Written defensively: YouTube changes its layout often, so every lookup is
// optional and unknown shapes are skipped instead of crashing.
import 'models.dart';

typedef J = Map<String, dynamic>;

dynamic dig(dynamic o, List<Object> path) {
  var cur = o;
  for (final p in path) {
    if (cur == null) return null;
    if (p is int) {
      if (cur is List && p >= 0 && p < cur.length) {
        cur = cur[p];
      } else {
        return null;
      }
    } else {
      if (cur is Map) {
        cur = cur[p];
      } else {
        return null;
      }
    }
  }
  return cur;
}

/// Every value stored under [key] anywhere inside [o] (depth-first, in order).
List<dynamic> findAll(dynamic o, String key, {List<dynamic>? out}) {
  out ??= [];
  if (o is Map) {
    o.forEach((k, v) {
      if (k == key) out!.add(v);
      findAll(v, key, out: out);
    });
  } else if (o is List) {
    for (final v in o) {
      findAll(v, key, out: out);
    }
  }
  return out;
}

String runsText(dynamic textObj) {
  if (textObj == null) return '';
  if (textObj is Map) {
    if (textObj['simpleText'] is String) return textObj['simpleText'] as String;
    final runs = textObj['runs'];
    if (runs is List) return runs.map((r) => (r is Map ? r['text'] : null) ?? '').join();
  }
  return '';
}

List<J> runsOf(dynamic textObj) {
  final runs = textObj is Map ? textObj['runs'] : null;
  if (runs is List) return runs.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  return const [];
}

String? bestThumb(dynamic o) {
  final lists = findAll(o, 'thumbnails');
  for (final l in lists) {
    if (l is List && l.isNotEmpty) {
      final last = l.last;
      if (last is Map && last['url'] is String) {
        var u = last['url'] as String;
        if (u.startsWith('//')) u = 'https:$u';
        return u;
      }
    }
  }
  return null;
}

final _durRe = RegExp(r'^(\d{1,2}:)?\d{1,2}:\d{2}$');
int? parseDuration(String s) {
  s = s.trim();
  if (!_durRe.hasMatch(s)) return null;
  final parts = s.split(':').map(int.parse).toList();
  var t = 0;
  for (final p in parts) {
    t = t * 60 + p;
  }
  return t;
}

const _typeWords = {'song', 'video', 'album', 'single', 'ep', 'playlist', 'artist', 'episode', 'podcast', 'profile', 'station'};

String? _pageType(dynamic endpoint) =>
    dig(endpoint, ['browseEndpoint', 'browseEndpointContextSupportedConfigs', 'browseEndpointContextMusicConfig', 'pageType']) as String?;

class _Meta {
  final List<ArtistRef> artists = [];
  String? album;
  String? albumId;
  int? duration;
  final List<String> plain = [];
}

/// Reads "Artist • Album • 3:45"-style runs.
_Meta _readMetaRuns(List<J> runs) {
  final m = _Meta();
  for (final r in runs) {
    final text = (r['text'] as String? ?? '').trim();
    if (text.isEmpty || text == '•' || text == '&' || text == ',') continue;
    final pt = _pageType(r['navigationEndpoint']);
    final bid = dig(r, ['navigationEndpoint', 'browseEndpoint', 'browseId']) as String?;
    if (pt == 'MUSIC_PAGE_TYPE_ARTIST' || pt == 'MUSIC_PAGE_TYPE_USER_CHANNEL') {
      m.artists.add(ArtistRef(text, bid));
    } else if (pt == 'MUSIC_PAGE_TYPE_ALBUM') {
      m.album = text;
      m.albumId = bid;
    } else {
      final d = parseDuration(text);
      if (d != null) {
        m.duration = d;
      } else {
        m.plain.add(text);
      }
    }
  }
  return m;
}

bool _looksLikeStat(String s) =>
    RegExp(r'(views|plays|songs|tracks|subscribers|monthly|audience|likes|hours?|minutes?)\b', caseSensitive: false).hasMatch(s) ||
    RegExp(r'^\d{4}$').hasMatch(s);

ItemKind? _kindFromWatch(dynamic watchEndpoint) {
  if (watchEndpoint is! Map) return null;
  final vt = dig(watchEndpoint, ['watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']) as String?;
  if (vt == 'MUSIC_VIDEO_TYPE_ATV' || vt == null) return ItemKind.song;
  if (vt == 'MUSIC_VIDEO_TYPE_PODCAST_EPISODE') return ItemKind.episode;
  return ItemKind.video;
}

ItemKind? _kindFromPageType(String? pt) {
  switch (pt) {
    case 'MUSIC_PAGE_TYPE_ALBUM':
    case 'MUSIC_PAGE_TYPE_AUDIOBOOK':
      return ItemKind.album;
    case 'MUSIC_PAGE_TYPE_PLAYLIST':
      return ItemKind.playlist;
    case 'MUSIC_PAGE_TYPE_ARTIST':
    case 'MUSIC_PAGE_TYPE_USER_CHANNEL':
      return ItemKind.artist;
    case 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE':
      return ItemKind.podcast;
  }
  return null;
}

/// musicResponsiveListItemRenderer → Item (songs in lists, search rows, ...).
Item? parseResponsiveItem(dynamic r, {String? fallbackThumb, String? fallbackAlbum, String? fallbackAlbumId, List<ArtistRef>? fallbackArtists}) {
  if (r is! Map) return null;
  final cols = (r['flexColumns'] as List? ?? const []).map((c) => dig(c, ['musicResponsiveListItemFlexColumnRenderer', 'text'])).toList();
  if (cols.isEmpty) return null;
  final title = runsText(cols[0]).trim();
  if (title.isEmpty) return null;
  final firstRun = runsOf(cols[0]).isNotEmpty ? runsOf(cols[0]).first : null;

  String? videoId = dig(r, ['playlistItemData', 'videoId']) as String?;
  dynamic watch = dig(firstRun, ['navigationEndpoint', 'watchEndpoint']);
  watch ??= dig(r, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint']);
  videoId ??= dig(watch, ['videoId']) as String?;

  final nav = r['navigationEndpoint'];
  final pt = _pageType(nav);
  final browseId = dig(nav, ['browseEndpoint', 'browseId']) as String?;

  final metaRuns = <J>[];
  for (var i = 1; i < cols.length; i++) {
    if (metaRuns.isNotEmpty) metaRuns.add({'text': ' • '});
    metaRuns.addAll(runsOf(cols[i]));
  }
  for (final fc in (r['fixedColumns'] as List? ?? const [])) {
    metaRuns.addAll(runsOf(dig(fc, ['musicResponsiveListItemFixedColumnRenderer', 'text'])));
  }
  final meta = _readMetaRuns(metaRuns);
  final thumb = bestThumb(r['thumbnail']) ?? fallbackThumb;
  final explicit = findAll(r['badges'], 'iconType').contains('MUSIC_EXPLICIT_BADGE');

  if (videoId != null && browseId == null) {
    var kind = _kindFromWatch(watch) ?? ItemKind.song;
    var artists = meta.artists;
    if (artists.isEmpty) {
      // Uploader/artist without a link: first non-type, non-stat plain word.
      final p = meta.plain.where((t) => !_typeWords.contains(t.toLowerCase()) && !_looksLikeStat(t)).toList();
      if (p.isNotEmpty) artists = [ArtistRef(p.first)];
      if (meta.plain.isNotEmpty && meta.plain.first.toLowerCase() == 'video') kind = ItemKind.video;
    }
    if (artists.isEmpty && fallbackArtists != null) artists = fallbackArtists;
    return Item(
      kind: kind,
      id: videoId,
      title: title,
      artists: artists,
      album: meta.album ?? fallbackAlbum,
      albumId: meta.albumId ?? fallbackAlbumId,
      durationSec: meta.duration,
      thumb: thumb,
      explicit: explicit,
    );
  }
  final kind = _kindFromPageType(pt);
  if (browseId != null && kind != null) {
    final sub = runsText(cols.length > 1 ? cols[1] : null).trim();
    return Item(kind: kind, id: browseId, title: title, artists: meta.artists, thumb: thumb, subtitle: sub.isEmpty ? null : sub, explicit: explicit);
  }
  return null;
}

/// musicTwoRowItemRenderer → Item (carousels: albums, playlists, artists, videos).
Item? parseTwoRowItem(dynamic r) {
  if (r is! Map) return null;
  final title = runsText(r['title']).trim();
  if (title.isEmpty) return null;
  final subRuns = runsOf(r['subtitle']);
  final meta = _readMetaRuns(subRuns);
  final sub = runsText(r['subtitle']).trim();
  final thumb = bestThumb(r['thumbnailRenderer']);
  final nav = r['navigationEndpoint'];
  final watch = dig(nav, ['watchEndpoint']);
  final explicit = findAll(r['subtitleBadges'], 'iconType').contains('MUSIC_EXPLICIT_BADGE');
  if (watch is Map && watch['videoId'] is String) {
    var artists = meta.artists;
    if (artists.isEmpty) {
      final p = meta.plain.where((t) => !_typeWords.contains(t.toLowerCase()) && !_looksLikeStat(t)).toList();
      if (p.isNotEmpty) artists = [ArtistRef(p.first)];
    }
    return Item(
      kind: _kindFromWatch(watch) ?? ItemKind.video,
      id: watch['videoId'] as String,
      title: title,
      artists: artists,
      album: meta.album,
      albumId: meta.albumId,
      durationSec: meta.duration,
      thumb: thumb,
      explicit: explicit,
    );
  }
  final pt = _pageType(nav);
  final bid = dig(nav, ['browseEndpoint', 'browseId']) as String?;
  final kind = _kindFromPageType(pt);
  if (bid == null || kind == null) return null;
  return Item(kind: kind, id: bid, title: title, artists: meta.artists, thumb: thumb, subtitle: sub.isEmpty ? null : sub, explicit: explicit);
}

/// musicMultiRowListItemRenderer (a podcast episode row) → Item.
/// The show goes into album/albumId so "Go to podcast" works like "Go to album".
Item? parseEpisode(dynamic r, {String? fallbackShow, String? fallbackShowId}) {
  if (r is! Map) return null;
  final title = runsText(r['title']).trim();
  final watch = dig(r, ['onTap', 'watchEndpoint']) ??
      dig(r, ['overlay', 'musicItemThumbnailOverlayRenderer', 'content', 'musicPlayButtonRenderer', 'playNavigationEndpoint', 'watchEndpoint']);
  final id = dig(watch, ['videoId']) as String?;
  if (id == null || title.isEmpty) return null;
  final showRuns = runsOf(r['secondTitle']);
  final show = showRuns.isEmpty ? fallbackShow : runsText(r['secondTitle']).trim();
  final showId = showRuns.isEmpty ? fallbackShowId : dig(showRuns.first, ['navigationEndpoint', 'browseEndpoint', 'browseId']) as String?;
  final durText = runsText(dig(r, ['playbackProgress', 'musicPlaybackProgressRenderer', 'durationText'])).replaceAll('•', '').trim();
  final when = runsOf(r['subtitle']).map((x) => (x['text'] as String? ?? '').trim()).where((t) => t.isNotEmpty && t != '•').toList();
  return Item(
    kind: ItemKind.episode,
    id: id,
    title: title,
    artists: show == null || show.isEmpty ? const [] : [ArtistRef(show, showId)],
    album: show,
    albumId: showId,
    durationSec: parseEpisodeDuration(durText),
    thumb: bestThumb(r['thumbnail']),
    subtitle: [if (when.isNotEmpty) when.last, if (durText.isNotEmpty) durText].join(' • '),
  );
}

/// "18 min", "1 hr 5 min", "45 sec" → seconds.
int? parseEpisodeDuration(String s) {
  if (s.isEmpty) return null;
  final asClock = parseDuration(s);
  if (asClock != null) return asClock;
  var total = 0;
  var any = false;
  for (final m in RegExp(r'(\d+)\s*(hr|hour|h|min|m|sec|s)').allMatches(s.toLowerCase())) {
    final n = int.parse(m.group(1)!);
    final u = m.group(2)!;
    any = true;
    total += u.startsWith('h') ? n * 3600 : (u.startsWith('m') ? n * 60 : n);
  }
  return any ? total : null;
}

/// playlistPanelVideoRenderer (the "Up next" queue) → Item.
Item? parsePanelVideo(dynamic r) {
  if (r is! Map) return null;
  final id = r['videoId'] as String?;
  final title = runsText(r['title']).trim();
  if (id == null || title.isEmpty) return null;
  final meta = _readMetaRuns(runsOf(r['longBylineText']));
  var artists = meta.artists;
  if (artists.isEmpty) {
    final p = meta.plain.where((t) => !_typeWords.contains(t.toLowerCase()) && !_looksLikeStat(t)).toList();
    if (p.isNotEmpty) artists = [ArtistRef(p.first)];
  }
  final watch = dig(r, ['navigationEndpoint', 'watchEndpoint']);
  return Item(
    kind: _kindFromWatch(watch) ?? ItemKind.song,
    id: id,
    title: title,
    artists: artists,
    album: meta.album,
    albumId: meta.albumId,
    durationSec: parseDuration(runsText(r['lengthText'])),
    thumb: bestThumb(r['thumbnail']),
    explicit: findAll(r['badges'], 'iconType').contains('MUSIC_EXPLICIT_BADGE'),
  );
}

List<Item> _itemsOf(List contents, {String? fallbackThumb, String? fallbackAlbum, String? fallbackAlbumId, List<ArtistRef>? fallbackArtists}) {
  final out = <Item>[];
  for (final c in contents) {
    if (c is! Map) continue;
    Item? it;
    if (c['musicResponsiveListItemRenderer'] != null) {
      it = parseResponsiveItem(
        c['musicResponsiveListItemRenderer'],
        fallbackThumb: fallbackThumb,
        fallbackAlbum: fallbackAlbum,
        fallbackAlbumId: fallbackAlbumId,
        fallbackArtists: fallbackArtists,
      );
    } else if (c['musicTwoRowItemRenderer'] != null) {
      it = parseTwoRowItem(c['musicTwoRowItemRenderer']);
    } else if (c['playlistPanelVideoRenderer'] != null) {
      it = parsePanelVideo(c['playlistPanelVideoRenderer']);
    } else if (c['musicMultiRowListItemRenderer'] != null) {
      it = parseEpisode(c['musicMultiRowListItemRenderer'], fallbackShow: fallbackAlbum, fallbackShowId: fallbackAlbumId);
    }
    if (it != null) out.add(it);
  }
  return out;
}

String? _shelfTitle(Map sh) {
  final h = sh['header'];
  final t = runsText(dig(h, ['musicCarouselShelfBasicHeaderRenderer', 'title']));
  if (t.isNotEmpty) return t;
  final t2 = runsText(dig(h, ['musicImmersiveCarouselShelfRenderer', 'title']));
  if (t2.isNotEmpty) return t2;
  final t3 = runsText(sh['title']);
  if (t3.isNotEmpty) return t3;
  return null;
}

/// All carousels / shelves inside a browse or search response.
List<Shelf> parseShelves(dynamic root, {bool carouselsOnly = false}) {
  final out = <Shelf>[];
  void visit(dynamic o) {
    if (o is Map) {
      for (final e in o.entries) {
        final k = e.key;
        final v = e.value;
        if ((k == 'musicCarouselShelfRenderer' || (!carouselsOnly && k == 'musicShelfRenderer') || k == 'musicImmersiveCarouselShelfRenderer') && v is Map) {
          final items = _itemsOf(v['contents'] as List? ?? const []);
          final title = _shelfTitle(v) ?? '';
          final strap = runsText(dig(v, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'strapline']));
          final more =
              dig(v, ['header', 'musicCarouselShelfBasicHeaderRenderer', 'moreContentButton', 'buttonRenderer', 'navigationEndpoint', 'browseEndpoint']) ??
              dig(v, ['bottomEndpoint', 'browseEndpoint']);
          if (items.isNotEmpty) {
            out.add(
              Shelf(
                title,
                items,
                subtitle: strap.isEmpty ? null : strap,
                moreBrowseId: dig(more, ['browseId']) as String?,
                moreParams: dig(more, ['params']) as String?,
              ),
            );
          }
          continue; // don't descend into this shelf again
        }
        if (k == 'musicCardShelfRenderer' && v is Map) {
          final top = _parseCardShelf(v);
          if (top.isNotEmpty) out.add(Shelf('Top result', top));
          continue;
        }
        visit(v);
      }
    } else if (o is List) {
      for (final v in o) {
        visit(v);
      }
    }
  }

  visit(root);
  return out;
}

List<Item> _parseCardShelf(Map v) {
  final out = <Item>[];
  final title = runsText(v['title']).trim();
  final nav = dig(v, ['title', 'runs', 0, 'navigationEndpoint']);
  final sub = runsText(v['subtitle']).trim();
  final thumb = bestThumb(v['thumbnail']);
  final watch = dig(nav, ['watchEndpoint']);
  if (watch is Map && watch['videoId'] is String) {
    final meta = _readMetaRuns(runsOf(v['subtitle']));
    out.add(
      Item(
        kind: _kindFromWatch(watch) ?? ItemKind.song,
        id: watch['videoId'] as String,
        title: title,
        artists: meta.artists,
        album: meta.album,
        albumId: meta.albumId,
        durationSec: meta.duration,
        thumb: thumb,
      ),
    );
  } else {
    final kind = _kindFromPageType(_pageType(nav));
    final bid = dig(nav, ['browseEndpoint', 'browseId']) as String?;
    if (kind != null && bid != null) out.add(Item(kind: kind, id: bid, title: title, thumb: thumb, subtitle: sub));
  }
  out.addAll(_itemsOf(v['contents'] as List? ?? const []));
  return out;
}

String? _continuationToken(dynamic o) {
  final cirs = findAll(o, 'continuationItemRenderer');
  for (final c in cirs) {
    final t = dig(c, ['continuationEndpoint', 'continuationCommand', 'token']);
    if (t is String) return t;
  }
  return null;
}

String? sectionContinuation(dynamic o) {
  final cs = findAll(o, 'nextContinuationData');
  for (final c in cs) {
    final t = dig(c, ['continuation']);
    if (t is String) return t;
  }
  return null;
}

HomeFeed parseHome(dynamic root) {
  final sl = findAll(root, 'sectionListRenderer');
  String? cont;
  if (sl.isNotEmpty) cont = sectionContinuation(sl.first['continuations']);
  cont ??= sectionContinuation(dig(root, ['continuationContents', 'sectionListContinuation', 'continuations']));
  return HomeFeed(parseShelves(root['contents'] ?? root['continuationContents'] ?? root), cont);
}

/// Search results for one filter → items; [all] returns shelves.
List<Item> parseSearchItems(dynamic root) {
  final out = <Item>[];
  final seen = <String>{};
  for (final sh in parseShelves(root)) {
    for (final i in sh.items) {
      if (seen.add('${i.kind.name}:${i.id}')) out.add(i);
    }
  }
  // Some layouts put rows directly inside itemSectionRenderer.
  for (final isr in findAll(root, 'itemSectionRenderer')) {
    for (final i in _itemsOf(isr is Map ? (isr['contents'] as List? ?? const []) : const [])) {
      if (seen.add('${i.kind.name}:${i.id}')) out.add(i);
    }
  }
  return out;
}

String? parseSearchContinuation(dynamic root) {
  final ms = findAll(root, 'musicShelfRenderer');
  for (final m in ms) {
    final c = sectionContinuation(m is Map ? m['continuations'] : null) ?? _continuationToken(m);
    if (c != null) return c;
  }
  final mc = dig(root, ['continuationContents', 'musicShelfContinuation']);
  if (mc != null) return sectionContinuation(mc['continuations']);
  return null;
}

List<Item> parseSearchContinuationItems(dynamic root) {
  final mc = dig(root, ['continuationContents', 'musicShelfContinuation', 'contents']);
  if (mc is List) return _itemsOf(mc);
  return parseSearchItems(root);
}

PageHeader _parseHeader(dynamic root) {
  final rh = findAll(root, 'musicResponsiveHeaderRenderer');
  if (rh.isNotEmpty) {
    final h = rh.first as Map;
    final strap = _readMetaRuns(runsOf(h['straplineTextOne']));
    return PageHeader(
      title: runsText(h['title']),
      subtitle: runsText(h['subtitle']),
      secondSubtitle: runsText(h['secondSubtitle']),
      description: runsText(dig(h, ['description', 'musicDescriptionShelfRenderer', 'description'])),
      thumb: bestThumb(h['thumbnail']),
      artists: strap.artists.isNotEmpty ? strap.artists : [if (runsText(h['straplineTextOne']).isNotEmpty) ArtistRef(runsText(h['straplineTextOne']))],
    );
  }
  for (final k in ['musicImmersiveHeaderRenderer', 'musicVisualHeaderRenderer', 'musicDetailHeaderRenderer', 'musicEditablePlaylistDetailHeaderRenderer']) {
    final hs = findAll(root, k);
    if (hs.isNotEmpty) {
      final h = hs.first as Map;
      final inner = h['header'] is Map ? findAll(h['header'], 'musicDetailHeaderRenderer').firstOrNull ?? h : h;
      return PageHeader(
        title: runsText((inner as Map)['title']),
        subtitle: runsText(inner['subtitle']),
        secondSubtitle: runsText(inner['secondSubtitle']),
        description: runsText(inner['description']),
        thumb: bestThumb(inner['thumbnail'] ?? inner['foregroundThumbnail']),
      );
    }
  }
  return const PageHeader(title: '');
}

BrowsePage parseBrowsePage(String id, dynamic root) {
  final header = _parseHeader(root);
  ItemKind kind;
  if (id.startsWith('MPRE') || id.startsWith('OLAK')) {
    kind = ItemKind.album;
  } else if (id.startsWith('UC') || id.startsWith('MPLA')) {
    kind = ItemKind.artist;
  } else if (id.startsWith('MPSP')) {
    kind = ItemKind.podcast;
  } else {
    kind = ItemKind.playlist;
  }
  final tracks = <Item>[];
  final shelves = <Shelf>[];
  if (kind == ItemKind.artist) {
    shelves.addAll(parseShelves(root['contents'] ?? root));
  } else {
    // Tracks live in musicShelfRenderer / musicPlaylistShelfRenderer of the main column.
    final albumArtists = header.artists.where((a) => a.id != null).toList();
    final containers = [...findAll(root, 'musicPlaylistShelfRenderer'), ...findAll(root, 'musicShelfRenderer')];
    for (final c in containers.take(1)) {
      tracks.addAll(
        _itemsOf(
          (c as Map)['contents'] as List? ?? const [],
          fallbackThumb: kind == ItemKind.album ? header.thumb : null,
          fallbackAlbum: kind == ItemKind.album || kind == ItemKind.podcast ? header.title : null,
          fallbackAlbumId: kind == ItemKind.album || kind == ItemKind.podcast ? id : null,
          fallbackArtists: kind == ItemKind.album ? albumArtists : null,
        ),
      );
    }
    shelves.addAll(parseShelves(root['contents'] ?? root, carouselsOnly: true));
  }
  return BrowsePage(id: id, kind: kind, header: header, tracks: tracks, shelves: shelves, continuation: _continuationToken(root));
}

/// Continuation of a long playlist → (items, next token).
(List<Item>, String?) parseTrackContinuation(dynamic root) {
  final items = <Item>[];
  for (final a in findAll(root, 'appendContinuationItemsAction')) {
    items.addAll(_itemsOf((a as Map)['continuationItems'] as List? ?? const []));
  }
  final legacy = dig(root, ['continuationContents', 'musicPlaylistShelfContinuation', 'contents']);
  if (legacy is List) items.addAll(_itemsOf(legacy));
  return (items, _continuationToken(root));
}

class NextInfo {
  final List<Item> queue;
  final String? lyricsBrowseId;
  final String? relatedBrowseId;
  const NextInfo(this.queue, this.lyricsBrowseId, this.relatedBrowseId);
}

NextInfo parseNext(dynamic root) {
  final queue = <Item>[];
  final seen = <String>{};
  // The other version of a song (its music video, or the audio of a video)
  // rides inside the same queue entry: it's not a separate song to play.
  final counterparts = <String>{};
  for (final w in findAll(root, 'playlistPanelVideoWrapperRenderer')) {
    for (final c in ((w as Map)['counterpart'] as List? ?? const [])) {
      final id = dig(c, ['counterpartRenderer', 'playlistPanelVideoRenderer', 'videoId']);
      if (id is String) counterparts.add(id);
    }
  }
  for (final p in findAll(root, 'playlistPanelVideoRenderer')) {
    final it = parsePanelVideo(p);
    if (it != null && !counterparts.contains(it.id) && seen.add(it.id)) queue.add(it);
  }
  String? lyrics, related;
  for (final t in findAll(root, 'tabRenderer')) {
    final bid = dig(t, ['endpoint', 'browseEndpoint', 'browseId']) as String?;
    final pt = dig(t, ['endpoint', 'browseEndpoint', 'browseEndpointContextSupportedConfigs', 'browseEndpointContextMusicConfig', 'pageType']);
    if (bid == null) continue;
    if (pt == 'MUSIC_PAGE_TYPE_TRACK_LYRICS' || bid.startsWith('MPLYt')) lyrics = bid;
    if (pt == 'MUSIC_PAGE_TYPE_TRACK_RELATED' || bid.startsWith('MPTRt')) related = bid;
  }
  return NextInfo(queue, lyrics, related);
}

/// Plain lyrics from the lyrics tab browse response (null when the tab says "not available").
String? parsePlainLyrics(dynamic root) {
  final shelves = findAll(root, 'musicDescriptionShelfRenderer');
  for (final s in shelves) {
    final t = runsText((s as Map)['description']).replaceAll('\r\n', '\n').trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

List<String> parseSuggestions(dynamic root) {
  final out = <String>[];
  for (final s in findAll(root, 'searchSuggestionRenderer')) {
    final t = runsText((s as Map)['suggestion']).trim();
    if (t.isNotEmpty) out.add(t);
  }
  return out;
}

/// musicNavigationButtonRenderer grid → mood/genre categories.
List<MoodCategory> parseMoods(dynamic root) {
  final out = <MoodCategory>[];
  final seen = <String>{};
  for (final b in findAll(root, 'musicNavigationButtonRenderer')) {
    final title = runsText(b['buttonText']).trim();
    final params = dig(b, ['clickCommand', 'browseEndpoint', 'params']) as String?;
    final color = (dig(b, ['solid', 'leftStripeColor']) as num?)?.toInt() ?? 0xFF7C5CFF;
    if (title.isEmpty || params == null || !seen.add(params)) continue;
    out.add(MoodCategory(title, color | 0xFF000000, params));
  }
  return out;
}


// ── Versions: a song's audio track and its music video ─────────────────

/// One version of a song, with YouTube Music's own type for it.
class Rendition {
  final Item item;

  /// MUSIC_VIDEO_TYPE_ATV (audio / art track), _OMV (official music video),
  /// _UGC (user video), _PODCAST_EPISODE …
  final String type;
  const Rendition(this.item, this.type);
  bool get isAudio => type == 'MUSIC_VIDEO_TYPE_ATV' || type.isEmpty;
  bool get isVideo => type == 'MUSIC_VIDEO_TYPE_OMV' || type == 'MUSIC_VIDEO_TYPE_UGC' || type == 'MUSIC_VIDEO_TYPE_OFFICIAL_SOURCE_MUSIC';
}

/// Which part of one version lines up with which part of the other
/// (music videos often start with an intro the song doesn't have).
class VersionSegment {
  final int primaryStartMs;
  final int counterpartStartMs;
  final int durationMs;
  const VersionSegment(this.primaryStartMs, this.counterpartStartMs, this.durationMs);
}

/// A song that exists both as its audio track and as a music video.
class SongVersions {
  final Rendition primary;
  final Rendition counterpart;
  final List<VersionSegment> segments;
  const SongVersions(this.primary, this.counterpart, this.segments);

  Rendition? get audio => primary.isAudio ? primary : (counterpart.isAudio ? counterpart : null);
  Rendition? get video => primary.isVideo ? primary : (counterpart.isVideo ? counterpart : null);
  bool get hasBoth => audio != null && video != null;

  /// The other version of [id] (null if [id] is neither).
  Rendition? other(String id) => id == primary.item.id ? counterpart : (id == counterpart.item.id ? primary : null);

  /// Where [pos] in version [fromId] is in the other version. Inside a
  /// matched segment the offset carries over; between segments it snaps to
  /// the nearest matched point; with no map, the same time.
  Duration map(Duration pos, {required String fromId}) {
    if (segments.isEmpty) return pos;
    final fromPrimary = fromId == primary.item.id;
    final p = pos.inMilliseconds;
    VersionSegment? best;
    var bestDist = 1 << 62;
    for (final s in segments) {
      final start = fromPrimary ? s.primaryStartMs : s.counterpartStartMs;
      final other = fromPrimary ? s.counterpartStartMs : s.primaryStartMs;
      if (p >= start && p < start + s.durationMs) return Duration(milliseconds: other + (p - start));
      final d = p < start ? start - p : p - (start + s.durationMs);
      if (d < bestDist) {
        bestDist = d;
        best = s;
      }
    }
    final s = best!;
    final start = fromPrimary ? s.primaryStartMs : s.counterpartStartMs;
    final other = fromPrimary ? s.counterpartStartMs : s.primaryStartMs;
    return Duration(milliseconds: p < start ? other : other + s.durationMs - 1);
  }
}

String _musicVideoType(dynamic panel) =>
    dig(panel, ['navigationEndpoint', 'watchEndpoint', 'watchEndpointMusicSupportedConfigs', 'watchEndpointMusicConfig', 'musicVideoType']) as String? ?? '';

int _ms(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;

/// The audio/video versions of [videoId] from a `next` response, if it has two.
SongVersions? parseVersions(dynamic root, String videoId) {
  for (final w in findAll(root, 'playlistPanelVideoWrapperRenderer')) {
    final pr = dig(w, ['primaryRenderer', 'playlistPanelVideoRenderer']);
    final primary = parsePanelVideo(pr);
    if (primary == null) continue;
    for (final c in ((w as Map)['counterpart'] as List? ?? const [])) {
      final cr = dig(c, ['counterpartRenderer', 'playlistPanelVideoRenderer']);
      final other = parsePanelVideo(cr);
      if (other == null) continue;
      if (primary.id != videoId && other.id != videoId) continue;
      final segs = [
        for (final s in (dig(c, ['segmentMap', 'segment']) as List? ?? const []))
          if (s is Map) VersionSegment(_ms(s['primaryVideoStartTimeMilliseconds']), _ms(s['counterpartVideoStartTimeMilliseconds']), _ms(s['durationMilliseconds'])),
      ];
      return SongVersions(Rendition(primary, _musicVideoType(pr)), Rendition(other, _musicVideoType(cr)), segs);
    }
  }
  return null;
}
