import 'dart:io';

import 'package:byte/automix/analysis.dart';
import 'package:byte/automix/automix_service.dart';
import 'package:byte/automix/planner.dart';
import 'package:byte/core/models.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/equalizer.dart';
import 'package:byte/player/queue.dart' as q;
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Automix test double: analyses are handed in, "fetching" takes a moment.
class FakeAutomix extends AutomixService {
  final Map<String, TrackAnalysis> known;
  final Set<String> ready = {};
  final Set<String> failing;
  final Set<String> prepared = {};
  Duration delay;
  FakeAutomix(Services sv, this.known, {this.failing = const {}, this.delay = const Duration(milliseconds: 60)})
    : super(resolver: sv.resolver, library: sv.library, settings: sv.settings);

  @override
  TrackAnalysis? analysisOf(String id) => ready.contains(id) ? known[id] : null;
  @override
  String? cachedFile(String id) => null; // play the (fake) streams
  final Set<String> _busy = {};
  @override
  bool isPreparing(String id) => _busy.contains(id);
  @override
  Future<AutomixTrack> prepare(Item it, {bool preferMp4 = false}) async {
    prepared.add(it.id);
    _busy.add(it.id);
    await Future<void>.delayed(delay);
    _busy.remove(it.id);
    if (failing.contains(it.id)) return const AutomixTrack(null, null);
    ready.add(it.id);
    return AutomixTrack(null, known[it.id]);
  }

  @override
  Future<void> trim(Set<String> keep) async {}
}

TrackAnalysis beatTrack({required int durMs, double bpm = 120, int start = 0, int? end, int? outro, double loud = -12, double conf = 0.9}) {
  final e = end ?? durMs;
  final p = 60000 / bpm;
  return TrackAnalysis(
    durationMs: durMs,
    bpm: bpm,
    beatConfidence: conf,
    beatsMs: [for (var t = start.toDouble(); t <= e; t += p) t.round()],
    downbeat: 0,
    loudnessDb: loud,
    audioStartMs: start,
    introEndMs: start,
    outroStartMs: outro ?? e,
    audioEndMs: e,
    energy: 0.5,
  );
}

Item s(String id, {int sec = 24}) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: sec);

/// The real player with Automix on, against a fake audio engine that plays
/// in real time. Covers the bug-hunt list: skip / seek / pause during a
/// blend, a failed analysis, short songs, long silent outros, queue end,
/// and a network drop while the next song is fetched.
void main() {
  late Services sv;
  late ByteAudioHandler p;
  late FakeAutomix ax;
  late ByteEqualizer eq;
  final durations = <String, int>{};

  Future<ByteAudioHandler> build(Map<String, TrackAnalysis> an, {Set<String> failing = const {}}) async {
    ax = FakeAutomix(sv, an, failing: failing);
    eq = ByteEqualizer(sv.settings, ios: true);
    final h = ByteAudioHandler(resolver: sv.resolver, yt: sv.yt, library: sv.library, settings: sv.settings, automix: ax, equalizer: eq);
    return h;
  }

  setUp(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.normalizeVolume = true;
    sv.settings.verifyStreams = false;
    sv.settings.automix = true;
    sv.settings.automixSmart = false; // 2.0.0+2003 default: Simple, exactly the lead before the end
    // automixSeconds is left at its default: 8.5 s
    sv.settings.crossfadeSeconds = 0;
    durations.clear();
    fakeAudio.durationFor = (uri) {
      final m = RegExp(r'media\.example/([^/]+)/').firstMatch(uri);
      return Duration(milliseconds: durations[m?.group(1)] ?? 24000);
    };
  });
  tearDown(() async {
    await p.stop();
    await p.disposeAll();
  });

  Future<void> until(bool Function() ok, {int ms = 12000, String? why}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) {
        fail(
          'timed out${why == null ? '' : ': $why'}; now ${p.current.value?.id}, fading ${p.inTransition}, '
          'decks ${fakeAudio.players.values.map((x) => '${x.uri?.split('/').elementAtOrNull(3)} ${x.playing ? 'playing' : 'stopped'} ${x.position.inMilliseconds}/${x.duration?.inMilliseconds} v${x.volume.toStringAsFixed(2)} s${x.speed.toStringAsFixed(3)}').toList()}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  FakePlayerPlatform deckOf(String id) => fakeAudio.players.values.lastWhere((x) => x.uri?.contains('/$id/') ?? false);
  Iterable<FakePlayerPlatform> playingDecks() => fakeAudio.players.values.where((x) => x.playing);

  test('2.0.0+2003 Automix: the next song starts 8.5 s before the music ends and overlaps; no gap', () async {
    expect(sv.settings.automixSeconds, 8.5);
    durations.addAll({'mixAAAAAAA1': 32000, 'mixAAAAAAA2': 40000});
    p = await build({
      'mixAAAAAAA1': beatTrack(durMs: 32000, bpm: 124, end: 28000, loud: -9), // 4 s of silence at the end
      'mixAAAAAAA2': beatTrack(durMs: 40000, bpm: 120, start: 600, loud: -14),
    });
    expect(sv.settings.automix, isTrue);
    await p.playItems([s('mixAAAAAAA1'), s('mixAAAAAAA2', sec: 40)]);
    await until(() => ax.ready.contains('mixAAAAAAA1'));
    await p.seek(const Duration(seconds: 16));
    await until(() => ax.ready.contains('mixAAAAAAA2'));
    // the plan itself: music ends at 28 s -> starts at 19.5 s, 8.5 s long
    final plan = p.planFor(s('mixAAAAAAA1'), s('mixAAAAAAA2', sec: 40), 32000);
    expect(plan.startAtMs, 19500);
    expect(plan.fadeMs, 8500);
    // wait for the second deck to start while the first is still playing
    var outPosAtStart = -1;
    await until(() {
      final ds = playingDecks().toList();
      if (ds.length == 2 && outPosAtStart < 0) outPosAtStart = deckOf('mixAAAAAAA1').position.inMilliseconds;
      return outPosAtStart >= 0;
    }, ms: 15000, why: 'overlap never started');
    expect(outPosAtStart, inInclusiveRange(19300, 20300), reason: 'next song starts ~8.5 s before the music ends (28 s)');
    expect(p.inTransition, isTrue);
    expect(p.current.value!.id, 'mixAAAAAAA2');
    // ...and the blend ends on the next song alone, with no silence in between
    var quiet = false;
    await until(() {
      if (playingDecks().isEmpty) quiet = true;
      return !p.inTransition && playingDecks().length == 1;
    }, ms: 12000);
    expect(quiet, isFalse, reason: 'never silent between the songs');
    final inDeck = deckOf('mixAAAAAAA2');
    expect(playingDecks().single.uri, contains('mixAAAAAAA2'));
    expect(inDeck.position.inMilliseconds, greaterThan(600 + 6000)); // it began at its first sound (600 ms) and has played the blend
    expect(inDeck.speed, 1.0);
    expect(inDeck.volume, closeTo(1.0, 0.001)); // -14 LUFS: no turn-down
  });

  test('2.0.0+2003 Automix: the lead is a setting (2–15 s) and the plan follows it; short songs get a short blend', () async {
    durations.addAll({'ldAAAAAAAA1': 24000, 'ldAAAAAAAA2': 30000});
    p = await build({'ldAAAAAAAA1': beatTrack(durMs: 24000), 'ldAAAAAAAA2': beatTrack(durMs: 30000)});
    await p.playItems([s('ldAAAAAAAA1'), s('ldAAAAAAAA2', sec: 30)]);
    await until(() => ax.ready.contains('ldAAAAAAAA1') && ax.ready.contains('ldAAAAAAAA2'));
    sv.settings.automixSeconds = 6;
    var plan = p.planFor(s('ldAAAAAAAA1'), s('ldAAAAAAAA2', sec: 30), 24000);
    expect((plan.startAtMs, plan.fadeMs), (18000, 6000));
    sv.settings.automixSeconds = 99;
    expect(sv.settings.automixSeconds, 15);
    sv.settings.automixSeconds = 0;
    expect(sv.settings.automixSeconds, 2);
    sv.settings.automixSeconds = 8.5;
    // a 9 s song: at most a third of it
    plan = p.planFor(s('ldAAAAAAAA1', sec: 9), s('ldAAAAAAAA2', sec: 30), 9000);
    expect(plan.fadeMs, lessThanOrEqualTo(3000));
  });

  test('2.0.0+2003 Automix: Next is instant — no blend, no gap', () async {
    durations.addAll({'nxAAAAAAAA1': 30000, 'nxAAAAAAAA2': 30000});
    p = await build({'nxAAAAAAAA1': beatTrack(durMs: 30000), 'nxAAAAAAAA2': beatTrack(durMs: 30000)});
    await p.playItems([s('nxAAAAAAAA1', sec: 30), s('nxAAAAAAAA2', sec: 30)]);
    await until(() => playingDecks().length == 1);
    await p.skipToNext();
    expect(p.inTransition, isFalse);
    expect(p.inGap, isFalse);
    await until(() => p.current.value!.id == 'nxAAAAAAAA2' && playingDecks().length == 1 && playingDecks().first.uri!.contains('/nxAAAAAAAA2/'), ms: 3000);
  });

  test('2.0.0+2003 Automix: repeat-one never blends the song into itself', () async {
    durations.addAll({'roAAAAAAAA1': 9000});
    p = await build({'roAAAAAAAA1': beatTrack(durMs: 9000)});
    p.queueModel.repeat = q.RepeatMode.one;
    await p.playItems([s('roAAAAAAAA1', sec: 9)]);
    await p.seek(const Duration(seconds: 5));
    var blended = false;
    final end = DateTime.now().add(const Duration(seconds: 7));
    while (DateTime.now().isBefore(end)) {
      if (p.inTransition) blended = true;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(blended, isFalse);
  });

  test('skip during a blend: the old song stops, no stuck tempo or bass cut, next song plays', () async {
    durations.addAll({'skpAAAAAAA1': 14000, 'skpAAAAAAA2': 30000, 'skpAAAAAAA3': 30000});
    p = await build({
      'skpAAAAAAA1': beatTrack(durMs: 14000, bpm: 124),
      'skpAAAAAAA2': beatTrack(durMs: 30000, bpm: 120),
      'skpAAAAAAA3': beatTrack(durMs: 30000, bpm: 120),
    });
    await p.playItems([s('skpAAAAAAA1', sec: 14), s('skpAAAAAAA2', sec: 30), s('skpAAAAAAA3', sec: 30)]);
    await until(() => playingDecks().length == 1);
    await until(() => ax.ready.contains('skpAAAAAAA2'));
    // 1.4.5: Automix itself no longer overlaps songs; the DJ's "Switch it up" still blends
    await p.blendToNext(ms: 4000);
    await until(() => p.inTransition);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await p.skipToNext();
    expect(p.inTransition, isFalse);
    await until(() => p.current.value!.id == 'skpAAAAAAA3');
    await until(() => playingDecks().length == 1 && playingDecks().first.uri!.contains('skpAAAAAAA3'));
    final d = playingDecks().first;
    expect(d.speed, 1.0);
    // full volume again (YouTube's loudness figure until the analysis is in)
    await until(() => d.volume > 0.69);
  });

  test('seek during a blend: blend ends cleanly on the new song', () async {
    durations.addAll({'skAAAAAAAA1': 14000, 'skAAAAAAAA2': 30000});
    p = await build({'skAAAAAAAA1': beatTrack(durMs: 14000, bpm: 124), 'skAAAAAAAA2': beatTrack(durMs: 30000, bpm: 121)});
    await p.playItems([s('skAAAAAAAA1', sec: 14), s('skAAAAAAAA2', sec: 30)]);
    await until(() => playingDecks().length == 1);
    await until(() => ax.ready.contains('skAAAAAAAA2'));
    await p.blendToNext(ms: 4000); // the DJ's blend (Automix itself no longer overlaps)
    await until(() => p.inTransition);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await p.seek(const Duration(seconds: 10));
    expect(p.inTransition, isFalse);
    expect(p.current.value!.id, 'skAAAAAAAA2');
    await until(() => playingDecks().length == 1 && (playingDecks().first.uri?.contains('/skAAAAAAAA2/') ?? false));
    final d = playingDecks().single;
    expect(d.uri, contains('skAAAAAAAA2'));
    expect(d.position.inMilliseconds, inInclusiveRange(9900, 11000));
    expect(d.speed, 1.0);
    expect(d.volume, closeTo(loudnessGain(-12), 0.01));
  });

  test('pause during a blend: everything stops; play carries on with the new song alone', () async {
    durations.addAll({'paAAAAAAAA1': 14000, 'paAAAAAAAA2': 30000});
    p = await build({'paAAAAAAAA1': beatTrack(durMs: 14000), 'paAAAAAAAA2': beatTrack(durMs: 30000)});
    await p.playItems([s('paAAAAAAAA1', sec: 14), s('paAAAAAAAA2', sec: 30)]);
    await until(() => playingDecks().length == 1);
    await until(() => ax.ready.contains('paAAAAAAAA2'));
    await p.blendToNext(ms: 4000); // the DJ's blend (Automix itself no longer overlaps)
    await until(() => p.inTransition);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await p.pause();
    expect(playingDecks(), isEmpty);
    expect(p.inTransition, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await p.play();
    await until(() => playingDecks().length == 1);
    expect(playingDecks().single.uri, contains('paAAAAAAAA2'));
    expect(playingDecks().single.volume, closeTo(loudnessGain(-12), 0.01));
  });

  test('analysis fails: still moves on (a plain crossfade at the lead)', () async {
    durations.addAll({'faAAAAAAAA1': 12000, 'faAAAAAAAA2': 30000});
    p = await build({}, failing: {'faAAAAAAAA1', 'faAAAAAAAA2'});
    await p.playItems([s('faAAAAAAAA1', sec: 12), s('faAAAAAAAA2', sec: 30)]);
    final plan = p.planFor(s('faAAAAAAAA1', sec: 12), s('faAAAAAAAA2', sec: 30), 12000);
    expect(plan.kind, 'fallback');
    await p.seek(const Duration(seconds: 8));
    var overlap = false;
    await until(() {
      if (playingDecks().length == 2) overlap = true;
      final playing = playingDecks().toList();
      return p.current.value!.id == 'faAAAAAAAA2' && playing.length == 1 && (playing.first.uri?.contains('/faAAAAAAAA2/') ?? false);
    });
    expect(overlap, isTrue);
  });

  test('short songs (< 30 s): short blends, every song plays, ends at queue end', () async {
    durations.addAll({'shAAAAAAAA1': 9000, 'shAAAAAAAA2': 8000, 'shAAAAAAAA3': 7000});
    sv.settings.automixSeconds = 12;
    p = await build({
      'shAAAAAAAA1': beatTrack(durMs: 9000, bpm: 120),
      'shAAAAAAAA2': beatTrack(durMs: 8000, bpm: 122),
      'shAAAAAAAA3': beatTrack(durMs: 7000, bpm: 118),
    });
    final seen = <String>[];
    p.current.addListener(() => seen.add(p.current.value!.id));
    await p.playItems([s('shAAAAAAAA1', sec: 9), s('shAAAAAAAA2', sec: 8), s('shAAAAAAAA3', sec: 7)]);
    await until(() => p.current.value!.id == 'shAAAAAAAA3', ms: 30000); // 1.4.5: 2.5 s between songs
    // the last song finishes and nothing else starts (queue end, autoplay off)
    await until(() => playingDecks().isEmpty, ms: 12000);
    expect(seen.toSet(), {'shAAAAAAAA1', 'shAAAAAAAA2', 'shAAAAAAAA3'});
    expect(p.inTransition, isFalse);
    expect(p.current.value!.id, 'shAAAAAAAA3');
  });

  test('queue end: no blend into nothing', () async {
    durations.addAll({'enAAAAAAAA1': 8000});
    p = await build({'enAAAAAAAA1': beatTrack(durMs: 8000)});
    await p.playItems([s('enAAAAAAAA1', sec: 8)]);
    await p.seek(const Duration(seconds: 5));
    await until(() => playingDecks().isEmpty, ms: 8000);
    expect(p.inTransition, isFalse);
  });

  test('net drop while fetching the next song: plain crossfade from the stream instead', () async {
    durations.addAll({'ndAAAAAAAA1': 14000, 'ndAAAAAAAA2': 30000});
    p = await build({'ndAAAAAAAA1': beatTrack(durMs: 14000)}, failing: {'ndAAAAAAAA2'});
    await p.playItems([s('ndAAAAAAAA1', sec: 14), s('ndAAAAAAAA2', sec: 30)]);
    await p.seek(const Duration(seconds: 7));
    await until(
      () => p.current.value!.id == 'ndAAAAAAAA2' && playingDecks().length == 1 && (playingDecks().first.uri?.contains('/ndAAAAAAAA2/') ?? false),
      ms: 12000,
    );
    expect(playingDecks().single.uri, contains('ndAAAAAAAA2'));
  });

  test('ducking for the DJ voice lowers and restores the music', () async {
    durations.addAll({'dkAAAAAAAA1': 30000});
    p = await build({'dkAAAAAAAA1': beatTrack(durMs: 30000)});
    await p.playItems([s('dkAAAAAAAA1', sec: 30)]);
    await until(() => playingDecks().length == 1);
    final d = playingDecks().single;
    final base = d.volume;
    await p.duck(0.25, ms: 200);
    expect(d.volume, closeTo(0.25 * base, 0.02));
    await p.duck(1, ms: 200);
    expect(d.volume, closeTo(base, 0.02));
  });

  test('Automix off: the old crossfade setting is used', () async {
    durations.addAll({'ofAAAAAAAA1': 6000, 'ofAAAAAAAA2': 6000});
    sv.settings.automix = false;
    sv.settings.crossfadeSeconds = 0;
    p = await build({'ofAAAAAAAA1': beatTrack(durMs: 6000)});
    await p.playItems([s('ofAAAAAAAA1', sec: 6), s('ofAAAAAAAA2', sec: 6)]);
    await until(() => p.current.value!.id == 'ofAAAAAAAA2', ms: 10000);
    expect(ax.prepared, isEmpty);
  });

  test('a cached copy is played from the phone (offline-safe)', () async {
    final dir = Directory.systemTemp.createTempSync('byte_ax_');
    final f = File('${dir.path}/cacAAAAAAA1.m4a')..writeAsBytesSync([0, 1, 2]);
    final real = AutomixService(resolver: sv.resolver, library: sv.library, settings: sv.settings);
    real.cacheDir = () async => dir;
    real.fetch = (u, out, t, ua) async => out.writeAsBytesSync([1, 2, 3]);
    real.decoder = _NoDecoder();
    p = ByteAudioHandler(resolver: sv.resolver, yt: sv.yt, library: sv.library, settings: sv.settings, automix: real);
    await real.prepare(s('cacAAAAAAA1'));
    expect(real.cachedFile('cacAAAAAAA1'), isNotNull);
    await p.playItems([s('cacAAAAAAA1')]);
    await until(() => playingDecks().isNotEmpty);
    expect(playingDecks().first.uri, startsWith('file://'));
    f.parent.deleteSync(recursive: true);
  });
}

class _NoDecoder implements PcmDecoder {
  @override
  int get rate => 11025;
  @override
  Future<Never> decode(String path) async => throw UnsupportedError('test');
}
