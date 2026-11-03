import 'package:byte/core/models.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Item s(String id) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: 3);

/// The real player logic (two decks, gapless, crossfade, sleep timer) running
/// against a fake audio engine that plays in real time.
void main() {
  late Services sv;
  late ByteAudioHandler p;
  setUp(() async {
    sv = await makeServices();
    p = sv.player;
    sv.settings.autoplay = false;
    sv.settings.normalizeVolume = false;
    fakeAudio.durationFor = (_) => const Duration(milliseconds: 2500);
  });
  tearDown(() async {
    await p.stop();
  });

  Future<void> until(bool Function() ok, {int ms = 8000}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out');
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  test('plays the resolved stream and moves to the next song by itself (gapless)', () async {
    sv.settings.crossfadeSeconds = 0;
    await p.playItems([s('aaaaaaaaaa1'), s('aaaaaaaaaa2')]);
    expect(p.current.value!.id, 'aaaaaaaaaa1');
    expect(p.playing, isTrue);
    final loads = fakeAudio.players.values.expand((x) => x.loads).toList();
    expect(loads.first, contains('media.example/aaaaaaaaaa1/251'));
    await until(() => p.current.value!.id == 'aaaaaaaaaa2');
    // the second song was preloaded on the other deck before the first ended
    expect(fakeAudio.players.values.where((x) => x.loads.any((u) => u.contains('aaaaaaaaaa2'))).length, 1);
    await until(() => !p.playing);
    expect(p.current.value!.id, 'aaaaaaaaaa2');
  });

  test('crossfade overlaps the two songs and ends with the new one at full volume', () async {
    sv.settings.crossfadeSeconds = 2; // capped to a third of 2.5 s
    await p.playItems([s('bbbbbbbbbb1'), s('bbbbbbbbbb2')]);
    var sawOverlap = false;
    await until(() {
      final playing = fakeAudio.players.values.where((x) => x.playing).toList();
      if (playing.length == 2 && playing.every((x) => x.volume > 0.05 && x.volume < 0.95)) sawOverlap = true;
      return p.current.value!.id == 'bbbbbbbbbb2' && !fakeAudio.players.values.any((x) => x.playing && x.uri!.contains('bbbbbbbbbb1'));
    });
    expect(sawOverlap, isTrue);
    await until(() => fakeAudio.players.values.any((x) => x.playing && x.volume == 1));
  });

  test('sleep at end of song stops after the current one', () async {
    sv.settings.crossfadeSeconds = 0;
    await p.playItems([s('cccccccccc1'), s('cccccccccc2')]);
    p.sleepAtEndOfTrack();
    await until(() => !p.playing);
    expect(p.current.value!.id, 'cccccccccc1');
  });

  test('next / previous / queue editing', () async {
    await p.playItems([s('dddddddddd1'), s('dddddddddd2'), s('dddddddddd3')]);
    await p.skipToNext();
    expect(p.current.value!.id, 'dddddddddd2');
    p.playNextItem(s('dddddddddd9'));
    expect(p.queueModel.nextItem!.id, 'dddddddddd9');
    await p.skipToPrevious();
    expect(p.current.value!.id, 'dddddddddd1');
    expect(p.queue.value.length, 4);
  });

  test('speed applies to the playing deck', () async {
    await p.playItems([s('eeeeeeeeee1')]);
    await p.setSpeed(1.5);
    expect(fakeAudio.players.values.firstWhere((x) => x.playing).speed, 1.5);
  });

  test('history is recorded', () async {
    await p.playItems([s('ffffffffff1')]);
    expect(sv.library.history.first.item.id, 'ffffffffff1');
  });
}
