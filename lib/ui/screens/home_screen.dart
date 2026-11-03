import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../services.dart';
import '../art_colors.dart';
import '../logo.dart';
import '../mood_card.dart';
import '../nav.dart';
import '../page.dart';
import '../shelves.dart';
import '../shell.dart';
import '../style.dart';
import '../widgets.dart';
import 'explore_screen.dart';
import '../dj_card.dart';
import '../home_library_rows.dart';
import '../imported_row.dart';
import '../service_rows.dart';
import '../../core/platform_caps.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with AutomaticKeepAliveClientMixin {
  final List<Shelf> shelves = [];
  List<MoodCategory> moods = const [];
  String? cont;
  bool loading = true;
  bool failed = false;
  final scroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    scroll.addListener(() {
      if (scroll.position.pixels > scroll.position.maxScrollExtent - 600) _more();
    });
    Services.i.feedVersion.addListener(_load);
  }

  @override
  void dispose() {
    Services.i.feedVersion.removeListener(_load);
    scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    try {
      final yt = Services.i.yt;
      final r = await Future.wait([yt.home(), yt.moods().catchError((_) => <MoodCategory>[])]);
      final f = r[0] as HomeFeed;
      if (!mounted) return;
      setState(() {
        shelves
          ..clear()
          ..addAll(f.shelves);
        moods = r[1] as List<MoodCategory>;
        cont = f.continuation;
      });
      await _more();
    } catch (_) {
      if (mounted) setState(() => failed = shelves.isEmpty);
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  bool _loadingMore = false;
  Future<void> _more() async {
    if (cont == null || _loadingMore) return;
    _loadingMore = true;
    try {
      final f = await Services.i.yt.home(continuation: cont);
      if (!mounted) return;
      final have = shelves.map((s) => s.title).toSet();
      setState(() {
        shelves.addAll(f.shelves.where((s) => !have.contains(s.title)));
        cont = f.continuation;
      });
    } catch (_) {
      cont = null;
    } finally {
      _loadingMore = false;
    }
  }

  /// "Top Picks for You": albums, singles and mixes from the feed, with the
  /// shelf they came from as the small caption.
  List<(String, Item)> get _picks {
    final out = <(String, Item)>[];
    final seen = <String>{};
    for (final s in shelves) {
      for (final it in s.items) {
        if (it.kind != ItemKind.album && it.kind != ItemKind.playlist) continue;
        if (!seen.add(it.id)) continue;
        out.add((s.title, it));
        if (out.length >= 10) return out;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: Services.i.library,
      builder: (context, _) {
        final history = Services.i.library.history.map((e) => e.item).where((i) => i.kind != ItemKind.episode).take(24).toList();
        final quick = shelves.where((s) => s.isSongList).firstOrNull;
        final recents = history.length >= 4 ? history : (quick?.items ?? history);
        final picks = _picks;
        final rest = shelves.where((s) => s != quick).toList();
        return TabPage(
          controller: scroll,
          onRefresh: _load,
          titleWidget: const Padding(padding: EdgeInsets.only(top: 4, bottom: 4), child: ByteWordmark(height: 34)),
          // the DJ is a small feature inside the app, not a tab
          actions: const [DjPill()],
          slivers: [
            // 1.4.5: Liked songs + the playlists made in Byte, first, for every
            // account (Byte email, music-app log-in, or signed out)
            const SliverToBoxAdapter(child: HomeLibraryRows()),
            // 1.4.2: imported playlists (works offline too)
            // 1.4.4: each logged-in music account's playlists ("From Spotify")
            const SliverToBoxAdapter(child: MusicServiceRows()),
            const SliverToBoxAdapter(child: ImportedRow()),
            if (failed)
              SliverToBoxAdapter(
                child: ErrorRetry(
                  onWeb
                      ? 'Can\'t reach online music right now.\nYour library, playlists and settings still work.'
                      : 'Can\'t reach online music right now.\nYour downloads and device music still work in Library.',
                  onRetry: _load,
                ),
              )
            else if (loading && shelves.isEmpty)
              const SliverToBoxAdapter(child: HomeSkeleton())
            else ...[
              if (picks.isNotEmpty) ...[
                const SliverToBoxAdapter(child: SectionTitle('Top Picks for You', padding: EdgeInsets.fromLTRB(16, 12, 16, 12))),
                SliverToBoxAdapter(child: _TopPicks(picks: picks)),
              ],
              if (recents.isNotEmpty) ...[
                SliverToBoxAdapter(child: SectionTitle(history.length >= 4 ? 'Recents' : (quick?.title ?? 'Quick picks'))),
                SliverToBoxAdapter(child: PagedSongGrid(items: recents)),
              ],
              if (moods.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: SectionTitle('Find Your Mood', action: 'Show all', onAction: () => ShellState.current?.select(1)),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 96,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: moods.length.clamp(0, 16),
                      separatorBuilder: (_, _) => const SizedBox(width: 12),
                      itemBuilder: (c, i) => SizedBox(
                        width: 164,
                        child: MoodCard(mood: moods[i], onTap: () => pushPage(context, MoodScreen(mood: moods[i]))),
                      ),
                    ),
                  ),
                ),
              ],
              for (final s in rest) ShelfSliver(shelf: s),
            ],
            SliverToBoxAdapter(
              child: SizedBox(
                height: 60,
                child: cont != null && !failed
                    ? const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TopPicks extends StatelessWidget {
  final List<(String, Item)> picks;
  const _TopPicks({required this.picks});
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final cardW = (w >= 820 ? 300.0 : (w * 0.62).clamp(220.0, 300.0));
    final cardH = cardW * 1.33;
    return SizedBox(
      height: cardH,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: picks.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (c, i) => SizedBox(width: cardW, child: PickCard(caption: picks[i].$1, item: picks[i].$2)),
      ),
    );
  }
}

/// Tall art card with the title over a gradient taken from the art.
class PickCard extends StatefulWidget {
  final String caption;
  final Item item;
  const PickCard({super.key, required this.caption, required this.item});
  @override
  State<PickCard> createState() => _PickCardState();
}

class _PickCardState extends State<PickCard> {
  Color tone = const Color(0xFF2A2A2E);
  @override
  void initState() {
    super.initState();
    paletteFor(widget.item.thumbAt(226)).then((p) {
      if (!mounted) return;
      final h = HSLColor.fromColor(p.primary);
      setState(() => tone = h.withLightness(h.lightness.clamp(0.16, 0.32)).withSaturation(h.saturation.clamp(0.2, 0.75)).toColor());
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final it = widget.item;
    final tag = 'pick-${it.id}';
    return Pressable(
      onTap: () => openItem(context, it, heroTag: tag),
      onLongPress: () => showItemMenu(context, it),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        decoration: BoxDecoration(color: tone, borderRadius: BorderRadius.circular(14)),
        clipBehavior: Clip.antiAlias,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Hero(tag: tag, child: Artwork(it.thumbAt(544), size: c.maxWidth, radius: 0)),
              ),
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.5, 0.78],
                      colors: [tone.withValues(alpha: 0), tone.withValues(alpha: 0.35), tone],
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 14,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 13)),
                    const SizedBox(height: 3),
                    Text(
                      it.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600, height: 1.2, letterSpacing: -0.2),
                    ),
                    if ((it.subtitle ?? it.artistLine).isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        it.subtitle ?? it.artistLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.75), fontSize: 14),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Grey placeholders shown while Home loads.
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});
  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final cardW = (w * 0.62).clamp(220.0, 300.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 12), child: Skel(width: 170, height: 18)),
        SizedBox(
          height: cardW * 1.33,
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              Skel(width: cardW, height: cardW * 1.33, radius: 14),
              const SizedBox(width: 14),
              Skel(width: cardW, height: cardW * 1.33, radius: 14),
            ],
          ),
        ),
        const Padding(padding: EdgeInsets.fromLTRB(16, 26, 16, 12), child: Skel(width: 90, height: 18)),
        for (var i = 0; i < 4; i++)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 5, 16, 5),
            child: Row(
              children: [
                Skel(width: 52, height: 52, radius: 6),
                SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Skel(width: 180, height: 13), SizedBox(height: 8), Skel(width: 110, height: 11)],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
