// Byte © 2026 Apurba Laskar
//
// 1.4.5 QA: keys on a computer / the web. Before, Space scrolled the page
// (or the lyrics, which then went full screen again) and never paused.
// Text fields keep their keys: Flutter's text editing stops Space and the
// arrows from reaching these app-wide shortcuts while typing.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../services.dart';

class PlayPauseIntent extends Intent {
  const PlayPauseIntent();
}

class NextSongIntent extends Intent {
  const NextSongIntent();
}

class PreviousSongIntent extends Intent {
  const PreviousSongIntent();
}

class SeekByIntent extends Intent {
  final int seconds;
  const SeekByIntent(this.seconds);
}

/// Space / media key: play or pause · Ctrl (⌘) + → / ←: next / previous song
/// · Shift + → / ←: 10 s forward / back. Added on top of Flutter's own keys.
Map<ShortcutActivator, Intent> byteShortcuts(Map<ShortcutActivator, Intent> base) => {
  ...base,
  const SingleActivator(LogicalKeyboardKey.space): const PlayPauseIntent(),
  const SingleActivator(LogicalKeyboardKey.mediaPlayPause): const PlayPauseIntent(),
  const SingleActivator(LogicalKeyboardKey.mediaTrackNext): const NextSongIntent(),
  const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): const PreviousSongIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): const NextSongIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): const PreviousSongIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowRight, meta: true): const NextSongIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowLeft, meta: true): const PreviousSongIntent(),
  const SingleActivator(LogicalKeyboardKey.arrowRight, shift: true): const SeekByIntent(10),
  const SingleActivator(LogicalKeyboardKey.arrowLeft, shift: true): const SeekByIntent(-10),
};

Map<Type, Action<Intent>> byteActions(Map<Type, Action<Intent>> base) => {
  ...base,
  PlayPauseIntent: CallbackAction<PlayPauseIntent>(
    onInvoke: (_) {
      final p = Services.i.player;
      if (p.current.value == null) return null;
      p.playing ? p.pause() : p.play();
      return null;
    },
  ),
  NextSongIntent: CallbackAction<NextSongIntent>(
    onInvoke: (_) {
      if (Services.i.player.current.value != null) Services.i.player.skipToNext();
      return null;
    },
  ),
  PreviousSongIntent: CallbackAction<PreviousSongIntent>(
    onInvoke: (_) {
      if (Services.i.player.current.value != null) Services.i.player.skipToPrevious();
      return null;
    },
  ),
  SeekByIntent: CallbackAction<SeekByIntent>(
    onInvoke: (i) {
      final p = Services.i.player;
      if (p.current.value == null) return null;
      var to = p.position + Duration(seconds: i.seconds);
      final d = p.duration;
      if (to < Duration.zero) to = Duration.zero;
      if (d != null && d > Duration.zero && to > d) to = d - const Duration(milliseconds: 500);
      p.seek(to);
      return null;
    },
  ),
};
