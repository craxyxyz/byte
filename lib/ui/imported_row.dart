// Byte © 2026 Apurba Laskar.
//
// Home → "From <app>" shelves (1.4.2, Apurba; one shelf per app since 1.4.5): every playlist brought in
// from another music app — by log-in or by link, from any number of apps —
// plus the liked songs, as the very first row of Home. Tap: it plays and opens.

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/library.dart';
import '../services.dart';
import 'nav.dart';
import 'screens/playlist_screen.dart';
import 'service_rows.dart' show playlistsInServiceRows;
import 'style.dart';
import 'widgets.dart';

/// Where an imported playlist came from, as a short label ("Amazon Music"),
/// or null for a playlist made in Byte.
String? importSourceLabel(String? source) {
  if (source == null || source.isEmpty) return null;
  if (source.startsWith('account:')) return 'YouTube Music';
  return switch (source.split(':').first) {
    'spotify' => 'Spotify',
    'youtube' || 'youtubeMusic' => 'YouTube Music',
    'apple' => 'Apple Music',
    'amazon' => 'Amazon Music',
    'jiosaavn' => 'JioSaavn',
    'gaana' => 'Gaana',
    'soundcloud' => 'SoundCloud',
    'deezer' => 'Deezer',
    'wynk' => 'Wynk',
    'web' => 'Web page',
    'text' => 'Song list',
    'file' => 'File',
    _ => null,
  };
}

/// Every imported playlist, most recently updated first (pinned ones first).
List<LocalPlaylist> importedPlaylists(Library lib) {
  final pins = lib.pinnedPlaylists;
  final l = lib.playlists.where((p) => importSourceLabel(p.source) != null).toList();
  l.sort((a, b) {
    final pa = pins.contains(a.id), pb = pins.contains(b.id);
    if (pa != pb) return pa ? -1 : 1;
    return b.updated.compareTo(a.updated);
  });
  return l;
}

class ImportedRow extends StatelessWidget {
  const ImportedRow({super.key});

  // 1.4.5: listens itself. Home builds this row as a const child, so a
  // parent rebuild never reached it and a new import only showed after a
  // restart or a pull to refresh.
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Services.i.library, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final lib = Services.i.library;
    // 1.4.4: a logged-in account's playlists have their own row ("From
    // Spotify") just above; this row keeps the rest (links, other sources).
    final inRows = playlistsInServiceRows(lib);
    final lists = importedPlaylists(lib).where((p) => !inRows.contains(p.id)).toList();
    // 1.4.5: Liked songs moved to the top of Home (HomeLibraryRows), for
    // every account; this row only keeps playlists from other apps.
    if (lists.isEmpty) return const SizedBox.shrink();
    // 1.4.5 (Apurba: imported playlists show like "Your playlists"): one
    // shelf per app, "From Spotify", "From JioSaavn" …, same cards; lists
    // from a web page, a song list or a file share one "Imported lists" shelf.
    final shownInRows = {for (final p in lib.playlists) if (inRows.contains(p.id)) importSourceLabel(p.source)};
    final groups = <String, List<LocalPlaylist>>{};
    for (final p in lists) {
      final label = importSourceLabel(p.source)!;
      final title = const {'Web page', 'Song list', 'File'}.contains(label)
          ? 'Imported lists'
          : shownInRows.contains(label)
          ? 'More from $label'
          : 'From $label';
      groups.putIfAbsent(title, () => []).add(p);
    }
    return Column(
      key: const ValueKey('home-imports'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final g in groups.entries) ...[
          SectionTitle(g.key, padding: const EdgeInsets.fromLTRB(16, 12, 16, 10)),
          SizedBox(
            height: 206,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final p in g.value)
                  _ImportCard(
                    key: ValueKey('home-import-${p.id}'),
                    art: PlaylistMosaic(p),
                    title: p.name,
                    sub: g.key == 'Imported lists' ? '${importSourceLabel(p.source)} · ${songCount(p.items.length)}' : songCount(p.items.length),
                    onTap: () {
                      if (p.items.isNotEmpty) Services.i.player.playItems(p.items, from: p.name);
                      pushPage(context, PlaylistScreen(id: p.id));
                    },
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ImportCard extends StatelessWidget {
  final Widget art;
  final String title;
  final String sub;
  final VoidCallback onTap;
  const _ImportCard({super.key, required this.art, required this.title, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Pressable(
        onTap: onTap,
        child: SizedBox(
          width: 148,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox(width: 148, height: 148, child: art)),
              const SizedBox(height: 8),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: p.label, fontWeight: FontWeight.w600)),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.caption.copyWith(color: p.secondary)),
            ],
          ),
        ),
      ),
    );
  }
}

/// The playlist's own cover, else the first four songs' covers in a 2×2 grid.
class PlaylistMosaic extends StatelessWidget {
  final LocalPlaylist p;
  const PlaylistMosaic(this.p, {super.key});
  @override
  Widget build(BuildContext context) {
    final thumbs = <String>[];
    for (final Item it in p.items) {
      final t = it.thumb;
      if (t != null && !thumbs.contains(t)) thumbs.add(t);
      if (thumbs.length == 4) break;
    }
    if (p.cover != null || thumbs.length < 4) return Artwork(p.artwork, size: 148, radius: 0, icon: Icons.queue_music_rounded);
    return GridView.count(
      crossAxisCount: 2,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      children: [for (final t in thumbs) Artwork(t, size: 74, radius: 0)],
    );
  }
}
