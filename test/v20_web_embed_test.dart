import 'package:byte/core/models.dart';
import 'package:byte/services.dart';
import 'package:byte/web/embed_output.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 2.0 © 2026 Apurba Laskar: web playback through the embedded player.

class _FakeEmbed extends EmbedBridge {
  final loads = <String>[];
  final calls = <String>[];
  Map<String, Object?> st = {'t': 0, 'd': 0, 's': -1, 'e': 0, 'n': 0, 'ready': true};
  @override
  bool available() => true;
  @override
  void load(String id, double startSec) => loads.add(id);
  @override
  void play() => calls.add('play');
  @override
  void pause() => calls.add('pause');
  @override
  void seek(double s) => calls.add('seek:$s');
  @override
  void volume(double v) => calls.add('vol');
  @override
  void hide() => calls.add('hide');
  @override
  Map<String, Object?> snap() => Map.of(st);
}

Item _song(String id) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A', null)], durationSec: 200);

void main() {
  late Services sv;
  late _FakeEmbed fake;
  late WebEmbedOutput out;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });
  setUp(() {
    fake = _FakeEmbed();
    out = WebEmbedOutput(sv.player, bridge: fake);
    sv.player.remote = out;
    sv.player.error.value = null;
  });
  tearDown(() {
    out.dispose();
    sv.player.remote = null;
  });

  test('plays, follows the clock, pauses, seeks, and goes on to the next song', () async {
    await sv.player.playItems([_song('webA1'), _song('webB1')]);
    expect(fake.loads, ['webA1']);
    fake.st = {...fake.st, 's': 1, 't': 12.5, 'd': 201.0};
    out.tick();
    expect(sv.player.playing, isTrue);
    expect(out.positionMs, 12500);
    expect(sv.player.duration, const Duration(milliseconds: 201000));
    await sv.player.pause();
    expect(fake.calls, contains('pause'));
    expect(sv.player.playing, isFalse);
    await sv.player.seek(const Duration(seconds: 30));
    expect(fake.calls, contains('seek:30.0'));
    await sv.player.play();
    expect(fake.calls, contains('play'));
    // the song ends: the next one loads at once
    fake.st = {...fake.st, 's': 0, 'n': 1};
    out.tick();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fake.loads, ['webA1', 'webB1']);
  });

  test('a song that can\'t play embedded: short words at once, then the next song', () async {
    await sv.player.playItems([_song('webA2'), _song('webB2')]);
    fake.st = {...fake.st, 'e': 150};
    final t0 = DateTime.now();
    out.tick();
    expect(sv.player.error.value, WebEmbedOutput.cantPlay);
    expect(DateTime.now().difference(t0).inSeconds, lessThan(5));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(fake.loads.last, 'webB2');
  });

  test('an upload that refuses: the same song\'s other upload plays instead', () async {
    out.dispose();
    out = WebEmbedOutput(sv.player, bridge: fake, alternates: (it) async => ['${it.id}-alt1', '${it.id}-alt2']);
    sv.player.remote = out;
    await sv.player.playItems([_song('webD1'), _song('webD2')]);
    fake.st = {...fake.st, 'e': 150};
    out.tick();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(fake.loads, ['webD1', 'webD1-alt1']);
    expect(sv.player.error.value, isNull, reason: 'no message while another upload is tried');
    fake.st = {...fake.st, 'e': 0, 's': 1, 't': 2.0};
    out.tick();
    expect(sv.player.playing, isTrue);
    expect(sv.player.current.value?.id, 'webD1', reason: 'still the same song in the queue');
  });

  test('blocked script: says so, doesn\'t skip through the queue', () async {
    await sv.player.playItems([_song('webA3'), _song('webB3')]);
    fake.st = {...fake.st, 'e': 'api'};
    out.tick();
    expect(sv.player.error.value, WebEmbedOutput.blocked);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(fake.loads, ['webA3']);
  });

  test('held back by the browser: asks for a tap within 5 s', () async {
    WebEmbedOutput.startLimit = const Duration(milliseconds: 200);
    addTearDown(() => WebEmbedOutput.startLimit = const Duration(milliseconds: 4500));
    await sv.player.playItems([_song('webA4')]);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    out.tick();
    expect(sv.player.error.value, WebEmbedOutput.tapPlay);
    fake.st = {...fake.st, 's': 1, 't': 1.0};
    out.tick();
    expect(sv.player.error.value, isNull);
  });

  test('three songs in a row refused: stops skipping and says so once', () async {
    out.failsInRow = 0;
    await sv.player.playItems([_song('webC1'), _song('webC2'), _song('webC3'), _song('webC4'), _song('webC5')]);
    for (var k = 0; k < 3; k++) {
      fake.st = {...fake.st, 'e': 150};
      out.tick();
      if (k < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 1000));
        fake.st = {...fake.st, 'e': 0};
      }
    }
    expect(sv.player.error.value, WebEmbedOutput.noneHere);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(fake.loads, ['webC1', 'webC2', 'webC3']);
    expect(fake.calls, contains('hide'));
  });

  test('every message fits one line of the mini player on a small phone', () {
    for (final m in [WebEmbedOutput.noneHere, WebEmbedOutput.cantPlay, WebEmbedOutput.blocked, WebEmbedOutput.tapPlay, WebEmbedOutput.phoneOnly]) {
      expect(m.length, lessThanOrEqualTo(32), reason: m);
    }
  });

  test('songs on a phone say so in the browser', () async {
    await sv.player.playItems([Item(kind: ItemKind.song, id: 'local:/x.mp3', title: 'x', artists: const [])]);
    expect(sv.player.error.value, WebEmbedOutput.phoneOnly);
  });
}
