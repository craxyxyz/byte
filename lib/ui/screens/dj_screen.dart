import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../dj/dj_session.dart';
import '../../dj/for_you.dart';
import '../../services.dart';
import '../dj_card.dart';
import '../nav.dart';
import '../page.dart';
import '../style.dart';
import '../widgets.dart';
import 'dj_chat_screen.dart';
import 'settings_pages.dart' show DjSettingsScreen;

/// The personal DJ: what's on now, what the DJ said, "Switch it up",
/// and what's coming next.
class DjScreen extends StatelessWidget {
  const DjScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final dj = s.dj;
    return ListenableBuilder(
      listenable: Listenable.merge([dj, s.player.current, s.settings]),
      builder: (context, _) {
        final p = BytePalette.of(context);
        final seg = dj.segment;
        final cur = s.player.current.value;
        final rest = <Item>[];
        if (dj.active && seg != null) {
          final order = s.player.queueModel.playOrder;
          final pos = s.player.queueModel.position;
          final ids = seg.items.map((e) => e.id).toSet();
          rest.addAll(order.skip(pos + 1).where((i) => ids.contains(i.id)));
        }
        return SubPage(capWidth: true, 
          title: 'DJ',
          showProfile: false,
          actions: [
            BarIcon(Icons.tune_rounded, tooltip: 'DJ settings', onTap: () => pushPage(context, const DjSettingsScreen())),
          ],
          slivers: [
            SliverToBoxAdapter(child: _Hero(active: dj.active, starting: dj.starting, segment: seg, line: dj.lastLine, speaking: false)),
            const SliverToBoxAdapter(child: TalkToDjCard()),
            if (dj.error != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                  child: Text(dj.error!, textAlign: TextAlign.center, style: BT.sub.copyWith(color: p.secondary)),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: dj.active
                    ? Row(
                        children: [
                          Expanded(
                            child: PillButton(
                              icon: Icons.shuffle_on_rounded,
                              label: dj.switching ? 'Switching…' : 'Switch it up',
                              filled: true,
                              onTap: dj.switching ? null : dj.switchItUp,
                            ),
                          ),
                          const SizedBox(width: 10),
                          _RoundToggle(icon: Icons.stop_rounded, tooltip: 'Stop the DJ', on: false, onTap: dj.stop),
                        ],
                      )
                    : PillButton(
                        icon: Icons.play_arrow_rounded,
                        label: dj.starting ? 'Getting your mix ready…' : 'Start the DJ',
                        filled: true,
                        onTap: dj.starting ? null : dj.start,
                      ),
              ),
            ),
            if (dj.active && cur != null) ...[
              const SliverToBoxAdapter(child: SectionTitle('Now playing')),
              SliverToBoxAdapter(child: SongTile(item: cur, swipe: false)),
            ],
            if (rest.isNotEmpty) ...[
              SliverToBoxAdapter(child: SectionTitle('Up next in ${seg!.title}')),
              SliverList.builder(
                itemCount: rest.length,
                itemBuilder: (c, i) {
                  final tile = SongTile(
                    item: rest[i],
                    swipe: false,
                    onTap: () {
                      final idx = s.player.queueModel.playOrder.indexWhere((e) => e.id == rest[i].id);
                      if (idx >= 0) s.player.skipToQueueItem(idx);
                    },
                  );
                  final why = dj.reasons[rest[i].id];
                  if (why == null || why.isEmpty) return tile;
                  // a requested mix says why each song is there
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      tile,
                      Padding(
                        padding: const EdgeInsets.fromLTRB(84, 0, 16, 6),
                        child: Text(why, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.caption.copyWith(color: p.secondary)),
                      ),
                    ],
                  );
                },
              ),
            ],
            if (dj.active && dj.upcoming.isNotEmpty) ...[
              const SliverToBoxAdapter(child: SectionTitle('Coming up')),
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 92,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: dj.upcoming.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (c, i) => _SegmentChip(segment: dj.upcoming[i]),
                  ),
                ),
              ),
            ],
            const SliverToBoxAdapter(child: ForYouSection()),
            if (!dj.active)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
                  child: Text(
                    'Your own DJ mixes your favourites, old songs you miss, new picks and Bengali + Hindi hits, '
                    'changes with the time of day, and talks between sets. Songs blend into each other with Automix.',
                    textAlign: TextAlign.center,
                    style: BT.sub.copyWith(color: p.secondary, height: 1.35),
                  ),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: bottomBarSpace(context))),
          ],
        );
      },
    );
  }
}

class _Hero extends StatelessWidget {
  final bool active;
  final bool starting;
  final bool speaking;
  final DjSegment? segment;
  final String? line;
  const _Hero({required this.active, required this.starting, required this.segment, required this.line, required this.speaking});
  @override
  Widget build(BuildContext context) {
    final title = active ? (segment?.title ?? 'On air') : (starting ? 'Warming up…' : 'Your DJ');
    final sub = active ? (segment?.subtitle ?? '') : 'For ${Services.i.settings.djName}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 190),
        child: DjSurface(
          radius: 28,
          waves: false,
          child: Stack(
          children: [
            Positioned.fill(child: Opacity(opacity: 0.9, child: DjWaves(active: active, speaking: speaking))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: active ? Colors.white : Colors.white38,
                          boxShadow: active ? [BoxShadow(color: Colors.white.withValues(alpha: 0.7), blurRadius: 8)] : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        active ? 'ON AIR' : 'PERSONAL DJ',
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.85), fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 1.6),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: -0.8, height: 1.05),
                  ),
                  if (sub.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 15)),
                  ],
                  if (line != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      '“$line”',
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.95), fontSize: 15, fontStyle: FontStyle.italic, height: 1.3),
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

class _RoundToggle extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool on;
  final VoidCallback onTap;
  const _RoundToggle({required this.icon, required this.tooltip, required this.on, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(color: on ? p.accent.withValues(alpha: 0.13) : p.grouped, borderRadius: BorderRadius.circular(24)),
          child: Icon(icon, color: on ? p.accent : p.label, semanticLabel: tooltip),
        ),
      ),
    );
  }
}

class _SegmentChip extends StatelessWidget {
  final DjSegment segment;
  const _SegmentChip({required this.segment});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final first = segment.items.isEmpty ? null : segment.items.first;
    return Container(
      width: 210,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: p.grouped, borderRadius: BorderRadius.circular(18)),
      child: Row(
        children: [
          Artwork(first?.thumbAt(120), size: 58, radius: 8),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(segment.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.bodyStrong.copyWith(color: p.label, fontSize: 15)),
                const SizedBox(height: 2),
                Text('${segment.items.length} songs', maxLines: 1, style: BT.caption.copyWith(color: p.secondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}


/// "For you": new songs picked from what the person plays most, each with why.
class ForYouSection extends StatefulWidget {
  const ForYouSection({super.key});

  /// Kept while the app runs, so switching tabs doesn't fetch again.
  static List<ForYouPick>? cached;
  static DateTime? cachedAt;

  @override
  State<ForYouSection> createState() => _ForYouSectionState();
}

class _ForYouSectionState extends State<ForYouSection> {
  bool loading = false;
  bool failed = false;

  @override
  void initState() {
    super.initState();
    final age = ForYouSection.cachedAt == null ? null : DateTime.now().difference(ForYouSection.cachedAt!);
    if (ForYouSection.cached == null || age! > const Duration(hours: 3)) _load();
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      failed = false;
    });
    final s = Services.i;
    List<ForYouPick> picks = const [];
    try {
      picks = await ForYou(library: s.library, stats: s.stats, yt: s.yt).build().timeout(const Duration(seconds: 30));
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() {
      loading = false;
      if (!failed) {
        ForYouSection.cached = picks;
        ForYouSection.cachedAt = DateTime.now();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final picks = ForYouSection.cached ?? const <ForYouPick>[];
    final s = Services.i;
    final empty = !loading && picks.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle('For you', action: loading ? null : 'Refresh', onAction: loading ? null : _load),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'New songs picked from what you play most',
            style: BT.sub.copyWith(color: p.secondary),
          ),
        ),
        if (picks.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Row(
              children: [
                Expanded(
                  child: PillButton(
                    icon: Icons.play_arrow_rounded,
                    label: 'Play all',
                    filled: true,
                    onTap: () => s.player.playItems([for (final x in picks) x.item], from: 'For you'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PillButton(
                    icon: Icons.shuffle_rounded,
                    label: 'Shuffle',
                    onTap: () => s.player.playItems([for (final x in picks) x.item], shuffle: true, from: 'For you'),
                  ),
                ),
              ],
            ),
          ),
        if (loading && picks.isEmpty)
          for (var i = 0; i < 4; i++) const _PickSkeleton(),
        if (empty)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
            child: Text(
              failed
                  ? 'Couldn\'t get picks right now. Check the internet and tap Refresh.'
                  : 'Play a few songs and your picks show up here, with the reason for each one.',
              textAlign: TextAlign.center,
              style: BT.sub.copyWith(color: p.secondary, height: 1.35),
            ),
          ),
        for (final (i, x) in picks.indexed)
          _PickRow(pick: x, onTap: () => s.player.playItems([for (final y in picks) y.item], start: i, from: 'For you')),
      ],
    );
  }
}

class _PickRow extends StatelessWidget {
  final ForYouPick pick;
  final VoidCallback onTap;
  const _PickRow({required this.pick, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final it = pick.item;
    return InkWell(
      onTap: onTap,
      onLongPress: () => showItemMenu(context, it),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Row(
          children: [
            Artwork(it.thumbAt(120), size: 54, radius: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: p.label, fontWeight: FontWeight.w700)),
                  Text(it.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.sub.copyWith(color: p.secondary)),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.auto_awesome_rounded, size: 12, color: p.accent),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          pick.reason,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: BT.caption.copyWith(color: p.accent, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'More',
              icon: Icon(Icons.more_vert_rounded, color: p.secondary),
              onPressed: () => showItemMenu(context, it),
            ),
          ],
        ),
      ),
    );
  }
}

class _PickSkeleton extends StatelessWidget {
  const _PickSkeleton();
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final c = p.secondary.withValues(alpha: 0.15);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      child: Row(
        children: [
          Container(width: 54, height: 54, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(10))),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(height: 12, width: 160, color: c),
                const SizedBox(height: 8),
                Container(height: 10, width: 100, color: c),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Talk to your DJ": opens the DJ chat (ask for a mood, language, singer…).
class TalkToDjCard extends StatelessWidget {
  const TalkToDjCard({super.key});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final hinglish = Services.i.settings.djLanguage != 'english';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Material(
        color: p.grouped,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: const Key('talkToDj'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => const DjChatScreen())),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [ByteColors.pink, ByteColors.deep], begin: Alignment.topLeft, end: Alignment.bottomRight),
                  ),
                  child: const Icon(Icons.mic_rounded, color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Talk to your DJ', style: BT.bodyStrong.copyWith(color: p.label)),
                      const SizedBox(height: 2),
                      Text(
                        hinglish ? 'Bolo ya likho: "sad Hindi", "Arijit jaisa", "kuch naya"' : 'Say or type: "sad Hindi", "like Arijit", "something new"',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: BT.sub.copyWith(color: p.secondary),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right_rounded, color: p.tertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
