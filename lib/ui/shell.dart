import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../services.dart';
import 'logo.dart';
import 'links.dart';
import 'glyphs.dart';
import 'nav.dart';
import 'screens/listen_together_screen.dart';
import 'now_playing.dart';
import 'screens/explore_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/search_screen.dart';
import 'style.dart';
import 'glass.dart';
import 'kit/liquid_bar.dart';
import 'art_colors.dart';
import 'widgets.dart';

class _DepthObserver extends NavigatorObserver {
  final ValueNotifier<int> depth = ValueNotifier(0);
  @override
  void didPush(Route route, Route? previousRoute) {
    if (previousRoute != null) depth.value++;
  }

  @override
  void didPop(Route route, Route? previousRoute) => depth.value = (depth.value - 1).clamp(0, 999);
  @override
  void didRemove(Route route, Route? previousRoute) => depth.value = (depth.value - 1).clamp(0, 999);
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => ShellState();
}

/// Tabs: Home, Explore, Library (+ Search behind the round button).
class ShellState extends State<Shell> with SingleTickerProviderStateMixin {
  static ShellState? current;
  int index = 0;
  final navKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());
  final observers = List.generate(4, (_) => _DepthObserver());
  final scrolled = List.generate(4, (_) => false);
  final List<ScrollPosition?> positions = List.filled(4, null);
  final searchKey = GlobalKey<SearchScreenState>();
  late final AnimationController bar = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));

  static const tabs = [
    // filled glyphs in both states (grey when not selected), like the video
    (Icons.home_rounded, Icons.home_rounded, 'Home'),
    (Icons.grid_view_rounded, Icons.grid_view_rounded, 'Explore'),
    (Icons.library_music_rounded, Icons.library_music_rounded, 'Library'),
    (Icons.search_rounded, Icons.search_rounded, 'Search'),
    // No DJ tab: the DJ is a small feature inside the app (Home "DJ" pill,
    // player ⋯ → Start DJ, floating DJ button on the player while it's on).
  ];

  /// Tabs shown in the pill, in order.
  static const pillTabs = [0, 1, 2];

  @override
  void initState() {
    super.initState();
    current = this;
    Services.i.player.notice.addListener(_showNotice);
    openItemFromRoot = (context, item) => WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = navKeys[index].currentContext;
      if (ctx != null) openItem(ctx, item);
    });
    pushInCurrentTab = (page) => navKeys[index].currentState?.push(MaterialPageRoute(builder: (_) => page));
    for (final o in observers) {
      o.depth.addListener(_updateBar);
    }
    Services.i.player.current.addListener(_updateBar);
    Services.i.sync.remoteNow.addListener(_offerContinue);
    _notifTaps = notificationTaps().listen((clicked) {
      if (clicked) WidgetsBinding.instance.addPostFrameCallback((_) => _openPlayerFromNotification());
    });
    ByteLinks.listen((code) => WidgetsBinding.instance.addPostFrameCallback((_) => pushInCurrentTab?.call(ListenTogetherScreen(joinCode: code))));
  }

  /// Taps on the media notification / lock-screen player (tests swap it).
  static Stream<bool> Function() notificationTaps = () => AudioService.notificationClicked;
  StreamSubscription<bool>? _notifTaps;

  /// The media notification was tapped: show the Now Playing screen (once).
  void _openPlayerFromNotification() {
    if (!mounted || Services.i.player.current.value == null) return;
    var open = false;
    void find(Element e) {
      if (open) return;
      if (e.widget is NowPlayingScreen) {
        open = true;
        return;
      }
      e.visitChildElements(find);
    }

    WidgetsBinding.instance.rootElement?.visitChildElements(find);
    if (!open) NowPlayingScreen.open(context);
  }

  /// Something was playing on another device signed in to the same Gmail:
  /// offer to carry on here (only when nothing is playing here).
  void _offerContinue() {
    final now = Services.i.sync.remoteNow.value;
    final it = now?.item;
    if (it == null || !mounted || Services.i.player.current.value != null) return;
    final m = ScaffoldMessenger.maybeOf(context);
    m?.hideCurrentSnackBar();
    m?.showSnackBar(
      SnackBar(
        key: const ValueKey('continue-from-device'),
        content: GlassToast(
          'Continue "${it.title}" from ${now!.deviceName}?',
          action: 'Play',
          onAction: () async {
            m.hideCurrentSnackBar();
            Services.i.sync.clearRemoteNow();
            await Services.i.player.playItems(now.items, start: now.index);
            await Services.i.player.seek(now.position);
          },
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        padding: EdgeInsets.zero,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
      ),
    );
  }

  void _showNotice() {
    final n = Services.i.player.notice.value;
    if (n == null || !mounted) return;
    Services.i.player.notice.value = null;
    toast(context, n);
  }

  @override
  @override
  void dispose() {
    _notifTaps?.cancel();
    Services.i.player.notice.removeListener(_showNotice);
    Services.i.sync.remoteNow.removeListener(_offerContinue);
    if (current == this) current = null;
    Services.i.player.current.removeListener(_updateBar);
    bar.dispose();
    super.dispose();
  }

  // Only scrolling down folds the bar; opening a page keeps every tab in
  // sight (people thought Explore and Library had disappeared).
  bool get _wantCompact => Services.i.player.current.value != null && scrolled[index];

  void _updateBar() {
    if (!mounted) return;
    final reduce = Services.i.settings.reduceMotion;
    if (_wantCompact) {
      reduce ? bar.value = 1 : bar.animateTo(1, curve: Curves.easeInOutCubic);
    } else {
      reduce ? bar.value = 0 : bar.animateBack(0, curve: Curves.easeInOutCubic);
    }
  }

  bool _onScroll(int tab, ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final px = n.metrics.pixels;
    final ctx = n.context;
    if (ctx != null) positions[tab] = Scrollable.maybeOf(ctx)?.position;
    var s = scrolled[tab];
    if (n is ScrollUpdateNotification && (n.scrollDelta ?? 0) > 2 && px > 90) s = true;
    // scrolling back up brings the full bar (all tabs) back, like the reference
    if (n is ScrollUpdateNotification && (n.scrollDelta ?? 0) < -4) s = false;
    if (px < 40) s = false;
    if (s != scrolled[tab]) {
      scrolled[tab] = s;
      if (tab == index) _updateBar();
    }
    return false;
  }

  void select(int i) {
    HapticFeedback.selectionClick();
    if (i == index) {
      // tap the current tab again: back to its first page
      navKeys[i].currentState?.popUntil((r) => r.isFirst);
      if (i == 3) searchKey.currentState?.focusSearch();
      return;
    }
    setState(() => index = i);
    _updateBar();
  }

  /// Compact bar's left button: unfold the bar (all tabs again), staying on the page.
  void tapCompactTab() {
    HapticFeedback.selectionClick();
    scrolled[index] = false;
    _updateBar();
  }

  Widget _tab(int i) {
    final Widget root = switch (i) {
      0 => const HomeScreen(),
      1 => const ExploreScreen(),
      2 => const LibraryScreen(),
      _ => SearchScreen(key: searchKey),
    };
    return NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(i, n),
      child: Navigator(
        key: navKeys[i],
        observers: [observers[i]],
        onGenerateRoute: (s) => MaterialPageRoute(builder: (_) => root, settings: s),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 820;
    final stack = IndexedStack(
      index: index,
      children: [for (var i = 0; i < 4; i++) HeroMode(enabled: i == index, child: _tab(i))],
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final nav = navKeys[index].currentState;
        if (nav != null && nav.canPop()) {
          nav.pop();
        } else if (index != 0) {
          select(0);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        extendBody: true,
        body: wide
            ? Row(
                children: [
                  _SideBar(index: index, onSelect: select),
                  Expanded(
                    child: Stack(
                      children: [
                        Positioned.fill(child: stack),
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 16 + MediaQuery.paddingOf(context).bottom,
                          child: const Center(
                            child: SizedBox(width: 560, height: 60, child: MiniPlayer(compact: false)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              )
            : Stack(
                children: [
                  Positioned.fill(child: stack),
                  // Out of the way while the keyboard is up (it sat on top of
                  // the keyboard and covered buttons like "Find songs").
                  if (MediaQuery.viewInsetsOf(context).bottom < 40)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: FloatingBar(state: this),
                    ),
                ],
              ),
      ),
    );
  }
}

/// The floating glass bar: mini player above a Home/Explore/Library pill and a
/// round search button. Scrolling down (or opening a page) folds it into one
/// slim row: current tab · mini player · search.
class FloatingBar extends StatelessWidget {
  final ShellState state;
  const FloatingBar({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    final p = BytePalette.of(context);
    return ValueListenableBuilder<Item?>(
      valueListenable: Services.i.player.current,
      builder: (context, song, _) {
        final hasSong = song != null;
        final h = (hasSong ? 64 + 8 + 56 : 64) + 10 + bottom;
        return SizedBox(
          height: h.toDouble(),
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final base = c.maxHeight - bottom - 10; // bottom edge of the bars
              return AnimatedBuilder(
                animation: state.bar,
                builder: (context, _) {
                  final t = state.bar.value;
                  final navE = Rect.fromLTWH(16, base - 64, w - 16 - 16 - 64 - 12, 64);
                  final navC = Rect.fromLTWH(16, base - 56, 56, 56);
                  final searchE = Rect.fromLTWH(w - 16 - 64, base - 64, 64, 64);
                  final searchC = Rect.fromLTWH(w - 16 - 56, base - 56, 56, 56);
                  final miniE = Rect.fromLTWH(16, base - 64 - 8 - 56, w - 32, 56);
                  final miniC = Rect.fromLTWH(16 + 56 + 10, base - 56, w - 2 * (16 + 56 + 10), 56);
                  final nav = Rect.lerp(navE, navC, t)!;
                  final search = Rect.lerp(searchE, searchC, t)!;
                  final mini = Rect.lerp(miniE, miniC, t)!;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // soft fade so content doesn't fight with the bars
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        height: bottom + 40,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [p.bg.withValues(alpha: 0), p.bg.withValues(alpha: LiquidBar.blurOn ? 0.0 : 0.6)],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (hasSong) Positioned.fromRect(rect: mini, child: MiniPlayer(compact: t > 0.5)),
                      Positioned.fromRect(
                        rect: nav,
                        child: LiquidBar(
                          key: const ValueKey('nav-glass'),
                          radius: BorderRadius.circular(nav.height / 2),
                          child: Stack(
                            children: [
                              if (t < 0.98)
                                Opacity(
                                  opacity: (1 - t * 1.8).clamp(0.0, 1.0),
                                  child: OverflowBox(
                                    alignment: Alignment.centerLeft,
                                    minWidth: navE.width,
                                    maxWidth: navE.width,
                                    child: _TabRow(index: state.index, onSelect: state.select),
                                  ),
                                ),
                              if (t > 0.02)
                                Opacity(
                                  opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0),
                                  child: Center(
                                    child: IconButton(
                                      tooltip: ShellState.tabs[state.index].$3,
                                      onPressed: state.tapCompactTab,
                                      icon: tabGlyph(state.index, ShellState.tabs[state.index].$2, color: p.label, size: 26),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Positioned.fromRect(
                        rect: search,
                        child: Tooltip(
                          message: 'Search',
                          child: Pressable(
                            onTap: () => state.select(3),
                            child: LiquidBar(
                              key: const ValueKey('search-glass'),
                              radius: BorderRadius.circular(search.height / 2),
                              child: Center(
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 220),
                                  width: search.height - 10,
                                  height: search.height - 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: state.index == 3 ? p.accent.withValues(alpha: 0.16) : Colors.transparent,
                                  ),
                                  child: Icon(Icons.search_rounded, size: 28, color: state.index == 3 ? p.accent : p.label, semanticLabel: 'Search'),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

class _TabRow extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  const _TabRow({required this.index, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final tabs = ShellState.pillTabs;
        final w = (c.maxWidth - 8) / tabs.length;
        final pos = tabs.indexOf(index);
        return Stack(
          children: [
            // the "lens" behind the selected tab slides between tabs
            AnimatedPositioned(
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              left: 4 + w * (pos < 0 ? 0 : pos),
              top: 4,
              bottom: 4,
              width: w,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: pos >= 0 ? 1 : 0,
                child: LiquidCapsule(key: const ValueKey('nav-capsule'), accent: p.accent, dark: Theme.of(context).brightness == Brightness.dark),
              ),
            ),
            Row(
              children: [
                const SizedBox(width: 4),
                for (final i in tabs)
                  SizedBox(
                    width: w,
                    child: Semantics(
                      button: true,
                      selected: i == index,
                      label: ShellState.tabs[i].$3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelect(i),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            tabGlyph(i, ShellState.tabs[i].$2, size: 26, color: i == index ? p.accent : ReadableGlass.navSecondary(Theme.of(context).brightness == Brightness.dark)),
                            const SizedBox(height: 2),
                            // 1.4.6: tab labels keep their size (like the
                            // phone's own tab bars); at large text they
                            // spilled out of the bar.
                            Text(
                              ShellState.tabs[i].$3,
                              textScaler: TextScaler.noScaling,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: BT.tab.copyWith(color: i == index ? p.accent : ReadableGlass.navSecondary(Theme.of(context).brightness == Brightness.dark), fontWeight: i == index ? FontWeight.w700 : FontWeight.w500),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Tablet: a glass sidebar instead of the bottom bar.
class _SideBar extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;
  const _SideBar({required this.index, required this.onSelect});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    return Container(
      width: wide ? 240 : 96,
      decoration: BoxDecoration(
        color: p.grouped.withValues(alpha: 0.6),
        border: Border(right: BorderSide(color: p.separator, width: 0.6)),
      ),
      child: SafeArea(
        right: false,
        child: Column(
          crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(wide ? 22 : 0, 18, 0, 22),
              child: const ByteLogo(size: 34),
            ),
            for (var i = 0; i < 4; i++)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: Semantics(
                  button: true,
                  selected: i == index,
                  label: ShellState.tabs[i].$3,
                  child: Pressable(
                    onTap: () => onSelect(i),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      height: wide ? 48 : 64,
                      decoration: BoxDecoration(color: i == index ? p.accent.withValues(alpha: 0.11) : Colors.transparent, borderRadius: BorderRadius.circular(14)),
                      padding: EdgeInsets.symmetric(horizontal: wide ? 12 : 0),
                      child: wide
                          ? Row(
                              children: [
                                tabGlyph(i, ShellState.tabs[i].$2, size: 24, color: i == index ? p.accent : p.secondary),
                                const SizedBox(width: 12),
                                Text(ShellState.tabs[i].$3, style: BT.body.copyWith(color: i == index ? p.accent : p.secondary, fontWeight: i == index ? FontWeight.w700 : FontWeight.w500)),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                tabGlyph(i, ShellState.tabs[i].$2, size: 24, color: i == index ? p.accent : p.secondary),
                                const SizedBox(height: 2),
                                Text(ShellState.tabs[i].$3, style: BT.tab.copyWith(color: i == index ? p.accent : ReadableGlass.navSecondary(Theme.of(context).brightness == Brightness.dark), fontWeight: i == index ? FontWeight.w700 : FontWeight.w500)),
                              ],
                            ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The floating glass pill showing the song playing.
class MiniPlayer extends StatelessWidget {
  final bool compact;
  const MiniPlayer({super.key, this.compact = false});
  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    // 1.4.1: always white text on a near-solid, darkened cover-colour tint
    // (frosted behind it), so it reads over white pages and busy covers alike.
    const label = Colors.white;
    const secondary = ReadableGlass.miniSecondary;
    return ValueListenableBuilder<Item?>(
      valueListenable: p.current,
      builder: (context, it, _) {
        if (it == null) return const SizedBox.shrink();
        return GestureDetector(
          key: const ValueKey('mini'),
          onTap: () => NowPlayingScreen.open(context),
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -200) NowPlayingScreen.open(context);
          },
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300) p.skipToNext();
            if (v > 300) p.skipToPrevious();
          },
          child: MiniGlass(
            url: it.thumbAt(226),
            child: Stack(
              children: [
                Row(
                  children: [
                    const SizedBox(width: 9),
                    Hero(
                      tag: 'np-art',
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: Artwork(it.thumb, key: ValueKey(it.id), size: 38, radius: 8),
                      ),
                    ),
                    const SizedBox(width: 11),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        layoutBuilder: (cur, prev) => Stack(alignment: Alignment.centerLeft, children: [...prev, ?cur]),
                        child: Column(
                          key: ValueKey(it.id),
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              it.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: label, letterSpacing: -0.2),
                            ),
                            ValueListenableBuilder<String?>(
                              valueListenable: p.error,
                              builder: (c, err, _) => Text(
                                err ?? it.artistLine,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: err != null ? const Color(0xFFFFB4AB) : secondary, fontSize: 13),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const PlayPauseButton(size: 42, plain: true, color: label),
                    const SizedBox(width: 2),
                    if (!compact) IconButton(tooltip: 'Next', onPressed: p.skipToNext, icon: const Icon(Icons.fast_forward_rounded, color: label, size: 28)),
                    SizedBox(width: compact ? 4 : 6),
                  ],
                ),
                const Positioned(left: 22, right: 22, bottom: 2, child: _MiniProgress(color: Colors.white)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The mini player's backing: strong frosted blur + a near-solid tint of the
/// cover's colour (darkened, see [ReadableGlass.miniTint]), a thin light edge
/// and a soft shadow that lifts it off any page.
class MiniGlass extends StatefulWidget {
  final String? url;
  final Widget child;
  const MiniGlass({super.key, required this.url, required this.child});
  @override
  State<MiniGlass> createState() => _MiniGlassState();
}

class _MiniGlassState extends State<MiniGlass> {
  ArtPalette _pal = ArtPalette.fallback;
  String? _for;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant MiniGlass old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) _load();
  }

  Future<void> _load() async {
    final u = widget.url;
    _for = u;
    final p = await paletteFor(u);
    if (mounted && _for == u) setState(() => _pal = p);
  }

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(28);
    final blur = LiquidBar.blurOn;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: liquidMiniTint(_pal.primary, blur: blur)),
      duration: const Duration(milliseconds: 600),
      builder: (context, tint, child) => LiquidBar(
        key: const ValueKey('mini-glass'),
        radius: r,
        tint: tint,
        dark: true,
        child: child!,
      ),
      child: widget.child,
    );
  }
}

class _MiniProgress extends StatelessWidget {
  final Color color;
  const _MiniProgress({required this.color});
  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    return StreamBuilder<PlaybackState>(
      stream: p.playbackState,
      builder: (context, _) => StreamBuilder<Duration>(
        stream: p.activePlayer.positionStream,
        builder: (context, s) {
          final d = p.duration?.inMilliseconds ?? 0;
          final v = d <= 0 ? 0.0 : ((s.data?.inMilliseconds ?? 0) / d).clamp(0.0, 1.0);
          return ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(value: v, minHeight: 3, backgroundColor: color.withValues(alpha: 0.18), color: color.withValues(alpha: 0.92)),
          );
        },
      ),
    );
  }
}
