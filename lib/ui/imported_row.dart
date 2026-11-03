// Byte © 2026 Apurba Laskar.
//
// Home → "From your music apps" (1.4.2, Apurba): every playlist brought in
// from another music app — by log-in or by link, from any number of apps —
// plus the liked songs, as the very first row of Home. Tap: it plays and opens.

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/library.dart';
import '../data/service_library.dart' show LibService;
import '../services.dart';
import 'nav.dart';
import 'screens/library_pages.dart' show LikedScreen;
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

  @override
  Widget build(BuildContext context) {
    final lib = Services.i.library;
    // 1.4.4: a logged-in account's playlists have their own row ("From
    // Spotify") just above; this row keeps the rest (links, other sources).
    final inRows = playlistsInServiceRows(lib);
    final lists = importedPlaylists(lib).where((p) => !inRows.contains(p.id)).toList();
    final likes = lib.likes;
    var fromApps = false;
    try {
      fromApps = Services.i.spotify.connected || LibService.values.any(Services.i.libSync.connected);
    } catch (_) {}
    // the service rows already carry Liked Songs: nothing left → no row
    if (fromApps && lists.isEmpty) return const SizedBox.shrink();
    // nothing imported yet: no row at all
    if (lists.isEmpty && !(fromApps && likes.isNotEmpty)) return const SizedBox.shrink();
    return Column(
      key: const ValueKey('home-imports'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('From your music apps', padding: EdgeInsets.fromLTRB(16, 12, 16, 10)),
        SizedBox(
          height: 206,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              if (likes.isNotEmpty)
                _ImportCard(
                  key: const ValueKey('home-import-liked'),
                  art: const _LikedArt(),
                  title: 'Liked songs',
                  sub: '${likes.length} songs · all apps',
                  onTap: () {
                    Services.i.player.playItems(likes, from: 'Liked songs');
                    pushPage(context, const LikedScreen());
                  },
                ),
              for (final p in lists)
                _ImportCard(
                  key: ValueKey('home-import-${p.id}'),
                  art: _Mosaic(p),
                  title: p.name,
                  sub: '${importSourceLabel(p.source)} · ${p.items.length} songs',
                  onTap: () {
                    if (p.items.isNotEmpty) Services.i.player.playItems(p.items, from: p.name);
                    pushPage(context, PlaylistScreen(id: p.id));
                  },
                ),
            ],
          ),
        ),
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
class _Mosaic extends StatelessWidget {
  final LocalPlaylist p;
  const _Mosaic(this.p);
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

class _LikedArt extends StatelessWidget {
  const _LikedArt();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFFFF2D55), Color(0xFF7B2CBF)], begin: Alignment.topLeft, end: Alignment.bottomRight)),
      alignment: Alignment.center,
      child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 56),
    );
  }
}
