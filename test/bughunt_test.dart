import 'dart:async';

import 'package:byte/core/models.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Item s(String id, {String? title}) => Item(kind: ItemKind.song, id: id, title: title ?? 'Song $id', artists: const [ArtistRef('A')], durationSec: 3);

/// The bug hunt: connection dropping mid-song, rapid skipping, seeking during
/// a crossfade, an empty queue and the app going to the background.
void main() {
  late Services sv;
  late ByteAudioHandler p;
  setUp(() async {
    sv = await makeServices();
    p = sv.player;
    sv.settings.autoplay = false;
    sv.settings.normalizeVolume = false;
    sv.settings.crossfadeSeconds = 0;
    fakeAudio.durationFor = (_) => const Duration(milliseconds: 2500);
  });
  tearDown(() async => p.stop());

  Future<void> until(bool Function() ok, {int ms = 8000, String what = ''}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out: $what');
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
  }

  FakePlayerPlatform deckPlaying(String id) => fakeAudio.players.values.firstWhere((x) => x.playing && (x.uri ?? '').contains(id));

  test('connection drops mid-song: Byte waits, then resumes the same song where it was', () async {
    final back = Completer<void>();
    p.waitOnline = () => back.future;
    fakeAudio.durationFor = (_) => const Duration(seconds: 20);
    await p.playItems([s('netdrop0001'), s('netdrop0002')]);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    final deck = deckPlaying('netdrop0001');
    // first failure: Byte retries once by itself
    deck.failNow();
    await until(() => fakeAudio.players.values.any((x) => x.playing && (x.uri ?? '').contains('netdrop0001')), what: 'quiet retry');
    // second failure while still offline: it waits instead of skipping
    deckPlaying('netdrop0001').failNow();
    await until(() => p.error.value != null, what: 'offline message');
    expect(p.error.value, contains('No internet'));
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    expect(p.current.value!.id, 'netdrop0001', reason: 'did not skip ahead while offline');
    back.complete();
    await until(() => p.error.value == null && p.playing, what: 'resumed');
    expect(p.current.value!.id, 'netdrop0001');
    expect(p.position.inMilliseconds, greaterThan(400), reason: 'picked up near where it stopped');
  });

  test('rapid skipping lands on the right song with one deck playing', () async {
    final items = [for (var i = 0; i < 12; i++) s('rapidskip${i.toString().padLeft(2, '0')}')];
    await p.playItems(items);
    final futures = [for (var i = 0; i < 9; i++) p.skipToNext()];
    await Future.wait(futures);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(p.current.value!.id, 'rapidskip09');
    final playing = fakeAudio.players.values.where((x) => x.playing).toList();
    expect(playing.length, 1);
    expect(playing.single.uri, contains('rapidskip09'));
    // and back again
    await Future.wait([for (var i = 0; i < 5; i++) p.skipToPrevious()]);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(fakeAudio.players.values.where((x) => x.playing).length, 1);
    expect(p.current.value, isNotNull);
  });

  test('seeking in the middle of a crossfade ends cleanly on one song at full volume', () async {
    sv.settings.crossfadeSeconds = 2;
    await p.playItems([s('xfadeseek01'), s('xfadeseek02')]);
    await until(() => fakeAudio.players.values.where((x) => x.playing).length == 2, what: 'overlap');
    await p.seek(const Duration(milliseconds: 300));
    await until(() {
      final pl = fakeAudio.players.values.where((x) => x.playing).toList();
      return pl.length == 1 && pl.single.volume == 1;
    }, what: 'one deck at full volume');
    expect(p.current.value, isNotNull);
  });

  test('an empty queue never throws', () async {
    await p.stop();
    await p.playItems(const []);
    await p.skipToNext();
    await p.skipToPrevious();
    await p.play();
    await p.pause();
    await p.seek(const Duration(seconds: 3));
    expect(p.current.value, isNull);
    expect(p.playing, isFalse);
  });

  test('going to the background keeps the music playing', () async {
    fakeAudio.durationFor = (_) => const Duration(seconds: 20);
    await p.playItems([s('background1')]);
    final binding = TestWidgetsFlutterBinding.instance;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(p.playing, isTrue);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(p.playing, isTrue);
  });

  test('long Hindi and Bengali titles go through the player and the notification', () async {
    const hi = 'तुम ही हो (अरिजीत सिंह की आवाज़ में एक बहुत लंबा शीर्षक जो कभी ख़त्म नहीं होता और चलता ही रहता है)';
    const bn = 'আমি তোমার সঙ্গে বেঁধেছি আমার প্রাণ — রবীন্দ্রসঙ্গীতের একটি অনেক লম্বা শিরোনাম';
    await p.playItems([s('longtitle01', title: hi), s('longtitle02', title: bn)]);
    expect(p.mediaItem.value?.title, hi);
    await p.skipToNext();
    expect(p.mediaItem.value?.title, bn);
  });
}
