import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../core/platform_caps.dart';

import '../../data/library.dart';
import '../../services.dart';
import '../../data/playlist_import.dart';
import '../import_sheet.dart';
import '../nav.dart';
import '../page.dart';
import '../stats_card.dart';
import '../style.dart';
import '../widgets.dart';
import 'explore_screen.dart';
import 'integrations_pages.dart';
import 'library_pages.dart';
import 'playlist_screen.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final s = Services.i;
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.stats, s.account]),
      builder: (context, _) {
        final lists = s.library.playlists;
        final spotifyCount = lists.where((l) => importedFrom(l.source) != null).length;
        return TabPage(
          title: 'Library',
          actions: [CircleGlassButton(icon: Icons.history_rounded, tooltip: 'History', onTap: () => pushPage(context, const HistoryScreen()))],
          slivers: [
            const SliverToBoxAdapter(child: StatsCarousel()),
            if (s.account.syncing)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
                  child: Row(
                    children: [
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Expanded(child: Text(s.account.syncMessage ?? '', style: BT.sub.copyWith(color: p.secondary))),
                    ],
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Column(
                children: [
                  if (!onWeb)
                  PlainRow(
                    icon: Icon(Icons.download_rounded, color: p.label),
                    title: 'Downloads',
                    trailingText: s.library.downloads.isEmpty ? null : '${s.library.downloads.length}',
                    onTap: () => pushPage(context, const DownloadsScreen()),
                  ),
                  if (!onWeb)
                  PlainRow(
                    icon: Icon(Icons.folder_rounded, color: p.label),
                    title: 'Local Music',
                    trailingText: s.library.localTracks.isEmpty ? null : '${s.library.localTracks.length}',
                    onTap: () => pushPage(context, const LocalMusicScreen()),
                  ),
                  if (s.webdav.configured)
                    PlainRow(
                      icon: Icon(Icons.dns_rounded, color: p.label),
                      title: 'Your server',
                      onTap: () => pushPage(context, const DavFolderScreen()),
                    ),
                  PlainRow(
                    icon: Icon(Icons.queue_music_rounded, color: p.label),
                    title: 'Imported',
                    trailingText: spotifyCount == 0 ? null : '$spotifyCount',
                    divider: false,
                    onTap: () => pushPage(context, const SpotifyScreen()),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: SectionTitle(
                'Playlists',
                action: lists.length > 3 ? 'Show all' : null,
                onAction: () => pushPage(context, const AllPlaylistsScreen()),
              ),
            ),
            SliverToBoxAdapter(
              child: _TileRow(
                tiles: [
                  _Tile(
                    art: _IconArt(icon: Icons.add_rounded, colors: [p.grouped, p.grouped], iconColor: p.secondary),
                    title: 'New playlist',
                    sub: s.account.signedIn ? 'Saved in Byte' : 'Saved on this phone',
                    onTap: () => newPlaylist(context),
                  ),
                  _Tile(
                    art: _IconArt(icon: Icons.link_rounded, colors: [p.grouped, p.grouped], iconColor: p.secondary),
                    title: 'Import playlist',
                    sub: 'From a playlist link',
                    onTap: () => showImportSheet(context),
                  ),
                  _Tile(
                    art: const _IconArt(icon: Icons.favorite_rounded, colors: [Color(0xFF6A3DF0), Color(0xFF3F8CFF)]),
                    title: 'Liked Songs',
                    sub: '${s.library.likes.length} songs',
                    onTap: () => pushPage(context, const LikedScreen()),
                  ),
                  for (final l in lists) _playlistTile(context, l),
                ],
              ),
            ),
            if (libraryArtists(s).isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionTitle('Artists')),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 150,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    children: [
                      for (final a in libraryArtists(s).take(20))
                        Pressable(
                          onTap: () => a.id != null
                              ? openItem(context, Item(kind: ItemKind.artist, id: a.id!, title: a.name))
                              : pushPage(context, LibraryArtistScreen(name: a.name)),
                          child: SizedBox(
                            width: 104,
                            child: Column(
                              children: [
                                Artwork(a.thumb, size: 92, circle: true, icon: Icons.person_rounded),
                                const SizedBox(height: 6),
                                Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w600)),
                                Text(a.count == 1 ? '1 song' : '${a.count} songs', style: BT.caption.copyWith(color: p.secondary)),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SectionTitle('Podcasts')),
            SliverToBoxAdapter(
              child: _TileRow(
                tiles: [
                  _Tile(
                    art: const _IconArt(icon: Icons.podcasts_rounded, colors: [Color(0xFFE5245C), Color(0xFF8E44D9)]),
                    title: 'Episodes for Later',
                    sub: s.library.laterEpisodes.isEmpty ? 'Your queued episodes' : '${s.library.laterEpisodes.length} episodes',
                    onTap: () => pushPage(context, const LaterScreen()),
                  ),
                  for (final pod in s.library.savedPodcasts)
                    _Tile(
                      art: Artwork(pod.thumbAt(544), size: 166, radius: 0, icon: Icons.podcasts_rounded),
                      title: pod.title,
                      sub: pod.subtitle ?? pod.artistLine,
                      onTap: () => openItem(context, pod),
                      onLongPress: () => showItemMenu(context, pod),
                    ),
                  _Tile(
                    art: _IconArt(icon: Icons.travel_explore_rounded, colors: [p.grouped, p.grouped], iconColor: p.secondary),
                    title: 'Find podcasts',
                    sub: 'Shows and episodes',
                    onTap: () => pushPage(context, const PodcastsScreen()),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  _Tile _playlistTile(BuildContext context, LocalPlaylist l) => _Tile(
    art: l.artwork == null
        ? _IconArt(icon: Icons.queue_music_rounded, colors: [BytePalette.of(context).grouped, BytePalette.of(context).grouped], iconColor: BytePalette.of(context).secondary)
        : Artwork(l.artwork, size: 166, radius: 0),
    title: Services.i.library.isPinned(l.id) ? '📌 ${l.name}' : l.name,
    sub: l.source?.startsWith('account:') == true ? 'From your account' : (importedFrom(l.source) ?? '${l.items.length} songs'),
    onTap: () => pushPage(context, PlaylistScreen(id: l.id)),
    // long-press: pin to the top / unpin
    onLongPress: () async {
      final lib = Services.i.library;
      final on = !lib.isPinned(l.id);
      await lib.setPinned(l.id, on);
      if (context.mounted) toast(context, on ? 'Pinned "${l.name}" to the top' : 'Unpinned "${l.name}"');
    },
  );
}

Future<void> newPlaylist(BuildContext context) async {
  final name = await promptText(context, title: 'New playlist', hint: 'Playlist name');
  if (name == null) return;
  final pl = await Services.i.library.createPlaylist(name);
  if (context.mounted) pushPage(context, PlaylistScreen(id: pl.id));
}

class _Tile {
  final Widget art;
  final String title;
  final String sub;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  const _Tile({required this.art, required this.title, required this.sub, required this.onTap, this.onLongPress});
}

class _TileRow extends StatelessWidget {
  final List<_Tile> tiles;
  const _TileRow({required this.tiles});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    const size = 166.0;
    return SizedBox(
      height: size + 54,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: tiles.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (c, i) {
          final t = tiles[i];
          return Pressable(
            onTap: t.onTap,
            onLongPress: t.onLongPress,
            child: SizedBox(
              width: size,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(borderRadius: BorderRadius.circular(12), child: SizedBox(width: size, height: size, child: t.art)),
                  const SizedBox(height: 8),
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.row.copyWith(color: p.label, fontSize: 16)),
                  Text(t.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.sub.copyWith(color: p.secondary)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _IconArt extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final Color iconColor;
  const _IconArt({required this.icon, required this.colors, this.iconColor = Colors.white});
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight)),
    child: Center(child: Icon(icon, size: 64, color: iconColor)),
  );
}

/// "From a music app" etc. for a playlist that came in through the importer.
String? importedFrom(String? source) {
  if (source == null || source.startsWith('account:')) return null;
  final svc = source.split(':').first;
  final name = MusicService.values.where((m) => m.name == svc).firstOrNull;
  if (name == null) return null;
  return switch (name) {
    MusicService.text => 'From a song list',
    MusicService.file => 'From a file',
    MusicService.web => 'Imported',
    _ => 'From ${serviceName(name)}',
  };
}


/// An artist in your library: liked, downloaded and local songs, most songs first.
class LibraryArtist {
  final String name;
  final String? id;
  final String? thumb;
  final int count;
  const LibraryArtist(this.name, this.id, this.thumb, this.count);
}

List<LibraryArtist> libraryArtists(Services s) {
  final songs = [...s.library.likes, ...s.library.downloads.map((d) => d.item), ...s.library.localTracks];
  final seen = <String>{};
  final by = <String, (String, String?, String?, int)>{};
  for (final it in songs) {
    if (!seen.add(it.id)) continue;
    for (final a in it.artists.take(1)) {
      final k = a.name.trim().toLowerCase();
      if (k.isEmpty) continue;
      final o = by[k];
      by[k] = (a.name, o?.$2 ?? a.id, o?.$3 ?? it.thumb, (o?.$4 ?? 0) + 1);
    }
  }
  final out = [for (final v in by.values) LibraryArtist(v.$1, v.$2, v.$3, v.$4)]..sort((a, b) => b.count.compareTo(a.count));
  return out;
}

/// Songs in your library by one artist (for artists without a YouTube page, e.g. local files).
class LibraryArtistScreen extends StatelessWidget {
  final String name;
  const LibraryArtistScreen({super.key, required this.name});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final songs = <Item>[];
    final seen = <String>{};
    for (final it in [...s.library.likes, ...s.library.downloads.map((d) => d.item), ...s.library.localTracks]) {
      if (it.artists.any((a) => a.name.toLowerCase() == name.toLowerCase()) && seen.add(it.id)) songs.add(it);
    }
    return SubPage(
      title: name,
      showProfile: false,
      slivers: [
        SliverList.list(
          children: [for (final (i, it) in songs.indexed) SongTile(item: it, onTap: () => s.player.playItems(songs, start: i, from: name))],
        ),
      ],
    );
  }
}
