import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services.dart';
import 'nav.dart';
import 'page.dart';
import 'style.dart';
import 'widgets.dart';

/// One carousel / song shelf as a sliver.
class ShelfSliver extends StatelessWidget {
  final Shelf shelf;
  const ShelfSliver({super.key, required this.shelf});
  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(child: ShelfView(shelf: shelf));
  }
}

class ShelfView extends StatelessWidget {
  final Shelf shelf;
  const ShelfView({super.key, required this.shelf});

  @override
  Widget build(BuildContext context) {
    final more = shelf.moreBrowseId == null
        ? null
        : () => pushPage(context, (_MoreScreen(title: shelf.title, browseId: shelf.moreBrowseId!, params: shelf.moreParams)));
    if (shelf.isSongList) return _SongGrid(shelf: shelf, onMore: more);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(shelf.title, action: more == null ? null : 'Show all', onAction: more),
        SizedBox(
          height: shelf.items.any((i) => i.kind == ItemKind.video) && shelf.items.every((i) => i.kind == ItemKind.video) ? 196 : 214,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            scrollDirection: Axis.horizontal,
            itemCount: shelf.items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 4),
            itemBuilder: (c, i) => ItemCard(item: shelf.items[i], scope: '${shelf.title}#$i'),
          ),
        ),
      ],
    );
  }
}

/// "Quick picks" style: songs in columns of four, paged horizontally.
class _SongGrid extends StatelessWidget {
  final Shelf shelf;
  final VoidCallback? onMore;
  const _SongGrid({required this.shelf, this.onMore});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionTitle(shelf.title, action: onMore == null ? null : 'Show all', onAction: onMore),
        PagedSongGrid(items: shelf.items),
      ],
    );
  }
}

/// Songs four to a column; the next column peeks in from the right.
class PagedSongGrid extends StatelessWidget {
  final List<Item> items;
  const PagedSongGrid({super.key, required this.items});
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final colW = w >= 820 ? 380.0 : w - 40;
    final cols = (items.length / 4).ceil();
    const rowH = 62.0;
    return SizedBox(
      height: (items.length < 4 ? items.length : 4) * rowH,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(left: 4),
        physics: const PageScrollPhysics(),
        itemCount: cols,
        itemBuilder: (c, col) => SizedBox(
          width: colW,
          child: Column(
            children: [
              for (var r = 0; r < 4 && col * 4 + r < items.length; r++)
                SizedBox(
                  height: rowH,
                  child: SongTile(item: items[col * 4 + r], dense: true, swipe: false, onTap: () => Services.i.player.playSong(items[col * 4 + r])),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MoreScreen extends StatefulWidget {
  final String title;
  final String browseId;
  final String? params;
  const _MoreScreen({required this.title, required this.browseId, this.params});
  @override
  State<_MoreScreen> createState() => _MoreScreenState();
}

class _MoreScreenState extends State<_MoreScreen> {
  List<Item>? items;
  bool failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => failed = false);
    try {
      if (widget.browseId.startsWith('VL')) {
        final p = await Services.i.yt.playlist(widget.browseId);
        if (mounted) setState(() => items = p.tracks);
        return;
      }
      final p = await Services.i.yt.browse(widget.browseId, params: widget.params);
      final all = [...p.tracks, ...p.shelves.expand((s) => s.items)];
      if (mounted) setState(() => items = all);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final its = items;
    return SubPage(
      title: widget.title,
      slivers: [
        if (failed)
          SliverToBoxAdapter(child: ErrorRetry('Couldn\'t load.', onRetry: _load))
        else if (its == null)
          const SliverToBoxAdapter(child: LoadingList())
        else if (its.every((i) => i.isPlayable))
          SliverList.builder(
            itemCount: its.length,
            itemBuilder: (c, i) => SongTile(item: its[i], onTap: () => Services.i.player.playItems(its, start: i)),
          )
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 190, mainAxisExtent: 240),
              itemCount: its.length,
              itemBuilder: (c, i) => LayoutBuilder(builder: (c, cons) => ItemCard(item: its[i], width: cons.maxWidth, scope: 'grid#$i')),
            ),
          ),
      ],
    );
  }
}
