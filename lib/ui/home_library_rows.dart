// Byte © 2026 Apurba Laskar.
//
// Home → "Liked songs" + "Your playlists" (1.4.5, Apurba: "Byte account se
// login karne ke baad liked songs home page pe kyun nahi aa rahe? Agar koi
// Byte app pe playlist banaye toh woh home page pe hi show hona chahiye").
// Everything here is read from the phone's own library, so it shows signed
// out too, and it is rebuilt on every library change: a like, a new / renamed
// / deleted playlist, a song added, or likes and playlists pulled from the
// Byte account after signing in.

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/library.dart';
import '../services.dart';
import 'imported_row.dart' show importSourceLabel, PlaylistMosaic;
import 'nav.dart';
import 'screens/library_pages.dart' show LikedScreen;
import 'screens/library_screen.dart' show newPlaylist;
import 'screens/playlist_screen.dart';
import 'service_rows.dart' show LikedArt;
import 'shell.dart';
import 'style.dart';
import 'widgets.dart' show textGrow;

/// Playlists made in Byte (not brought in from another app), local or synced
/// from the Byte account: pinned first, then most recently played or edited.
List<LocalPlaylist> byteMadePlaylists(Library lib) {
  final pins = lib.pinnedPlaylists;
  final played = lib.playlistPlayed;
  final l = lib.playlists.where((p) => importSourceLabel(p.source) == null).toList();
  l.sort((a, b) {
    final pa = pins.contains(a.id), pb = pins.contains(b.id);
    if (pa != pb) return pa ? -1 : 1;
    return lib.playlistRecency(b, played).compareTo(lib.playlistRecency(a, played));
  });
  return l;
}

/// Plays a Byte playlist from Home (and remembers it for the order) and opens it.
void openBytePlaylist(BuildContext context, LocalPlaylist p) {
  final lib = Services.i.library;
  if (p.items.isNotEmpty) {
    Services.i.player.playItems(p.items, from: p.name);
    lib.notePlaylistPlayed(p.id);
  }
  pushPage(context, PlaylistScreen(id: p.id));
}

/// The top of Home: the Liked songs card (when there are likes) and the
/// "Your playlists" shelf (always, with its "New playlist" tile).
class HomeLibraryRows extends StatelessWidget {
  const HomeLibraryRows({super.key});

  @override
  Widget build(BuildContext context) {
    final lib = Services.i.library;
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final likes = lib.likes;
        final mine = byteMadePlaylists(lib);
        return Column(
          key: const ValueKey('home-library'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (likes.isNotEmpty) _LikedCard(likes: likes),
            SectionTitle(
              'Your playlists',
              key: const ValueKey('home-your-playlists'),
              padding: EdgeInsets.fromLTRB(16, likes.isNotEmpty ? 18 : 12, 16, 10),
              action: mine.isEmpty ? null : 'See all',
              onAction: () => ShellState.current?.select(2),
            ),
            SizedBox(
              // 1.4.6: taller with large text (the names were cut at 1.3×)
              height: 206 + textGrow(context, 44),
              child: ListView(
                key: const ValueKey('home-your-playlists-list'),
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  const _NewPlaylistTile(),
                  for (final p in mine)
                    _PlaylistCard(
                      key: ValueKey('home-pl-${p.id}'),
                      art: PlaylistMosaic(p),
                      title: p.name,
                      sub: songCount(p.items.length),
                      onTap: () => openBytePlaylist(context, p),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// "Liked songs · N songs": tap plays them and opens the full list; ▶ only plays.
class _LikedCard extends StatelessWidget {
  final List<Item> likes;
  const _LikedCard({required this.likes});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 700;
    void play() => Services.i.player.playItems(likes, from: 'Liked songs');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 520 : double.infinity),
          child: Semantics(
            button: true,
            label: 'Liked songs, ${songCount(likes.length)}',
            child: Pressable(
              key: const ValueKey('home-liked'),
              onTap: () {
                play();
                pushPage(context, const LikedScreen());
              },
              child: Container(
                constraints: const BoxConstraints(minHeight: 76), // 1.4.6: grows with large text
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: p.grouped, borderRadius: BorderRadius.circular(14)),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: const SizedBox(width: 56, height: 56, child: FittedBox(child: SizedBox(width: 148, height: 148, child: LikedArt()))),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Liked songs', maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.bodyStrong.copyWith(color: p.label)),
                          const SizedBox(height: 2),
                          Text(
                            songCount(likes.length),
                            key: const ValueKey('home-liked-count'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BT.caption.copyWith(color: p.secondary),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('home-liked-play'),
                      tooltip: 'Play liked songs',
                      onPressed: play,
                      icon: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(color: p.label, shape: BoxShape.circle),
                        child: Icon(Icons.play_arrow_rounded, color: p.bg, size: 26),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlaylistCard extends StatelessWidget {
  final Widget art;
  final String title;
  final String sub;
  final VoidCallback onTap;
  const _PlaylistCard({super.key, required this.art, required this.title, required this.sub, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: Semantics(
        button: true,
        label: '$title, $sub',
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
      ),
    );
  }
}

class _NewPlaylistTile extends StatelessWidget {
  const _NewPlaylistTile();
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return _PlaylistCard(
      key: const ValueKey('home-new-playlist'),
      art: Container(
        color: p.fill,
        alignment: Alignment.center,
        child: Icon(Icons.add_rounded, size: 56, color: p.secondary),
      ),
      title: 'New playlist',
      sub: 'Make one in Byte',
      onTap: () => newPlaylist(context),
    );
  }
}
