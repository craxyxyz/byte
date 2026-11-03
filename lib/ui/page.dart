import 'package:flutter/material.dart';

import 'account_ui.dart';
import 'style.dart';

/// A main tab page (Home, Explore, Library): frosted round buttons + avatar
/// pinned at the top right, a large title that scrolls with the content.
class TabPage extends StatefulWidget {
  final String? title;
  final Widget? titleWidget;
  final List<Widget> actions;
  final List<Widget> slivers;
  final Future<void> Function()? onRefresh;
  final ScrollController? controller;
  const TabPage({super.key, this.title, this.titleWidget, this.actions = const [], required this.slivers, this.onRefresh, this.controller});
  @override
  State<TabPage> createState() => _TabPageState();
}

class _TabPageState extends State<TabPage> {
  /// The top bar turns into liquid glass once the page scrolls under it.
  bool scrolled = false;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final s = n.metrics.pixels > 24;
    if (s != scrolled) setState(() => scrolled = s);
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    Widget list = CustomScrollView(
      controller: widget.controller,
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      slivers: [
        SliverToBoxAdapter(child: SizedBox(height: top + 58)),
        if (widget.title != null || widget.titleWidget != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: widget.titleWidget ?? Text(widget.title!, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.largeTitle.copyWith(color: p.label)),
              ),
            ),
          ),
        ...widget.slivers,
        SliverToBoxAdapter(child: SizedBox(height: bottomBarSpace(context))),
      ],
    );
    if (widget.onRefresh != null) {
      list = RefreshIndicator(onRefresh: widget.onRefresh!, edgeOffset: top + 50, color: p.accent, backgroundColor: p.grouped, child: list);
    }
    return Scaffold(
      backgroundColor: p.bg,
      body: Stack(
        children: [
          Positioned.fill(child: NotificationListener<ScrollNotification>(onNotification: _onScroll, child: list)),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                key: const ValueKey('tab-glass-bar'),
                opacity: scrolled ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: GlassBox(radius: BorderRadius.zero, shadow: false, fadeBottom: true, child: SizedBox(height: top + 60, width: double.infinity)),
              ),
            ),
          ),
          Positioned(
            top: top + 8,
            right: 14,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final a in widget.actions) ...[a, const SizedBox(width: 10)],
                const ProfileButton(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A pushed page: round back button, actions + avatar on the right, and an
/// iOS-style large title that shrinks into the bar when you scroll.
class SubPage extends StatefulWidget {
  final String title;
  final bool largeTitle;
  final List<Widget> actions;
  final List<Widget> slivers;
  final Widget? background;
  final bool showProfile;
  final Future<void> Function()? onRefresh;

  /// Opens where it was last scrolled to (Settings and its pages).
  final bool rememberScroll;

  /// Keeps the content a readable column on wide screens (tablet, laptop,
  /// browser) instead of stretching rows edge to edge. Settings pages use it.
  final bool capWidth;

  /// The widest a [capWidth] page's content gets.
  static const double maxContentWidth = 720;

  /// The collapsed top bar is solid (not see-through glass), so a big header
  /// scrolling under it never shows through the title (About, 1.4.3).
  final bool solidBar;
  const SubPage({
    this.solidBar = false,
    this.rememberScroll = false,
    this.capWidth = false,
    super.key,
    required this.title,
    required this.slivers,
    this.largeTitle = true,
    this.actions = const [],
    this.background,
    this.showProfile = true,
    this.onRefresh,
  });
  @override
  State<SubPage> createState() => _SubPageState();

  /// Forget remembered scroll positions (tests start each screen at the top).
  static void forgetScroll() => _SubPageState._remembered.clear();
}

class _SubPageState extends State<SubPage> {
  /// Where each page was scrolled to, so Settings (and its pages) open where you left them.
  static final Map<String, double> _remembered = {};
  late final ScrollController scroll = ScrollController(initialScrollOffset: widget.rememberScroll ? (_remembered[widget.title] ?? 0) : 0);
  bool collapsed = false;

  @override
  void initState() {
    super.initState();
    if (widget.rememberScroll) collapsed = (_remembered[widget.title] ?? 0) > (widget.largeTitle ? 44 : 320);
    scroll.addListener(() {
      if (widget.rememberScroll && scroll.hasClients) _remembered[widget.title] = scroll.offset;
      final c = scroll.hasClients && scroll.offset > (widget.largeTitle ? 44 : 320);
      if (c != collapsed) setState(() => collapsed = c);
    });
  }

  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final width = MediaQuery.sizeOf(context).width;
    final side = widget.capWidth && width > SubPage.maxContentWidth + 40 ? (width - SubPage.maxContentWidth) / 2 : 0.0;
    final content = <Widget>[
      if (widget.largeTitle)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: BT.largeTitle.copyWith(color: p.label)),
          ),
        ),
      ...widget.slivers,
    ];
    Widget list = CustomScrollView(
      controller: scroll,
      physics: const AlwaysScrollableScrollPhysics(parent: BouncingScrollPhysics()),
      slivers: [
        SliverToBoxAdapter(child: SizedBox(height: top + 60)),
        if (side > 0)
          SliverPadding(
            key: const ValueKey('subpage-capped'),
            padding: EdgeInsets.symmetric(horizontal: side),
            sliver: SliverMainAxisGroup(slivers: content),
          )
        else
          ...content,
        SliverToBoxAdapter(child: SizedBox(height: bottomBarSpace(context))),
      ],
    );
    if (widget.onRefresh != null) {
      list = RefreshIndicator(onRefresh: widget.onRefresh!, edgeOffset: top + 56, color: p.label, backgroundColor: p.grouped, child: list);
    }
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: widget.background == null ? p.bg : Colors.transparent,
      body: Stack(
        children: [
          if (widget.background != null) Positioned.fill(child: widget.background!),
          Positioned.fill(child: list),
          // Bar that fades in when the large title has scrolled away.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: collapsed ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: () {
                  final bar = SizedBox(
                    height: top + 60,
                    child: Padding(
                      padding: EdgeInsets.only(top: top, left: 70, right: 110),
                      child: Center(
                        child: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.bodyStrong.copyWith(color: p.label)),
                      ),
                    ),
                  );
                  if (widget.solidBar) {
                    return DecoratedBox(
                      key: const ValueKey('subpage-solid-bar'),
                      decoration: BoxDecoration(
                        color: p.bg,
                        border: Border(bottom: BorderSide(color: p.separator.withValues(alpha: 0.5), width: 0.5)),
                      ),
                      child: bar,
                    );
                  }
                  return GlassBox(radius: BorderRadius.zero, shadow: false, fadeBottom: true, child: bar);
                }(),
              ),
            ),
          ),
          if (canPop)
            Positioned(
              top: top + 8,
              left: 14,
              child: CircleGlassButton(icon: Icons.chevron_left_rounded, iconSize: 30, tooltip: 'Back', onTap: () => Navigator.of(context).maybePop()),
            ),
          Positioned(
            top: top + 8,
            right: 14,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.actions.isNotEmpty)
                  GlassBox(
                    radius: BorderRadius.circular(22),
                    shadow: false,
                    child: SizedBox(
                      height: 44,
                      child: Row(mainAxisSize: MainAxisSize.min, children: [const SizedBox(width: 4), ...widget.actions, const SizedBox(width: 4)]),
                    ),
                  ),
                if (widget.showProfile) ...[const SizedBox(width: 10), const ProfileButton()],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// An icon button that sits inside a [SubPage] action pill.
class BarIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  const BarIcon(this.icon, {super.key, required this.tooltip, this.onTap});
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    onPressed: onTap,
    visualDensity: VisualDensity.compact,
    icon: Icon(icon, color: BytePalette.of(context).label, size: 24),
  );
}

/// Big centred tile + title + subtitle (Downloads, Local Music, playlists).
class TileHeader extends StatelessWidget {
  final Widget tile;
  final String title;
  final String? subtitle;
  final List<Widget> buttons;
  const TileHeader({super.key, required this.tile, required this.title, this.subtitle, this.buttons = const []});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final w = MediaQuery.sizeOf(context).width;
    final size = (w - 100).clamp(160.0, 330.0);
    return Column(
      children: [
        const SizedBox(height: 4),
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.16), blurRadius: 28, offset: const Offset(0, 12))],
          ),
          child: ClipRRect(borderRadius: BorderRadius.circular(14), child: tile),
        ),
        const SizedBox(height: 22),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: BT.title2.copyWith(color: p.label)),
        ),
        if (subtitle != null && subtitle!.isNotEmpty) ...[
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(subtitle!, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: BT.title3.copyWith(color: p.secondary, fontWeight: FontWeight.w400)),
          ),
        ],
        if (buttons.isNotEmpty) ...[
          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(children: [for (var i = 0; i < buttons.length; i++) ...[if (i > 0) const SizedBox(width: 12), Expanded(child: buttons[i])]]),
          ),
        ],
        const SizedBox(height: 14),
      ],
    );
  }
}

/// Grey rounded "Play" / "Shuffle" button under a [TileHeader].
class PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// Solid brand red with white text (the main action on a screen).
  final bool filled;
  const PillButton({super.key, required this.icon, required this.label, this.onTap, this.filled = false});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final fg = filled ? Colors.white : p.accent;
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          color: filled ? ByteColors.brand : p.accent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(24),
          boxShadow: filled ? [BoxShadow(color: ByteColors.brand.withValues(alpha: 0.28), blurRadius: 14, offset: const Offset(0, 5))] : null,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: fg, size: 24),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.bodyStrong.copyWith(color: fg)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Centered grey text for empty lists.
class EmptyNote extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Widget? action;
  const EmptyNote(this.text, {super.key, this.icon, this.action});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 28, 32, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 44, color: p.tertiary), const SizedBox(height: 12)],
          Text(text, textAlign: TextAlign.center, style: BT.body.copyWith(color: p.secondary)),
          if (action != null) ...[const SizedBox(height: 14), action!],
        ],
      ),
    );
  }
}
