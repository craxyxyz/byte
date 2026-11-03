// Byte © 2026 Apurba Laskar.
// 1.4.6 QA round 2: the player under stress (rapid Next, very long queues,
// seeking past the end, sleep timer, playlist edits, restart).

import 'package:audio_service/audio_service.dart';
import 'package:byte/core/models.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v145_song_gap_test.dart' show FakeClock;

Item s(String id, {int sec = 200}) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: sec);

void main() {
  late Services sv;
  late ByteAudioHandler p;
  late FakeClock clock;
  final durations = <String, int>{};

  setUp(() async {
    sv = await makeServices();
    p = sv.player;
    clock = FakeClock();
    p.gapTimer = clock.make;
    sv.settings.autoplay = false;
    sv.settings.normalizeVolume = false;
    sv.settings.crossfadeSeconds = 0;
    await p.setRepeatMode(AudioServiceRepeatMode.none);
    durations.clear();
    fakeAudio.durationFor = (uri) {
      final m = RegExp(r'media\.example/([^/]+)/').firstMatch(uri);
      return Duration(milliseconds: durations[m?.group(1)] ?? 60000);
    };
  });
  tearDown(() async {
    await p.stop();
  });

  Future<void> until(bool Function() ok, {int ms = 8000, String? why}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out${why == null ? '' : ': $why'}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  List<String> soundingAll() => [
        for (final x in fakeAudio.players.values)
          if (x.playing && x.state.name == 'ready') RegExp(r'media\.example/([^/]+)/').firstMatch(x.uri ?? '')?.group(1) ?? '?',
      ];

  test('rapid Next spam (15 taps without waiting): lands on the 16th song, only it sounds', () async {
    await p.playItems([for (var i = 0; i < 40; i++) s('n$i')]);
    await until(() => soundingAll().contains('n0'));
    final f = [for (var i = 0; i < 15; i++) p.skipToNext()];
    await Future.wait(f);
    await until(() => soundingAll().length == 1 && soundingAll().first == 'n15', why: 'got ${soundingAll()} current ${p.current.value?.id}');
    expect(p.current.value?.id, 'n15');
    expect(p.queueModel.position, 15);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(soundingAll(), ['n15'], reason: 'no stale load starts playing later');
  });

  test('Next then Previous spam settles on the right song', () async {
    await p.playItems([for (var i = 0; i < 10; i++) s('m$i')]);
    await until(() => soundingAll().contains('m0'));
    await Future.wait([p.skipToNext(), p.skipToNext(), p.skipToNext(), p.skipToPrevious()]);
    await until(() => soundingAll().length == 1);
    expect(p.current.value?.id, soundingAll().single);
  });

  test('a 1500-song queue: load, jump to the end, reorder, remove, clear upcoming stay fast', () async {
    final items = [for (var i = 0; i < 1500; i++) s('q$i')];
    final sw = Stopwatch()..start();
    await p.playItems(items);
    expect(p.queue.value.length, 1500);
    p.moveQueueItem(1400, 1);
    expect(p.queueModel.playOrder[1].id, 'q1400');
    p.removeFromQueue(2);
    expect(p.queueModel.playOrder.length, 1499);
    await p.skipToQueueItem(1498);
    await until(() => p.current.value?.id == 'q1499');
    p.queueModel.jumpTo(0);
    p.queueModel.clearUpcoming();
    expect(p.queueModel.playOrder.length, 1);
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  test('seeking past the end of a song ends it normally (gap, then the next)', () async {
    durations['e0'] = 3000;
    await p.playItems([s('e0', sec: 3), s('e1', sec: 3)]);
    await until(() => soundingAll().contains('e0'));
    await p.seek(const Duration(seconds: 30));
    await until(() => clock.pending != null || p.current.value?.id == 'e1', why: 'song ends after a seek past its end');
    expect(p.current.value?.id, 'e1');
  });

  test('Next spam during the pause between songs: no double start', () async {
    durations['g0'] = 800;
    await p.playItems([s('g0', sec: 1), s('g1'), s('g2'), s('g3')]);
    await until(() => clock.pending != null, why: 'gap starts');
    await Future.wait([p.skipToNext(), p.skipToNext()]);
    await until(() => soundingAll().length == 1);
    expect(p.current.value?.id, 'g3');
    expect(soundingAll(), ['g3']);
    clock.elapse(const Duration(seconds: 3)); // the old gap timer firing late must not start anything
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(soundingAll(), ['g3']);
  });

  test('playlists: reorder with a stale index does nothing instead of throwing; adding twice keeps one', () async {
    final pl = await sv.library.createPlaylist('Mix', items: [s('a'), s('b')]);
    await sv.library.reorderPlaylistItem(pl.id, 5, 0);
    await sv.library.reorderPlaylistItem(pl.id, -1, 0);
    expect(sv.library.playlist(pl.id)!.items.map((i) => i.id), ['a', 'b']);
    await sv.library.reorderPlaylistItem(pl.id, 1, 0);
    expect(sv.library.playlist(pl.id)!.items.map((i) => i.id), ['b', 'a']);
    expect(await sv.library.addToPlaylist(pl.id, [s('a'), s('c'), s('c')]), 1);
    expect(sv.library.playlist(pl.id)!.items.map((i) => i.id), ['b', 'a', 'c']);
    await sv.library.reorderPlaylists(9, 0);
  });

  test('a song the catalogue lists as 0:00 long still plays and moves on', () async {
    durations['z0'] = 1200;
    await p.playItems([s('z0', sec: 0), s('z1')]);
    await until(() => soundingAll().contains('z0'));
    await until(() => clock.pending != null, why: 'ends and waits the gap');
    clock.elapse(const Duration(seconds: 3));
    await until(() => soundingAll().contains('z1'));
  });
}
