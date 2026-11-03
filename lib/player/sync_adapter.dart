import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../data/listen_together.dart';
import 'byte_handler.dart';

/// Lets Listen together drive (and watch) Byte's real player.
class HandlerSyncPlayer implements SyncPlayer {
  final ByteAudioHandler h;
  final ValueNotifier<int> _changes = ValueNotifier(0);
  final List<StreamSubscription> _subs = [];
  bool? _lastPlaying;
  int _lastPosMs = 0;
  DateTime _lastAt = DateTime.now();
  String? _lastId;

  HandlerSyncPlayer(this.h) {
    h.current.addListener(_bump);
    _subs.add(
      // Real sound, not the lock screen's "playing": during the pause between
      // songs (1.4.5) the party hears the next song start when the host's does.
      h.playbackState.listen((_) {
        final now = h.audible;
        if (now != _lastPlaying) {
          _lastPlaying = now;
          _bump();
        }
      }),
    );
    // A jump in position that normal playback can't explain = a seek.
    _subs.add(
      Stream.periodic(const Duration(milliseconds: 500)).listen((_) {
        final now = DateTime.now();
        final pos = h.position.inMilliseconds;
        // A new song starts at 0:00: that's not a seek.
        final id = h.current.value?.id;
        if (id != _lastId) {
          _lastId = id;
          _lastPosMs = pos;
          _lastAt = now;
          return;
        }
        final expected = _lastPosMs + (h.audible ? now.difference(_lastAt).inMilliseconds : 0);
        if ((pos - expected).abs() > 1500 && h.current.value != null) _bump();
        _lastPosMs = pos;
        _lastAt = now;
      }),
    );
  }

  void _bump() => _changes.value++;

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
    if (!play) await h.pause();
  }

  @override
  Future<void> seekTo(Duration d) => h.seek(d);

  @override
  Future<void> setPlaying(bool play) => play ? h.play() : h.pause();

  void dispose() {
    h.current.removeListener(_bump);
    for (final s in _subs) {
      s.cancel();
    }
  }
}
