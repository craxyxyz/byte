// Byte © 2026 Apurba Laskar.
import 'package:byte/audiolab/audio_lab.dart';

/// A backend that records everything (tests).
class FakeSoundBackend extends SoundBackend {
  @override
  SoundCaps caps;
  FakeSoundBackend([this.caps = SoundCaps.android]);
  final Set<int> sessions = {};
  final List<String> log = [];
  final List<Map<String, Object?>> applied = [];

  /// What every live session hears now (the last config, if any session).
  Map<String, Object?>? get live => applied.isEmpty ? null : applied.last;

  /// The config each session got when it was attached or last updated.
  final Map<int, Map<String, Object?>> perSession = {};

  @override
  Future<void> attach(int session) async {
    sessions.add(session);
    log.add('attach $session');
  }

  @override
  Future<void> detach(int session) async {
    sessions.remove(session);
    perSession.remove(session);
    log.add('detach $session');
  }

  @override
  Future<void> apply(AudioLab lab, Map<String, Object?> config) async {
    applied.add(config);
    for (final s in sessions) {
      perSession[s] = config;
    }
  }
}
