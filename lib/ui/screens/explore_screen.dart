import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../services.dart';
import '../mood_card.dart';
import '../nav.dart';
import '../page.dart';
import '../shelves.dart';
import '../style.dart';
import '../widgets.dart';

/// Explore: every mood and genre as a colour card (plus new releases & charts).
class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key});
  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> with AutomaticKeepAliveClientMixin {
  List<MoodCategory>? moods;
  bool failed = false;
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => failed = false);
    try {
      final m = await Services.i.yt.moods();
      if (mounted) setState(() => moods = m);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final w = MediaQuery.sizeOf(context).width;
    final cols = w >= 1100 ? 4 : (w >= 600 ? 3 : 2);
    final m = moods;
    const extras = [
      MoodCategory('New releases', 0xFFE5245C, '_new'),
      MoodCategory('Charts', 0xFF2F6BFF, '_charts'),
      MoodCategory('Podcasts', 0xFF8E44D9, '_podcasts'),
    ];
    // Moods & genres first (as YouTube Music orders them), then charts, new releases, podcasts.
    final all = m == null ? null : [...m, ...extras];
    return TabPage(
      title: 'Explore',
      onRefresh: _load,
      slivers: [
        if (failed)
          SliverToBoxAdapter(child: ErrorRetry('Can\'t reach online music right now.', onRetry: _load))
        else
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, mainAxisSpacing: 14, crossAxisSpacing: 14, childAspectRatio: 1.72),
              delegate: SliverChildBuilderDelegate(
                (c, i) => all == null
                    ? const MoodSkeleton()
                    : MoodCard(
                        key: ValueKey(all[i].params),
                        mood: all[i],
                        onTap: () => pushPage(context, all[i].params == '_podcasts' ? const PodcastsScreen() : MoodScreen(mood: all[i])),
                      ),
                childCount: all?.length ?? 12,
              ),
            ),
          ),
      ],
    );
  }
}

/// One mood / genre (or New releases / Charts): its shelves.
class MoodScreen extends StatefulWidget {
  final MoodCategory mood;
  const MoodScreen({super.key, required this.mood});
  @override
  State<MoodScreen> createState() => _MoodScreenState();
}

class _MoodScreenState extends State<MoodScreen> {
  List<Shelf>? shelves;
  bool failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => failed = false);
    try {
      final yt = Services.i.yt;
      final s = switch (widget.mood.params) {
        '_new' => await yt.newReleases(),
        '_charts' => await yt.charts(),
        _ => await yt.moodPage(widget.mood.params),
      };
      if (mounted) setState(() => shelves = s);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = shelves;
    return SubPage(
      title: widget.mood.title,
      onRefresh: _load,
      slivers: [
        if (failed)
          SliverToBoxAdapter(child: ErrorRetry('Couldn\'t load this page.', onRetry: _load))
        else if (s == null)
          const SliverToBoxAdapter(child: LoadingList(rows: 6))
        else if (s.isEmpty)
          const SliverToBoxAdapter(child: EmptyNote('Nothing here right now.'))
        else
          for (final sh in s) ShelfSliver(shelf: sh),
      ],
    );
  }
}

/// Podcasts home: popular shows, episodes and categories.
class PodcastsScreen extends StatefulWidget {
  const PodcastsScreen({super.key});
  @override
  State<PodcastsScreen> createState() => _PodcastsScreenState();
}

class _PodcastsScreenState extends State<PodcastsScreen> {
  List<Shelf>? shelves;
  bool failed = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => failed = false);
    try {
      final s = await Services.i.yt.podcasts();
      if (mounted) setState(() => shelves = s);
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = shelves;
    final p = BytePalette.of(context);
    return SubPage(
      title: 'Podcasts',
      onRefresh: _load,
      slivers: [
        if (failed)
          SliverToBoxAdapter(child: ErrorRetry('Couldn\'t load podcasts.', onRetry: _load))
        else if (s == null)
          const SliverToBoxAdapter(child: LoadingList(rows: 6))
        else
          for (final sh in s) ShelfSliver(shelf: sh),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
            child: Text('Tap ⋮ on an episode → "Save for later" to keep it in Library.', style: BT.sub.copyWith(color: p.secondary)),
          ),
        ),
      ],
    );
  }
}
