import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../data/stats.dart';
import '../../services.dart';
import '../import_sheet.dart';
import '../nav.dart';
import '../page.dart';
import '../stats_card.dart';
import '../style.dart';
import '../widgets.dart';
import 'integrations_pages.dart';
import 'library_screen.dart' show importedFrom;
import 'playlist_screen.dart';
import '../glass.dart';

Widget _iconTile(BuildContext context, IconData icon, {List<Color>? colors, Color? iconColor}) {
  final p = BytePalette.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  return DecoratedBox(
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: colors ?? (dark ? const [Color(0xFF2C2C30), Color(0xFF1C1C1E)] : const [Color(0xFFE4E4E9), Color(0xFFF5F5F7)]),
      ),
      border: Border.all(color: p.separator, width: 0.6),
    ),
    child: Center(child: Icon(icon, size: 120, color: iconColor ?? p.secondary.withValues(alpha: 0.75))),
  );
}

List<Widget> _songSlivers(List<Item> items, {bool durations = true, Widget Function(Item, int)? trailing}) => [
  SliverList.builder(
    itemCount: items.length,
    itemBuilder: (c, i) => SongTile(
      item: items[i],
      showDuration: false,
      trailing: trailing?.call(items[i], i) ?? (durations && items[i].durationSec != null ? _Dur(items[i].durationSec!) : null),
      onTap: () => Services.i.player.playItems(items, start: i),
    ),
  ),
];

class _Dur extends StatelessWidget {
  final int sec;
  const _Dur(this.sec);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 14, left: 6),
    child: Text(fmtDuration(sec), style: BT.sub.copyWith(color: BytePalette.of(context).secondary)),
  );
}

// ── History ─────────────────────────────────────────────────────────────
class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final lib = Services.i.library;
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final h = lib.history;
        final items = h.map((e) => e.item).toList();
        return SubPage(
          title: 'History',
          actions: [
            if (h.isNotEmpty)
              BarIcon(
                Icons.delete_sweep_outlined,
                tooltip: 'Clear history',
                onTap: () async {
                  final ok = await confirm(context, 'Clear listening history?', 'Your stats in Library are kept.', action: 'Clear');
                  if (ok) await lib.clearHistory();
                },
              ),
          ],
          slivers: [
            if (!Services.i.settings.saveHistory)
              const SliverToBoxAdapter(child: EmptyNote('History is paused (Settings → Your data).')),
            if (h.isEmpty)
              const SliverToBoxAdapter(child: EmptyNote('Songs you play show up here.', icon: Icons.history_rounded))
            else
              ..._songSlivers(items),
          ],
        );
      },
    );
  }
}

Future<bool> confirm(BuildContext context, String title, String body, {String action = 'OK', bool destructive = true}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => GlassDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action, style: TextStyle(color: destructive ? const Color(0xFFFF3B30) : null, fontWeight: FontWeight.w600)),
        ),
      ],
    ),
  );
  return r == true;
}

// ── Downloads ───────────────────────────────────────────────────────────
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});
  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  int sort = 0; // 0 newest, 1 title, 2 artist
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([s.library, s.downloads]),
      builder: (context, _) {
        final recs = s.library.downloads.toList();
        if (sort == 1) recs.sort((a, b) => a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase()));
        if (sort == 2) recs.sort((a, b) => a.item.artistLine.toLowerCase().compareTo(b.item.artistLine.toLowerCase()));
        final items = recs.map((r) => r.item).toList();
        final mb = (s.downloads.totalBytes / 1048576).toStringAsFixed(1);
        return SubPage(
          title: 'Downloads',
          largeTitle: false,
          actions: [
            PopupMenuButton<int>(
              tooltip: 'Sort',
              icon: Icon(Icons.sort_rounded, color: p.label),
              initialValue: sort,
              onSelected: (v) => setState(() => sort = v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 0, child: Text('Recently downloaded')),
                PopupMenuItem(value: 1, child: Text('Title')),
                PopupMenuItem(value: 2, child: Text('Artist')),
              ],
            ),
          ],
          slivers: [
            SliverToBoxAdapter(
              child: TileHeader(
                tile: _iconTile(context, Icons.download_rounded),
                title: 'Downloads',
                subtitle: recs.isEmpty ? 'Downloaded songs' : '${songCount(recs.length)} · $mb MB',
                buttons: recs.isEmpty
                    ? const []
                    : [
                        PillButton(icon: Icons.play_arrow_rounded, label: 'Play', filled: true, onTap: () => s.player.playItems(items)),
                        PillButton(icon: Icons.shuffle_rounded, label: 'Shuffle', onTap: () => s.player.playItems(items, shuffle: true)),
                      ],
              ),
            ),
            if (!s.downloads.supported)
              const SliverToBoxAdapter(child: EmptyNote('Downloads work in the phone app.'))
            else if (recs.isEmpty)
              const SliverToBoxAdapter(child: EmptyNote('No downloaded tracks'))
            else
              ..._songSlivers(items),
          ],
        );
      },
    );
  }
}

// ── Local music ─────────────────────────────────────────────────────────
class LocalMusicScreen extends StatefulWidget {
  const LocalMusicScreen({super.key});
  @override
  State<LocalMusicScreen> createState() => _LocalMusicScreenState();
}

class _LocalMusicScreenState extends State<LocalMusicScreen> {
  bool busy = false;
  Future<void> _run(Future<int> Function() f) async {
    setState(() => busy = true);
    try {
      final n = await f();
      if (mounted) toast(context, n == 0 ? 'No new songs found' : 'Found $n songs');
    } catch (_) {
      if (mounted) toast(context, 'Couldn\'t read your music. Allow access in Android settings.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        var items = s.library.localTracks;
        if (s.settings.filterShortAudio) items = items.where((i) => (i.durationSec ?? 31) >= 30 && !i.id.toLowerCase().endsWith('.wav')).toList();
        return SubPage(
          title: 'Local Music',
          largeTitle: false,
          actions: [
            if (!kIsWeb) BarIcon(Icons.refresh_rounded, tooltip: 'Scan again', onTap: busy ? null : () => _run(() => s.local.scanDevice())),
            if (!kIsWeb) BarIcon(Icons.add_rounded, tooltip: 'Add files', onTap: busy ? null : () => _run(() => s.local.pickFiles())),
          ],
          slivers: [
            SliverToBoxAdapter(
              child: TileHeader(
                tile: _iconTile(context, Icons.folder_rounded),
                title: 'Local Music',
                subtitle: items.isEmpty ? 'Songs on this phone' : '${songCount(items.length)} on this phone',
                buttons: items.isEmpty
                    ? [PillButton(icon: Icons.search_rounded, label: busy ? 'Scanning…' : 'Find songs on this phone', onTap: busy ? null : () => _run(() => s.local.scanDevice()))]
                    : [
                        PillButton(icon: Icons.play_arrow_rounded, label: 'Play', filled: true, onTap: () => s.player.playItems(items)),
                        PillButton(icon: Icons.shuffle_rounded, label: 'Shuffle', onTap: () => s.player.playItems(items, shuffle: true)),
                      ],
              ),
            ),
            if (busy) const SliverToBoxAdapter(child: LinearProgressIndicator(minHeight: 2)),
            if (items.isEmpty)
              const SliverToBoxAdapter(child: EmptyNote('No songs yet. Tap "Find songs on this phone", or + to pick files.'))
            else
              ..._songSlivers(items),
          ],
        );
      },
    );
  }
}

// ── Imported playlists (from any music app, a list or a file) ────────────
class SpotifyScreen extends StatelessWidget {
  const SpotifyScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final lib = Services.i.library;
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final lists = lib.playlists.where((l) => importedFrom(l.source) != null).toList();
        return SubPage(
          title: 'Imported',
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Playlists brought in from other music apps, song lists and CSV files.',
                  style: BT.sub.copyWith(color: p.secondary),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: _ListRow(
                art: Container(color: p.grouped, child: Icon(Icons.add_link_rounded, color: p.label, size: 30)),
                title: 'Import a playlist',
                sub: 'Link, song list or file',
                onTap: () => showImportSheet(context),
              ),
            ),
            SliverToBoxAdapter(
              child: _ListRow(
                art: Container(color: p.grouped, child: Icon(Icons.login_rounded, color: p.label, size: 28)),
                title: Services.i.spotify.connected ? 'My Spotify playlists' : 'Log in with Spotify',
                sub: Services.i.spotify.connected ? Services.i.spotify.userName : 'Private playlists and Liked Songs',
                onTap: () => pushPage(context, const SpotifyAccountScreen()),
              ),
            ),
            if (lists.isEmpty)
              const SliverToBoxAdapter(child: EmptyNote('Nothing imported yet.'))
            else
              SliverList.builder(
                itemCount: lists.length,
                itemBuilder: (c, i) => _ListRow(
                  art: Artwork(lists[i].artwork, size: 58, radius: 0, icon: Icons.queue_music_rounded),
                  title: lists[i].name,
                  sub: '${importedFrom(lists[i].source)} · ${songCount(lists[i].items.length)}',
                  onTap: () => pushPage(context, PlaylistScreen(id: lists[i].id)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ListRow extends StatelessWidget {
  final Widget art;
  final String title;
  final String sub;
  final VoidCallback onTap;
  const _ListRow({required this.art, required this.title, required this.sub, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return InkWell(mouseCursor: SystemMouseCursors.click, 
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(6), child: SizedBox(width: 58, height: 58, child: art)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: p.label)),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.sub.copyWith(color: p.secondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── All playlists (reorder) ─────────────────────────────────────────────
class AllPlaylistsScreen extends StatelessWidget {
  const AllPlaylistsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final lib = Services.i.library;
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final lists = lib.playlists;
        return SubPage(
          title: 'Playlists',
          slivers: [
            SliverReorderableList(
              itemCount: lists.length,
              onReorderItem: (a, b) => lib.reorderPlaylists(a, b),
              itemBuilder: (c, i) => ReorderableDelayedDragStartListener(
                key: ValueKey(lists[i].id),
                index: i,
                child: Material(
                  color: Colors.transparent,
                  child: _ListRow(
                    art: Artwork(lists[i].artwork, size: 58, radius: 0, icon: Icons.queue_music_rounded),
                    title: lists[i].name,
                    sub: songCount(lists[i].items.length),
                    onTap: () => pushPage(context, PlaylistScreen(id: lists[i].id)),
                  ),
                ),
              ),
            ),
            if (lists.isEmpty) const SliverToBoxAdapter(child: EmptyNote('No playlists yet.')),
          ],
        );
      },
    );
  }
}

// ── Liked songs ─────────────────────────────────────────────────────────
class LikedScreen extends StatelessWidget {
  const LikedScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final items = s.library.likes;
        return SubPage(
          title: 'Liked Songs',
          largeTitle: false,
          slivers: [
            SliverToBoxAdapter(
              child: TileHeader(
                tile: _iconTile(context, Icons.favorite_rounded, colors: const [Color(0xFF6A3DF0), Color(0xFF3F8CFF)], iconColor: Colors.white),
                title: 'Liked Songs',
                subtitle: listSummary(items).isEmpty ? songCount(items.length) : listSummary(items),
                buttons: items.isEmpty
                    ? const []
                    : [
                        PillButton(icon: Icons.play_arrow_rounded, label: 'Play', filled: true, onTap: () => s.player.playItems(items)),
                        PillButton(icon: Icons.shuffle_rounded, label: 'Shuffle', onTap: () => s.player.playItems(items, shuffle: true)),
                      ],
              ),
            ),
            if (items.isEmpty) const SliverToBoxAdapter(child: EmptyNote('Tap ♡ on any song to keep it here.')) else ..._songSlivers(items),
          ],
        );
      },
    );
  }
}

// ── Episodes for later ──────────────────────────────────────────────────
class LaterScreen extends StatelessWidget {
  const LaterScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: s.library,
      builder: (context, _) {
        final eps = s.library.laterEpisodes;
        return SubPage(
          title: 'Episodes for Later',
          largeTitle: false,
          slivers: [
            SliverToBoxAdapter(
              child: TileHeader(
                tile: _iconTile(context, Icons.podcasts_rounded, colors: const [Color(0xFFE5245C), Color(0xFF8E44D9)], iconColor: Colors.white),
                title: 'Episodes for Later',
                subtitle: eps.isEmpty ? 'Your queued episodes' : '${eps.length} episodes',
                buttons: eps.isEmpty ? const [] : [PillButton(icon: Icons.play_arrow_rounded, label: 'Play all', filled: true, onTap: () => s.player.playItems(eps))],
              ),
            ),
            if (eps.isEmpty)
              const SliverToBoxAdapter(child: EmptyNote('Save podcast episodes here with ⋮ → "Save for later".'))
            else
              ..._songSlivers(
                eps,
                durations: false,
                trailing: (it, i) => IconButton(
                  tooltip: 'Remove',
                  icon: Icon(Icons.bookmark_remove_outlined, color: p.secondary),
                  onPressed: () => s.library.setLater(it, false),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ── Replay (your year in music) ─────────────────────────────────────────
class ReplayScreen extends StatefulWidget {
  const ReplayScreen({super.key});
  @override
  State<ReplayScreen> createState() => _ReplayScreenState();
}

class _ReplayScreenState extends State<ReplayScreen> {
  int? year;
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ListenableBuilder(
      listenable: s.stats,
      builder: (context, _) {
        final years = s.stats.years;
        final y = year ?? (years.isEmpty ? DateTime.now().year : years.first);
        final st = s.stats.year(y);
        final p = BytePalette.of(context);
        final top = st.songs.take(25).toList();
        return SubPage(
          title: 'Replay $y',
          background: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark ? const [Color(0xFF2A1B45), Color(0xFF120D1C), Colors.black] : const [Color(0xFFC3A9EC), Color(0xFFE9DDF8), Color(0xFFF7F2FC)],
              ),
            ),
          ),
          actions: [
            if (top.isNotEmpty) BarIcon(Icons.play_arrow_rounded, tooltip: 'Play your Replay', onTap: () => s.player.playItems(top.map((e) => e.item).toList())),
            if (years.length > 1)
              PopupMenuButton<int>(
                tooltip: 'Year',
                icon: Icon(Icons.calendar_month_rounded, color: p.label),
                onSelected: (v) => setState(() => year = v),
                itemBuilder: (_) => [for (final yy in years) PopupMenuItem(value: yy, child: Text('$yy'))],
              ),
          ],
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text('${st.minutes} minutes · ${st.plays} plays', style: BT.body.copyWith(color: p.secondary)),
              ),
            ),
            if (st.isEmpty)
              const SliverToBoxAdapter(child: EmptyNote('Play some music — your top songs, artists and albums appear here.', icon: Icons.insights_rounded))
            else ...[
              const SliverToBoxAdapter(child: SectionTitle('Top songs')),
              SliverList.builder(
                itemCount: top.length,
                itemBuilder: (c, i) => _RankRow(
                  rank: i + 1,
                  art: Artwork(top[i].item.thumb, size: 52, radius: 6),
                  title: top[i].item.title,
                  sub: top[i].item.artistLine,
                  value: '${top[i].plays}',
                  onTap: () => s.player.playItems(top.map((e) => e.item).toList(), start: i),
                ),
              ),
              const SliverToBoxAdapter(child: SectionTitle('Top artists')),
              _groupList(context, st.artists, circle: true),
              const SliverToBoxAdapter(child: SectionTitle('Top albums')),
              _groupList(context, st.albums),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                  child: Text(statsFootnote(st), style: BT.caption.copyWith(color: p.secondary)),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _groupList(BuildContext context, List<GroupStat> g, {bool circle = false}) => SliverList.builder(
    itemCount: g.length.clamp(0, 10),
    itemBuilder: (c, i) => _RankRow(
      rank: i + 1,
      art: Artwork(g[i].thumb, size: 52, radius: 6, circle: circle),
      title: g[i].name,
      sub: g[i].detail == null || g[i].detail!.isEmpty ? '${g[i].minutes} min' : '${g[i].detail} · ${g[i].minutes} min',
      value: '${g[i].plays}',
      onTap: g[i].id == null
          ? null
          : () => openItem(context, Item(kind: circle ? ItemKind.artist : ItemKind.album, id: g[i].id!, title: g[i].name, thumb: g[i].thumb)),
    ),
  );
}

class _RankRow extends StatelessWidget {
  final int rank;
  final Widget art;
  final String title;
  final String sub;
  final String value;
  final VoidCallback? onTap;
  const _RankRow({required this.rank, required this.art, required this.title, required this.sub, required this.value, this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return InkWell(mouseCursor: SystemMouseCursors.click, 
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 16, 6),
        child: Row(
          children: [
            SizedBox(
              width: 30,
              child: Text('$rank', textAlign: TextAlign.center, style: BT.bodyStrong.copyWith(color: rank == 1 ? p.accent : p.secondary)),
            ),
            const SizedBox(width: 8),
            art,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: p.label)),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.sub.copyWith(color: p.secondary)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(value, style: BT.sub.copyWith(color: p.secondary)),
          ],
        ),
      ),
    );
  }
}

/// Path helper kept for the local-music filter (file name of an item).
String fileNameOf(Item it) => it.isDav ? Uri.decodeComponent(it.id.split('/').last) : (it.isLocal ? it.id.substring(6).split(Platform.pathSeparator).last : it.title);
