import 'dart:async';

import 'package:flutter/material.dart';

import 'style.dart';
import '../dj/dj_chat.dart';
import '../dj/recommender.dart';
import '../dj/request_parser.dart';
import '../dj/speech_input.dart';
import '../services.dart';
import 'widgets.dart';
import 'glass.dart';

/// Hold to talk to the DJ: listens while held, then plays what was said.
/// Byte © 2026 Apurba Laskar.
class DjHoldToTalk {
  DjHoldToTalk._();

  /// What was heard so far (shown while holding).
  static final ValueNotifier<String?> heard = ValueNotifier(null);
  static String _last = '';
  static bool _final = false;

  /// Starts listening. Returns false (and says why) when the mic can't be used.
  static Future<bool> start(BuildContext context) async {
    final s = Services.i;
    final hinglish = s.settings.djLanguage != 'english';
    final st = await s.speech.init();
    if (!context.mounted) return false;
    if (st != MicStatus.ready) {
      toast(
        context,
        st == MicStatus.denied
            ? (hinglish ? 'Mic ki permission nahi hai. DJ chat mein likh ke bolo.' : 'No microphone permission. Type it in DJ chat instead.')
            : (hinglish ? 'Voice input is phone pe nahi hai. DJ chat mein likh ke bolo.' : 'Voice input isn\'t available. Type it in DJ chat instead.'),
      );
      return false;
    }
    _last = '';
    _final = false;
    heard.value = '';
    await s.speech.listen(
      locale: s.settings.djMicLocale,
      onText: (t, isFinal) {
        _last = t;
        heard.value = t;
        if (isFinal) _final = true;
      },
      onError: (_) => heard.value = null,
    );
    return true;
  }

  /// Released: stops listening and plays the request. Returns the picks.
  static Future<List<DjPick>> finish(BuildContext context) async {
    final s = Services.i;
    final hinglish = s.settings.djLanguage != 'english';
    await s.speech.stop();
    // the last words can arrive a moment after stopping
    for (var i = 0; i < 10 && !_final && _last.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    heard.value = null;
    final text = _last.trim();
    if (text.isEmpty) {
      if (context.mounted) toast(context, hinglish ? 'Kuch suna nahi. Button daba ke rakho aur bolo.' : 'Didn\'t hear anything. Hold the button and speak.');
      return const [];
    }
    final taste = TasteProfile.build(library: s.library, stats: s.stats, log: s.playLog);
    final req = DjRequestParser(historyArtists: taste.topArtists(40)).parse(text);
    final picks = await s.dj.playRequest(req);
    if (context.mounted) {
      toast(context, picks.isEmpty ? DjChatLines.nothing(hinglish: hinglish) : 'DJ: ${req.summary}');
    }
    return picks;
  }
}

/// The big round DJ button on the player while the DJ is on: tap to switch
/// it up, hold to say what you want.
class DjFloatingButton extends StatefulWidget {
  const DjFloatingButton({super.key});
  @override
  State<DjFloatingButton> createState() => _DjFloatingButtonState();
}

class _DjFloatingButtonState extends State<DjFloatingButton> {
  bool holding = false;
  bool listening = false;

  Future<void> _down() async {
    setState(() => holding = true);
    final ok = await DjHoldToTalk.start(context);
    if (!mounted) return;
    setState(() => listening = ok);
    if (!ok) holding = false;
  }

  Future<void> _up() async {
    if (!listening) {
      setState(() => holding = false);
      return;
    }
    setState(() {
      holding = false;
      listening = false;
    });
    await DjHoldToTalk.finish(context);
  }

  @override
  Widget build(BuildContext context) {
    final dj = Services.i.dj;
    return ListenableBuilder(
      listenable: dj,
      builder: (context, _) {
        final busy = dj.switching || dj.starting;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            ValueListenableBuilder<String?>(
              valueListenable: DjHoldToTalk.heard,
              builder: (_, h, _) => h == null || !listening
                  ? const SizedBox.shrink()
                  : Container(
                      key: const Key('djHoldHeard'),
                      margin: const EdgeInsets.only(bottom: 8),
                      constraints: const BoxConstraints(maxWidth: 240),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.25), width: 0.8),
                      ),
                      child: Text(h.isEmpty ? 'Listening…' : h, style: const TextStyle(color: Colors.white, fontSize: 14)),
                    ),
            ),
            Semantics(
              button: true,
              label: 'DJ: tap to switch it up, hold to talk',
              child: Tooltip(
                message: 'Tap: switch it up · Hold: talk to your DJ',
                child: GestureDetector(
                  key: const Key('djFloatingButton'),
                  onTap: busy ? null : dj.switchItUp,
                  onLongPressStart: (_) => _down(),
                  onLongPressEnd: (_) => _up(),
                  child: AnimatedScale(
                    scale: holding ? 1.15 : 1,
                    duration: const Duration(milliseconds: 150),
                    child: Container(
                      width: 60,
                      height: 60,
                      foregroundDecoration: glassLevel() == 0
                          ? null
                          : BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white.withValues(alpha: 0.55), width: 1),
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.center,
                                colors: [Colors.white.withValues(alpha: 0.30), Colors.white.withValues(alpha: 0)],
                              ),
                            ),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [ByteColors.pink.withValues(alpha: glassLevel() == 0 ? 1 : 0.88), ByteColors.deep.withValues(alpha: glassLevel() == 0 ? 1 : 0.88)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [BoxShadow(color: ByteColors.red.withValues(alpha: 0.45), blurRadius: listening ? 22 : 12)],
                      ),
                      child: busy
                          ? const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(listening ? Icons.mic_rounded : Icons.shuffle_rounded, color: Colors.white, size: 22),
                                const Text('DJ', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1)),
                              ],
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
  }
}
