import 'dart:async';

import 'package:audio_service/audio_service.dart' show AudioProcessingState;
import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../data/listen_together.dart';
import 'byte_handler.dart';

/// Lets Listen together drive (and watch) Byte's real player.
class HandlerSyncPlayer implements SyncPlayer, PartyClockPlayer, PartyHoldPlayer {
  final ByteAudioHandler h;
  final ValueNotifier<int> _changes = ValueNotifier(0);
  final List<StreamSubscription> _subs = [];
  bool? _lastPlaying;

  HandlerSyncPlayer(this.h) {
    h.current.addListener(_onSong);
    _subs.add(
      // Real sound, not the lock screen's "playing": during the pause between
      // songs (1.4.5) the party hears the next song start when the host's does.
      h.playbackState.listen((_) {
        final st = stalled;
        if (st && !_wasStalled) stallCount++;
        _wasStalled = st;
        final now = h.audible;
        if (now != _lastPlaying) {
          _lastPlaying = now;
          _bump();
        }
      }),
    );
    // 1.4.5: a seek is the player saying it seeked, not a position jump
    // (a desktop host's coarse or briefly-zero position looked like a seek
    // and pulled every guest back: the "part of the song repeats" bug).
    h.seeks.addListener(_bump);
  }

  void _bump() => _changes.value++;

  // 1.4.6: a new song is one change. Its "playing" is read with it, so the
  // sound stopping for the switch isn't sent again as a second change (it
  // was logged as "Seeked to 0:00" and then a "Played" tap).
  void _onSong() {
    _lastPlaying = h.audible;
    _bump();
  }

  bool _wasStalled = false;

  // ── 1.4.5 party clock ─────────────────────────────────────────────────
  @override
  int stallCount = 0;

  /// Meant to play, but the stream is buffering (no sound, position frozen).
  @override
  bool get stalled {
    if (h.remote != null || h.inGap || !h.audible) return false;
    final ps = h.playbackState.value.processingState;
    return ps == AudioProcessingState.buffering || ps == AudioProcessingState.loading;
  }

  @override
  Future<void> setRate(double r) => h.setPartyRate(r);

  @override
  Item? get upNext => h.queueModel.nextItem;

  @override
  int? get startsInMs {
    final at = h.gapEndsAt;
    if (at == null || !h.inGap) return null;
    final ms = at.difference(DateTime.now()).inMilliseconds;
    return ms < 0 ? 0 : ms;
  }

  @override
  Listenable get changes => _changes;
  @override
  Item? get item => h.current.value;
  @override
  Duration get position => h.position;
  @override
  bool get isPlaying => h.audible;

  @override
  Future<void> load(Item item, Duration at, {required bool play}) async {
    // Paused: load it without a blip of sound first.
    await h.playItems([item], startPaused: !play);
    if (at > const Duration(seconds: 1)) await h.seek(at);
    if (!play) await h.partyPause(); // the party paused it, not the person
    h.partyMoved();
  }

  @override
  set partyHold(bool v) => h.partyHold = v;

  @override
  Future<void> seekTo(Duration d) => h.seek(d);

  @override
  Future<void> setPlaying(bool play) async {
    if (play) return h.play();
    await h.partyPause();
  }

  void dispose() {
    h.current.removeListener(_onSong);
    h.seeks.removeListener(_bump);
    for (final s in _subs) {
      s.cancel();
    }
  }
}
