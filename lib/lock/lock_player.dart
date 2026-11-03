import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What the lock-screen player shows about the song playing.
@immutable
class LockTrack {
  final String title;
  final String? artist;
  final String? artUrl;
  final Uint8List? artBytes; // when the art isn't a web/file address (local songs)
  final Duration? duration;
  const LockTrack({required this.title, this.artist, this.artUrl, this.artBytes, this.duration});
}

/// One snapshot of the player, with the position as of [positionAt].
@immutable
class LockSnapshot {
  final LockTrack? track;
  final bool playing;
  final Duration position;
  final DateTime positionAt;
  final double speed;
  final double? volume; // 0..1, null when the phone's volume can't be read
  LockSnapshot({this.track, this.playing = false, this.position = Duration.zero, DateTime? positionAt, this.speed = 1, this.volume})
    : positionAt = positionAt ?? DateTime.now();

  /// The live position: extrapolated while playing, clamped to the song's length.
  Duration positionNow([DateTime? now]) {
    var p = position;
    if (playing) {
      final dt = (now ?? DateTime.now()).difference(positionAt);
      if (dt > Duration.zero) p += dt * speed;
    }
    final d = track?.duration;
    if (d != null && d > Duration.zero && p > d) p = d;
    return p < Duration.zero ? Duration.zero : p;
  }
}

/// The player the lock screen drives. In the lock-screen window this talks to
/// the real playback service through Android's media session (so it is the
/// same player as the app's); inside the app (preview) and in tests it wraps
/// the app's own handler.
abstract class LockPlayer extends ChangeNotifier {
  LockSnapshot get state;
  Future<void> play();
  Future<void> pause();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration to);
  Future<void> setVolume(double v);
}

/// The lock-screen window's player: Android's media session, via the
/// `byte/lockplayer` channel opened by LockScreenActivity.
class ChannelLockPlayer extends LockPlayer {
  final MethodChannel channel;
  LockSnapshot _state = LockSnapshot();
  final _actions = StreamController<String>.broadcast();

  ChannelLockPlayer([this.channel = const MethodChannel('byte/lockplayer')]) {
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'state':
          _state = stateFromMap((call.arguments as Map).cast<String, Object?>());
          notifyListeners();
        case 'volume':
          final v = (call.arguments as num?)?.toDouble();
          _state = LockSnapshot(
            track: _state.track,
            playing: _state.playing,
            position: _state.position,
            positionAt: _state.positionAt,
            speed: _state.speed,
            volume: v,
          );
          notifyListeners();
        case 'shown':
          _actions.add('shown');
      }
      return null;
    });
  }

  /// 'shown' each time the window comes back on screen.
  Stream<String> get actions => _actions.stream;

  /// Parses the native snapshot (pure, unit-testable).
  static LockSnapshot stateFromMap(Map<String, Object?> m, {DateTime? now}) {
    final title = m['title'] as String?;
    final durMs = (m['durationMs'] as num?)?.toInt();
    final art = m['artBytes'];
    final artist = (m['artist'] as String?)?.trim();
    return LockSnapshot(
      track: title == null
          ? null
          : LockTrack(
              title: title,
              artist: artist == null || artist.isEmpty ? null : artist,
              artUrl: m['artUri'] as String?,
              artBytes: art is Uint8List ? art : null,
              duration: durMs == null || durMs <= 0 ? null : Duration(milliseconds: durMs),
            ),
      playing: m['playing'] == true,
      position: Duration(milliseconds: (m['positionMs'] as num?)?.toInt() ?? 0),
      positionAt: now ?? DateTime.now(),
      speed: (m['speed'] as num?)?.toDouble() ?? 1,
      volume: (m['volume'] as num?)?.toDouble(),
    );
  }

  Future<void> ready() => _call('ready');
  Future<void> unlock() => _call('unlock');
  Future<void> hide() => _call('hide');

  Future<void> _call(String m, [Object? a]) async {
    try {
      await channel.invokeMethod(m, a);
    } catch (_) {}
  }

  @override
  LockSnapshot get state => _state;
  @override
  Future<void> play() => _call('play');
  @override
  Future<void> pause() => _call('pause');
  @override
  Future<void> next() => _call('next');
  @override
  Future<void> previous() => _call('previous');
  @override
  Future<void> seek(Duration to) => _call('seek', {'ms': to.inMilliseconds});
  @override
  Future<void> setVolume(double v) async {
    _state = LockSnapshot(
      track: _state.track,
      playing: _state.playing,
      position: _state.position,
      positionAt: _state.positionAt,
      speed: _state.speed,
      volume: v,
    );
    notifyListeners();
    await _call('setVolume', {'v': v});
  }
}
