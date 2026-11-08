import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/player/desktop_sound.dart';

/// Fake engine: records every call, answers status from a script.
class FakeEngine implements DesktopEngineBridge {
  final calls = <String>[];
  final opened = <String>[];
  int nextId = 7;
  EngineStatus next = const EngineStatus(state: 'ready', posMs: 0, durMs: 180000, playing: false, error: '', queuedMs: 0);
  Map<String, Object?>? lastChain;

  @override
  Future<int> create() async {
    calls.add('create');
    return nextId;
  }

  @override
  Future<void> dispose(int id) async => calls.add('dispose $id');
  @override
  Future<void> open(int id, String source, int startMs) async {
    calls.add('open $startMs');
    opened.add(source);
  }

  @override
  Future<void> play(int id) async => calls.add('play');
  @override
  Future<void> pause(int id) async => calls.add('pause');
  @override
  Future<void> seek(int id, int ms) async => calls.add('seek $ms');
  @override
  Future<void> volume(int id, double volume) async => calls.add('volume');
  @override
  Future<EngineStatus> status(int id) async => next;
  @override
  Future<void> setChain(Map<String, Object?> chain) async {
    calls.add('chain');
    lastChain = chain;
  }

  @override
  Future<bool> overlayInit() async => true;
  @override
  Future<void> overlayUpdate(Map<String, Object?> m) async => calls.add('overlay');
  @override
  Future<List<String>> overlayPoll() async => const [];
}

/// Fake normal player (the system one): records calls, emits nothing.
class FakePlayer extends AudioPlayerPlatform {
  FakePlayer(super.id);
  final calls = <String>[];
  final _events = StreamController<PlaybackEventMessage>.broadcast();
  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => _events.stream;
  @override
  Future<LoadResponse> load(LoadRequest request) async {
    calls.add('load ${request.initialPosition?.inMilliseconds ?? 0}');
    return LoadResponse(duration: const Duration(minutes: 3));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    calls.add('play');
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    calls.add('pause');
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async => SetVolumeResponse();
  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    calls.add('seek ${request.position?.inMilliseconds}');
    return SeekResponse();
  }

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    calls.add('dispose');
    return DisposeResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async => SetSpeedResponse();
  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) async => SetPitchResponse();
}

class FakeHost extends JustAudioPlatform {
  final players = <FakePlayer>[];
  @override
  Future<DisposePlayerResponse> disposePlayer(DisposePlayerRequest request) async {
    players.removeWhere((p) => p.id == request.id);
    return DisposePlayerResponse();
  }

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = FakePlayer(request.id);
    players.add(p);
    return p;
  }
}

UriAudioSourceMessage uriSource(String uri) => ProgressiveAudioSourceMessage(id: 'a', uri: uri);

AudioLab labWithEq() {
  final lab = AudioLab()..openForTest();
  lab.eqOn = true;
  return lab;
}

void main() {
  group('biquad design (the same numbers as the on-screen curve)', () {
    test('a peak point gives its own gain at its centre frequency', () {
      for (final g in [-9.0, -3.0, 4.5, 12.0]) {
        final db = EqMath.nodeDb(const EqNode(EqNodeType.peak, 1000, 0, 1.0).copyWith(g: g), 1000);
        expect(db, closeTo(g, 0.01), reason: 'peak at ${g}dB');
      }
    });

    test('a low shelf is the gain at DC and flat at 20 kHz', () {
      const n = EqNode(EqNodeType.lowShelf, 200, 6, 0.7);
      expect(EqMath.nodeDb(n, 20), closeTo(6, 0.05));
      expect(EqMath.nodeDb(n, 16000), closeTo(0, 0.05));
    });

    test('a high shelf is the gain at 20 kHz and flat at 20 Hz', () {
      const n = EqNode(EqNodeType.highShelf, 4000, -5, 0.7);
      expect(EqMath.nodeDb(n, 20000), closeTo(-5, 0.2));
      expect(EqMath.nodeDb(n, 20), closeTo(0, 0.05));
    });

    test('a flat point gives no section', () {
      expect(EqMath.sectionCoefficients(const EqNode(EqNodeType.peak, 1000, 0, 1)), isNull);
    });
  });

  group('chain encoding', () {
    test('an untouched Audio Lab sends no effects', () {
      final lab = AudioLab()..openForTest();
      expect(desktopEffectsOn(lab), isFalse);
      final c = encodeDesktopChain(lab);
      expect(c['eqOn'], isFalse);
      expect(c['reverbOn'], isFalse);
      expect(c['mono'], isFalse);
      expect(c['eq'], isEmpty);
    });

    test('an equalizer point becomes one section and turns effects on', () {
      final lab = labWithEq();
      lab.nodes = [const EqNode(EqNodeType.peak, 1000, 6, 1)];
      expect(desktopEffectsOn(lab), isTrue);
      final c = encodeDesktopChain(lab);
      expect((c['eq'] as List), hasLength(1));
      expect(c['eqOn'], isTrue);
      expect(c['limit'], 0.89);
    });

    test('mono and balance are carried', () {
      final lab = AudioLab()..openForTest();
      lab.mono = true;
      lab.balance = -0.4;
      final c = encodeDesktopChain(lab);
      expect(c['mono'], isTrue);
      expect(c['balance'], closeTo(-0.4, 1e-9));
      expect(desktopEffectsOn(lab), isTrue);
    });
  });

  group('routing between the normal player and the engine', () {
    late FakeEngine engine;
    late FakeHost host;
    late DesktopEngineBridge savedBridge;
    late TargetPlatform? savedOverride;

    setUp(() {
      engine = FakeEngine();
      host = FakeHost();
      savedBridge = DesktopSound.bridge;
      DesktopSound.bridge = engine;
      DesktopSound.effectsOn = false;
      DesktopSound.chain = null;
      savedOverride = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    });

    tearDown(() {
      DesktopSound.bridge = savedBridge;
      DesktopSound.effectsOn = false;
      DesktopSound.players.clear();
      debugDefaultTargetPlatformOverride = savedOverride;
    });

    test('without effects a song goes to the normal player', () async {
      final sw = SwitchPlayer('p', FakePlayer('p'));
      await sw.load(LoadRequest(audioSourceMessage: uriSource('https://x/y.m4a')));
      expect(sw.onEngine, isFalse);
      expect(engine.calls, isNot(contains('open 0')));
      await sw.play(PlayRequest());
      expect((sw.inner as FakePlayer).calls, containsAllInOrder(['load 0', 'play']));
    });

    test('with effects on a song goes to the engine and plays there', () async {
      DesktopSound.effectsOn = true;
      final sw = SwitchPlayer('p', FakePlayer('p'));
      await sw.load(LoadRequest(audioSourceMessage: uriSource('https://x/y.m4a')));
      expect(sw.onEngine, isTrue);
      expect(engine.opened, ['https://x/y.m4a']);
      await sw.play(PlayRequest());
      expect(engine.calls, contains('play'));
      expect((sw.inner as FakePlayer).calls, isNot(contains('play')));
      await sw.dispose(DisposeRequest());
    });

    test('a speed other than 1 keeps the normal player', () async {
      DesktopSound.effectsOn = true;
      final sw = SwitchPlayer('p', FakePlayer('p'));
      await sw.setSpeed(SetSpeedRequest(speed: 1.25));
      await sw.load(LoadRequest(audioSourceMessage: uriSource('https://x/y.m4a')));
      expect(sw.onEngine, isFalse);
      await sw.dispose(DisposeRequest());
    });

    test('a file path goes to the engine as a path', () async {
      DesktopSound.effectsOn = true;
      final sw = SwitchPlayer('p', FakePlayer('p'));
      await sw.load(LoadRequest(audioSourceMessage: uriSource('file:///C:/music/a.flac')));
      expect(sw.onEngine, isTrue);
      expect(engine.opened.single.toLowerCase(), contains('music'));
      await sw.dispose(DisposeRequest());
    });

    test('turning effects on mid-song moves the deck at the same spot, playing', () async {
      final sw = SwitchPlayer('p', FakePlayer('p'));
      await sw.load(LoadRequest(audioSourceMessage: uriSource('https://x/y.m4a'), initialPosition: const Duration(seconds: 30)));
      await sw.play(PlayRequest());
      expect(sw.onEngine, isFalse);
      final lab = AudioLab()..openForTest();
      lab.mono = true;
      await DesktopSound.setEffects(lab);
      expect(DesktopSound.effectsOn, isTrue);
      expect(sw.onEngine, isTrue, reason: 'effects on moves the deck');
      expect(engine.calls, containsAllInOrder(['open 30000', 'play']), reason: 'same spot, and it keeps playing');
      await sw.dispose(DisposeRequest());
    });

    test('a changed chain is sent once, an unchanged one is not sent again', () async {
      final lab = AudioLab()..openForTest();
      lab.mono = true;
      await DesktopSound.setEffects(lab);
      final before = engine.calls.where((c) => c == 'chain').length;
      await DesktopSound.setEffects(lab);
      expect(engine.calls.where((c) => c == 'chain').length, before);
      expect(engine.lastChain!['mono'], isTrue);
    });

    test('the platform switch wraps each player it creates', () async {
      final sw = ByteSwitchPlatform(host);
      final p = await sw.init(InitRequest(id: 'deck1'));
      expect(p, isA<SwitchPlayer>());
      await sw.disposePlayer(DisposePlayerRequest(id: 'deck1'));
    });
  });
}
