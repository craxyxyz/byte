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

  HandlerSyncPlayer(this.h) {
    h.current.addListener(_bump);
    _subs.add(
      h.playbackState.listen((s) {
        if (s.playing != _lastPlaying) {
          _lastPlaying = s.playing;
          _bump();
        }
      }),
    );
    // A jump in position that normal playback can't explain = a seek.
    _subs.add(
      Stream.periodic(const Duration(milliseconds: 500)).listen((_) {
        final now = DateTime.now();
        final pos = h.position.inMilliseconds;
        final expected = _lastPosMs + (h.playing ? now.difference(_lastAt).inMilliseconds : 0);
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
  bool get isPlaying => h.playing;

  @override
  Future<void> load(Item item, Duration at, {required bool play}) async {
    await h.playItems([item]);
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
