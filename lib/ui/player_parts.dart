import 'dart:async';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../cast/cast_controller.dart';
import '../core/models.dart';
import '../core/platform_caps.dart';
import '../data/audio_format.dart';
import '../lyrics/lrc.dart';
import 'lyrics_view.dart' show lyricsNowMs, lyricsInLook, defaultLookFor, LyricsLook, LyricsPane, playingDurationSec;
import '../player/audio_route.dart';
import '../player/byte_handler.dart';
import '../player/queue.dart' as q;
import '../services.dart';
import 'glyphs.dart';
import 'now_playing.dart' show showSleepSheet, showSpeedSheet;
import 'widgets.dart';
import 'glass.dart';
import 'screens/dj_screen.dart';

// ── Player pieces: volume, bottom row, output sheet, pipeline, Cast ───────

/// Speaker-small · slider · speaker-loud. Moves the phone's media volume.
class PlayerVolume extends StatefulWidget {
  const PlayerVolume({super.key});
  @override
  State<PlayerVolume> createState() => _PlayerVolumeState();
}

class _PlayerVolumeState extends State<PlayerVolume> {
  @override
  void initState() {
    super.initState();
    Services.i.route.watch();
  }

  @override
  void dispose() {
    Services.i.route.unwatch();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = Services.i.route;
    return Row(
      children: [
        const Icon(Icons.volume_down_rounded, size: 20, color: Colors.white70),
        const SizedBox(width: 6),
        Expanded(
          child: ByteVolumeSlider(
            key: const ValueKey('player-volume'),
            value: r.volumeShown,
            onDrag: r.dragging,
            onChanged: (x) => r.setVolume(x, playerVolume: Services.i.player.setAppVolume),
          ),
        ),
        const SizedBox(width: 6),
        const Icon(Icons.volume_up_rounded, size: 18, color: Colors.white70),
      ],
    );
  }
}

/// A drag that is ours the moment a finger touches the bar: no waiting to
/// learn whether the gesture is a scroll, so the bar follows the finger from
/// the first pixel (the player's swipe-down never steals it).
class _InstantDrag extends OneSequenceGestureRecognizer {
  void Function(Offset local)? onStart;
  void Function(Offset local)? onUpdate;
  VoidCallback? onEnd;
  _InstantDrag({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
    onStart?.call(event.localPosition);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      onUpdate?.call(event.localPosition);
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      onEnd?.call();
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'byte volume drag';
}

/// The player's volume bar: follows the finger with no lag (only this bar
/// repaints while dragging), grows a little while held like the reference
/// player, glides to the new level when the phone's buttons change it, and
/// can be nudged with accessibility actions.
class ByteVolumeSlider extends StatefulWidget {
  final ValueListenable<double> value;
  final ValueChanged<double> onChanged;
  final ValueChanged<bool>? onDrag;
  const ByteVolumeSlider({super.key, required this.value, required this.onChanged, this.onDrag});
  @override
  State<ByteVolumeSlider> createState() => ByteVolumeSliderState();
}

class ByteVolumeSliderState extends State<ByteVolumeSlider> with TickerProviderStateMixin {
  late final AnimationController _glide = AnimationController(vsync: this, duration: const Duration(milliseconds: 180));
  late final AnimationController _press = AnimationController(vsync: this, duration: const Duration(milliseconds: 140));
  late double _shown = widget.value.value;
  double _from = 0, _to = 0;
  bool _held = false;
  double _width = 1;
  double _grabOffset = 0;

  /// What the bar is drawing right now (for tests).
  double get shown => _shown;
  bool get held => _held;

  @override
  void initState() {
    super.initState();
    widget.value.addListener(_external);
    _glide.addListener(() {
      final t = Curves.easeOutCubic.transform(_glide.value);
      setState(() => _shown = _from + (_to - _from) * t);
    });
  }

  @override
  void didUpdateWidget(ByteVolumeSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      oldWidget.value.removeListener(_external);
      widget.value.addListener(_external);
    }
  }

  @override
  void dispose() {
    widget.value.removeListener(_external);
    _glide.dispose();
    _press.dispose();
    super.dispose();
  }

  void _external() {
    if (_held) return; // the finger wins
    final v = widget.value.value.clamp(0.0, 1.0);
    if ((v - _shown).abs() < 0.001) return;
    _from = _shown;
    _to = v;
    _glide.forward(from: 0);
  }

  double _valueAt(double dx) => ((dx - _grabOffset) / _width).clamp(0.0, 1.0);

  void _start(Offset p) {
    _glide.stop();
    _held = true;
    widget.onDrag?.call(true);
    _press.forward();
    // Touching the thumb grabs it where it is (no jump); touching the bar
    // elsewhere jumps there, like the phone's own slider.
    final thumbX = _shown * _width;
    _grabOffset = (p.dx - thumbX).abs() <= 22 ? p.dx - thumbX : 0;
    _set(_valueAt(p.dx));
  }

  void _update(Offset p) => _set(_valueAt(p.dx));

  void _end() {
    if (!_held) return;
    _held = false;
    _press.reverse();
    widget.onDrag?.call(false);
  }

  void _set(double v) {
    if ((v - _shown).abs() < 0.0005 && v != 0 && v != 1) return;
    setState(() => _shown = v);
    widget.onChanged(v);
  }

  void _nudge(double by) {
    final v = (_shown + by).clamp(0.0, 1.0);
    setState(() => _shown = v);
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final pct = (_shown * 100).round();
    return Semantics(
      slider: true,
      label: 'Volume',
      value: '$pct%',
      increasedValue: '${(pct + 10).clamp(0, 100)}%',
      decreasedValue: '${(pct - 10).clamp(0, 100)}%',
      onIncrease: () => _nudge(0.1),
      onDecrease: () => _nudge(-0.1),
      child: LayoutBuilder(
        builder: (context, c) {
          _width = c.maxWidth <= 0 ? 1 : c.maxWidth;
          return RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              _InstantDrag: GestureRecognizerFactoryWithHandlers<_InstantDrag>(
                () => _InstantDrag(debugOwner: this),
                (g) => g
                  ..onStart = _start
                  ..onUpdate = _update
                  ..onEnd = _end,
              ),
            },
            child: SizedBox(
              height: 36,
              width: double.infinity,
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: _press,
                  builder: (context, _) => CustomPaint(painter: _VolumePainter(_shown, Curves.easeOut.transform(_press.value))),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _VolumePainter extends CustomPainter {
  final double v;
  final double press; // 0 idle … 1 held
  _VolumePainter(this.v, this.press);

  @override
  void paint(Canvas canvas, Size size) {
    final h = 6 + 4 * press;
    final top = (size.height - h) / 2;
    final r = Radius.circular(h / 2);
    final track = RRect.fromLTRBR(0, top, size.width, top + h, r);
    canvas.drawRRect(track, Paint()..color = Colors.white.withValues(alpha: 0.22 + 0.06 * press));
    final w = (size.width * v).clamp(0.0, size.width);
    if (w > 0) {
      canvas.save();
      canvas.clipRRect(track);
      canvas.drawRect(Rect.fromLTWH(0, top, w, h), Paint()..color = Colors.white.withValues(alpha: 0.86 + 0.14 * press));
      canvas.restore();
    }
    if (press > 0.01) {
      final x = w.clamp(8.0, size.width - 8.0);
      canvas.drawCircle(Offset(x, size.height / 2), 8 * press, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_VolumePainter o) => o.v != v || o.press != press;
}

/// The player's three modes.
enum PlayerMode { song, lyrics, queue }

/// Lyrics · output (device name under it) · queue. In queue mode the middle
/// becomes a shuffle | repeat | ∞ pill.
class PlayerBottomRow extends StatelessWidget {
  final PlayerMode mode;
  final ValueChanged<PlayerMode> onMode;
  const PlayerBottomRow({super.key, required this.mode, required this.onMode});

  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    return ListenableBuilder(
      listenable: Listenable.merge([s.route, s.cast, s.settings, s.party]),
      builder: (context, _) {
        final casting = s.cast.connected;
        final label = casting ? (s.cast.device?.name ?? 'Cast') : s.route.info.label;
        final icon = casting
            ? Icons.cast_connected_rounded
            : switch (s.route.info.outputType) {
                'bluetooth' => Icons.bluetooth_audio_rounded,
                'wired' => Icons.headphones_rounded,
                'usb' => Icons.usb_rounded,
                _ => Icons.cast_rounded,
              };
        final middle = mode == PlayerMode.queue
            ? const QueueModesPill()
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (s.settings.showListenTogetherButton) ...[
                    _RoundIcon(
                      icon: s.party.active ? Icons.people_rounded : Icons.people_outline_rounded,
                      tooltip: 'Listen together',
                      on: s.party.active,
                      onTap: () => openListenTogether(context),
                    ),
                    const SizedBox(width: 18),
                  ],
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _RoundIcon(icon: icon, tooltip: 'Audio output', on: casting, onTap: () => showOutputSheet(context)),
                      const SizedBox(height: 2),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
              );
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _RoundIcon(
              icon: Icons.format_quote_rounded,
              lyricsGlyph: true,
              tooltip: 'Lyrics',
              on: mode == PlayerMode.lyrics,
              onTap: () => onMode(mode == PlayerMode.lyrics ? PlayerMode.song : PlayerMode.lyrics),
            ),
            Expanded(child: Center(child: middle)),
            _RoundIcon(
              icon: Icons.format_list_bulleted_rounded,
              tooltip: 'Queue',
              on: mode == PlayerMode.queue,
              onTap: () => onMode(mode == PlayerMode.queue ? PlayerMode.song : PlayerMode.queue),
            ),
          ],
        );
      },
    );
  }
}

/// Opens Listen Together (set by the player so this file needs no screen import).
void Function(BuildContext) openListenTogether = (_) {};

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool on;
  final VoidCallback onTap;
  final bool lyricsGlyph;
  const _RoundIcon({required this.icon, required this.tooltip, required this.on, required this.onTap, this.lyricsGlyph = false});
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      button: true,
      selected: on,
      label: tooltip,
      child: InkResponse(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        radius: 26,
        // 1.4.1, like the reference: plain icons on the background; the one
        // that is on gets a white rounded backing
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(color: on ? Colors.white : Colors.white.withValues(alpha: 0), borderRadius: BorderRadius.circular(14)),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: lyricsGlyph
                  ? LyricsGlyph(size: 28, color: on ? Colors.black : Colors.white.withValues(alpha: 0.9))
                  : Icon(icon, size: 28, color: on ? Colors.black : Colors.white.withValues(alpha: 0.9)),
            ),
          ),
        ),
      ),
    ),
  );
}

/// shuffle | repeat | ∞ (keep playing similar songs when the queue ends).
class QueueModesPill extends StatelessWidget {
  const QueueModesPill({super.key});
  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    return StreamBuilder<PlaybackState>(
      stream: p.playbackState,
      builder: (context, _) => ListenableBuilder(
        listenable: Services.i.settings,
        builder: (context, _) {
          final shuffle = p.queueModel.shuffle;
          final repeat = p.queueModel.repeat;
          final auto = Services.i.settings.autoplay;
          Widget seg(IconData i, String tip, bool on, VoidCallback tap) => Tooltip(
            message: tip,
            child: Semantics(
              button: true,
              selected: on,
              label: tip,
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () {
                  HapticFeedback.selectionClick();
                  tap();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 50,
                  height: 36,
                  decoration: BoxDecoration(color: on ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(18)),
                  child: Icon(i, size: 21, color: on ? Colors.black : Colors.white),
                ),
              ),
            ),
          );
          return LiquidGlass(
            radius: BorderRadius.circular(21),
            dark: true,
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  seg(Icons.shuffle_rounded, 'Shuffle', shuffle, () => p.setShuffleMode(shuffle ? AudioServiceShuffleMode.none : AudioServiceShuffleMode.all)),
                  seg(repeat == q.RepeatMode.one ? Icons.repeat_one_rounded : Icons.repeat_rounded, 'Repeat', repeat != q.RepeatMode.off, p.cycleRepeat),
                  seg(Icons.all_inclusive_rounded, 'Autoplay similar songs', auto, () => Services.i.settings.autoplay = !auto),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// "♫ Kesariya Radio ›" under the title; tap opens the queue.
class PlayerContextLine extends StatelessWidget {
  final VoidCallback onTap;
  const PlayerContextLine({super.key, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = Services.i.player;
    return ValueListenableBuilder<String?>(
      valueListenable: p.playingFrom,
      builder: (context, from, _) => ValueListenableBuilder<int>(
        valueListenable: p.queueVersion,
        builder: (context, _, _) {
          final next = p.queueModel.position + 1 < p.queueModel.playOrder.length ? p.queueModel.playOrder[p.queueModel.position + 1] : null;
          final text = from ?? (next != null ? 'Next: ${next.title}' : (Services.i.settings.autoplay ? 'Similar songs next' : 'End of queue'));
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.music_note_rounded, size: 15, color: Colors.white60),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white60, fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, size: 18, color: Colors.white60),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Song mode (1.4.1, like the reference player): ONE small line under the
/// title with the line being sung right now. The sung part of it fills in
/// bright white word by word, the rest stays dim, a small "›" sits after it,
/// and it swaps smoothly to the next line. Tap → full lyrics. It runs on the
/// very same clock (position, lead, per-song nudge) as the lyrics screen, so
/// both change line at the same moment.
class NextLyricLine extends StatefulWidget {
  final VoidCallback? onTap;

  /// Shown instead when the song has no synced lyrics (the "playing from" line).
  final Widget? fallback;
  const NextLyricLine({super.key, this.onTap, this.fallback});
  @override
  State<NextLyricLine> createState() => _NextLyricLineState();
}

class _NextLyricLineState extends State<NextLyricLine> with SingleTickerProviderStateMixin {
  Item? _for;
  bool _loading = false;
  late final Ticker _ticker;
  LyricsClock? _clock;

  /// Index of the line shown (-1 = before the first line: the first line, unlit).
  int _idx = -2;
  final ValueNotifier<int> _ms = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _tick());
    Services.i.player.current.addListener(_load);
    LyricsPane.reload.addListener(_reload);
    _load();
  }

  void _reload() {
    _for = null;
    _load();
  }

  @override
  void dispose() {
    Services.i.player.current.removeListener(_load);
    LyricsPane.reload.removeListener(_reload);
    _ticker.dispose();
    _ms.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final it = Services.i.player.current.value;
    if (it == null || it.id == _for?.id) return;
    if (_ticker.isActive) _ticker.stop();
    setState(() {
      _for = it;
      _clock = null;
      _loading = true;
      _idx = -2;
    });
    Lyrics l;
    try {
      l = await Services.i.lyrics.forItem(it, durationSec: playingDurationSec(it)).timeout(const Duration(seconds: 25));
    } catch (_) {
      l = const Lyrics.none();
    }
    if (!mounted || _for?.id != it.id) return;
    // the letters the person picked, same words; lyrics in another script
    // (Urdu, Hindi, Bengali…) show their Roman letters here (1.4.3)
    final look = l.kind == LyricsKind.synced ? defaultLookFor(l, Services.i.settings.lyricsScript) : LyricsLook.original;
    final shown = l.kind == LyricsKind.synced ? lyricsInLook(l, look) : l;
    setState(() {
      _clock = shown.kind == LyricsKind.synced && shown.lines.isNotEmpty
          ? LyricsClock(shown.lines, trackDurationMs: Services.i.player.duration?.inMilliseconds)
          : null;
      _loading = false;
    });
    _tick();
    if (_clock != null && !_ticker.isActive) _ticker.start();
    if (look == LyricsLook.dual) {
      // the spelling from a Roman-letter version of the song, when one matches
      try {
        final d = await Services.i.lyrics.dualFor(it, l).timeout(const Duration(seconds: 20));
        final r = d.roman;
        if (!mounted || _for?.id != it.id || r.lines.length != shown.lines.length) return;
        setState(() => _clock = LyricsClock(r.lines, trackDurationMs: Services.i.player.duration?.inMilliseconds));
      } catch (_) {}
    }
  }

  /// The sung line at [ms]: an instrumental break keeps the last sung line;
  /// before the first line, the first line (nothing lit yet).
  static int lineFor(LyricsClock c, int ms) {
    final i = c.indexAt(ms);
    for (var j = i; j >= 0; j--) {
      if (!c.lines[j].isBreak && c.lines[j].text.trim().isNotEmpty) return j;
    }
    for (var j = 0; j < c.lines.length; j++) {
      if (!c.lines[j].isBreak && c.lines[j].text.trim().isNotEmpty) return -1 - j;
    }
    return -1;
  }

  void _tick() {
    final c = _clock;
    if (!mounted || c == null) return;
    final ms = lyricsNowMs();
    final i = lineFor(c, ms);
    if (i != _idx) setState(() => _idx = i);
    _ms.value = ms;
  }

  @override
  Widget build(BuildContext context) {
    final c = _clock;
    if (!_loading && (c == null || _idx == -2)) return widget.fallback ?? const SizedBox(height: 24);
    final idx = _idx;
    final lineIdx = idx >= 0 ? idx : -1 - idx; // the line drawn
    final text = _loading || c == null ? 'Loading lyrics…' : c.lines[lineIdx].text.split('\n').first.trim();
    const style = TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500, height: 1.2, letterSpacing: -0.1);
    return Semantics(
      button: true,
      label: 'Lyrics: $text',
      child: GestureDetector(
        key: const ValueKey('mini-lyric'),
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: SizedBox(
          height: 24,
          child: ClipRect(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 380),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              // the old line slides up and fades while the new one rises in
              transitionBuilder: (child, a) {
                final incoming = child.key == ValueKey('l$lineIdx$text');
                return FadeTransition(
                  opacity: a,
                  child: SlideTransition(
                    position: Tween(begin: Offset(0, incoming ? 0.7 : -0.7), end: Offset.zero).animate(a),
                    child: child,
                  ),
                );
              },
              layoutBuilder: (cur, prev) => Stack(alignment: Alignment.centerLeft, children: [...prev, ?cur]),
              child: Row(
                key: ValueKey('l$lineIdx$text'),
                children: [
                  if (_loading) ...[
                    const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.white54)),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: _loading || c == null || idx < 0
                        ? Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style.copyWith(color: Colors.white.withValues(alpha: 0.5)))
                        : ValueListenableBuilder<int>(
                            valueListenable: _ms,
                            builder: (context, ms, _) => MiniLyricFill(text: text, fill: miniLineFill(c, idx, ms), style: style),
                          ),
                  ),
                  if (!_loading) Padding(padding: const EdgeInsets.only(left: 2), child: Icon(Icons.chevron_right_rounded, size: 18, color: Colors.white.withValues(alpha: 0.6))),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The mini line's pick at [ms] (see [_NextLyricLineState.lineFor]), for tests.
int debugMiniLineFor(LyricsClock c, int ms) => _NextLyricLineState.lineFor(c, ms);

/// 0..1: how much of line [i]'s letters are sung at [ms] (word by word, the
/// word being sung filling smoothly), from the same word timings as the
/// lyrics screen.
double miniLineFill(LyricsClock c, int i, int ms) {
  final fills = c.wordFill(i, ms + c.leadMs);
  final words = c.lines[i].words?.map((w) => w.text).toList() ?? splitWords(c.lines[i].text.split('\n').first);
  var total = 0, lit = 0.0;
  for (var w = 0; w < words.length; w++) {
    final n = words[w].length;
    total += n;
    lit += n * (w < fills.length ? fills[w] : 0);
  }
  return total == 0 ? 0 : (lit / total).clamp(0.0, 1.0);
}

/// One line of text, the first [fill] of its letters bright, the rest dim,
/// with a short soft edge between them. Measured, so the edge sits exactly on
/// the letters even when the line is cut with "…".
class MiniLyricFill extends StatelessWidget {
  final String text;
  final double fill;
  final TextStyle style;
  final double dimAlpha;
  const MiniLyricFill({super.key, required this.text, required this.fill, required this.style, this.dimAlpha = 0.42});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, cons) {
        final dir = Directionality.of(context);
        final scaler = MediaQuery.textScalerOf(context);
        // measure in the font the Text will really use (the app's font)
        final style = DefaultTextStyle.of(context).style.merge(this.style);
        final all = TextPainter(text: TextSpan(text: text, style: style), textDirection: dir, maxLines: 1, textScaler: scaler)..layout();
        final n = (text.length * fill).round().clamp(0, text.length);
        final pre = TextPainter(text: TextSpan(text: text.substring(0, n), style: style), textDirection: dir, maxLines: 1, textScaler: scaler)..layout();
        final shown = math.min(all.width, cons.maxWidth.isFinite ? cons.maxWidth : all.width);
        final edge = shown <= 0 ? 0.0 : (pre.width / shown).clamp(0.0, 1.0);
        final lit = style.color ?? Colors.white;
        final dim = lit.withValues(alpha: dimAlpha);
        const soft = 0.06;
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (r) => LinearGradient(
            colors: [lit, lit, dim, dim],
            stops: [0, (edge - soft / 2).clamp(0.0, 1.0), (edge + soft / 2).clamp(0.0, 1.0), 1],
          ).createShader(Rect.fromLTWH(0, 0, shown, r.height)),
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
        );
      },
    );
  }
}

// ── Output sheet ─────────────────────────────────────────────────────────

Future<void> showOutputSheet(BuildContext context) {
  final s = Services.i;
  s.route.watch();
  return showByteSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([s.route, s.cast, s.player.currentStream]),
        builder: (c, _) {
          final info = s.route.info;
          final casting = s.cast.connected;
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Audio output', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                _OutCard(
                  icon: info.onPhoneSpeaker ? Icons.phone_android_rounded : Icons.headphones_rounded,
                  title: info.label,
                  subtitle: casting ? info.outputKind : 'Playing here · ${info.outputKind}',
                  trailing: casting ? null : const Icon(Icons.check_rounded, color: Colors.white),
                  onTap: casting ? () => s.cast.disconnect() : () => s.route.openSoundSettings(),
                ),
                if (!onWeb) const SizedBox(height: 8),
                if (!onWeb)
                _OutCard(
                  icon: casting ? Icons.cast_connected_rounded : Icons.cast_rounded,
                  title: casting ? (s.cast.device?.name ?? 'Cast') : 'Cast',
                  subtitle: casting ? 'Playing here' : 'TVs and speakers that support casting',
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white70),
                  onTap: () => showCastDialog(c),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(16)),
                  child: const PlayerVolume(),
                ),
                const SizedBox(height: 8),
                _OutCard(
                  icon: Icons.graphic_eq_rounded,
                  title: 'Audio Pipeline',
                  subtitle: pipelineSummary(),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Colors.white70),
                  onTap: () => showPipelineDialog(c),
                ),
              ],
            ),
          );
        },
      ),
    ),
  ).whenComplete(s.route.unwatch);
}

class _OutCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  const _OutCard({required this.icon, required this.title, required this.subtitle, this.trailing, this.onTap});
  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white.withValues(alpha: 0.08),
    borderRadius: BorderRadius.circular(16),
    child: InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.12)),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 13),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    ),
  );
}

// ── Audio pipeline ───────────────────────────────────────────────────────

/// One stage of the signal path, as rows of label → value.
class PipeStage {
  final String name;
  final IconData icon;
  final List<(String, String)> rows;
  const PipeStage(this.name, this.icon, this.rows);
}

String _khz(int hz) => '${(hz / 1000).toStringAsFixed(hz % 1000 == 0 ? 0 : 1)} kHz';

/// The live path from the source to the speaker, from what Byte knows.
List<PipeStage> audioPipeline() {
  final s = Services.i;
  final it = s.player.current.value;
  final st = s.player.currentStream.value;
  final info = s.route.info;
  // addons say what they serve; files on the phone are read from their own header
  final fmt = it == null ? null : (s.addons.formats[it.id] ?? (it.isOnPhone ? AudioFormats.cached(it.id.substring(6)) : null));
  final outRate = info.sampleRate ?? 48000;
  String source;
  String format;
  int? srcRate;
  int bits = 16;
  int ch = 2;
  String? bitrate;
  if (fmt != null) {
    source = it!.isOnPhone ? 'This phone' : 'Addon';
    format = [(fmt.codec ?? '').toUpperCase(), ?fmt.badge].join(' · ');
    srcRate = fmt.sampleRate;
    bits = fmt.bitDepth ?? 16;
    ch = fmt.channels ?? 2;
    if (fmt.bitrate != null) bitrate = '${(fmt.bitrate! / 1000).round()} kbps';
  } else if (it != null && it.isLocal) {
    source = it.isSmb ? 'SMB share' : (it.isDav ? 'Your server' : 'This phone');
    format = it.id.split('.').last.toUpperCase();
  } else if (st != null) {
    source = s.library.isDownloaded(it?.id ?? '') ? 'Download' : 'Online';
    final codec = RegExp(r'codecs="([^"]+)"').firstMatch(st.mime)?.group(1) ?? st.mime;
    format = codec.toUpperCase();
    srcRate = 48000;
    bitrate = '${(st.bitrate / 1000).round()} kbps';
  } else {
    source = it == null ? '—' : 'Loading…';
    format = '—';
  }
  final rate = srcRate ?? 44100;
  final pcmRate = rate * bits * ch;
  final dsp = <String>[
    if (s.settings.normalizeVolume && !(s.settings.normalizeOffOnSpeaker && info.onPhoneSpeaker)) 'Loudness normalization',
    if (s.settings.eqEnabled) 'Equalizer (${s.settings.eqPreset})',
    if (s.settings.speed != 1.0) 'Speed ${s.settings.speed}×',
    if (s.settings.skipSilence) 'Skip silence',
    if (s.settings.crossfadeSeconds > 0) 'Crossfade ${s.settings.crossfadeSeconds.round()} s',
  ];
  return [
    PipeStage('Track info', Icons.music_note_rounded, [
      ('Source', source),
      ('Format', format),
      ('Bit Depth', '$bits-bit'),
      ('Sample Rate', srcRate == null ? '—' : _khz(srcRate)),
      if (bitrate != null) ('Bitrate', bitrate),
      ('PCM Data Rate', '${(pcmRate / 1000).toStringAsFixed(0)} kbps'),
      ('Channels', ch == 1 ? 'Mono' : (ch == 2 ? 'Stereo' : '$ch channels')),
    ]),
    PipeStage('Decoder', Icons.memory_rounded, [('Decoder Name', format == '—' ? '—' : 'Android media decoder ($format)')]),
    PipeStage('Resampler', Icons.swap_horiz_rounded, [
      ('I/O Rate', '${srcRate == null ? '—' : _khz(rate)} → ${_khz(outRate)}'),
      ('Type', rate == outRate ? 'Pass-through' : 'System resampler'),
    ]),
    PipeStage('DSP', Icons.tune_rounded, [('PCM Format', '16-bit PCM'), ('Effects', dsp.isEmpty ? 'None' : dsp.join(', '))]),
    PipeStage('Output', Icons.speaker_rounded, [
      ('Device', '${info.label} · ${info.outputKind}'),
      ('Sample Rate', _khz(outRate)),
      if (info.framesPerBuffer != null) ('Buffer', '${info.framesPerBuffer} frames'),
      ('Mode', s.settings.bitPerfect && info.outputType == 'usb' ? 'Bit-perfect' : '16-bit'),
    ]),
  ];
}

String pipelineSummary() {
  final s = Services.i;
  final info = s.route.info;
  final mode = s.settings.bitPerfect && info.outputType == 'usb' ? 'Bit-perfect' : '16-bit';
  return '$mode · ${_khz(info.sampleRate ?? 48000)}';
}

Future<void> showPipelineDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (c) => Dialog(
    backgroundColor: const Color(0xFF1C1C1E),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 440, maxHeight: MediaQuery.sizeOf(c).height * 0.8),
      child: ListenableBuilder(
        listenable: Listenable.merge([Services.i.route, Services.i.player.currentStream]),
        builder: (c, _) {
          final stages = audioPipeline();
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 22, 22, 2),
                child: Text(
                  'Audio Pipeline',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                ),
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 0, 22, 10),
                child: Text('Live signal path, decoder to output', style: TextStyle(color: Colors.white60)),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 0, 22, 8),
                  children: [
                    for (var i = 0; i < stages.length; i++)
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.12)),
                                  child: Icon(stages[i].icon, size: 18, color: Colors.white),
                                ),
                                if (i < stages.length - 1) Expanded(child: Container(width: 2, color: Colors.white24)),
                              ],
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 6, bottom: 14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      stages[i].name.toUpperCase(),
                                      style: const TextStyle(color: Colors.white60, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.6),
                                    ),
                                    const SizedBox(height: 4),
                                    for (final (k, v) in stages[i].rows)
                                      Padding(
                                        padding: const EdgeInsets.symmetric(vertical: 2),
                                        child: Row(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            SizedBox(
                                              width: 110,
                                              child: Text(k, style: const TextStyle(color: Colors.white70, fontSize: 13.5)),
                                            ),
                                            Expanded(
                                              child: Text(
                                                v,
                                                style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w600),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(46)),
                  onPressed: () => Navigator.pop(c),
                  child: const Text('Done'),
                ),
              ),
            ],
          );
        },
      ),
    ),
  ),
);

// ── Cast ────────────────────────────────────────────────────────────────

Future<void> showCastDialog(BuildContext context) {
  final cast = Services.i.cast;
  unawaited(cast.scan());
  return showDialog<void>(
    context: context,
    builder: (c) => Dialog(
      backgroundColor: const Color(0xFF1C1C1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: ListenableBuilder(
            listenable: cast,
            builder: (c, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Cast',
                  style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800),
                ),
                const Text('Play on a TV or speaker that supports casting', style: TextStyle(color: Colors.white60)),
                const SizedBox(height: 16),
                if (cast.connected)
                  _OutCard(
                    icon: Icons.cast_connected_rounded,
                    title: cast.device?.name ?? 'Cast',
                    subtitle: 'Connected · tap to stop casting',
                    onTap: () => cast.disconnect(),
                  ),
                for (final d in cast.devices.where((d) => d != cast.device))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _OutCard(
                      icon: Icons.speaker_rounded,
                      title: d.name,
                      subtitle: d.model ?? 'Cast device',
                      onTap: () async {
                        await cast.connect(d);
                        if (c.mounted && cast.connected) Navigator.pop(c);
                      },
                    ),
                  ),
                if (cast.scanning)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Column(
                      children: [
                        SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)),
                        SizedBox(height: 12),
                        Text(
                          'Looking for devices…',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                        Text(
                          'Make sure the phone and the speaker are on the same Wi-Fi.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 13),
                        ),
                      ],
                    ),
                  )
                else if (cast.devices.isEmpty && !cast.connected)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      children: [
                        const Text(
                          'No Cast devices found',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                        ),
                        const Text(
                          'Check that the speaker is on and on the same Wi-Fi.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 13),
                        ),
                        TextButton(
                          onPressed: cast.scan,
                          child: const Text('Search again', style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  ),
                if (cast.error != null) Text(cast.error!, style: const TextStyle(color: Color(0xFFFF6B6B))),
                const SizedBox(height: 8),
                FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size.fromHeight(46)),
                  onPressed: () => Navigator.pop(c),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

// ── ⋯ in the player ─────────────────────────────────────────────────────

/// Player ⋯ → DJ: opens the DJ page over the player.
void openDjFromPlayer(BuildContext context) =>
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute<void>(builder: (_) => const DjScreen()));

Future<void> showPlayerMore(BuildContext context, Item it) {
  final s = Services.i;
  return showByteSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1C1C1E), // white text: dark glass from wherever it is opened
    builder: (c) {
      Widget row(IconData i, String t, VoidCallback onTap, {String? sub}) => ListTile(
        leading: Icon(i, color: Colors.white),
        title: Text(
          t,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
        ),
        subtitle: sub == null ? null : Text(sub, style: const TextStyle(color: Colors.white60)),
        onTap: () {
          Navigator.pop(c);
          onTap();
        },
      );
      final (sleepMode, _) = s.player.sleep.value;
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Artwork(it.thumb, size: 44, radius: 6),
                title: Text(
                  it.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                ),
                subtitle: Text(
                  it.artistLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white60),
                ),
              ),
              const Divider(color: Colors.white12, height: 1),
              // 1.4.4: the same liked state as the heart beside ⋯ on Now Playing
              row(
                s.library.isLiked(it.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                s.library.isLiked(it.id) ? 'Remove from Liked' : 'Like',
                () => s.library.setLiked(it, !s.library.isLiked(it.id)),
              ),
              if (!s.dj.active)
                row(Icons.graphic_eq_rounded, 'Start DJ', () {
                  s.dj.start();
                  toast(context, 'DJ is starting…');
                }, sub: 'Non-stop mix from what you play')
              else
                row(Icons.graphic_eq_rounded, 'DJ', () => openDjFromPlayer(context), sub: 'Talk to your DJ, switch it up, stop'),
              row(Icons.playlist_add_rounded, 'Add to playlist', () => addToPlaylistSheet(context, [it])),
              if (!it.isLocal && s.downloads.supported && !s.library.isDownloaded(it.id))
                row(Icons.download_rounded, 'Download', () {
                  s.downloads.enqueue([it]);
                  toast(context, 'Downloading…');
                }),
              row(
                sleepMode == SleepMode.off ? Icons.bedtime_outlined : Icons.bedtime_rounded,
                'Sleep timer',
                () => showSleepSheet(context),
                sub: sleepMode == SleepMode.off ? null : 'On',
              ),
              row(Icons.speed_rounded, 'Playback speed', () => showSpeedSheet(context), sub: '${s.settings.speed}×'),
              row(Icons.info_outline_rounded, 'Song info', () => showSongInfo(context, it), sub: 'Release year, your plays and listening time'),
              row(
                s.party.active ? Icons.people_rounded : Icons.people_outline_rounded,
                'Listen together',
                () => openListenTogether(context),
                sub: s.party.active ? 'In a party' : 'Play the same song with friends',
              ),
              if (!it.isLocal)
                row(Icons.ios_share_rounded, 'Share', () => SharePlus.instance.share(ShareParams(text: '${it.title} — ${it.artistLine}\n${shareUrlFor(it)}'))),
              row(Icons.more_horiz_rounded, 'More options', () => showItemMenu(context, it)),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

/// Kept so tests can reach the cast controller type from here.
typedef PlayerCast = CastController;
typedef PlayerRoute = AudioRoute;

/// The release year in an album page's subtitle ("Album • Arijit Singh • 2022").
String? releaseYearFrom(String? subtitle) => subtitle == null ? null : RegExp(r'\b(19[5-9]\d|20\d\d)\b').firstMatch(subtitle)?.group(0);

/// Song info: what it is, when it came out, and your own numbers for it.
Future<void> showSongInfo(BuildContext context, Item it) {
  final s = Services.i;
  final (plays, ms) = s.stats.song(it.id);
  final hist = s.library.history.where((h) => h.item.id == it.id).toList();
  final first = hist.isEmpty ? null : hist.map((h) => h.at).reduce((a, b) => a.isBefore(b) ? a : b);
  final last = hist.isEmpty ? null : hist.map((h) => h.at).reduce((a, b) => a.isAfter(b) ? a : b);
  final stream = s.player.current.value?.id == it.id ? s.player.currentStream.value : null;
  String day(DateTime d) => '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]} ${d.year}';
  final year = it.albumId == null
      ? Future<String?>.value(null)
      : s.yt.album(it.albumId!).then((p) => releaseYearFrom(p.header.subtitle) ?? releaseYearFrom(p.header.secondSubtitle)).catchError((_) => null);
  return showByteSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) {
      Widget row(String k, String? v) => v == null || v.isEmpty
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 120, child: Text(k, style: const TextStyle(color: Colors.white60, fontWeight: FontWeight.w600))),
                  Expanded(child: Text(v, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                ],
              ),
            );
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Artwork(it.thumbAt(226), size: 56, radius: 8),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
                        Text(it.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text('Song', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
              row('Album', it.album),
              FutureBuilder<String?>(future: year, builder: (_, y) => row('Released', y.data)),
              row('Length', it.durationSec == null ? null : fmtDuration(it.durationSec)),
              if (stream != null) row('Stream', '${stream.isMp4 ? 'AAC' : 'Opus'} · ${(stream.bitrate / 1000).round()} kbps'),
              const SizedBox(height: 10),
              const Text('You', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
              row('Plays', plays == 0 ? 'Not counted yet' : '$plays'),
              row('Listened', ms < 60000 ? null : '${ms ~/ 60000} min'),
              row('First played', first == null ? null : day(first)),
              row('Last played', last == null ? null : day(last)),
            ],
          ),
        ),
      );
    },
  );
}
