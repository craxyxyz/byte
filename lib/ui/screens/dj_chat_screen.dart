import 'dart:async';

import 'package:flutter/material.dart';

import '../../dj/dj_chat.dart';
import '../../dj/recommender.dart';
import '../../dj/request_parser.dart';
import '../../dj/speech_input.dart';
import '../../services.dart';
import '../style.dart';
import '../widgets.dart';
import '../glass.dart';

class _Msg {
  final bool fromDj;
  final String text;
  DjRequest? request; // the understood chips (editable on the latest one)
  List<DjPick> picks;
  _Msg(this.fromDj, this.text, {this.request, List<DjPick>? picks}) : picks = picks ?? [];
}

/// Talk to your DJ: it looks at what you've been playing, asks what you
/// want right now, and plays exactly that (by text or voice).
/// Byte © 2026 Apurba Laskar.
class DjChatScreen extends StatefulWidget {
  const DjChatScreen({super.key});
  @override
  State<DjChatScreen> createState() => DjChatScreenState();
}

class DjChatScreenState extends State<DjChatScreen> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final List<_Msg> _msgs = [];
  late TasteProfile taste;
  bool busy = false;
  bool listening = false;
  MicStatus? _mic;

  Services get s => Services.i;
  bool get hinglish => s.settings.djLanguage != 'english';

  @override
  void initState() {
    super.initState();
    taste = TasteProfile.build(library: s.library, stats: s.stats, log: s.playLog);
    _msgs.add(_Msg(true, DjChatLines.greeting(taste, hinglish: hinglish, name: s.settings.djName)));
  }

  @override
  void dispose() {
    if (listening) unawaited(s.speech.stop());
    _text.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  /// Sends what the listener typed / said / tapped.
  Future<void> send(String text) async {
    final t = text.trim();
    if (busy) return;
    _text.clear();
    final req = DjRequestParser(historyArtists: taste.topArtists(40)).parse(t);
    setState(() => _msgs.add(_Msg(false, t.isEmpty ? (hinglish ? 'Mere liye mix' : 'Mix for me') : t)));
    await play(req);
  }

  /// Plays [req] and tells the listener what was understood and picked.
  Future<void> play(DjRequest req) async {
    final hello = _Msg(true, DjChatLines.understood(req, hinglish: hinglish), request: req);
    setState(() {
      for (final m in _msgs) {
        m.request = null; // only the newest request stays editable
      }
      _msgs.add(hello);
      busy = true;
    });
    _toEnd();
    final picks = await s.dj.playRequest(req);
    if (!mounted) return;
    final line = picks.isEmpty ? DjChatLines.nothing(hinglish: hinglish) : DjChatLines.playing(req, picks, hinglish: hinglish);
    setState(() {
      _msgs.add(_Msg(true, line, picks: picks.take(8).toList()));
      busy = false;
    });
    _toEnd();
  }

  Future<void> _editChip(DjRequest req, DjChip c) async {
    final alts = DjChatLines.alternatives(c);
    if (alts.isEmpty) return;
    final p = BytePalette.of(context);
    final picked = await showByteSheet<DjChip>(
      context: context,
      backgroundColor: p.bg,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final a in alts)
                ChoiceChip(
                  key: Key('alt:${a.kind.name}:${a.value}'),
                  label: Text(a.label),
                  selected: a == c,
                  onSelected: (_) => Navigator.pop(ctx, a),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == c) return;
    await play(req.replace(c, picked));
  }

  Future<void> mic() async {
    if (listening) {
      await s.speech.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    _mic ??= await s.speech.init();
    if (!mounted) return;
    if (_mic != MicStatus.ready) {
      final denied = _mic == MicStatus.denied;
      _mic = null; // ask again next time (they may allow it in settings)
      final line = denied ? DjChatLines.micDenied(hinglish: hinglish) : DjChatLines.micUnavailable(hinglish: hinglish);
      setState(() => _msgs.add(_Msg(true, line)));
      toast(context, denied ? 'Microphone permission is off' : 'Voice input not available');
      _focus.requestFocus();
      _toEnd();
      return;
    }
    setState(() => listening = true);
    await s.speech.listen(
      locale: s.settings.djMicLocale,
      onText: (text, isFinal) {
        if (!mounted) return;
        _text.text = text;
        _text.selection = TextSelection.collapsed(offset: text.length);
        if (isFinal) {
          setState(() => listening = false);
          if (text.trim().isNotEmpty) send(text);
        }
      },
      onError: (reason) {
        if (!mounted) return;
        setState(() => listening = false);
        toast(context, hinglish ? 'Sun nahi paaya, dobara bolo ya likho' : 'Didn\'t catch that, try again or type it');
      },
    );
  }

  void _cycleMicLang() {
    final keys = micLocales.keys.toList();
    final i = keys.indexOf(s.settings.djMicLocale);
    s.settings.djMicLocale = keys[(i + 1) % keys.length];
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final quick = DjChatLines.quickPicks(taste, hinglish: hinglish);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          children: [
            // header
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
              child: Row(
                children: [
                  IconButton(tooltip: 'Back', icon: Icon(Icons.arrow_back_ios_new_rounded, color: p.label, size: 22), onPressed: () => Navigator.maybePop(context)),
                  Container(
                    width: 36,
                    height: 36,
                    decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [ByteColors.pink, ByteColors.deep], begin: Alignment.topLeft, end: Alignment.bottomRight)),
                    child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Your DJ', style: BT.bodyStrong.copyWith(color: p.label)),
                        ListenableBuilder(
                          listenable: s.dj,
                          builder: (_, _) => Text(
                            busy ? 'Picking songs…' : (s.dj.inRequest ? 'Playing: ${s.dj.request!.summary}' : 'Ask for anything'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BT.caption.copyWith(color: p.secondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: p.separator),
            Expanded(
              child: ListView.builder(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                itemCount: _msgs.length + (busy ? 1 : 0) + (_msgs.length == 1 ? 1 : 0),
                itemBuilder: (c, i) {
                  if (i == _msgs.length) return _msgs.length == 1 && !busy ? _Ideas(ideas: DjChatLines.ideas(taste, hinglish: hinglish), onPick: send) : const _Typing();
                  final m = _msgs[i];
                  return _Bubble(msg: m, onRemove: (r, chip) => play(r.without(chip)), onEdit: _editChip);
                },
              ),
            ),
            // quick picks
            SizedBox(
              height: 46,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                itemCount: quick.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (c, i) => ActionChip(
                  key: Key('quick:${quick[i].$1}'),
                  label: Text(quick[i].$1),
                  labelStyle: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w600),
                  backgroundColor: p.grouped,
                  side: BorderSide(color: p.separator),
                  shape: const StadiumBorder(),
                  onPressed: busy ? null : () => send(quick[i].$2),
                ),
              ),
            ),
            // input
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('djChatInput'),
                      controller: _text,
                      focusNode: _focus,
                      textInputAction: TextInputAction.send,
                      onSubmitted: send,
                      style: BT.row.copyWith(color: p.label),
                      decoration: InputDecoration(
                        hintText: listening ? (hinglish ? 'Sun raha hoon…' : 'Listening…') : (hinglish ? 'Kya sunna hai? e.g. sad Hindi' : 'What do you want to hear?'),
                        hintStyle: BT.row.copyWith(color: p.tertiary),
                        filled: true,
                        fillColor: p.fill,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: s.settings,
                    builder: (_, _) => TextButton(
                      key: const Key('djMicLang'),
                      onPressed: _cycleMicLang,
                      style: TextButton.styleFrom(minimumSize: const Size(40, 40), padding: const EdgeInsets.symmetric(horizontal: 6)),
                      child: Text(s.settings.djMicLocale.split('-').first.toUpperCase(), style: BT.caption.copyWith(color: p.secondary, fontWeight: FontWeight.w700)),
                    ),
                  ),
                  _RoundIcon(
                    key: const Key('djChatMic'),
                    icon: listening ? Icons.stop_rounded : Icons.mic_rounded,
                    filled: listening,
                    tooltip: listening ? 'Stop' : 'Speak',
                    onTap: mic,
                  ),
                  const SizedBox(width: 6),
                  _RoundIcon(key: const Key('djChatSend'), icon: Icons.arrow_upward_rounded, filled: true, tooltip: 'Send', onTap: busy ? null : () => send(_text.text)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ideas to start with, by mood / language / artist / era / activity.
class _Ideas extends StatelessWidget {
  final List<(String, List<(String, String)>)> ideas;
  final void Function(String text) onPick;
  const _Ideas({required this.ideas, required this.onPick});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (group, items) in ideas) ...[
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 6, top: 6),
              child: Text(group.toUpperCase(), style: BT.caption.copyWith(color: p.secondary, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (label, text) in items)
                  ActionChip(
                    key: Key('idea:$label'),
                    label: Text(label),
                    labelStyle: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w600),
                    backgroundColor: p.bg,
                    side: BorderSide(color: p.separator),
                    shape: const StadiumBorder(),
                    onPressed: () => onPick(text),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  final IconData icon;
  final bool filled;
  final String tooltip;
  final VoidCallback? onTap;
  const _RoundIcon({super.key, required this.icon, required this.filled, required this.tooltip, this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: filled ? ByteColors.brand : p.fill,
        shape: const CircleBorder(),
        child: InkWell(mouseCursor: SystemMouseCursors.click, 
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(width: 42, height: 42, child: Icon(icon, size: 22, color: filled ? Colors.white : p.label)),
        ),
      ),
    );
  }
}

class _Typing extends StatelessWidget {
  const _Typing();
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: p.grouped, borderRadius: BorderRadius.circular(18)),
        child: SizedBox(width: 36, height: 12, child: LinearProgressIndicator(color: ByteColors.brand, backgroundColor: p.fill, minHeight: 3)),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final _Msg msg;
  final void Function(DjRequest r, DjChip c) onRemove;
  final Future<void> Function(DjRequest r, DjChip c) onEdit;
  const _Bubble({required this.msg, required this.onRemove, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final mine = !msg.fromDj;
    final req = msg.request;
    final width = MediaQuery.sizeOf(context).width;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width * (msg.picks.isNotEmpty ? 0.92 : 0.8)),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: mine ? ByteColors.brand : p.grouped,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(mine ? 18 : 4),
              bottomRight: Radius.circular(mine ? 4 : 18),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(msg.text, style: BT.row.copyWith(color: mine ? Colors.white : p.label, height: 1.3)),
              if (req != null && req.chips.isNotEmpty && !(req.isMix && !req.fresh)) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in req.chips)
                      InputChip(
                        key: Key('understood:${c.kind.name}:${c.value}'),
                        label: Text(c.label),
                        labelStyle: BT.caption.copyWith(color: ByteColors.brandText, fontWeight: FontWeight.w600),
                        backgroundColor: p.bg,
                        side: BorderSide(color: ByteColors.brand.withValues(alpha: 0.35)),
                        shape: const StadiumBorder(),
                        visualDensity: VisualDensity.compact,
                        deleteIcon: const Icon(Icons.close_rounded, size: 16),
                        deleteIconColor: p.secondary,
                        deleteButtonTooltipMessage: 'Remove',
                        onDeleted: () => onRemove(req, c),
                        onPressed: DjChatLines.alternatives(c).isEmpty ? null : () => onEdit(req, c),
                      ),
                  ],
                ),
              ],
              if (msg.picks.isNotEmpty) ...[
                const SizedBox(height: 8),
                for (final pk in msg.picks)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Artwork(pk.item.thumb, size: 40, radius: 6),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(pk.item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w600)),
                              Text(
                                pk.reason,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: BT.caption.copyWith(color: pk.fresh ? ByteColors.brandText : p.secondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
