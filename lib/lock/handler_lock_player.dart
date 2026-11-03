import 'dart:async';

import '../player/audio_route.dart';
import '../player/byte_handler.dart';
import 'lock_player.dart';

/// The lock-screen player wired straight to the app's own handler (the
/// in-app preview from Settings, and tests).
class HandlerLockPlayer extends LockPlayer {
  final ByteAudioHandler handler;
  final AudioRoute? route;
  final List<StreamSubscription<Object?>> _subs = [];
  LockSnapshot _state = LockSnapshot();

  HandlerLockPlayer(this.handler, {this.route}) {
    _subs.add(handler.mediaItem.listen((_) => _refresh()));
    _subs.add(handler.playbackState.listen((_) => _refresh()));
    route?.addListener(_refresh);
    _refresh();
  }

  void _refresh() {
    final m = handler.mediaItem.valueOrNull;
    final ps = handler.playbackState.valueOrNull;
    _state = LockSnapshot(
      track: m == null ? null : LockTrack(title: m.title, artist: m.artist, artUrl: m.artUri?.toString(), duration: m.duration),
      playing: ps?.playing ?? handler.playing,
      position: handler.position,
      speed: ps?.speed ?? 1,
      volume: route?.volume,
    );
    notifyListeners();
  }

  @override
  LockSnapshot get state => _state;
  @override
  Future<void> play() => handler.play();
  @override
  Future<void> pause() => handler.pause();
  @override
  Future<void> next() => handler.skipToNext();
  @override
  Future<void> previous() => handler.skipToPrevious();
  @override
  Future<void> seek(Duration to) async {
    await handler.seek(to);
    _refresh();
  }

  @override
  Future<void> setVolume(double v) async {
    await route?.setVolume(v, playerVolume: handler.setAppVolume);
    _refresh();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    route?.removeListener(_refresh);
    super.dispose();
  }
}
