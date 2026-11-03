import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';

import 'package:share_plus/share_plus.dart';

import '../lyrics/dual.dart';
import '../lyrics/lrc.dart';
import '../lyrics/lyrics_service.dart';
import '../lyrics/romanize.dart';
import '../lyrics/script.dart';
import '../lyrics/translate.dart';
import '../lyrics/urdu_roman.dart';
import '../player/screen_awake.dart';
import 'widgets.dart' show toast;
import '../services.dart';
import 'glass.dart';

/// Loads lyrics for the song playing and shows them, with romanize /
/// translate buttons and a "Lyrics · <source>" link that opens the provider picker.
class LyricsPane extends StatefulWidget {
  final Color textColor;
  final EdgeInsets padding;
  final bool tools;
  const LyricsPane({super.key, this.textColor = Colors.white, this.padding = const EdgeInsets.fromLTRB(24, 24, 24, 160), this.tools = true});

  /// True while the person scrolls through the lyrics (the player hides its controls).
  static final browsing = ValueNotifier<bool>(false);

  /// No touch for a few seconds on the lyrics screen: the controls fold away
  /// and the lyrics take the whole screen (a tap brings them back).
  static final idle = ValueNotifier<bool>(false);

  /// How long the lyrics screen waits before going full screen.
  static Duration idleAfter = const Duration(milliseconds: 4500);

  /// Line selection for sharing (null = not selecting).
  static final selection = ValueNotifier<Set<int>?>(null);

  /// Bumped to reload (a provider was picked) or to jump back to the live line.
  static final reload = ValueNotifier<int>(0);
  static final resync = ValueNotifier<int>(0);

  /// The lyrics on screen right now (for sharing selected lines).
  static Lyrics? shown;

  @override
  State<LyricsPane> createState() => _LyricsPaneState();
}

/// 1.4.4 (Apurba): in full-screen lyrics (the player's controls folded away
/// after a few seconds, or while scrolling on a phone) the type buttons and the
/// "Romanized · …" line go too: only the lyrics. They come back with the
/// controls. The look picked stays.
class _HiddenInFullScreen extends StatelessWidget {
  final Widget child;
  const _HiddenInFullScreen({required this.child});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([LyricsPane.idle, LyricsPane.browsing]),
    builder: (context, _) {
      // scrolling folds the controls only on a phone-sized player
      final full = LyricsPane.idle.value || (LyricsPane.browsing.value && MediaQuery.sizeOf(context).width < 820);
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        child: full ? const SizedBox(key: ValueKey('lyrics-tools-hidden'), width: double.infinity) : KeyedSubtree(key: const ValueKey('lyrics-tools'), child: child),
      );
    },
  );
}

/// dual (1.4.3): the original and the same words in Roman letters side by
/// side (or Roman over the original on a narrow phone).
enum LyricsLook { original, romanized, hindi, translated, dual }

class _LyricsPaneState extends State<LyricsPane> {
  Item? _for;
  Lyrics? raw;
  Lyrics? lyrics;
  bool loading = false;
  LyricsLook look = LyricsLook.original;
  bool working = false;

  /// The Roman side for the dual look (Byte's own reading first, then the
  /// better one from the song's other versions when it arrives).
  DualLyrics? dual;

  @override
  void initState() {
    super.initState();
    Services.i.player.current.addListener(_changed);
    LyricsPane.reload.addListener(_reload);
    _changed();
  }

  @override
  void dispose() {
    Services.i.player.current.removeListener(_changed);
    LyricsPane.reload.removeListener(_reload);
    LyricsPane.browsing.value = false;
    LyricsPane.selection.value = null;
    super.dispose();
  }

  void _reload() {
    _for = null;
    _changed();
  }

  Future<void> _changed() async {
    final it = Services.i.player.current.value;
    if (it == null || it.id == _for?.id) return;
    LyricsPane.selection.value = null;
    setState(() {
      _for = it;
      raw = lyrics = null;
      dual = null;
      loading = true;
      look = LyricsLook.original;
    });
    Lyrics l;
    try {
      // Never leave the pane spinning: after 25 s it says there are none.
      l = await Services.i.lyrics.forItem(it, durationSec: playingDurationSec(it)).timeout(const Duration(seconds: 25));
    } catch (_) {
      l = const Lyrics.none();
    }
    if (!mounted || _for?.id != it.id) return;
    final first = defaultLookFor(l, Services.i.settings.lyricsScript, picked: Services.i.settings.lyricsLook);
    setState(() {
      raw = l;
      look = first;
      if (lyricsNeedDual(l)) dual = buildDual(l);
      // 1.4.4: Romanized (the default) shows the same Roman words as the
      // dual look's Roman side, with the same word fill
      lyrics = LyricsPane.shown = first == LyricsLook.dual
          ? l
          : first == LyricsLook.romanized && dual != null
          ? dual!.roman
          : lyricsInLook(l, first);
      loading = false;
    });
    if (lyricsNeedDual(l)) unawaited(_betterRoman(it, l));
  }

  /// Asks the lyric sources for a Roman (or Hindi-letter) version of this
  /// song and, when its words match, uses its spelling.
  Future<void> _betterRoman(Item it, Lyrics l) async {
    DualLyrics? d;
    try {
      d = await Services.i.lyrics.dualFor(it, l).timeout(const Duration(seconds: 20));
    } catch (_) {}
    if (d == null || !mounted || _for?.id != it.id || raw != l) return;
    setState(() {
      dual = d;
      if (look == LyricsLook.romanized) lyrics = LyricsPane.shown = d!.roman;
    });
  }

  Future<void> _setLook(LyricsLook v) async {
    final r = raw;
    if (r == null || r.kind == LyricsKind.none) return;
    if (look == v) v = LyricsLook.original;
    // 1.4.4: a look picked by hand for lyrics in another script is kept for
    // the next songs and the next launch (translation needs the network: not kept)
    if (v != LyricsLook.translated && lyricsNeedDual(r)) Services.i.settings.lyricsLook = v.name;
    if (v == LyricsLook.original) {
      setState(() {
        look = v;
        lyrics = LyricsPane.shown = r;
      });
      return;
    }
    if (v == LyricsLook.dual) {
      setState(() {
        look = v;
        dual ??= buildDual(r);
        lyrics = LyricsPane.shown = r;
      });
      return;
    }
    if (v == LyricsLook.romanized || v == LyricsLook.hindi) {
      setState(() {
        look = v;
        lyrics = LyricsPane.shown = v == LyricsLook.romanized && dual != null ? dual!.roman : lyricsInLook(r, v);
      });
      return;
    }
    setState(() => working = true);
    final lang = Services.i.settings.translationLanguage;
    Lyrics? out;
    try {
      final texts = r.kind == LyricsKind.synced ? r.lines.map((l) => l.text).toList() : r.plain!.split('\n');
      final tr = await Services.i.translator.lines(texts, lang);
      if (tr.any((t) => t.isNotEmpty)) out = combineTranslation(r, tr);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      working = false;
      if (out != null) {
        look = v;
        lyrics = LyricsPane.shown = out;
      }
    });
    if (out == null && mounted) toast(context, 'Couldn\'t translate these lyrics right now');
  }

  // 1.4.2 (Apurba): the screen never turns off while the lyrics are open,
  // playing or paused. Built in, no setting.
  @override
  Widget build(BuildContext context) => KeepScreenOn(child: _body(context));

  Widget _body(BuildContext context) {
    final c = widget.textColor;
    final l = lyrics;
    final both = look == LyricsLook.dual ? dual : null;
    Widget child;
    if (loading || l == null) {
      child = _LoadingLines(color: c, key: const ValueKey('loading'));
    } else if (l.kind == LyricsKind.synced && !Services.i.settings.syncedLyrics) {
      // Settings → Appearance → Synced lyrics off: the same words, as plain text.
      child = _PlainLyrics(key: ValueKey('plainS${_for?.id}$look'), text: l.lines.map((x) => x.text).join('\n'), roman: both?.lines.map((x) => x.text).toList(), color: c, padding: widget.padding);
    } else if (l.kind == LyricsKind.synced) {
      child = SyncedLyricsView(key: ValueKey('sync${_for?.id}'), lyrics: l, roman: both?.roman, color: c, padding: widget.padding);
    } else if (l.kind == LyricsKind.plain) {
      child = _PlainLyrics(key: ValueKey('plain${_for?.id}$look'), text: l.plain!, roman: both?.lines.map((x) => x.text).toList(), color: c, padding: widget.padding);
    } else {
      child = Center(
        key: const ValueKey('none'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lyrics_outlined, size: 56, color: c.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text(
                'No lyrics for this song',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.withValues(alpha: 0.85), fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'None of your lyrics sources has this one.',
                textAlign: TextAlign.center,
                style: TextStyle(color: c.withValues(alpha: 0.6), fontSize: 14),
              ),
              const SizedBox(height: 14),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: c,
                  side: BorderSide(color: c.withValues(alpha: 0.4)),
                ),
                onPressed: _for == null ? null : () => showLyricsProviders(context, _for!),
                child: const Text('Try another source'),
              ),
            ],
          ),
        ),
      );
    }
    final hasWords = l != null && l.kind != LyricsKind.none && !loading;
    final indic = hasWords && hasIndicLetters(l.kind == LyricsKind.synced ? l.lines.take(30).map((x) => x.text).join() : (l.plain ?? ''));
    final canDual = hasWords && raw != null && lyricsNeedDual(raw!);
    final canRoman = hasWords && (indic || canDual || look == LyricsLook.romanized);
    final canHindi = hasWords && (look == LyricsLook.hindi || hasOtherIndicLetters(raw?.kind == LyricsKind.synced ? raw!.lines.take(30).map((x) => x.text).join() : (raw?.plain ?? '')));
    return Stack(
      children: [
        Positioned.fill(
          child: AnimatedSwitcher(duration: const Duration(milliseconds: 350), switchInCurve: Curves.easeOut, child: child),
        ),
        if (widget.tools && hasWords)
          Positioned(
            left: 16,
            right: 16,
            bottom: 0,
            child: ValueListenableBuilder<Set<int>?>(
              valueListenable: LyricsPane.selection,
              builder: (context, sel, _) => sel != null
                  ? Padding(padding: const EdgeInsets.only(bottom: 6), child: _ShareBar(count: sel.length, color: c))
                  : _HiddenInFullScreen(
                      child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            _RoundTool(
                              icon: Icons.language_rounded,
                              tooltip: 'Romanize',
                              on: look == LyricsLook.romanized,
                              onTap: () {
                                if (!canRoman) {
                                  toast(context, 'These lyrics already use Latin letters');
                                  return;
                                }
                                _setLook(LyricsLook.romanized);
                              },
                            ),
                            if (canDual) ...[
                              const SizedBox(width: 10),
                              _RoundTool(
                                key: const ValueKey('lyrics-dual'),
                                icon: Icons.view_column_rounded,
                                tooltip: 'Both: Roman letters and the original',
                                on: look == LyricsLook.dual,
                                onTap: () => _setLook(LyricsLook.dual),
                              ),
                            ],
                            if (canHindi) ...[
                              const SizedBox(width: 10),
                              _RoundTool(
                                key: const ValueKey('lyrics-hindi'),
                                label: 'अ',
                                tooltip: 'Hindi letters',
                                on: look == LyricsLook.hindi,
                                onTap: () => _setLook(LyricsLook.hindi),
                              ),
                            ],
                            const Spacer(),
                            _RoundTool(
                              icon: Icons.translate_rounded,
                              tooltip: 'Translate',
                              on: look == LyricsLook.translated,
                              busy: working,
                              onTap: () => _setLook(LyricsLook.translated),
                            ),
                          ],
                        ),
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: working ? null : () => showLyricsProviders(context, _for!),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 250),
                              child: Text(
                                lyricsCaption(raw!.shiftedMs == null ? raw!.source : '${raw!.source} · lined up with this version', look: look, working: working, language: LyricsTranslatorNames.name(Services.i.settings.translationLanguage)),
                                key: ValueKey('cap$working$look'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: c.withValues(alpha: 0.62),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  decoration: TextDecoration.underline,
                                  decorationColor: c.withValues(alpha: 0.4),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    ),
            ),
          ),
      ],
    );
  }
}

/// The small caption over the progress bar: the source, or the translation state.
String lyricsCaption(String source, {required LyricsLook look, required bool working, required String language}) {
  if (working) return 'Translating to $language…';
  if (look == LyricsLook.translated) return 'Translated to $language';
  if (look == LyricsLook.romanized) return 'Romanized · $source';
  if (look == LyricsLook.hindi) return 'Hindi letters · $source';
  if (look == LyricsLook.dual) return 'Roman letters + original · $source';
  return 'Lyrics · $source';
}

/// Language names for the caption.
class LyricsTranslatorNames {
  static String name(String code) => LyricsTranslator.languages[code] ?? code;
}

/// The same lyrics in Latin letters (Indian scripts), timings kept.
Lyrics romanizeLyrics(Lyrics l) {
  if (l.kind == LyricsKind.synced) {
    return Lyrics.synced([
      for (final x in l.lines)
        LyricLine(
          x.startMs,
          _roman(x.text),
          x.words == null ? null : _romanWords(x.words!),
        ),
    ], l.source);
  }
  if (l.kind == LyricsKind.plain) return Lyrics.plain(l.plain!.split('\n').map(_roman).join('\n'), l.source);
  return l;
}

String _roman(String s) => hasArabicLetters(s) ? romanizeUrdu(s) : romanizeLyric(s);

List<LyricWord> _romanWords(List<LyricWord> ws) {
  if (ws.any((w) => hasArabicLetters(w.text))) {
    final r = romanizeUrduWords([for (final w in ws) w.text]);
    return [for (final (i, w) in ws.indexed) LyricWord(i == 0 ? capitalizeFirst(r[i]) : r[i], w.startMs, w.endMs)];
  }
  return [for (final (i, w) in ws.indexed) LyricWord(romanizeLyric(w.text, capitalize: i == 0), w.startMs, w.endMs)];
}

/// How long the version of [it] that is actually playing is (the stream's own
/// length, which can differ from the catalogue's by an intro or an edit).
int? playingDurationSec(Item it) {
  try {
    // The catalogue's length is the upload's own; the stream's is only
    // needed when the catalogue has none (some local files, shared links).
    if (it.durationSec != null) return it.durationSec;
    final p = Services.i.player;
    if (p.current.value?.id != it.id) return it.durationSec;
    final d = p.duration;
    return d == null || d.inSeconds <= 0 ? it.durationSec : d.inSeconds;
  } catch (_) {
    return it.durationSec;
  }
}

/// 1.4.5.2 (computer lag): the lyric clocks ran a per-frame ticker forever,
/// so a screen with lyrics redrew at the display's refresh rate even when the
/// song was paused. [LyricsPace] keeps the per-frame ticker only while the
/// song plays (or [busy] says something is moving, e.g. a scroll glide);
/// paused, it checks 4 times a second instead, which draws nothing unless the
/// line actually changes (a seek while paused). On computers a playing song's
/// lyrics move 30 times a second ([playingStepMs]).
class LyricsPace {
  final Ticker ticker;
  final VoidCallback onTick;
  final bool Function()? busy;
  Timer? _poll;

  /// Whether the song is playing (tests replace it).
  static bool Function() isPlaying = () {
    try {
      return Services.i.player.playing;
    } catch (_) {
      return true;
    }
  };

  LyricsPace(this.ticker, this.onTick, {this.busy});

  /// True while the per-frame ticker runs.
  bool get perFrame => ticker.isActive;

  /// Computers (Windows / Linux): while a song plays, the lyrics move 30
  /// times a second on a timer instead of on every screen refresh (60–144 on
  /// laptops), which halves or quarters the drawing work. 0 = every frame.
  static int playingStepMs = !kIsWeb && (defaultTargetPlatform == TargetPlatform.windows || defaultTargetPlatform == TargetPlatform.linux) ? 33 : 0;
  int _pollMs = 0;

  /// Call at the end of every tick (ticker or timer).
  void update() {
    final playing = isPlaying();
    if ((busy?.call() ?? false) || (playing && playingStepMs == 0)) {
      if (!ticker.isActive) wake();
      return;
    }
    if (ticker.isActive) ticker.stop();
    final ms = playing ? playingStepMs : 250;
    if (_poll == null || _pollMs != ms) {
      _poll?.cancel();
      _pollMs = ms;
      _poll = Timer.periodic(Duration(milliseconds: ms), (_) => onTick());
    }
  }

  /// Per frame again right away (a new song, a glide, play); the next tick
  /// settles on the right pace.
  void wake() {
    _poll?.cancel();
    _poll = null;
    if (!ticker.isActive) ticker.start();
  }

  void dispose() {
    _poll?.cancel();
    _poll = null;
  }
}

/// The player's position for lyrics: the smooth clock plus the person's
/// timing nudges (Settings, and this song's own from the source sheet).
int lyricsNowMs() {
  final s = Services.i;
  final id = s.player.current.value?.id;
  return s.player.clock.nowMs + s.settings.lyricsOffsetMs + (id == null ? 0 : s.settings.lyricsOffsetFor(id));
}

/// The same lyrics in Hindi (Devanagari) letters, words and timings kept.
Lyrics devanagariLyrics(Lyrics l) {
  if (l.kind == LyricsKind.synced) {
    return Lyrics.synced([
      for (final x in l.lines)
        LyricLine(x.startMs, toDevanagari(x.text), x.words == null ? null : [for (final w in x.words!) LyricWord(toDevanagari(w.text), w.startMs, w.endMs)]),
    ], l.source);
  }
  if (l.kind == LyricsKind.plain) return Lyrics.plain(toDevanagari(l.plain!), l.source);
  return l;
}

/// The look the person picked in Settings (Lyrics letters) for these lyrics:
/// Hindi letters for a song in another Indian script; otherwise, for lyrics
/// in a script other than Roman (Urdu, Hindi, Bengali, Punjabi, Tamil…),
/// the same words in Roman letters only (1.4.4, Apurba: "by default
/// Romanized"); English stays as it is. [picked] is the look he picked by
/// hand on the lyrics screen (Settings.lyricsLook): Both, Song's own…
LyricsLook defaultLookFor(Lyrics l, String script, {String? picked}) {
  if (l.kind == LyricsKind.none) return LyricsLook.original;
  final sample = l.kind == LyricsKind.synced ? l.lines.take(40).map((x) => x.text).join(' ') : (l.plain ?? '');
  final other = needsDualText(sample);
  if (other && picked != null) {
    switch (picked) {
      case 'dual':
        return LyricsLook.dual;
      case 'original':
        return LyricsLook.original;
      case 'romanized':
        return LyricsLook.romanized;
      case 'hindi':
        if (hasOtherIndicLetters(sample)) return LyricsLook.hindi;
    }
  }
  if (script == 'hindi' && hasOtherIndicLetters(sample)) return LyricsLook.hindi;
  if (script == 'hindi' && hasDevanagari(sample) && !hasArabicLetters(sample)) return LyricsLook.original; // reads Hindi letters
  if (script != 'original' && other) return LyricsLook.romanized;
  return LyricsLook.original;
}

/// [l] in [look] (no translation here: that one needs the network).
/// The dual look's Roman side here (the mini line shows that one).
Lyrics lyricsInLook(Lyrics l, LyricsLook look) => switch (look) {
  LyricsLook.hindi => devanagariLyrics(l),
  // 1.4.4: lyrics in another script use the dual look's Roman words (the same
  // words, word for word, on the original's clock)
  LyricsLook.romanized => lyricsNeedDual(l) ? buildDual(l).roman : romanizeLyrics(l),
  LyricsLook.dual => buildDual(l).roman,
  _ => l,
};

/// Each line followed by its translation (same timing).
Lyrics combineTranslation(Lyrics l, List<String> tr) {
  String both(String a, String b) {
    final bb = b.replaceAll('\u200B', '').trim();
    return bb.isEmpty || bb.toLowerCase() == a.trim().toLowerCase() ? a : '$a\n$b';
  }
  if (l.kind == LyricsKind.synced) {
    return Lyrics.synced([for (var i = 0; i < l.lines.length; i++) LyricLine(l.lines[i].startMs, both(l.lines[i].text, i < tr.length ? tr[i] : ''))], l.source);
  }
  // Plain lyrics: the translation row starts with a zero-width space so the
  // view can draw it small and grey under its line.
  final ls = l.plain!.split('\n');
  return Lyrics.plain([for (var i = 0; i < ls.length; i++) both(ls[i], i < tr.length && tr[i].isNotEmpty ? '\u200B${tr[i]}' : '')].join('\n'), l.source);
}

class _RoundTool extends StatelessWidget {
  final IconData? icon;
  final String? label;
  final String tooltip;
  final bool on;
  final VoidCallback onTap;
  final bool busy;
  const _RoundTool({super.key, this.icon, this.label, required this.tooltip, required this.on, required this.onTap, this.busy = false});
  @override
  Widget build(BuildContext context) => Opacity(
    opacity: 1,
    child: Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: busy ? null : onTap,
        radius: 26,
        child: LiquidGlass(
          radius: BorderRadius.circular(22),
          dark: true,
          tint: on ? Colors.white : null,
          child: SizedBox(
            width: 44,
            height: 44,
            child: busy
                ? const Padding(padding: EdgeInsets.all(13), child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : label != null
                ? Center(child: Text(label!, style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: on ? Colors.black : Colors.white)))
                : Icon(icon, size: 22, color: on ? Colors.black : Colors.white),
          ),
        ),
      ),
    ),
  );
}

class _ShareBar extends StatelessWidget {
  final int count;
  final Color color;
  const _ShareBar({required this.count, required this.color});
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: color),
          onPressed: () => LyricsPane.selection.value = null,
          child: const Text('Cancel'),
        ),
        const Spacer(),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
          onPressed: count == 0 ? null : () => shareSelectedLyrics(),
          icon: const Icon(Icons.ios_share_rounded, size: 18),
          label: Text(count == 0 ? 'Pick lines' : 'Share $count ${count == 1 ? 'line' : 'lines'}'),
        ),
      ],
    );
  }
}

/// The picked lines with the song's name, as text.
String selectedLyricsText() {
  final l = LyricsPane.shown;
  final sel = LyricsPane.selection.value ?? const <int>{};
  final it = Services.i.player.current.value;
  if (l == null || it == null) return '';
  final lines = l.kind == LyricsKind.synced ? l.lines.map((x) => x.text).toList() : (l.plain ?? '').split('\n');
  final picked = [
    for (final i in sel.toList()..sort())
      if (i < lines.length) lines[i],
  ];
  return '${picked.join('\n')}\n\n— ${it.title}${it.artistLine.isEmpty ? '' : ' · ${it.artistLine}'}';
}

Future<void> shareSelectedLyrics() async {
  final t = selectedLyricsText();
  LyricsPane.selection.value = null;
  if (t.trim().isEmpty) return;
  await SharePlus.instance.share(ShareParams(text: t));
}

/// "Choose lyrics provider": every source, whether it has this song, tap to use it.
Future<void> showLyricsProviders(BuildContext context, Item song) {
  final svc = Services.i.lyrics;
  final off = Services.i.settings.lyricsOff;
  final ids = [...svc.activeOrder, ...LyricsProvider.all.map((p) => p.id).where((id) => off.contains(id))];
  final results = {for (final id in ids) id: off.contains(id) ? null : svc.fromProvider(id, song)};
  return showByteSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Choose lyrics provider', style: Theme.of(c).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            _TimingRow(songId: song.id),
            const SizedBox(height: 12),
            for (final id in ids)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ProviderCard(
                  provider: LyricsProvider.byId(id),
                  result: results[id],
                  onPick: (l) {
                    svc.choose(song, l);
                    Navigator.pop(c);
                    LyricsPane.reload.value++;
                  },
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// "Lyrics early / late" for one song: nudges in half seconds, remembered.
class _TimingRow extends StatefulWidget {
  final String songId;
  const _TimingRow({required this.songId});
  @override
  State<_TimingRow> createState() => _TimingRowState();
}

class _TimingRowState extends State<_TimingRow> {
  int get ms => Services.i.settings.lyricsOffsetFor(widget.songId);
  void _nudge(int d) {
    setState(() => Services.i.settings.setLyricsOffsetFor(widget.songId, ms + d));
    HapticFeedback.selectionClick();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final v = ms;
    final label = v == 0 ? 'In time' : (v > 0 ? '${(v / 1000).toStringAsFixed(1)} s earlier' : '${(-v / 1000).toStringAsFixed(1)} s later');
    return Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Lyrics timing (this song)', style: TextStyle(fontWeight: FontWeight.w700)),
                  Text(label, key: const ValueKey('lyrics-timing-value')),
                ],
              ),
            ),
            IconButton(key: const ValueKey('lyrics-later'), tooltip: 'Lyrics later', onPressed: () => _nudge(-500), icon: const Icon(Icons.remove_circle_outline_rounded)),
            IconButton(key: const ValueKey('lyrics-earlier'), tooltip: 'Lyrics earlier', onPressed: () => _nudge(500), icon: const Icon(Icons.add_circle_outline_rounded)),
            if (v != 0) TextButton(onPressed: () => setState(() => Services.i.settings.setLyricsOffsetFor(widget.songId, 0)), child: const Text('Reset')),
          ],
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final LyricsProvider provider;
  final Future<Lyrics>? result;
  final ValueChanged<Lyrics> onPick;
  const _ProviderCard({required this.provider, required this.result, required this.onPick});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget card(Widget lead, String sub, {Lyrics? l}) => Material(
      color: cs.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(16),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        leading: lead,
        title: Text(provider.name, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(sub),
        enabled: l != null,
        onTap: l == null ? null : () => onPick(l),
      ),
    );
    if (result == null) return card(const Icon(Icons.block_rounded), 'Turned off in Settings → Appearance → Lyrics sources');
    return FutureBuilder<Lyrics>(
      future: result,
      builder: (context, s) {
        if (s.connectionState != ConnectionState.done) {
          return card(const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)), 'Looking…');
        }
        final l = s.data ?? const Lyrics.none();
        if (l.kind == LyricsKind.none) return card(const Icon(Icons.cancel_rounded), 'Lyrics not found');
        final n = l.kind == LyricsKind.synced ? l.lines.where((x) => !x.isBreak).length : l.plain!.split('\n').where((x) => x.trim().isNotEmpty).length;
        return card(const Icon(Icons.check_circle_rounded, color: Color(0xFF34C759)), '${l.kind == LyricsKind.synced ? 'Synced' : 'Plain'} · $n lines', l: l);
      },
    );
  }
}

/// Apple-Music-style synced lyrics: the line being sung is bright and
/// fills word by word; the rest sit dimmed and softly blurred; the view
/// glides to keep the current line near the top third. Tap a line to jump.
/// Dual look layout knobs.
class LyricsDual {
  /// From this width of the lyrics (inside their padding) Roman and the
  /// original sit side by side (tablet); narrower (a phone in portrait), the
  /// Roman line sits over a smaller original.
  static double columnsFrom = 400;

  /// Extra fonts for the original script (the screenshot harness loads Noto
  /// here; phones use their own system fonts).
  static List<String>? fontFallback;
}

class SyncedLyricsView extends StatefulWidget {
  final Lyrics lyrics;
  final Color color;
  final EdgeInsets padding;

  /// Position source (ms). Defaults to the player's smooth clock.
  final int Function()? now;
  final void Function(int ms)? onSeek;

  /// The same lines in Roman letters (dual look), one per line of [lyrics],
  /// timed so each Roman word fills with the original word it says.
  final Lyrics? roman;
  const SyncedLyricsView({
    super.key,
    required this.lyrics,
    this.roman,
    this.color = Colors.white,
    this.padding = const EdgeInsets.fromLTRB(24, 24, 24, 160),
    this.now,
    this.onSeek,
  });
  @override
  State<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<SyncedLyricsView> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  late LyricsClock clock;
  LyricsClock? romanClock;
  final scroll = ScrollController();
  final ValueNotifier<int> nowMs = ValueNotifier(0);
  late List<GlobalKey> keys;
  int active = -1;
  bool _userScrolling = false;
  Timer? _resume;
  bool _first = true;

  int _now() => widget.now?.call() ?? lyricsNowMs();

  void _resyncNow() {
    _resume?.cancel();
    if (!mounted) return;
    setState(() => _userScrolling = false);
    LyricsPane.browsing.value = false;
    _scrollToActive();
  }

  void _selChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    LyricsPane.resync.addListener(_resyncNow);
    LyricsPane.selection.addListener(_selChanged);
    _init();
    _ticker = createTicker((e) {
      // the ticker restarts at 0 after a pause: keep [_tickMs] going up
      final el = e.inMilliseconds;
      if (el < _lastEl) _tickBase = _tickMs;
      _lastEl = el;
      _tickMs = _tickBase + el;
      _frame();
    })..start();
  }

  int _tickBase = 0, _lastEl = 0;

  /// 1.4.5.2: per frame only while playing or gliding (see [LyricsPace]); a
  /// custom clock ([SyncedLyricsView.now]) always runs per frame.
  late final LyricsPace _pace = LyricsPace(_ticker, _frame, busy: () => widget.now != null || _glideTo != null);

  void _init() {
    final lines = widget.lyrics.lines;
    clock = LyricsClock(lines, trackDurationMs: Services.i.player.duration?.inMilliseconds);
    final r = widget.roman;
    romanClock = r != null && r.kind == LyricsKind.synced && r.lines.length == lines.length ? LyricsClock(r.lines, trackDurationMs: Services.i.player.duration?.inMilliseconds) : null;
    keys = List.generate(lines.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant SyncedLyricsView old) {
    super.didUpdateWidget(old);
    if (old.lyrics != widget.lyrics) {
      _init();
      active = -1;
      _first = true;
    } else if (old.roman != widget.roman) {
      final r = widget.roman;
      final lines = widget.lyrics.lines;
      romanClock = r != null && r.kind == LyricsKind.synced && r.lines.length == lines.length ? LyricsClock(r.lines, trackDurationMs: Services.i.player.duration?.inMilliseconds) : null;
    }
  }

  @override
  void dispose() {
    LyricsPane.resync.removeListener(_resyncNow);
    LyricsPane.selection.removeListener(_selChanged);
    _pace.dispose();
    _ticker.dispose();
    _resume?.cancel();
    scroll.dispose();
    nowMs.dispose();
    super.dispose();
  }

  // Our own glide (instead of animateTo, which ignores taps while it runs, so
  // "tap a line to jump" would sometimes do nothing).
  double? _glideFrom, _glideTo;
  int _glideStart = 0;
  int _tickMs = 0; // ticker time (follows the test clock in tests)
  static const _glideMs = 650;

  void _glide() {
    final to = _glideTo, from = _glideFrom;
    if (to == null || from == null || !scroll.hasClients) return;
    final t = ((_tickMs - _glideStart) / _glideMs).clamp(0.0, 1.0);
    final y = from + (to - from) * Curves.easeOutCubic.transform(t);
    scroll.jumpTo(y.clamp(0.0, scroll.position.maxScrollExtent));
    if (t >= 1) _glideTo = _glideFrom = null;
  }

  void _frame() {
    if (!mounted) return;
    _glide();
    final ms = _now();
    nowMs.value = ms;
    final i = clock.indexAt(ms);
    if (i != active) {
      setState(() => active = i);
      if (!_userScrolling) WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToActive());
    }
    _pace.update();
  }

  void _scrollToActive({bool animate = true}) {
    if (!mounted || !scroll.hasClients) return;
    final idx = active < 0 ? 0 : active;
    final ctx = keys[idx].currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    final viewport = scroll.position.viewportDimension;
    final scrollBox = context.findRenderObject() as RenderBox?;
    if (box == null || scrollBox == null) return;
    final dy = box.localToGlobal(Offset.zero, ancestor: scrollBox).dy;
    // 1.4.1: the line being sung sits near the top, right under the header (reference)
    // dual look: a two-row line sits a little lower so its Roman row clears the top fade
    final target = (scroll.offset + dy - viewport * (romanClock != null ? 0.15 : 0.035)).clamp(0.0, scroll.position.maxScrollExtent);
    if (_first || !animate) {
      _first = false;
      scroll.jumpTo(target);
    } else {
      _glideFrom = scroll.offset;
      _glideTo = target;
      _glideStart = _tickMs;
      _pace.wake();
    }
  }

  void _toggle(int i, {bool start = false}) {
    final cur = LyricsPane.selection.value;
    if (cur == null && !start) return;
    final s = {...?cur};
    if (!s.remove(i)) s.add(i);
    HapticFeedback.selectionClick();
    LyricsPane.selection.value = s;
    _resume?.cancel();
  }

  bool _onScroll(ScrollNotification n) {
    if (n is UserScrollNotification || (n is ScrollUpdateNotification && n.dragDetails != null)) {
      _glideTo = _glideFrom = null;
      if (!_userScrolling) setState(() => _userScrolling = true);
      LyricsPane.browsing.value = true;
      _resume?.cancel();
      // While picking lines to share, stay where the person is.
      if (LyricsPane.selection.value != null) return false;
      _resume = Timer(const Duration(milliseconds: 4500), _resyncNow);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lyrics.lines;
    final size = Services.i.settings.lyricsSize;
    final width = MediaQuery.sizeOf(context).width;
    final base = (width > 820 ? 36.0 : (width < 370 ? 29.0 : 33.0)) * [0.82, 1.0, 1.18][size];
    final style = TextStyle(fontSize: base, height: 1.22, fontWeight: FontWeight.w800, letterSpacing: -0.4, color: widget.color);
    final fill = Services.i.settings.lyricsWordFill || widget.lyrics.hasWordTimings;
    final rc = romanClock;
    // dual: two columns when there is room for both (tablet, landscape);
    // on a phone in portrait the Roman line sits over a smaller original
    return LayoutBuilder(
      builder: (context, cons) {
        // the lyrics' own width (half the screen on a tablet in landscape)
        final room = (cons.maxWidth.isFinite ? cons.maxWidth : width) - widget.padding.horizontal;
        final columns = rc != null && room >= LyricsDual.columnsFrom;
        final lineStyle = (rc == null ? style : style.copyWith(fontSize: base * (columns ? 0.62 : 0.8))).copyWith(fontFamilyFallback: LyricsDual.fontFallback);
        return _list(context, lines, style: lineStyle, fill: fill, rc: rc, columns: columns);
      },
    );
  }

  Widget _list(BuildContext context, List<LyricLine> lines, {required TextStyle style, required bool fill, required LyricsClock? rc, required bool columns}) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: ShaderMask(
        shaderCallback: (r) => const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
          stops: [0, 0.07, 0.86, 1],
        ).createShader(r),
        blendMode: BlendMode.dstIn,
        child: SingleChildScrollView(
          controller: scroll,
          padding: widget.padding.copyWith(bottom: MediaQuery.sizeOf(context).height * 0.55),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // instrumental intro dots
              _BreakDots(clock: clock, nowMs: nowMs, beforeIndex: 0, color: widget.color, visible: active < 0),
              for (var i = 0; i < lines.length; i++)
                KeyedSubtree(
                  key: keys[i],
                  child: lines[i].isBreak
                      ? _BreakDots(clock: clock, nowMs: nowMs, beforeIndex: i + 1, color: widget.color, visible: i == active)
                      : _LineView(
                          index: i,
                          line: lines[i],
                          distance: active < 0 ? i + 1 : i - active,
                          clock: clock,
                          nowMs: nowMs,
                          style: style,
                          romanClock: rc,
                          columns: columns,
                          fill: fill,
                          blurOff: _userScrolling || !Services.i.settings.blurLyrics,
                          selected: LyricsPane.selection.value?.contains(i),
                          onLongPress: () => _toggle(i, start: true),
                          onTap: () {
                            if (LyricsPane.selection.value != null) return _toggle(i);
                            final ms = lines[i].startMs;
                            if (widget.onSeek != null) {
                              widget.onSeek!(ms);
                            } else {
                              Services.i.player.seek(Duration(milliseconds: ms));
                              if (!Services.i.player.playing) Services.i.player.play();
                            }
                            setState(() => _userScrolling = false);
                          },
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LineView extends StatelessWidget {
  final int index;
  final LyricLine line;
  final int distance; // 0 = active, <0 sung, >0 upcoming
  final LyricsClock clock;
  final ValueNotifier<int> nowMs;
  final TextStyle style;
  final bool fill;
  final bool blurOff;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final bool? selected; // null = not selecting

  /// Dual look: the Roman lines' clock (same index, same fill) and whether
  /// the two sit side by side (else Roman on top, original under it).
  final LyricsClock? romanClock;
  final bool columns;
  const _LineView({
    this.onLongPress,
    this.selected,
    this.romanClock,
    this.columns = false,
    required this.index,
    required this.line,
    required this.distance,
    required this.clock,
    required this.nowMs,
    required this.style,
    required this.fill,
    required this.blurOff,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = selected ?? distance == 0;
    final d = selected == null ? distance.abs() : (selected! ? 0 : 2);
    final opacity = isActive ? 1.0 : (blurOff ? 0.55 : (distance < 0 ? 0.30 : math.max(0.22, 0.48 - d * 0.05)));
    // 1.4.1 (reference): the next line stays sharp, lines further away blur more
    final blur = isActive || blurOff || d <= 1 ? 0.0 : math.min((d - 1) * 1.0, 3.0);
    // "line\ntranslation" (translate on): the translation sits under the line, smaller and grey.
    final nl = line.text.indexOf('\n');
    final mainText = nl < 0 ? line.text : line.text.substring(0, nl);
    final sub = nl < 0 ? null : line.text.substring(nl + 1);
    // one line of words that fill as they are sung; Urdu reads from the right
    Widget words(LyricsClock c, LyricLine l, String shown, TextStyle st, {TextAlign align = TextAlign.start}) {
      final rtl = isRtlText(shown);
      final dir = rtl ? TextDirection.rtl : TextDirection.ltr;
      if (isActive && fill) {
        return ValueListenableBuilder<int>(
          valueListenable: nowMs,
          builder: (context, ms, _) {
            final ws = l.words?.map((w) => w.text).toList() ?? splitWords(shown);
            final fills = c.wordFill(index, ms + c.leadMs); // same lead as the line change (and the mini line)
            final d = st.color!.withValues(alpha: 0.32);
            return Wrap(
              textDirection: dir,
              alignment: align == TextAlign.end ? (rtl ? WrapAlignment.start : WrapAlignment.end) : (rtl ? WrapAlignment.end : WrapAlignment.start),
              children: [for (var w = 0; w < ws.length; w++) _Word(ws[w], w < fills.length ? fills[w] : 0, st, d, rtl: rtl)],
            );
          },
        );
      }
      return SizedBox(
        width: double.infinity,
        child: Text(shown, style: st, textDirection: dir, textAlign: align == TextAlign.end ? TextAlign.right : TextAlign.left),
      );
    }

    Widget text;
    final rc = romanClock;
    if (rc != null && index < rc.lines.length && sub == null) {
      final rl = rc.lines[index];
      final roman = words(rc, rl, rl.text, style, align: TextAlign.start);
      if (columns) {
        text = Row(
          key: ValueKey('dual-cols$index'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: roman),
            const SizedBox(width: 28),
            Expanded(child: words(clock, line, mainText, style, align: TextAlign.end)),
          ],
        );
      } else {
        final small = style.copyWith(fontSize: (style.fontSize ?? 28) * 0.62, fontWeight: FontWeight.w700, letterSpacing: 0, height: 1.35, color: style.color!.withValues(alpha: 0.78));
        text = Column(
          key: ValueKey('dual-stack$index'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            roman,
            Padding(padding: const EdgeInsets.only(top: 4), child: words(clock, line, mainText, small, align: TextAlign.end)),
          ],
        );
      }
    } else if (isActive && fill) {
      text = words(clock, line, mainText, style);
    } else {
      text = Text(mainText, style: style, textDirection: isRtlText(mainText) ? TextDirection.rtl : null);
    }
    if (sub != null && sub.trim().isNotEmpty) {
      text = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          text,
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              sub,
              key: ValueKey('tr$index'),
              style: TextStyle(fontSize: (style.fontSize ?? 28) * 0.6, height: 1.25, fontWeight: FontWeight.w600, color: style.color!.withValues(alpha: 0.7)),
            ),
          ),
        ],
      );
    }
    // 1.4.5.2: each line is its own layer, so the line being sung (redrawn
    // every frame) doesn't make the blurred / faded lines redraw with it.
    return RepaintBoundary(
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: selected == true
            ? BoxDecoration(color: Colors.white.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12))
            : const BoxDecoration(),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 450),
          curve: Curves.easeOut,
          opacity: opacity,
          child: AnimatedScale(
            scale: isActive ? 1.0 : 0.93,
            alignment: Alignment.centerLeft,
            duration: const Duration(milliseconds: 550),
            curve: Curves.easeOutBack,
            child: TweenAnimationBuilder<double>(
              tween: Tween(end: blur),
              duration: const Duration(milliseconds: 450),
              builder: (context, b, child) => b < 0.05
                  ? child!
                  : ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: b, sigmaY: b, tileMode: TileMode.decal),
                      child: child,
                    ),
              child: text,
            ),
          ),
        ),
      ),
    ));
  }
}

/// One word whose colour fills left→right with [fill] 0..1 and lifts slightly.
class _Word extends StatelessWidget {
  final String text;
  final double fill;
  final TextStyle style;
  final Color dim;

  /// Right-to-left script (Urdu): the colour fills from the right.
  final bool rtl;
  const _Word(this.text, this.fill, this.style, this.dim, {this.rtl = false});
  @override
  Widget build(BuildContext context) {
    final lit = style.color!;
    final f = fill.clamp(0.0, 1.0);
    const soft = 0.18;
    return Transform.translate(
      offset: Offset(0, -2.5 * Curves.easeOut.transform(f)),
      child: ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (r) => LinearGradient(
          begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
          end: rtl ? Alignment.centerLeft : Alignment.centerRight,
          colors: [lit, lit, dim, dim],
          stops: [0, (f * (1 + soft) - soft).clamp(0.0, 1.0), (f * (1 + soft)).clamp(0.0, 1.0), 1],
        ).createShader(r),
        child: Text(
          text,
          textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          style: style.copyWith(shadows: f > 0 && f < 1 ? [Shadow(color: lit.withValues(alpha: 0.35), blurRadius: 12)] : null),
        ),
      ),
    );
  }
}

/// Three dots that breathe and fill during an instrumental gap.
class _BreakDots extends StatelessWidget {
  final LyricsClock clock;
  final ValueNotifier<int> nowMs;
  final int beforeIndex;
  final Color color;
  final bool visible;
  const _BreakDots({required this.clock, required this.nowMs, required this.beforeIndex, required this.color, required this.visible});
  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOut,
      child: !visible
          ? const SizedBox(width: double.infinity)
          : ValueListenableBuilder<int>(
              valueListenable: nowMs,
              builder: (context, ms, _) {
                final gap = clock.breakAt(ms);
                if (gap == null) return const SizedBox(width: double.infinity);
                final p = ((ms - gap.$1) / (gap.$2 - gap.$1)).clamp(0.0, 1.0);
                final breathe = 1 + 0.12 * math.sin(ms / 420);
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Transform.scale(
                    scale: breathe,
                    alignment: Alignment.centerLeft,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var k = 0; k < 3; k++)
                          Container(
                            margin: const EdgeInsets.only(right: 10),
                            width: 13,
                            height: 13,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: color.withValues(alpha: 0.3 + 0.7 * ((p * 3 - k).clamp(0.0, 1.0))),
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _PlainLyrics extends StatelessWidget {
  final String text;
  final Color color;
  final EdgeInsets padding;

  /// Dual look: each line's Roman letters (shown over the original).
  final List<String>? roman;
  const _PlainLyrics({super.key, required this.text, required this.color, required this.padding, this.roman});
  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    return ValueListenableBuilder<Set<int>?>(
      valueListenable: LyricsPane.selection,
      builder: (context, sel, _) => SingleChildScrollView(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
              child: Text(
                'Not synced',
                style: TextStyle(color: color.withValues(alpha: 0.75), fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < lines.length; i++)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () => LyricsPane.selection.value = {...?sel, i},
                onTap: sel == null ? null : () => LyricsPane.selection.value = sel.contains(i) ? ({...sel}..remove(i)) : {...sel, i},
                child: Container(
                  width: double.infinity,
                  decoration: sel?.contains(i) == true ? BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)) : null,
                  child: lines[i].startsWith('\u200B')
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(lines[i].substring(1), style: TextStyle(color: color.withValues(alpha: 0.6), fontSize: 14, height: 1.3, fontWeight: FontWeight.w600)),
                        )
                      : roman != null && i < roman!.length && roman![i].trim().isNotEmpty && roman![i] != lines[i]
                      ? Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(roman![i], style: TextStyle(color: color.withValues(alpha: 0.92), fontSize: 21, height: 1.4, fontWeight: FontWeight.w700)),
                              Text(
                                lines[i],
                                textAlign: TextAlign.right,
                                textDirection: isRtlText(lines[i]) ? TextDirection.rtl : TextDirection.ltr,
                                style: TextStyle(color: color.withValues(alpha: 0.62), fontSize: 15, height: 1.4, fontWeight: FontWeight.w600, fontFamilyFallback: LyricsDual.fontFallback),
                              ),
                            ],
                          ),
                        )
                      : Text(
                          lines[i],
                          textDirection: isRtlText(lines[i]) ? TextDirection.rtl : null,
                          style: TextStyle(color: color.withValues(alpha: 0.9), fontSize: 21, height: 1.5, fontWeight: FontWeight.w700),
                        ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LoadingLines extends StatefulWidget {
  final Color color;
  const _LoadingLines({super.key, required this.color});
  @override
  State<_LoadingLines> createState() => _LoadingLinesState();
}

class _LoadingLinesState extends State<_LoadingLines> with SingleTickerProviderStateMixin {
  late final AnimationController a = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat(reverse: true);
  @override
  void dispose() {
    a.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: FadeTransition(
        opacity: Tween(begin: 0.25, end: 0.6).animate(a),
        // never overflows a short lyrics area (it clips instead)
        child: SingleChildScrollView(
          physics: const NeverScrollableScrollPhysics(),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final w in [0.8, 0.6, 0.9, 0.5, 0.7])
              FractionallySizedBox(
                widthFactor: w,
                child: Container(
                  height: 26,
                  margin: const EdgeInsets.only(bottom: 18),
                  decoration: BoxDecoration(color: widget.color.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(8)),
                ),
              ),
          ],
          ),
        ),
      ),
    );
  }
}
