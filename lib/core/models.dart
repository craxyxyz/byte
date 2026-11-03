import 'dart:convert';

/// podcast = a show (browseId MPSP…), episode = one playable podcast episode.
enum ItemKind { song, video, album, playlist, artist, podcast, episode }

ItemKind _kindFrom(String? s) => ItemKind.values.firstWhere((k) => k.name == s, orElse: () => ItemKind.song);

class ArtistRef {
  final String name;
  final String? id;
  const ArtistRef(this.name, [this.id]);
  Map<String, dynamic> toJson() => {'n': name, if (id != null) 'i': id};
  factory ArtistRef.fromJson(Map m) => ArtistRef(m['n'] as String? ?? '', m['i'] as String?);
  @override
  bool operator ==(Object other) => other is ArtistRef && other.name == name && other.id == id;
  @override
  int get hashCode => Object.hash(name, id);
}

/// Anything that shows up in a list: a song, video, album, playlist or artist.
class Item {
  final ItemKind kind;

  /// videoId for songs/videos, browseId for albums/playlists/artists,
  /// `local:<path>` for device files.
  final String id;
  final String title;
  final List<ArtistRef> artists;
  final String? album;
  final String? albumId;
  final int? durationSec;
  final String? thumb;
  final String? subtitle; // free text for albums/playlists/artists ("Album • 2023")
  final bool explicit;

  const Item({
    required this.kind,
    required this.id,
    required this.title,
    this.artists = const [],
    this.album,
    this.albumId,
    this.durationSec,
    this.thumb,
    this.subtitle,
    this.explicit = false,
  });

  bool get isPlayable => kind == ItemKind.song || kind == ItemKind.video || kind == ItemKind.episode;
  /// Not a YouTube song: a file on this phone (`local:`) or on your own
  /// WebDAV server (`dav:<url>`).
  /// Also songs from an addon (`addon:<addon>:<id>`) or an SMB share (`smb:/share/…`).
  bool get isLocal => id.startsWith('local:') || id.startsWith('dav:') || id.startsWith('addon:') || id.startsWith('smb:');
  bool get isDav => id.startsWith('dav:');
  bool get isAddon => id.startsWith('addon:');
  bool get isSmb => id.startsWith('smb:');
  bool get isOnPhone => id.startsWith('local:');
  String get artistLine => artists.map((a) => a.name).where((n) => n.isNotEmpty).join(', ');
  String get line2 {
    if (isPlayable) {
      final parts = <String>[if (artistLine.isNotEmpty) artistLine, if (album != null && album!.isNotEmpty) album!];
      return parts.join(' • ');
    }
    return subtitle ?? artistLine;
  }

  /// A larger version of the thumbnail (YouTube image URLs are resizable).
  String? thumbAt(int px) => resizeThumb(thumb, px);

  Item copyWith({String? thumb, int? durationSec, String? album, String? albumId, String? title, List<ArtistRef>? artists}) => Item(
    kind: kind,
    id: id,
    title: title ?? this.title,
    artists: artists ?? this.artists,
    album: album ?? this.album,
    albumId: albumId ?? this.albumId,
    durationSec: durationSec ?? this.durationSec,
    thumb: thumb ?? this.thumb,
    subtitle: subtitle,
    explicit: explicit,
  );

  Map<String, dynamic> toJson() => {
    'k': kind.name,
    'id': id,
    't': title,
    if (artists.isNotEmpty) 'a': artists.map((a) => a.toJson()).toList(),
    if (album != null) 'al': album,
    if (albumId != null) 'ai': albumId,
    if (durationSec != null) 'd': durationSec,
    if (thumb != null) 'th': thumb,
    if (subtitle != null) 's': subtitle,
    if (explicit) 'e': true,
  };

  factory Item.fromJson(Map m) => Item(
    kind: _kindFrom(m['k'] as String?),
    id: m['id'] as String,
    title: m['t'] as String? ?? '',
    artists: ((m['a'] as List?) ?? const []).map((e) => ArtistRef.fromJson(e as Map)).toList(),
    album: m['al'] as String?,
    albumId: m['ai'] as String?,
    durationSec: (m['d'] as num?)?.toInt(),
    thumb: m['th'] as String?,
    subtitle: m['s'] as String?,
    explicit: m['e'] == true,
  );

  String encode() => jsonEncode(toJson());
  static Item decode(String s) => Item.fromJson(jsonDecode(s) as Map);

  @override
  bool operator ==(Object other) => other is Item && other.id == id && other.kind == kind;
  @override
  int get hashCode => Object.hash(id, kind);
  @override
  String toString() => 'Item(${kind.name} $id "$title")';
}

String? resizeThumb(String? url, int px) {
  if (url == null) return null;
  if (url.contains('googleusercontent.com') || url.contains('ggpht.com')) {
    final r = RegExp(r'=w\d+-h\d+');
    if (r.hasMatch(url)) return url.replaceFirst(r, '=w$px-h$px');
    final s = RegExp(r'=s\d+');
    if (s.hasMatch(url)) return url.replaceFirst(s, '=s$px');
    return url;
  }
  if (url.contains('i.ytimg.com/vi')) {
    // 16:9 frames without black bars: small = mqdefault (320×180),
    // big = hq720 (1280×720). Square spots crop the centre.
    return url.replaceFirst(RegExp(r'/(default|mqdefault|hqdefault|sddefault|hq720|maxresdefault)\.jpg.*$'), px <= 320 ? '/mqdefault.jpg' : '/hq720.jpg');
  }
  return url;
}

/// A YouTube frame picture with black bars above and below (4:3 files).
bool isLetterboxedThumb(String? url) => url != null && url.contains('i.ytimg.com/vi') && RegExp(r'/(default|hqdefault|sddefault)\.jpg').hasMatch(url);

/// The same YouTube frame, another file (for when hq720 doesn't exist).
String? ytThumbVariant(String? url, String file) =>
    url == null || !url.contains('i.ytimg.com/vi') ? null : url.replaceFirst(RegExp(r'/[a-z0-9]+\.jpg.*$'), '/$file.jpg');

class Shelf {
  final String title;
  final String? subtitle;
  final List<Item> items;

  /// Optional "More" target (browseId + params).
  final String? moreBrowseId;
  final String? moreParams;
  const Shelf(this.title, this.items, {this.subtitle, this.moreBrowseId, this.moreParams});
  bool get isSongList => items.isNotEmpty && items.every((i) => i.isPlayable);
}

class PageHeader {
  final String title;
  final String? subtitle;
  final String? secondSubtitle;
  final String? description;
  final String? thumb;
  final List<ArtistRef> artists;
  const PageHeader({required this.title, this.subtitle, this.secondSubtitle, this.description, this.thumb, this.artists = const []});
}

/// An album, playlist or artist page.
class BrowsePage {
  final String id;
  final ItemKind kind;
  final PageHeader header;
  final List<Item> tracks;
  final List<Shelf> shelves;
  final String? continuation;
  const BrowsePage({required this.id, required this.kind, required this.header, this.tracks = const [], this.shelves = const [], this.continuation});
}

class HomeFeed {
  final List<Shelf> shelves;
  final String? continuation;
  const HomeFeed(this.shelves, [this.continuation]);
}

enum SearchFilter { all, songs, videos, albums, artists, playlists, podcasts, episodes }

/// A "Moods & genres" button: its name, YouTube's colour for it and the page to open.
class MoodCategory {
  final String title;
  final int color; // ARGB
  final String params;
  const MoodCategory(this.title, this.color, this.params);
}

class AccountInfo {
  final String name;
  final String? email;
  final String? handle;
  final String? photo;
  const AccountInfo({required this.name, this.email, this.handle, this.photo});
}

/// "1 song", "12 songs" (1.4.5 QA: lists said "1 songs").
String songCount(int n) => n == 1 ? '1 song' : '$n songs';
