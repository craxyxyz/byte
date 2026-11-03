import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../data/settings.dart' show Settings;
import '../player/byte_handler.dart';
import '../services.dart';
import 'app_fullscreen.dart';
import 'art_background.dart';
import 'lyrics_view.dart';
import 'player_parts.dart';
import 'style.dart';
import 'theme.dart';
import 'screens/listen_together_screen.dart';
import 'widgets.dart';
import 'dj_talk.dart';
import 'glass.dart';

enum NpTab { song, lyrics, queue }

/// Full-screen player. Phones: Song / Lyrics / Up next pages.
/// Tablets (≥820 px): artwork + controls on the left, lyrics / queue on the right.
class NowPlayingScreen extends StatefulWidget {
  final NpTab initial;
  const NowPlayingScreen({super.key, this.initial = NpTab.song});

  static Future<void> open(BuildContext context, {NpTab tab = NpTab.song}) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: false,
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, _, _) => NowPlayingScreen(initial: tab),
        transitionsBuilder: (_, a, _, child) {
          final c = CurvedAnimation(parent: a, curve: Curves.easeOutQuart, reverseCurve: Curves.easeInCubic);
          return SlideTransition(
            position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(c),
            child: child,
          );
        },
      ),
    );
  }

  @override
  State<NowPlayingScreen> createState() => _NowPlayingScreenState();
}

class _NowPlayingScreenState extends State<NowPlayingScreen> {
  late PlayerMode mode = PlayerMode.values[widget.initial.index];
  NpTab sideTab = NpTab.lyrics;

  late final bool _hidBar = Services.i.settings.hideStatusBarInPlayer;

  @override
  void initState() {
    super.initState();
    if (widget.initial != NpTab.song) sideTab = widget.initial;
    WidgetsBinding.instance.addPostFrameCallback((_) => _poke());
    if (_hidBar) SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    AppFullscreen.keepImmersive = _hidBar;
    LyricsPane.idle.addListener(_syncFullscreen);
    LyricsPane.browsing.addListener(_syncFullscreen);
    HardwareKeyboard.instance.addHandler(_onKey);
    openListenTogether = (c) => Navigator.of(c).push(MaterialPageRoute(builder: (_) => const ListenTogetherScreen()));
  }

  // Lyrics: after a few seconds without a touch, go full screen.
  Timer? _idleTimer;

  /// 1.4.4: the lyrics are on screen: the lyrics mode on a phone, or the
  /// Lyrics side of the wide (tablet / web / desktop) player.
  bool _wideNow = false;
  bool get _lyricsOnScreen => mode == PlayerMode.lyrics || (_wideNow && sideTab == NpTab.lyrics);
  void _poke() {
    _idleTimer?.cancel();
    if (LyricsPane.idle.value) LyricsPane.idle.value = false;
    if (!_lyricsOnScreen || !Services.i.settings.lyricsAutoFullScreen) return;
    _idleTimer = Timer(LyricsPane.idleAfter, () {
      if (!mounted || !_lyricsOnScreen || LyricsPane.selection.value != null) return;
      LyricsPane.idle.value = true;
    });
  }

  // ── 1.4.5: full-screen lyrics fill the whole screen on a computer / web ──
  Timer? _cursorTimer;
  bool _cursorHidden = false;

  /// Full-screen lyrics (the controls gone) → the window goes full screen;
  /// it stays so while the lyrics are on screen (a mouse move brings the
  /// controls back, not the title bar), and leaves with the lyrics, Esc or F11.
  /// 1.4.5 QA: Esc left full screen; the lyrics don't take the screen
  /// again by themselves until they are opened again.
  bool _escaped = false;

  void _syncFullscreen() {
    if (!mounted) return;
    if (!_lyricsOnScreen) _escaped = false;
    final lyricsFull = _lyricsOnScreen && (LyricsPane.idle.value || LyricsPane.browsing.value);
    if (lyricsFull && !AppFullscreen.active.value && !_escaped) {
      unawaited(AppFullscreen.enter());
      _wakeCursor();
    } else if (!_lyricsOnScreen && AppFullscreen.active.value) {
      unawaited(AppFullscreen.exit());
    }
  }

  bool _onKey(KeyEvent e) {
    if (!mounted) return false;
    final wasFull = AppFullscreen.active.value;
    final handled = AppFullscreen.handleKey(e);
    if (handled && wasFull && e.logicalKey == LogicalKeyboardKey.escape) {
      // Esc = back to normal: the window and the controls (before, the
      // controls stayed hidden and the lyrics went full screen again).
      _escaped = true;
      _idleTimer?.cancel();
      LyricsPane.idle.value = false;
    }
    if (handled) setState(() {});
    return handled;
  }

  void _wakeCursor() {
    _cursorTimer?.cancel();
    if (_cursorHidden) setState(() => _cursorHidden = false);
    if (!AppFullscreen.active.value) return;
    _cursorTimer = Timer(AppFullscreen.cursorIdle, () {
      if (mounted && AppFullscreen.active.value) setState(() => _cursorHidden = true);
    });
  }

  @override
  void dispose() {
    LyricsPane.idle.removeListener(_syncFullscreen);
    LyricsPane.browsing.removeListener(_syncFullscreen);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _cursorTimer?.cancel();
    AppFullscreen.keepImmersive = false;
    if (AppFullscreen.active.value) unawaited(AppFullscreen.exit());
    _idleTimer?.cancel();
    LyricsPane.idle.value = false;
    _controlsTop.dispose();
    if (_hidBar) SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    LyricsPane.browsing.value = false;
    LyricsPane.selection.value = null;
    super.dispose();
  }

  // Where the title/controls block starts on screen: the full-screen cover
  // reaches down to it on every phone shape.
  final _controlsKey = GlobalKey();
  final ValueNotifier<double> _controlsTop = ValueNotifier(0);

  void _measureControls() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _controlsKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached || !box.hasSize) return;
      final top = box.localToGlobal(Offset.zero).dy;
      if ((top - _controlsTop.value).abs() > 0.5) _controlsTop.value = top;
    });
  }

  void _setMode(PlayerMode m) {
    LyricsPane.browsing.value = false;
    LyricsPane.selection.value = null;
    // A browser allows full screen only straight after a tap: ask now.
    if (kIsWeb && m == PlayerMode.lyrics) unawaited(AppFullscreen.enter());
    setState(() => mode = m);
    _poke();
    _syncFullscreen();
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 820;
    if (wide != _wideNow) {
      _wideNow = wide;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _poke();
      });
    }
    return Theme(
      data: ByteTheme.player(Theme.of(context)),
      child: Scaffold(
        backgroundColor: Colors.black,
        body: MouseRegion(
          cursor: _cursorHidden && AppFullscreen.active.value ? SystemMouseCursors.none : MouseCursor.defer,
          onHover: (_) => _wakeCursor(),
          child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => _poke(),
          child: ArtBackground(
          child: ValueListenableBuilder<Item?>(
            valueListenable: Services.i.player.current,
            builder: (context, it, _) {
              final full = it != null && !wide && Services.i.settings.fullScreenCover;
              final bleed = full && mode == PlayerMode.song;
              _measureControls();
              return Stack(
                children: [
                  // Full-screen cover: edge to edge from the very top (under the
                  // status bar) down to the song title, fading into the
                  // background. It stays in the tree and fades with the mode, so
                  // the lyrics/queue never draw on top of a half-shown cover.
                  if (full)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: AnimatedOpacity(
                        opacity: bleed ? 1 : 0,
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeOutCubic,
                        child: ValueListenableBuilder<double>(
                          valueListenable: _controlsTop,
                          builder: (context, top, _) => FullBleedCover(item: it, controlsTop: top),
                        ),
                      ),
                    ),
                  SafeArea(
                    child: it == null
                        ? const Center(child: Text('Nothing playing'))
                        : wide
                        ? _wide(context, it)
                        : bleed
                        ? _poster(context, it)
                        : _phone(context, it, bleed: bleed),
                  ),
                  // DJ mode: the big round DJ button (tap: switch it up, hold: talk)
                  if (it != null)
                    Positioned(
                      right: 16,
                      top: 0,
                      child: ListenableBuilder(
                        listenable: Services.i.dj,
                        builder: (context, _) => Services.i.dj.active && (wide || mode == PlayerMode.song)
                            ? const SafeArea(child: Padding(padding: EdgeInsets.only(top: 48), child: DjFloatingButton()))
                            : const SizedBox.shrink(),
                      ),
                    ),
                ],
              );
            },
          ),
          ),
        ),
        ),
      ),
    );
  }

  /// 1.4.5: in full-screen lyrics the close arrow and the handle fold away
  /// too (only the lyrics on the screen); a touch brings them back.
  Widget _foldingGrabber(BuildContext context, {bool caption = false}) => ValueListenableBuilder<bool>(
    valueListenable: LyricsPane.idle,
    builder: (context, idle, child) {
      final hide = idle && _lyricsOnScreen;
      return AnimatedSize(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        child: hide ? const SizedBox(width: double.infinity, height: 0) : child,
      );
    },
    child: _grabber(context, caption: caption),
  );

  /// Swipe-down handle and close button (over the cover: "Playing from …" under the handle).
  Widget _grabber(BuildContext context, {bool caption = false}) => SizedBox(
    height: caption ? 52 : 40,
    child: Row(
      children: [
        IconButton(tooltip: 'Close', icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 30), onPressed: () => Navigator.pop(context)),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 38,
                height: 5,
                decoration: BoxDecoration(color: Colors.white54, borderRadius: BorderRadius.circular(3)),
              ),
              if (caption)
                ValueListenableBuilder<String?>(
                  valueListenable: Services.i.player.playingFrom,
                  builder: (context, from, _) => from == null || Services.i.settings.hideSongStatus
                      ? const SizedBox.shrink()
                      : Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Playing from $from',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.85),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              shadows: const [Shadow(color: Colors.black38, blurRadius: 6)],
                            ),
                          ),
                        ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 48),
      ],
    ),
  );

  Widget _phone(BuildContext context, Item it, {bool bleed = false}) {
    return GestureDetector(
      // swipe down anywhere outside the lists closes the player
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 700 && mode == PlayerMode.song) Navigator.pop(context);
      },
      child: Column(
        children: [
          _foldingGrabber(context, caption: bleed),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 320),
              switchInCurve: Curves.easeOutCubic,
              child: switch (mode) {
                // (the full-bleed cover sits behind, under the status bar)
                PlayerMode.song when bleed => const SizedBox.expand(key: ValueKey('bleed')),
                PlayerMode.song => _SongArt(key: const ValueKey('art'), item: it),
                PlayerMode.lyrics => Column(
                  key: const ValueKey('lyrics'),
                  children: [
                    ValueListenableBuilder<bool>(
                      valueListenable: LyricsPane.idle,
                      builder: (context, idle, child) => AnimatedSize(
                        duration: const Duration(milliseconds: 320),
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: idle ? 0 : 1,
                          duration: const Duration(milliseconds: 240),
                          child: idle ? const SizedBox(width: double.infinity) : child,
                        ),
                      ),
                      child: _ModeHeader(item: it, lyrics: true),
                    ),
                    const Expanded(child: _LyricsArea()),
                  ],
                ),
                PlayerMode.queue => Column(
                  key: const ValueKey('queue'),
                  children: [
                    _ModeHeader(item: it),
                    const Expanded(child: _QueuePage()),
                  ],
                ),
              },
            ),
          ),
          KeyedSubtree(key: _controlsKey, child: _PlayerControls(item: it, mode: mode, onMode: _setMode)),
        ],
      ),
    );
  }

  /// 1.4.1 poster layout (reference app): the square cover from the very top,
  /// the title sitting where the cover fades out, then everything spread
  /// evenly down to the bottom row.
  Widget _poster(BuildContext context, Item it) {
    final mq = MediaQuery.of(context);
    // the screen's real insets: read above the Scaffold/SafeArea (inside
    // them the padding is already taken away)
    final outer = MediaQuery.of(this.context);
    final pad = EdgeInsets.only(
      top: math.max(outer.padding.top, outer.viewPadding.top),
      bottom: math.max(outer.padding.bottom, outer.viewPadding.bottom),
    );
    final g = posterGeometry(mq.size, pad);
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 700) Navigator.pop(context);
      },
      child: Column(
        children: [
          _grabber(context, caption: true),
          SizedBox(height: g.gap),
          Expanded(
            child: KeyedSubtree(key: _controlsKey, child: _PlayerControls(item: it, mode: PlayerMode.song, onMode: _setMode, fill: true)),
          ),
        ],
      ),
    );
  }

  Widget _wide(BuildContext context, Item it) {
    // 1.4.4 (Apurba): full-screen lyrics here too: after a few seconds
    // without a touch on the Lyrics side, the cover, controls and the
    // Lyrics | Up next switch fold away and only the lyrics stay (centred);
    // a touch brings everything back.
    return Column(
      children: [
        _foldingGrabber(context),
        Expanded(
          child: ValueListenableBuilder<bool>(
            valueListenable: LyricsPane.idle,
            builder: (context, idle0, _) {
              final full = idle0 && sideTab == NpTab.lyrics;
              return LayoutBuilder(
                builder: (context, c) => Row(
                  children: [
                    AnimatedSize(
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeOutCubic,
                      child: full
                          ? const SizedBox(width: 0, height: double.infinity)
                          : SizedBox(
                              width: c.maxWidth * 5 / 11,
                              child: Column(
                                children: [
                                  Expanded(child: _SongArt(item: it)),
                                  _PlayerControls(
                                    item: it,
                                    mode: PlayerMode.song,
                                    sideMode: sideTab == NpTab.lyrics ? PlayerMode.lyrics : PlayerMode.queue,
                                    onMode: (m) {
                                      if (kIsWeb && m == PlayerMode.lyrics) unawaited(AppFullscreen.enter());
                                      if (m != PlayerMode.song) setState(() => sideTab = m == PlayerMode.lyrics ? NpTab.lyrics : NpTab.queue);
                                      _poke();
                                      _syncFullscreen();
                                    },
                                  ),
                                ],
                              ),
                            ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          AnimatedSize(
                            duration: const Duration(milliseconds: 320),
                            curve: Curves.easeOutCubic,
                            child: full
                                ? const SizedBox(width: double.infinity)
                                : Padding(
                                    padding: const EdgeInsets.only(top: 4, bottom: 4),
                                    child: _Segments(
                                      value: sideTab,
                                      options: const [NpTab.lyrics, NpTab.queue],
                                      onChanged: (t) {
                                        setState(() => sideTab = t);
                                        _poke();
                                      },
                                    ),
                                  ),
                          ),
                          Expanded(
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: full ? 880 : double.infinity),
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 300),
                                  child: sideTab == NpTab.lyrics ? const _LyricsArea(key: ValueKey('l')) : const _QueuePage(key: ValueKey('q')),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

}

/// Lyrics fill the space; while scrolling them a "back to the live line" button shows.
class _LyricsArea extends StatelessWidget {
  const _LyricsArea({super.key});
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(child: LyricsPane(padding: EdgeInsets.fromLTRB(24, 16, 24, 90))),
        Positioned(
          top: 6,
          right: 14,
          child: ValueListenableBuilder<bool>(
            valueListenable: LyricsPane.browsing,
            builder: (context, b, _) => AnimatedScale(
              scale: b ? 1 : 0,
              duration: const Duration(milliseconds: 200),
              child: Tooltip(
                message: 'Back to the live line',
                child: InkResponse(
                  onTap: () => LyricsPane.resync.value++,
                  child: const LiquidGlass(
                    radius: BorderRadius.all(Radius.circular(20)),
                    dark: true,
                    child: SizedBox(width: 40, height: 40, child: Icon(Icons.my_location_rounded, size: 20, color: Colors.white)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Title, status, seek, controls, volume and the bottom row. While the person
/// scrolls the lyrics, everything but nothing folds away (full-height lyrics).
class _PlayerControls extends StatelessWidget {
  final Item item;
  final PlayerMode mode;
  final PlayerMode? sideMode;
  final ValueChanged<PlayerMode> onMode;

  /// 1.4.1: fill the space under the poster, spread out like the reference.
  final bool fill;
  const _PlayerControls({required this.item, required this.mode, required this.onMode, this.sideMode, this.fill = false});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([Services.i.settings, LyricsPane.browsing, LyricsPane.idle]),
      builder: (context, _) {
        final st = Services.i.settings;
        final immersive = mode == PlayerMode.lyrics && (LyricsPane.browsing.value || LyricsPane.idle.value);
        return AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: immersive
              ? const SizedBox(width: double.infinity, height: 0)
              : fill
              ? LayoutBuilder(
                  builder: (context, c) => c.maxHeight < 430
                      ? _compact(st)
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 6),
                          child: Column(
                            children: [
                              _TitleRow(item: item),
                              const SizedBox(height: 14),
                              NextLyricLine(
                                onTap: () => onMode(PlayerMode.lyrics),
                                fallback: PlayerContextLine(onTap: () => onMode(PlayerMode.queue)),
                              ),
                              if (!st.hideSongStatus) const _SongStatus(),
                              const SizedBox(height: 6),
                              const SeekBar(),
                              if (st.statsForNerds) const _NerdStats(),
                              const Spacer(flex: 3),
                              const _MainControls(),
                              const Spacer(flex: 4),
                              if (!st.hideVolumeBar) ...[const PlayerVolume(), const Spacer(flex: 1)],
                              PlayerBottomRow(mode: sideMode ?? mode, onMode: onMode),
                            ],
                          ),
                        ),
                )
              : _compact(st),
        );
      },
    );
  }

  Widget _compact(Settings st) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 6, 24, 10),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mode == PlayerMode.song) ...[
          _TitleRow(item: item),
          const SizedBox(height: 4),
          NextLyricLine(
            onTap: () => onMode(PlayerMode.lyrics),
            fallback: PlayerContextLine(onTap: () => onMode(PlayerMode.queue)),
          ),
        ],
        if (!st.hideSongStatus) const _SongStatus(),
        if (mode == PlayerMode.queue) PlayerContextLine(onTap: () => onMode(PlayerMode.queue)),
        const SizedBox(height: 4),
        const SeekBar(),
        if (st.statsForNerds) const _NerdStats(),
        const _MainControls(),
        if (!st.hideVolumeBar) ...[const SizedBox(height: 16), const PlayerVolume()],
        const SizedBox(height: 8),
        PlayerBottomRow(mode: sideMode ?? mode, onMode: onMode),
      ],
    ),
  );
}

/// Small cover + title + star + ⋯ (share while browsing lyrics), on top of lyrics and queue.
class _ModeHeader extends StatelessWidget {
  final Item item;
  final bool lyrics;
  const _ModeHeader({required this.item, this.lyrics = false});
  @override
  Widget build(BuildContext context) {
    // 1.4.1 lyrics header like the reference: a tiny square cover, title and
    // artists, and only ⋯ on the right (Like is inside ⋯).
    final art = lyrics ? 44.0 : 56.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(lyrics ? 24 : 20, 4, lyrics ? 16 : 12, 4),
      child: Row(
        children: [
          Hero(tag: 'np-art', child: Artwork(item.thumbAt(226), size: art, radius: lyrics ? 6 : 8)),
          SizedBox(width: lyrics ? 11 : 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontWeight: lyrics ? FontWeight.w700 : FontWeight.w800, fontSize: lyrics ? 15.5 : 16, color: Colors.white),
                ),
                const SizedBox(height: 1),
                Text(
                  item.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: Colors.white.withValues(alpha: lyrics ? 0.66 : 0.7), fontSize: lyrics ? 13.5 : 14),
                ),
              ],
            ),
          ),
          if (!lyrics) ...[LikeButton(item: item, size: 20, round: true), const SizedBox(width: 8)],
          ValueListenableBuilder<bool>(
            valueListenable: LyricsPane.browsing,
            builder: (context, b, _) => lyrics && b
                ? _RoundBtn(icon: Icons.ios_share_rounded, tooltip: 'Share lines', onTap: () => LyricsPane.selection.value = {})
                : _RoundBtn(icon: Icons.more_horiz_rounded, tooltip: 'More', onTap: () => showPlayerMore(context, item)),
          ),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _RoundBtn({super.key, required this.icon, required this.tooltip, required this.onTap});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      label: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: LiquidGlass(
          radius: BorderRadius.circular(18),
          dark: true,
          child: SizedBox(width: 36, height: 36, child: Icon(icon, size: 20, color: Colors.white)),
        ),
      ),
    ),
  );
}

/// Where things sit in the 1.4.1 poster player (measured off the reference
/// recording, t02/t03): the square cover from the very top, the title about
/// 3 % of the screen below where the cover ends, and the rest spread down
/// to the bottom row. On short screens the title moves up into the cover's
/// fade so the controls always fit (they need about 440 px).
({double cover, double titleTop, double gap}) posterGeometry(Size size, EdgeInsets pad) {
  final cover = FullBleedCover.heightFor(size);
  const grabber = 52.0;
  const need = 440.0;
  var titleTop = cover + size.height * 0.03;
  final maxTop = size.height - pad.bottom - need;
  if (titleTop > maxTop) titleTop = maxTop;
  final gap = (titleTop - pad.top - grabber).clamp(0.0, double.infinity).toDouble();
  return (cover: cover, titleTop: pad.top + grabber + gap, gap: gap);
}

/// The player's cover in the default look: full screen. As wide as the
/// screen, from the very top down to the song title (so there is no empty
/// band between the picture and the controls), its lower part fading into
/// the background. A square cover on a tall phone is scaled to fill and
/// centred, so the middle of the art is always what shows.
class FullBleedCover extends StatelessWidget {
  final Item item;

  /// Top of the title/controls block on screen (0 = not measured yet).
  final double controlsTop;
  const FullBleedCover({super.key, required this.item, this.controlsTop = 0});

  /// The cover's height for a screen [size]: a square as wide as the screen,
  /// from the very top, like the reference player (1.3.1 stretched it down to
  /// the title, which pushed the art too far down). Only on short, wide
  /// screens is it cut to 58% of the height so the controls always fit.
  /// [top] (where the controls start) is accepted for older callers.
  static double heightFor(Size size, [double top = 0]) => size.width.clamp(0.0, size.height * 0.58).toDouble();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final h = heightFor(size, controlsTop);
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 420),
        child: ShaderMask(
          key: ValueKey(item.id),
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            // 1.4.1: the art stays solid most of the way, then melts into
            // the blurred art-colour background (reference player)
            colors: [Colors.white, Colors.white, Color(0x8CFFFFFF), Colors.transparent],
            stops: [0, 0.70, 0.88, 1],
          ).createShader(r),
          blendMode: BlendMode.dstIn,
          child: SizedBox(
            key: const ValueKey('full-cover'),
            width: size.width,
            height: h,
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                alignment: Alignment.topCenter,
                child: CoverDrift(
                  on: Services.i.settings.animatedCover && !Services.i.settings.reduceMotion,
                  child: Artwork(item.thumbAt(1080), size: size.width, radius: 0),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Appearance → Animated cover art: a slow, endless drift and zoom.
class CoverDrift extends StatefulWidget {
  final bool on;
  final Widget child;
  const CoverDrift({super.key, required this.on, required this.child});
  @override
  State<CoverDrift> createState() => _CoverDriftState();
}

class _CoverDriftState extends State<CoverDrift> with SingleTickerProviderStateMixin {
  late final AnimationController c = AnimationController(vsync: this, duration: const Duration(seconds: 22));

  @override
  void initState() {
    super.initState();
    if (widget.on) c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(CoverDrift old) {
    super.didUpdateWidget(old);
    if (widget.on && !c.isAnimating) c.repeat(reverse: true);
    if (!widget.on && c.isAnimating) c.animateTo(0, duration: const Duration(milliseconds: 600), curve: Curves.easeOut);
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    child: widget.child,
    builder: (_, child) {
      final t = Curves.easeInOutSine.transform(c.value);
      return Transform(
        alignment: Alignment.center,
        transform: Matrix4.identity()
          ..translateByDouble(-6 + 12 * t, 4 - 8 * t, 0, 1)
          // always zoomed a little more than the drift moves, so no edge of
          // the picture ever shows (a 6 px dark strip at the right edge before 1.4.1)
          ..scaleByDouble(1.045 + 0.07 * t, 1.045 + 0.07 * t, 1, 1),
        child: child,
      );
    },
  );
}

/// The big cover: full-bleed (Full-screen cover art) or a rounded square.
class _SongArt extends StatelessWidget {
  final Item item;
  const _SongArt({super.key, required this.item});
  @override
  Widget build(BuildContext context) {
    final full = Services.i.settings.fullScreenCover;
    return LayoutBuilder(
      builder: (context, c) {
        // 1.4.5 QA: a short space (a phone turned sideways, a small window)
        // made clamp(120, <120) throw and the player drew an error box.
        final double hi = full ? math.max(0.0, c.maxHeight) : (c.maxHeight - 16).clamp(0.0, 620.0).toDouble();
        final double art = (full ? c.maxWidth : c.maxWidth - 48).clamp(math.min(120.0, hi), hi).toDouble();
        return StreamBuilder<PlaybackState>(
          stream: Services.i.player.playbackState,
          builder: (context, s) {
            final playing = s.data?.playing ?? false;
            return Center(
              child: AnimatedScale(
                scale: playing || full ? 1 : 0.88,
                duration: const Duration(milliseconds: 520),
                curve: Curves.easeOutBack,
                child: Hero(
                  tag: 'np-art',
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 420),
                    child: Container(
                      key: ValueKey('${item.id}$full'),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(full ? 0 : 14),
                        boxShadow: full
                            ? null
                            : [
                                BoxShadow(
                                  color: Colors.black.withValues(alpha: playing ? 0.45 : 0.25),
                                  blurRadius: playing ? 40 : 18,
                                  offset: const Offset(0, 16),
                                ),
                              ],
                      ),
                      child: full
                          ? ShaderMask(
                              shaderCallback: (r) => const LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [Colors.white, Colors.white, Colors.transparent],
                                stops: [0, 0.8, 1],
                              ).createShader(r),
                              blendMode: BlendMode.dstIn,
                              child: Artwork(item.thumbAt(1080), size: art, radius: 0),
                            )
                          : Artwork(item.thumbAt(1080), size: art, radius: 14),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Segments extends StatelessWidget {
  final NpTab value;
  final List<NpTab> options;
  final ValueChanged<NpTab> onChanged;
  const _Segments({required this.value, required this.onChanged, this.options = NpTab.values});
  @override
  Widget build(BuildContext context) {
    String label(NpTab t) => switch (t) {
      NpTab.song => 'Song',
      NpTab.lyrics => 'Lyrics',
      NpTab.queue => 'Up next',
    };
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: LiquidGlass(
        radius: BorderRadius.circular(22),
        dark: true,
        child: Container(
        padding: const EdgeInsets.all(3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              GestureDetector(
                onTap: () {
                  HapticFeedback.selectionClick();
                  onChanged(o);
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: value == o ? Colors.white.withValues(alpha: 0.9) : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text(
                    label(o),
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: value == o ? Colors.black : Colors.white),
                  ),
                ),
              ),
          ],
        ),
      ),
      ),
    );
  }
}

/// One quiet line under the title: party, offline copy.
class _SongStatus extends StatelessWidget {
  const _SongStatus();
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    return ListenableBuilder(
      listenable: Listenable.merge([s.party, s.library, s.player.current]),
      builder: (context, _) {
        final it = s.player.current.value;
        String? text;
        IconData? icon;
        if (s.party.active) {
          text = 'Listening together · ${s.party.code} · ${s.party.people.length}';
          icon = Icons.people_rounded;
        } else if (it != null && it.isDav) {
          text = 'From your server';
          icon = Icons.dns_rounded;
        } else if (it != null && it.isLocal) {
          text = 'On this phone';
          icon = Icons.phone_iphone_rounded;
        } else if (it != null && s.library.isDownloaded(it.id)) {
          text = 'Downloaded';
          icon = Icons.download_done_rounded;
        }
        if (text == null) return const SizedBox(height: 4);
        return Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            children: [
              Icon(icon, size: 14, color: Colors.white60),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: Colors.white60, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Settings → Advanced → Stats for nerds.
class _NerdStats extends StatelessWidget {
  const _NerdStats();
  @override
  Widget build(BuildContext context) {
    final h = Services.i.player;
    return ValueListenableBuilder(
      valueListenable: h.currentStream,
      builder: (context, st, _) {
        final it = h.current.value;
        String line;
        if (it != null && it.isLocal) {
          line = '${it.isDav ? 'Your server' : 'Local file'} · ${it.id.split('.').last.toUpperCase()}';
        } else if (st == null) {
          line = it != null && Services.i.library.isDownloaded(it.id) ? 'Downloaded file' : 'Loading stream…';
        } else {
          final codec = RegExp(r'codecs="([^"]+)"').firstMatch(st.mime)?.group(1) ?? st.mime;
          final kb = (st.bitrate / 1000).round();
          final size = st.contentLength == null ? '' : ' · ${(st.contentLength! / 1048576).toStringAsFixed(1)} MB';
          final loud = st.loudnessDb == null ? '' : ' · ${st.loudnessDb!.toStringAsFixed(1)} dB';
          line = '${codec.toUpperCase()} · $kb kbps · itag ${st.itag}$size$loud · ${st.client}';
        }
        return Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, color: Colors.white54, fontFeatures: [FontFeature.tabularFigures()]),
          ),
        );
      },
    );
  }
}

class _TitleRow extends StatelessWidget {
  final Item item;
  const _TitleRow({required this.item});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Marquee(
                text: item.title,
                style: t.titleLarge!.copyWith(fontWeight: FontWeight.w700, fontSize: 21, letterSpacing: -0.2, color: Colors.white),
              ),
              const SizedBox(height: 2),
              GestureDetector(
                onTap: () {
                  final a = item.artists.where((a) => a.id != null).firstOrNull;
                  if (a == null) return;
                  Navigator.pop(context);
                  openItemFromRoot(context, Item(kind: ItemKind.artist, id: a.id!, title: a.name));
                },
                child: Text(
                  item.artistLine.isEmpty ? (item.album ?? '') : item.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleMedium!.copyWith(color: Colors.white70, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        // 1.4.4 (Apurba, 6:26 PM): a heart to the left of ⋯, same size as ⋯.
        LikeButton(key: const ValueKey('np-like'), item: item, size: 20, round: true),
        const SizedBox(width: 8),
        _RoundBtn(key: const ValueKey('np-more'), icon: Icons.more_horiz_rounded, tooltip: 'More', onTap: () => showPlayerMore(context, item)),
      ],
    );
  }
}

/// Opens a page in the current tab after the player sheet closes.
void Function(BuildContext, Item) openItemFromRoot = (context, item) {};

/// What the like control says (tooltip + screen reader), shared everywhere.
const likeLabel = 'Like';
const unlikeLabel = 'Remove from Liked';

/// The Like heart: outline when not liked, a filled brand-red heart when
/// liked. It reads and writes the same liked state as ⋯ → Like and the
/// Liked Songs page (Library.setLiked, synced with the "likes" box), so it
/// flips at once when the song changes or the song is liked elsewhere.
/// A tap pops the heart (scale 1 → 1.3 → 1) with a light haptic; with
/// system animations off it just switches.
class LikeButton extends StatefulWidget {
  final Item item;
  final double size;

  /// A heart in a soft round 36 px glass button (the player, beside ⋯).
  final bool round;
  const LikeButton({super.key, required this.item, this.size = 28, this.round = false});
  @override
  State<LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<LikeButton> with SingleTickerProviderStateMixin {
  late final AnimationController _pop = AnimationController(vsync: this, duration: const Duration(milliseconds: 360));
  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.32).chain(CurveTween(curve: Curves.easeOut)), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.32, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)), weight: 60),
  ]).animate(_pop);

  @override
  void dispose() {
    _pop.dispose();
    super.dispose();
  }

  void _tap() {
    HapticFeedback.lightImpact();
    if (!(MediaQuery.maybeDisableAnimationsOf(context) ?? false)) _pop.forward(from: 0);
    Services.i.library.toggleLike(widget.item);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Services.i.library,
      builder: (context, _) {
        final liked = Services.i.library.isLiked(widget.item.id);
        final label = liked ? unlikeLabel : likeLabel;
        final heart = ScaleTransition(
          scale: _scale,
          child: Icon(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            key: ValueKey(liked),
            size: widget.size,
            color: liked ? ByteColors.pink : (widget.round ? Colors.white : null),
          ),
        );
        if (widget.round) {
          return Tooltip(
            message: label,
            child: Semantics(
              button: true,
              toggled: liked,
              label: label,
              excludeSemantics: true,
              child: InkResponse(
                radius: 22,
                onTap: _tap,
                child: LiquidGlass(
                  radius: BorderRadius.circular(18),
                  dark: true,
                  child: SizedBox(width: 36, height: 36, child: Center(child: heart)),
                ),
              ),
            ),
          );
        }
        return IconButton(tooltip: label, onPressed: _tap, icon: heart);
      },
    );
  }
}

/// Scrolls a title that doesn't fit, gently, then pauses.
class Marquee extends StatefulWidget {
  final String text;
  final TextStyle style;
  const Marquee({super.key, required this.text, required this.style});
  @override
  State<Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<Marquee> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this);
  double overflow = 0;
  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final tp = TextPainter(
          text: TextSpan(text: widget.text, style: widget.style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout();
        final over = tp.width - c.maxWidth;
        if (over <= 0) {
          if (a.isAnimating) a.stop();
          return Text(widget.text, maxLines: 1, style: widget.style);
        }
        if (over != overflow) {
          overflow = over;
          final secs = 3 + over / 30;
          a
            ..duration = Duration(milliseconds: (secs * 1000).round())
            ..repeat();
        }
        return ClipRect(
          child: SizedBox(
            height: tp.height,
            child: AnimatedBuilder(
              animation: a,
              builder: (context, _) {
                // pause 25% at the start, scroll, pause, jump back
                final v = a.value;
                final p = v < 0.25 ? 0.0 : (v < 0.8 ? Curves.easeInOut.transform((v - 0.25) / 0.55) : 1.0);
                return Transform.translate(
                  offset: Offset(-p * (over + 8), 0),
                  child: OverflowBox(
                    alignment: Alignment.centerLeft,
                    maxWidth: double.infinity,
                    child: Text(widget.text, maxLines: 1, style: widget.style),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class SeekBar extends StatefulWidget {
  final bool compact;
  const SeekBar({super.key, this.compact = false});
  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  Timer? _t;
  double? _drag;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted && _drag == null) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    final dur = (p.duration?.inMilliseconds ?? 0).toDouble();
    final pos = _drag ?? p.clock.nowMs.toDouble().clamp(0.0, dur <= 0 ? 0.0 : dur);
    final buffered = p.activePlayer.bufferedPosition.inMilliseconds.toDouble().clamp(0.0, dur <= 0 ? 0.0 : dur);
    final small = Theme.of(context).textTheme.bodySmall!.copyWith(color: Colors.white70, fontFeatures: const [FontFeature.tabularFigures()]);
    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            // 1.4.1, like the reference: a thin white bar, the knob only while dragging
            trackHeight: _drag != null ? 10 : 6,
            activeTrackColor: Colors.white.withValues(alpha: 0.92),
            inactiveTrackColor: Colors.white.withValues(alpha: 0.22),
            secondaryActiveTrackColor: Colors.white.withValues(alpha: 0.34),
            thumbColor: Colors.white,
            thumbShape: _drag != null ? const RoundSliderThumbShape(enabledThumbRadius: 8, elevation: 2) : SliderComponentShape.noThumb,
            overlayShape: SliderComponentShape.noOverlay,
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: SizedBox(
            height: 24,
            child: Slider(
              value: dur <= 0 ? 0 : pos,
              secondaryTrackValue: dur <= 0 ? 0 : buffered,
              max: dur <= 0 ? 1 : dur,
              onChangeStart: (v) => setState(() => _drag = v),
              onChanged: (v) => setState(() => _drag = v),
              onChangeEnd: (v) {
                p.seek(Duration(milliseconds: v.round()));
                setState(() => _drag = null);
              },
            ),
          ),
        ),
        if (!widget.compact)
          Row(
            children: [
              Text(fmtDuration(pos ~/ 1000), style: small),
              const Spacer(),
              ValueListenableBuilder<bool>(
                valueListenable: p.loading,
                builder: (c, l, _) =>
                    l ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.white70)) : const SizedBox(),
              ),
              const Spacer(),
              Text(dur <= 0 ? '--:--' : '-${fmtDuration(((dur - pos) / 1000).ceil())}', style: small),
            ],
          ),
      ],
    );
  }
}

class PlayPauseButton extends StatefulWidget {
  final double size;
  final bool filled;

  /// A red-pink disc from the logo with a white icon (player, mini player).
  final bool brand;
  const PlayPauseButton({super.key, this.size = 72, this.filled = true, this.brand = false, this.plain = false, this.color});

  /// A big glyph with no circle (the full player and mini player, like the video).
  final bool plain;

  /// The plain glyph's colour (white in the player).
  final Color? color;
  @override
  State<PlayPauseButton> createState() => _PlayPauseButtonState();
}

class _PlayPauseButtonState extends State<PlayPauseButton> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  StreamSubscription? sub;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    final st = Services.i.player.playbackState.value;
    a.value = st.playing ? 1 : 0;
    sub = Services.i.player.playbackState.listen((s) {
      s.playing ? a.forward() : a.reverse();
      final l = s.processingState == AudioProcessingState.loading || s.processingState == AudioProcessingState.buffering;
      if (l != loading && mounted) setState(() => loading = l);
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    final cs = Theme.of(context).colorScheme;
    final fg = widget.plain ? (widget.color ?? Colors.white) : widget.brand ? Colors.white : (widget.filled ? Colors.black : (Theme.of(context).iconTheme.color ?? cs.onSurface));
    return Semantics(
      button: true,
      label: 'Play or pause',
      child: GestureDetector(
        onTap: () {
          HapticFeedback.lightImpact();
          p.playing ? p.pause() : p.play();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: widget.size,
          height: widget.size,
          decoration: widget.plain
              ? null
              : widget.brand
              ? BoxDecoration(
                  gradient: ByteColors.logoGradient,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: ByteColors.red.withValues(alpha: 0.35), blurRadius: widget.size * 0.3, offset: Offset(0, widget.size * 0.08))],
                )
              : (widget.filled ? const BoxDecoration(color: Colors.white, shape: BoxShape.circle) : null),
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedIcon(icon: AnimatedIcons.play_pause, progress: a, size: widget.size * (widget.plain ? 0.78 : 0.5), color: fg),
              if (loading)
                SizedBox(
                  width: widget.size * 0.92,
                  height: widget.size * 0.92,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: widget.brand || widget.plain ? Colors.white70 : (widget.filled ? Colors.black26 : fg.withValues(alpha: 0.5)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Previous · play/pause · next (shuffle and repeat live in the queue's pill).
class _MainControls extends StatelessWidget {
  const _MainControls();
  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        IconButton(tooltip: 'Previous', iconSize: 48, color: Colors.white, onPressed: p.skipToPrevious, icon: const Icon(Icons.fast_rewind_rounded)),
        const PlayPauseButton(plain: true, size: 76),
        IconButton(tooltip: 'Next', iconSize: 48, color: Colors.white, onPressed: p.skipToNext, icon: const Icon(Icons.fast_forward_rounded)),
      ],
    );
  }
}

/// Playback speed (opened from the player).
void showSpeedSheet(BuildContext context) {
  showByteSheet(
    context: context,
    builder: (c) => ListenableBuilder(
      listenable: Services.i.settings,
      builder: (c, _) {
        final v = Services.i.settings.speed;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Playback speed  ${v.toStringAsFixed(2)}×', style: Theme.of(c).textTheme.titleMedium),
                Slider(value: v, min: 0.5, max: 2.0, divisions: 30, onChanged: (x) => Services.i.player.setSpeed(x)),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final s in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
                      ChoiceChip(label: Text('$s×'), selected: (v - s).abs() < 0.01, onSelected: (_) => Services.i.player.setSpeed(s)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

void showSleepSheet(BuildContext context) {
  final p = Services.i.player;
  showByteSheet(
    context: context,
    isScrollControlled: true,
    builder: (c) {
      final (mode, at) = p.sleep.value;
      // Scrolls on short screens (nine choices overflowed half a phone screen).
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                mode == SleepMode.timer && at != null
                    ? 'Stops in ${at.difference(DateTime.now()).inMinutes + 1} min'
                    : mode == SleepMode.endOfTrack
                    ? 'Stops at the end of this song'
                    : 'Sleep timer',
                style: Theme.of(c).textTheme.titleMedium,
              ),
              for (final m in [5, 10, 15, 30, 45, 60, 90])
                ListTile(
                  title: Text('$m minutes'),
                  onTap: () {
                    p.setSleepTimer(Duration(minutes: m));
                    Navigator.pop(c);
                    toast(context, 'Music stops in $m minutes');
                  },
                ),
              ListTile(
                title: const Text('End of this song'),
                onTap: () {
                  p.sleepAtEndOfTrack();
                  Navigator.pop(c);
                },
              ),
              if (mode != SleepMode.off)
                ListTile(
                  leading: const Icon(Icons.close_rounded),
                  title: const Text('Turn off timer'),
                  onTap: () {
                    p.setSleepTimer(null);
                    Navigator.pop(c);
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// The queue inside the player: Now playing, then "Next from …" with drag
/// handles and remove buttons.
class _QueuePage extends StatelessWidget {
  const _QueuePage({super.key});
  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    return AnimatedBuilder(
      animation: Listenable.merge([p.queueVersion, p.current, p.radioLoading, p.partyUpNext]),
      builder: (context, _) {
        final cur = p.current.value;
        final items = p.queueModel.playOrder;
        final pos = p.queueModel.position.clamp(0, items.isEmpty ? 0 : items.length - 1);
        // Played songs: hidden, or the last 25 with "Show queue history".
        final start = Services.i.settings.showQueueHistory ? (pos - 25).clamp(0, pos) : pos + 1;
        final rest = items.length - start.clamp(0, items.length);
        const label = TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w700);
        final from = p.playingFrom.value;
        // 1.4.5: a party guest sees the host's next songs; with autoplay on
        // the queue is never "Nothing next" (a loading row while they come).
        final party = p.partyUpNext.value;
        final upcoming = rest - (start <= pos ? pos - start + 1 : 0);
        final autoplay = Services.i.settings.autoplay && cur != null && !cur.isLocal;
        final firstNext = pos + 1 < items.length ? items[pos + 1] : null;
        final String heading;
        if (party != null) {
          heading = 'Next in the party';
        } else if (upcoming <= 0 && rest <= 0) {
          heading = autoplay ? 'Similar songs next' : 'Nothing next';
        } else if (from == null && firstNext != null && p.isRadioPick(firstNext.id)) {
          heading = 'Similar songs next';
        } else {
          heading = from == null ? 'Next up' : 'Next from: $from';
        }
        final showLoading = party != null ? party.isEmpty : (upcoming <= 0 && autoplay);
        if (showLoading && party == null) WidgetsBinding.instance.addPostFrameCallback((_) => p.topUpRadio());
        return CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(20, 8, 20, 6),
                child: Text(
                  'Queue',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800),
                ),
              ),
            ),
            if (cur != null) ...[
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 2),
                  child: Text('Now playing', style: label),
                ),
              ),
              SliverToBoxAdapter(child: _QueueRow(item: cur, playing: true)),
            ],
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
                child: Row(
                  children: [
                    Flexible(child: Text(heading, maxLines: 1, overflow: TextOverflow.ellipsis, style: label)),
                    if (party == null && autoplay && heading == 'Similar songs next') ...[
                      const SizedBox(width: 6),
                      const Icon(Icons.all_inclusive_rounded, size: 15, color: Colors.white60),
                    ],
                  ],
                ),
              ),
            ),
            if (party != null)
              SliverList.builder(
                itemCount: party.length,
                itemBuilder: (c, i) => _QueueRow(item: party[i], readOnly: true),
              )
            else if (rest > 0)
              SliverReorderableList(
                itemCount: rest,
                onReorderItem: (a, b) => p.moveQueueItem(a + start, b + start),
                itemBuilder: (c, row) {
                  final i = row + start;
                  final it = items[i];
                  return Dismissible(
                    key: ValueKey('q-${it.id}-$i'),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) => p.removeFromQueue(i),
                    background: Container(
                      color: Colors.red.withValues(alpha: 0.3),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete_outline_rounded),
                    ),
                    child: Opacity(
                      opacity: i < pos ? 0.5 : 1,
                      child: _QueueRow(item: it, index: i, row: row),
                    ),
                  );
                },
              ),
            if (showLoading)
              SliverToBoxAdapter(
                child: _QueueLoadingRow(text: party != null ? 'Getting the host\'s next songs…' : 'Finding similar songs…'),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

/// "Finding similar songs…" while up next is on its way.
class _QueueLoadingRow extends StatelessWidget {
  final String text;
  const _QueueLoadingRow({required this.text});
  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return Padding(
      key: const ValueKey('queue-loading'),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 6),
      child: Row(
        children: [
          SizedBox(
            width: 46,
            height: 46,
            child: Center(
              child: reduce
                  ? const Icon(Icons.hourglass_empty_rounded, color: Colors.white54, size: 20)
                  : const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54)),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  final Item item;
  final bool playing;
  final int? index; // position in the play order
  final int? row; // row in the reorderable list
  final bool readOnly; // the host's list on a party guest
  const _QueueRow({required this.item, this.playing = false, this.index, this.row, this.readOnly = false});
  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: index == null ? null : () => p.skipToQueueItem(index!),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
          child: Row(
            children: [
              if (row != null)
                ReorderableDragStartListener(
                  index: row!,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle_rounded, color: Colors.white54),
                  ),
                )
              else
                const SizedBox(width: 12),
              Artwork(item.thumb, size: 46, radius: 6),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: playing ? FontWeight.w800 : FontWeight.w600, color: Colors.white),
                    ),
                    Text(
                      item.artistLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              if (playing)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.graphic_eq_rounded, color: Colors.white),
                )
              else if (readOnly)
                const SizedBox(width: 12)
              else
                IconButton(
                  tooltip: 'Remove from queue',
                  onPressed: index == null ? null : () => p.removeFromQueue(index!),
                  icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 20),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
