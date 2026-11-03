import '../art_background.dart' show BlurredCover;

import 'package:flutter/material.dart';
import '../style.dart' show bottomBarSpace, Skel;
import 'package:share_plus/share_plus.dart';

import '../../core/models.dart';
import '../../services.dart';
import '../nav.dart';
import '../shelves.dart';
import '../widgets.dart';

/// Album, playlist or artist page.
class BrowseScreen extends StatefulWidget {
  final Item item;
  final String? heroTag;
  const BrowseScreen({super.key, required this.item, this.heroTag});
  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  BrowsePage? page;
  Object? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => error = null);
    try {
      final yt = Services.i.yt;
      final it = widget.item;
      final p = it.kind == ItemKind.playlist ? await yt.playlist(it.id) : await yt.browse(it.id);
      if (mounted) setState(() => page = p);
    } catch (e) {
      if (mounted) setState(() => error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final p = page;
    final isArtist = it.kind == ItemKind.artist;
    final title = (p?.header.title.isNotEmpty ?? false) ? p!.header.title : it.title;
    final art = p?.header.thumb ?? it.thumb;
    final width = MediaQuery.sizeOf(context).width;
    final artSize = (width * 0.52).clamp(160.0, 280.0);
    final tracks = p?.tracks ?? const <Item>[];
    final topSongs = isArtist ? (p?.shelves.where((s) => s.isSongList).expand((s) => s.items).toList() ?? const <Item>[]) : tracks;
    final playable = (isArtist ? topSongs : tracks).where((i) => i.isPlayable).toList();
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            stretch: true,
            expandedHeight: isArtist ? 300 : artSize + 150,
            backgroundColor: cs.surface,
            title: const SizedBox.shrink(),
            actions: [
              IconButton(
                tooltip: 'Share',
                icon: const Icon(Icons.share_rounded),
                onPressed: () => SharePlus.instance.share(ShareParams(text: '$title\n${shareUrlFor(it)}')),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              stretchModes: const [StretchMode.zoomBackground, StretchMode.blurBackground],
              background: Stack(
                fit: StackFit.expand,
                children: [
                  if (art != null)
                    // 2.0: an album header is blurred once (a small pre-blurred
                    // picture), not live on every scroll frame
                    isArtist ? Artwork(art, size: width, radius: 0) : BlurredCover(url: art, opacity: 1),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          cs.surface.withValues(alpha: isArtist ? 0.05 : 0.35),
                          cs.surface.withValues(alpha: isArtist ? 0.35 : 0.75),
                          cs.surface,
                        ],
                        stops: const [0, 0.6, 1],
                      ),
                    ),
                  ),
                  if (!isArtist)
                    Align(
                      alignment: const Alignment(0, 0.15),
                      child: Hero(
                        tag: widget.heroTag ?? 'art-${it.kind.name}-${it.id}',
                        child: Material(
                          elevation: 18,
                          shadowColor: Colors.black54,
                          borderRadius: BorderRadius.circular(14),
                          clipBehavior: Clip.antiAlias,
                          child: Artwork(art, size: artSize, radius: 14, icon: Icons.album_rounded),
                        ),
                      ),
                    ),
                  Positioned(
                    left: 20,
                    right: 20,
                    bottom: 12,
                    child: Column(
                      crossAxisAlignment: isArtist ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                      children: [
                        Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: isArtist ? TextAlign.start : TextAlign.center,
                          style: (isArtist ? t.headlineLarge : t.headlineSmall),
                        ),
                        if (p != null)
                          Text(
                            [
                              if (!isArtist && p.header.artists.isNotEmpty) p.header.artists.map((a) => a.name).join(', '),
                              if ((p.header.subtitle ?? '').isNotEmpty) p.header.subtitle!,
                            ].join(' • '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        // playlist / album total length ("24 songs • 1 hr 32 min")
                        if (p != null && !isArtist && listSummary(tracks).isNotEmpty)
                          Text(
                            listSummary(tracks),
                            key: const ValueKey('list-total'),
                            maxLines: 1,
                            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        if (p == null && !isArtist) ...[
                          const SizedBox(height: 6),
                          const Skel(width: 160, height: 12, radius: 6),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (error != null)
            SliverFillRemaining(hasScrollBody: false, child: ErrorRetry('Couldn\'t load this page.\nCheck your internet connection.', onRetry: _load))
          else if (p == null)
            const SliverToBoxAdapter(child: LoadingList())
          else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: playable.isEmpty ? null : () => Services.i.player.playItems(playable, from: p.header.title),
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Play'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: playable.isEmpty ? null : () => Services.i.player.playItems(playable, shuffle: true, from: p.header.title),
                        icon: const Icon(Icons.shuffle_rounded),
                        label: const Text('Shuffle'),
                      ),
                    ),
                    if (!isArtist) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        tooltip: 'Save to library',
                        onPressed: () => saveCollection(context, it.copyWith(thumb: art, title: title)),
                        icon: const Icon(Icons.library_add_rounded),
                      ),
                      if (Services.i.downloads.supported)
                        IconButton(
                          tooltip: 'Download all',
                          onPressed: playable.isEmpty
                              ? null
                              : () {
                                  Services.i.downloads.enqueue(playable);
                                  toast(context, 'Downloading ${playable.length} songs');
                                },
                          icon: const Icon(Icons.download_rounded),
                        ),
                    ],
                  ],
                ),
              ),
            ),
            if ((p.header.description ?? '').isNotEmpty && !isArtist)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    p.header.description!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            if (!isArtist)
              SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (c, i) => SongTile(
                  item: tracks[i],
                  index: i,
                  showArt: it.kind != ItemKind.album,
                  onTap: () => Services.i.player.playItems(playable, start: playable.indexOf(tracks[i]).clamp(0, playable.length), from: p.header.title),
                ),
              ),
            if (isArtist && (p.header.description ?? '').isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                  child: Text(
                    p.header.description!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ),
            for (final s in p.shelves) ShelfSliver(shelf: s),
            SliverToBoxAdapter(child: SizedBox(height: bottomBarSpace(context))),
          ],
        ],
      ),
    );
  }
}
