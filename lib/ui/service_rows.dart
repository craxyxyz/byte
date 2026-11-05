// Byte © 2026 Apurba Laskar.
//
// Home → "From Spotify" (1.4.4, Apurba): as soon as a music account is
// logged in, Home shows ITS playlists — Liked Songs first — whether or not
// they are in Byte yet. Tap: an imported one opens (nothing plays until you tap
// a song or Play); one that isn't in Byte yet is brought in (read + matched)
// right there, then opens. The list is kept on the phone, so Home never goes empty
// for a logged-in account even when the service is slow or busy.
// Other logged-in music apps get the same row with their own playlists.

import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../data/library.dart';
import '../data/service_library.dart';
import '../data/spotify_account.dart';
import '../services.dart';
import 'nav.dart';
import 'screens/library_pages.dart' show LikedScreen;
import 'screens/playlist_screen.dart';
import 'style.dart';
import 'widgets.dart';

/// Playlist ids that already show in a service's own row on Home (so the
/// general "From your music apps" row doesn't repeat them).
Set<String> playlistsInServiceRows(Library lib) {
  final out = <String>{};
  final sv = Services.i;
  final prefixes = <String>[if (_spotifyOn()) 'spotify:', for (final s in _otherServices()) '${s.name}:'];
  if (prefixes.isEmpty) return out;
  for (final p in lib.playlists) {
    final src = p.source ?? '';
    if (prefixes.any(src.startsWith)) out.add(p.id);
  }
  // a link-imported Spotify list is still a Spotify list: one row, not two
  if (_spotifyOn()) {
    for (final p in sv.spotifySync.lists) {
      final have = sv.spotifySync.imported(p);
      if (have != null) out.add(have.id);
    }
  }
  return out;
}

bool _spotifyOn() {
  try {
    return Services.i.spotify.connected;
  } catch (_) {
    return false;
  }
}

List<LibService> _otherServices() {
  try {
    return [
      for (final s in LibService.values)
        if (s != LibService.youtubeMusic && !(s == LibService.spotify && _spotifyOn()) && Services.i.libSync.connected(s)) s,
    ];
  } catch (_) {
    return const [];
  }
}

/// Every logged-in music account's row, top of Home.
class MusicServiceRows extends StatelessWidget {
  const MusicServiceRows({super.key});
  @override
  Widget build(BuildContext context) {
    final sv = Services.i;
    return ListenableBuilder(
      listenable: Listenable.merge([sv.spotify, sv.spotifySync, sv.libSync, sv.library]),
      builder: (context, _) {
        final others = _otherServices();
        if (!_spotifyOn() && others.isEmpty) return const SizedBox.shrink();
        return Column(
          key: const ValueKey('home-service-rows'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [if (_spotifyOn()) const SpotifyHomeRow(), for (final s in others) _OtherServiceRow(s)],
        );
      },
    );
  }
}

/// Tests: let the next Home ask for the list again.
@visibleForTesting
void resetSpotifyHomeRowForTest() => _SpotifyHomeRowState._askedThisRun = false;

class SpotifyHomeRow extends StatefulWidget {
  const SpotifyHomeRow({super.key});
  @override
  State<SpotifyHomeRow> createState() => _SpotifyHomeRowState();
}

class _SpotifyHomeRowState extends State<SpotifyHomeRow> {
  /// One quiet list read per app run when Home first shows (more come from
  /// sync and its retries).
  static bool _askedThisRun = false;

  @override
  void initState() {
    super.initState();
    final sy = Services.i.spotifySync;
    final stale = sy.listsRead == null || DateTime.now().difference(sy.listsRead!) > const Duration(hours: 1);
    if (!_askedThisRun && stale) {
      _askedThisRun = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(sy.refreshLists()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sy = Services.i.spotifySync;
    var lists = sy.lists;
    // logged in but no list read yet (or the service is refusing right
    // now): Liked Songs is always there
    if (lists.isEmpty) lists = [SpotifyPlaylistInfo('liked', 'Liked Songs', null, -1, Services.i.spotify.userName)];
    return Column(
      key: const ValueKey('home-spotify'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle('From Spotify', padding: EdgeInsets.fromLTRB(16, 12, 16, 10)),
        SizedBox(
          height: 206,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final p in lists)
                ServiceCard(key: ValueKey('home-spotify-${p.id}'), art: p.id == 'liked' ? const LikedArt() : _SpotifyArt(p), title: p.name, sub: _sub(p), onTap: () => openSpotifyPlaylist(context, p)),
            ],
          ),
        ),
      ],
    );
  }

  String _sub(SpotifyPlaylistInfo p) {
    final sy = Services.i.spotifySync;
    final have = sy.imported(p);
    final n = have != null && have.items.isNotEmpty ? have.items.length : sy.countOf(p);
    if (n >= 0) return songCount(n);
    return p.id == 'liked' ? 'Your likes' : 'Playlist';
  }
}

class _SpotifyArt extends StatelessWidget {
  final SpotifyPlaylistInfo p;
  const _SpotifyArt(this.p);
  @override
  Widget build(BuildContext context) {
    if (p.cover != null) return Artwork(p.cover, size: 148, radius: 0, icon: Icons.queue_music_rounded);
    final have = Services.i.spotifySync.imported(p);
    return Artwork(have?.artwork, size: 148, radius: 0, icon: Icons.queue_music_rounded);
  }
}

/// Opens one of the account's playlists from Home: in Byte already → opens;
/// not yet → brought in right here, then opens. Never starts playback itself.
Future<void> openSpotifyPlaylist(BuildContext context, SpotifyPlaylistInfo p) async {
  final sv = Services.i;
  final sy = sv.spotifySync;
  if (p.id == 'liked') {
    if (sy.likedImported && sv.library.likes.isNotEmpty) {
      pushPage(context, const LikedScreen());
      return;
    }
  } else {
    final have = sy.imported(p);
    if (have != null && have.items.isNotEmpty) {
      pushPage(context, PlaylistScreen(id: have.id));
      return;
    }
  }
  final items = await bringInWithProgress(context, p);
  if (items == null || !context.mounted) return;
  if (items.isEmpty) {
    toast(context, 'Byte couldn\'t find the songs of ${p.name} yet. It will try again by itself.');
    return;
  }
  if (p.id == 'liked') {
    pushPage(context, const LikedScreen());
  } else {
    final have = sy.imported(p);
    if (have != null) pushPage(context, PlaylistScreen(id: have.id));
  }
}

/// Reads + matches one playlist with a small progress card on screen.
/// Null when it failed (the reason is shown).
Future<List<Item>?> bringInWithProgress(BuildContext context, SpotifyPlaylistInfo p) async {
  final status = ValueNotifier<String>('Bringing in ${p.name}…');
  final nav = Navigator.of(context, rootNavigator: true);
  var open = true;
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (ctx) => _BringingIn(name: p.name, status: status),
    ).whenComplete(() => open = false),
  );
  try {
    return await Services.i.spotifySync.importOne(p, onStatus: (s) => status.value = s);
  } catch (e) {
    if (context.mounted) toast(context, e is SpotifyProblem ? e.message : 'Couldn\'t bring in ${p.name} right now. Try again in a minute.');
    return null;
  } finally {
    if (open) nav.pop();
    status.dispose();
  }
}

class _BringingIn extends StatelessWidget {
  final String name;
  final ValueNotifier<String> status;
  const _BringingIn({required this.name, required this.status});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Dialog(
      key: const ValueKey('bringing-in'),
      backgroundColor: p.grouped,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: BT.title3.copyWith(color: p.label, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(minHeight: 3, color: p.accent, backgroundColor: p.separator),
            const SizedBox(height: 12),
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, _) => Text(s, style: BT.sub.copyWith(color: p.secondary)),
            ),
            const SizedBox(height: 4),
            Text('It opens as soon as it\'s ready.', style: BT.caption.copyWith(color: p.secondary)),
          ],
        ),
      ),
    );
  }
}

/// Another logged-in music app (its playlists were brought in at log-in).
class _OtherServiceRow extends StatelessWidget {
  final LibService s;
  const _OtherServiceRow(this.s);
  @override
  Widget build(BuildContext context) {
    final sv = Services.i;
    final name = libSpec(s).name;
    final lists = sv.library.playlists.where((p) => (p.source ?? '').startsWith('${s.name}:')).toList()..sort((a, b) => b.updated.compareTo(a.updated));
    final liked = sv.libSync.likedCount(s);
    if (lists.isEmpty && liked == 0) return const SizedBox.shrink();
    return Column(
      key: ValueKey('home-service-${s.name}'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle('From $name', padding: const EdgeInsets.fromLTRB(16, 12, 16, 10)),
        SizedBox(
          height: 206,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              if (liked > 0 && sv.library.likes.isNotEmpty)
                ServiceCard(
                  key: ValueKey('home-service-${s.name}-liked'),
                  art: const LikedArt(),
                  title: libSpec(s).likedLabel,
                  sub: songCount(liked),
                  onTap: () => pushPage(context, const LikedScreen()),
                ),
              for (final p in lists)
                ServiceCard(
                  key: ValueKey('home-service-${p.id}'),
                  art: Artwork(p.artwork, size: 148, radius: 0, icon: Icons.queue_music_rounded),
                  title: p.name,
                  sub: songCount(p.items.length),
                  onTap: () => pushPage(context, PlaylistScreen(id: p.id)),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class ServiceCard extends StatelessWidget {
  final Widget art;
  final String title;
  final String sub;
  final VoidCallback onTap;
  const ServiceCard({super.key, required this.art, required this.title, required this.sub, required this.onTap});

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
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(width: 148, height: 148, child: art),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BT.body.copyWith(color: p.label, fontWeight: FontWeight.w600),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: BT.caption.copyWith(color: p.secondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class LikedArt extends StatelessWidget {
  const LikedArt({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0xFFFF2D55), Color(0xFF7B2CBF)], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 56),
    );
  }
}
