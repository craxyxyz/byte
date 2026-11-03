import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../ui/glass.dart' show GlassEdgePainter;
import 'lock_player.dart';

/// Asks covers at a size that stays sharp when the art fills the screen.
String hiResArt(String url, {int px = 1080}) {
  final r = RegExp(r'=w\d+-h\d+');
  if (r.hasMatch(url)) return url.replaceFirst(r, '=w$px-h$px');
  final s = RegExp(r'=s\d+');
  if (s.hasMatch(url)) return url.replaceFirst(s, '=s$px');
  return url;
}

/// The cover: the square file Byte keeps on the phone for the lock screen
/// (the same one the system media panel shows), else the web picture.
ImageProvider defaultLockImage(String url) {
  if (url.startsWith('file:')) return FileImage(File(Uri.parse(url).toFilePath()));
  if (url.startsWith('/')) return FileImage(File(url));
  return NetworkImage(url);
}

const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _months = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

String lockDate(DateTime d) => '${_weekdays[d.weekday - 1]}, ${d.day} ${_months[d.month - 1]}';
String lockDateShort(DateTime d) => '${_weekdays[d.weekday - 1].substring(0, 3)} ${d.day} ${_months[d.month - 1].substring(0, 3)}';
String lockTime(DateTime d, {bool h24 = false}) {
  final m = d.minute.toString().padLeft(2, '0');
  if (h24) return '${d.hour.toString().padLeft(2, '0')}:$m';
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '$h:$m';
}

String _fmt(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, x = (s % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$x' : '$m:$x';
}

/// Byte's own lock-screen player: clock, a small card with the song, and the
/// controls. Tap the artwork and it grows into a big full-width cover (the
/// controls move under it); tap again and it shrinks back. Swipe up unlocks,
/// swipe down hides the player.
class LockScreenView extends StatefulWidget {
  final LockPlayer player;
  final VoidCallback? onUnlock;
  final VoidCallback? onHide;
  final ImageProvider Function(String url) image;
  final DateTime Function() now;
  final bool initiallyExpanded;
  final Duration animation;
  const LockScreenView({
    super.key,
    required this.player,
    this.onUnlock,
    this.onHide,
    this.image = defaultLockImage,
    this.now = DateTime.now,
    this.initiallyExpanded = false,
    this.animation = const Duration(milliseconds: 420),
  });

  @override
  State<LockScreenView> createState() => LockScreenViewState();
}

class LockScreenViewState extends State<LockScreenView> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.animation, value: widget.initiallyExpanded ? 1 : 0);
  late final CurvedAnimation _curve = CurvedAnimation(parent: _c, curve: Curves.easeInOutCubic);
  Timer? _tick;
  Timer? _minute;
  double _dragDy = 0;
  double? _scrub; // 0..1 while the progress bar is being dragged

  /// Whether the big artwork is showing (or growing).
  bool get expanded => _c.status == AnimationStatus.forward || _c.status == AnimationStatus.completed;

  /// 0 = small card, 1 = big artwork.
  double get progress => _c.value;

  void toggle() {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.value = expanded ? 0 : 1;
      return;
    }
    expanded ? _c.reverse() : _c.forward();
  }

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_onPlayer);
    _onPlayer();
    _armMinute();
  }

  @override
  void didUpdateWidget(LockScreenView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.player != widget.player) {
      oldWidget.player.removeListener(_onPlayer);
      widget.player.addListener(_onPlayer);
      _onPlayer();
    }
  }

  void _onPlayer() {
    final playing = widget.player.state.playing;
    if (playing && _tick == null) {
      _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } else if (!playing) {
      _tick?.cancel();
      _tick = null;
    }
    if (mounted) setState(() {});
  }

  void _armMinute() {
    final n = widget.now();
    final wait = Duration(seconds: 60 - n.second, milliseconds: -n.millisecond);
    _minute = Timer(wait < Duration.zero ? const Duration(seconds: 1) : wait, () {
      if (!mounted) return;
      setState(() {});
      _armMinute();
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _minute?.cancel();
    widget.player.removeListener(_onPlayer);
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  /// How bright the poster is (0..1): a bright poster gets a deeper shade
  /// behind the clock and controls so the white text always reads.
  double _lum = 0.4;
  Object? _lumFor;

  void _measure(ImageProvider? art) {
    if (art == null || identical(art, _lumFor) || _lumFor == art) return;
    _lumFor = art;
    final stream = ResizeImage(art, width: 8, height: 8).resolve(ImageConfiguration.empty);
    late ImageStreamListener l;
    l = ImageStreamListener(
      (info, _) async {
        stream.removeListener(l);
        try {
          final d = await info.image.toByteData(format: ui.ImageByteFormat.rawRgba);
          if (d == null || !mounted) return;
          var sum = 0.0;
          final n = d.lengthInBytes ~/ 4;
          for (var i = 0; i < n; i++) {
            sum += (0.2126 * d.getUint8(i * 4) + 0.7152 * d.getUint8(i * 4 + 1) + 0.0722 * d.getUint8(i * 4 + 2)) / 255;
          }
          if (mounted) setState(() => _lum = sum / n);
        } catch (_) {}
      },
      onError: (_, _) => stream.removeListener(l),
    );
    stream.addListener(l);
  }

  /// Extra shade for bright posters (0 for dark ones).
  double get shade => ((_lum - 0.45) / 0.55).clamp(0.0, 1.0) * 0.35;

  ImageProvider? _art(LockTrack? t) {
    if (t == null) return null;
    if (t.artBytes != null) return MemoryImage(t.artBytes!);
    final u = t.artUrl;
    if (u == null || u.isEmpty) return null;
    return widget.image(hiResArt(u));
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final st = widget.player.state;
    final art = _art(st.track);
    _measure(art);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onVerticalDragStart: (_) => _dragDy = 0,
      onVerticalDragUpdate: (d) => _dragDy += d.delta.dy,
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (_dragDy < -90 || v < -600) {
          widget.onUnlock?.call();
        } else if (_dragDy > 120 || v > 900) {
          widget.onHide?.call();
        }
      },
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, _) => LayoutBuilder(builder: (context, box) => _layout(context, box.biggest, mq.padding, st, art, _curve.value)),
      ),
    );
  }

  Widget _layout(BuildContext context, Size size, EdgeInsets pad, LockSnapshot st, ImageProvider? art, double t) {
    final w = size.width, h = size.height;
    final now = widget.now();
    final h24 = MediaQuery.maybeAlwaysUse24HourFormatOf(context) ?? false;
    final hasVolume = st.volume != null;
    final ctrlH = 34.0 + 64 + (hasVolume ? 40 : 0);
    final bottomGap = pad.bottom + 70; // room for "swipe up to unlock"

    // Small: a glass card near the bottom.
    final cardW = math.min(w - 20, 520.0);
    final cardH = 16 + 56 + 14 + ctrlH + 8;
    final card = Rect.fromLTWH((w - cardW) / 2, h - bottomGap - cardH, cardW, cardH);
    final artS = Rect.fromLTWH(card.left + 16, card.top + 16, 56, 56);
    final titleS = Rect.fromLTRB(artS.right + 14, artS.top, card.right - 16, artS.bottom);
    final ctrlS = Rect.fromLTWH(card.left + 16, artS.bottom + 14, cardW - 32, ctrlH);

    // Big: the poster edge to edge from the top, no box around it; its lower
    // part fades into the blurred-poster background and the song sits on
    // the fade, controls under it.
    final artH = math.max(120.0, math.min(w, h - bottomGap - ctrlH - 40));
    final artB = Rect.fromLTWH(0, 0, w, artH);
    final titleB = Rect.fromLTWH(20, artB.bottom - 24, w - 40, 64);
    final ctrlB = Rect.fromLTWH(20, titleB.bottom, w - 40, ctrlH);

    final artR = Rect.lerp(artS, artB, t)!;
    final titleR = Rect.lerp(titleS, titleB, t)!;
    final ctrlR = Rect.lerp(ctrlS, ctrlB, t)!;
    const white = Colors.white;
    final shadow = [Shadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 12)];

    return Stack(
      children: [
        // Background: the cover, blurred into its own colours.
        const Positioned.fill(child: ColoredBox(color: Color(0xFF1E1D24))),
        if (art != null)
          Positioned.fill(
            child: ImageFiltered(
              // the whole screen is the poster, lightly blurred, so the art
              // and the background are one picture in the poster's colours
              key: const ValueKey('lock-bg-poster'),
              imageFilter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22, tileMode: TileMode.clamp),
              child: Transform.scale(
                scale: 1.12,
                child: Image(image: art, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox()),
              ),
            ),
          ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: ui.lerpDouble(0.22, 0.10, t)! + shade),
                  Colors.black.withValues(alpha: (ui.lerpDouble(0.50, 0.55, t)! + shade).clamp(0.0, 0.9)),
                ],
              ),
            ),
          ),
        ),
        // Clock: big and centred with the small card, a compact row with the big cover.
        Positioned(
          left: 0,
          right: 0,
          top: pad.top + 30 - 24 * t,
          child: IgnorePointer(
            child: Opacity(
              opacity: (1 - t * 1.6).clamp(0.0, 1.0),
              child: Column(
                key: const ValueKey('lock-clock-big'),
                children: [
                  Text(
                    lockDate(now),
                    style: TextStyle(color: white.withValues(alpha: 0.85), fontSize: 18, fontWeight: FontWeight.w600, shadows: shadow),
                  ),
                  Text(
                    lockTime(now, h24: h24),
                    style: TextStyle(color: white, fontSize: 96, height: 1.05, fontWeight: FontWeight.w700, letterSpacing: -2, shadows: shadow),
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: 22,
          right: 22,
          top: pad.top + 22,
          child: IgnorePointer(
            child: Opacity(
              opacity: ((t - 0.4) / 0.6).clamp(0.0, 1.0),
              child: Row(
                key: const ValueKey('lock-clock-small'),
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    lockTime(now, h24: h24),
                    style: TextStyle(color: white, fontSize: 38, fontWeight: FontWeight.w700, letterSpacing: -1, shadows: shadow),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    lockDateShort(now),
                    style: TextStyle(color: white.withValues(alpha: 0.85), fontSize: 17, fontWeight: FontWeight.w600, shadows: shadow),
                  ),
                ],
              ),
            ),
          ),
        ),
        // The glass card (fades away as the cover grows).
        Positioned.fromRect(
          rect: card,
          child: IgnorePointer(
            child: Opacity(
              opacity: (1 - t).clamp(0.0, 1.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                  child: DecoratedBox(
                    key: const ValueKey('lock-glass-card'),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(26),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.center,
                        colors: [Colors.white.withValues(alpha: 0.14), Colors.white.withValues(alpha: 0)],
                      ),
                    ),
                    child: CustomPaint(
                      foregroundPainter: GlassEdgePainter(radius: BorderRadius.circular(26), dark: true),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        // Song title and artist.
        Positioned.fromRect(
          rect: titleR,
          child: Align(
            alignment: Alignment.lerp(Alignment.centerLeft, Alignment.topLeft, t)!,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  st.track?.title ?? 'Nothing playing',
                  key: const ValueKey('lock-title'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: white, fontSize: ui.lerpDouble(16, 21, t), fontWeight: FontWeight.w700),
                ),
                if (st.track?.artist != null)
                  Text(
                    st.track!.artist!,
                    key: const ValueKey('lock-artist'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: white.withValues(alpha: 0.72), fontSize: ui.lerpDouble(15, 18, t), fontWeight: FontWeight.w500),
                  ),
              ],
            ),
          ),
        ),
        // Progress, buttons, volume.
        Positioned.fromRect(rect: ctrlR, child: _controls(st)),
        // The artwork: tap to grow / shrink.
        Positioned.fromRect(
          rect: artR,
          child: GestureDetector(
            key: const ValueKey('lock-art'),
            onTap: toggle,
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(ui.lerpDouble(10, 0, t)!),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.18 * (1 - t)),
                    blurRadius: 8,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ShaderMask(
                key: const ValueKey('lock-art-fade'),
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.white, Colors.white.withValues(alpha: 1 - t)],
                  stops: const [0, 0.55, 1],
                ).createShader(r),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(ui.lerpDouble(10, 0, t)!),
                  child: art == null
                      ? ColoredBox(
                          color: Colors.white.withValues(alpha: 0.18),
                          child: FittedBox(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Icon(Icons.music_note_rounded, color: white.withValues(alpha: 0.8)),
                            ),
                          ),
                        )
                      : Image(
                          image: art,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.medium,
                          errorBuilder: (_, _, _) => ColoredBox(color: Colors.white.withValues(alpha: 0.18)),
                        ),
                ),
              ),
            ),
          ),
        ),
        // Swipe hint.
        Positioned(
          left: 0,
          right: 0,
          bottom: pad.bottom + 14,
          child: IgnorePointer(
            child: Column(
              children: [
                Text(
                  'Swipe up to unlock',
                  style: TextStyle(color: white.withValues(alpha: 0.75), fontSize: 13, fontWeight: FontWeight.w500, shadows: shadow),
                ),
                const SizedBox(height: 8),
                Container(
                  width: 132,
                  height: 5,
                  decoration: BoxDecoration(color: white.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(3)),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _controls(LockSnapshot st) {
    final p = widget.player;
    final dur = st.track?.duration;
    final pos = st.positionNow(widget.now());
    final frac = _scrub ?? (dur == null || dur.inMilliseconds == 0 ? 0.0 : (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0));
    final shown = dur == null ? pos : Duration(milliseconds: (frac * dur.inMilliseconds).round());
    const white = Colors.white;
    final dim = white.withValues(alpha: 0.6);
    return Column(
      children: [
        SizedBox(
          height: 20,
          child: LayoutBuilder(
            builder: (context, box) {
              double at(double dx) => (dx / box.maxWidth).clamp(0.0, 1.0);
              void end() {
                final f = _scrub;
                setState(() => _scrub = null);
                if (f != null && dur != null) p.seek(Duration(milliseconds: (f * dur.inMilliseconds).round()));
              }

              return GestureDetector(
                key: const ValueKey('lock-progress'),
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: dur == null ? null : (d) => setState(() => _scrub = at(d.localPosition.dx)),
                onHorizontalDragUpdate: dur == null ? null : (d) => setState(() => _scrub = at(d.localPosition.dx)),
                onHorizontalDragEnd: dur == null ? null : (_) => end(),
                onTapUp: dur == null
                    ? null
                    : (d) {
                        _scrub = at(d.localPosition.dx);
                        end();
                      },
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    height: _scrub == null ? 7 : 11,
                    decoration: BoxDecoration(color: white.withValues(alpha: 0.28), borderRadius: BorderRadius.circular(6)),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: frac,
                        heightFactor: 1,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: white.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        SizedBox(
          height: 14,
          child: Row(
            children: [
              Text(
                _fmt(shown),
                key: const ValueKey('lock-elapsed'),
                style: TextStyle(color: dim, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                dur == null ? '' : '-${_fmt(dur - shown)}',
                key: const ValueKey('lock-remaining'),
                style: TextStyle(color: dim, fontSize: 11.5, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 64,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                key: const ValueKey('lock-prev'),
                tooltip: 'Previous',
                iconSize: 40,
                color: white,
                onPressed: st.track == null ? null : p.previous,
                icon: const Icon(Icons.fast_rewind_rounded),
              ),
              IconButton(
                key: const ValueKey('lock-play'),
                tooltip: st.playing ? 'Pause' : 'Play',
                iconSize: 52,
                color: white,
                onPressed: st.track == null ? null : (st.playing ? p.pause : p.play),
                icon: Icon(st.playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
              ),
              IconButton(
                key: const ValueKey('lock-next'),
                tooltip: 'Next',
                iconSize: 40,
                color: white,
                onPressed: st.track == null ? null : p.next,
                icon: const Icon(Icons.fast_forward_rounded),
              ),
            ],
          ),
        ),
        if (st.volume != null)
          SizedBox(
            height: 40,
            child: Row(
              children: [
                Icon(Icons.volume_mute_rounded, size: 18, color: dim),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 7,
                      activeTrackColor: white.withValues(alpha: 0.92),
                      inactiveTrackColor: white.withValues(alpha: 0.28),
                      thumbColor: white,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 0, elevation: 0, pressedElevation: 0),
                      overlayShape: SliderComponentShape.noOverlay,
                    ),
                    child: Slider(key: const ValueKey('lock-volume'), value: st.volume!.clamp(0.0, 1.0), onChanged: p.setVolume),
                  ),
                ),
                Icon(Icons.volume_up_rounded, size: 18, color: dim),
              ],
            ),
          ),
      ],
    );
  }
}
