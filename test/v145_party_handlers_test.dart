// Byte © 2026 Apurba Laskar.
//
// 1.4.5 party sync with Byte's real player on both phones (fake audio
// engine, fake live server): a host whose stream gets stuck (screen off) or
// whose backend reports a wrong position for a moment (desktop) must not make
// the guests repeat a part of the song.
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/sync_adapter.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'party_bus.dart' as pb;

Item s(String id, {int sec = 120}) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: sec);

void main() {
  late Services sv;
  late ByteAudioHandler hostH;
  late ByteAudioHandler guestH;
  late HandlerSyncPlayer hp, gp;
  late ListenTogether host, guest;

  Future<void> settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));
  Future<void> until(bool Function() ok, {int ms = 6000, String? why}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out${why == null ? '' : ': $why'}');
      await settle(20);
    }
  }

  FakePlayerPlatform? deckOf(String id) {
    for (final x in fakeAudio.players.values) {
      if (x.playing && (x.uri ?? '').contains('media.example/$id/')) return x;
    }
    return null;
  }

  Future<int> worstJumpBack(ByteAudioHandler p, int ms) async {
    var worst = 0;
    var prev = p.position.inMilliseconds;
    var prevId = p.current.value?.id;
    final end = DateTime.now().millisecondsSinceEpoch + ms;
    while (DateTime.now().millisecondsSinceEpoch < end) {
      await settle(25);
      final now = p.position.inMilliseconds;
      if (p.current.value?.id == prevId && prev - now > worst) worst = prev - now;
      prev = now;
      prevId = p.current.value?.id;
    }
    return worst;
  }

  setUp(() async {
    sv = await makeServices();
    hostH = sv.player;
    sv.settings.autoplay = false;
    sv.settings.crossfadeSeconds = 0;
    ListenTogether.hostAnswerWait = const Duration(seconds: 2);
    ListenTogether.heartbeat = const Duration(milliseconds: 250);
    fakeAudio.durationFor = (_) => const Duration(seconds: 120);
    guestH = ByteAudioHandler(resolver: sv.resolver, yt: sv.yt, library: sv.library, settings: sv.settings);
    final bus = pb.FakePartyBus()..latencyMs = 30;
    hp = HandlerSyncPlayer(hostH);
    gp = HandlerSyncPlayer(guestH);
    host = ListenTogether(player: hp, deviceId: 'host-1', displayName: () => 'Apurba', net: pb.FakePartyNet(bus), store: MemoryPartyStore());
    guest = ListenTogether(player: gp, deviceId: 'guest-1', displayName: () => 'Rahul', net: pb.FakePartyNet(bus), store: MemoryPartyStore());
  });

  tearDown(() async {
    await host.leave();
    await guest.leave();
    hp.dispose();
    gp.dispose();
    await guestH.stop();
    await guestH.disposeAll();
    await hostH.stop();
  });

  Future<void> start(String id) async {
    await hostH.playItems([s(id)]);
    await until(() => hostH.audible, why: 'host plays');
    await hostH.seek(const Duration(seconds: 30));
    expect(await host.host(capacity: 5), isTrue, reason: host.error);
    expect(await guest.join(host.code!), isTrue, reason: guest.error);
    await until(() => guestH.current.value?.id == id && guestH.audible, why: 'guest hears it');
    await settle(800);
  }

  test('host stream stuck (screen off): the player says so, guests keep going without jumping back', () async {
    await start('ptyhandlr01');
    final deck = deckOf('ptyhandlr01')!;
    deck.stallNow();
    await until(() => hp.stalled, ms: 1000, why: 'host reports the stall');
    expect(hostH.audible, isTrue, reason: 'still "playing" while buffering (the old trap)');
    final back = await worstJumpBack(guestH, 2000);
    expect(back, lessThan(300));
    expect(guestH.audible, isTrue);
    deck.resumeNow();
    await settle(1200); // the host catches up by itself
    final back2 = await worstJumpBack(guestH, 800);
    expect(back2, lessThan(300));
    expect((hostH.position.inMilliseconds - guestH.position.inMilliseconds).abs(), lessThan(400));
  });

  test('desktop-like host: its backend blips the position to 0:00: not a seek, guests don\'t move', () async {
    await start('ptyhandlr02');
    final deck = deckOf('ptyhandlr02')!;
    final before = host.last?.v;
    for (var i = 0; i < 3; i++) {
      deck.reportPosition(Duration.zero);
      await settle(300);
      deck.reportPosition(deck.position);
      await settle(300);
    }
    expect(host.last?.v, before, reason: 'no "Seeked" state: ${host.activity.map((a) => a.what).toList()}');
    expect(host.activity.where((a) => a.what.startsWith('Seeked')), isEmpty);
    expect(guestH.position.inMilliseconds, greaterThan(30000));
    final back = await worstJumpBack(guestH, 800);
    expect(back, lessThan(300));
  });

  test('a real seek on the host still reaches the guest', () async {
    await start('ptyhandlr03');
    await hostH.seek(const Duration(seconds: 90));
    await until(() => (guestH.position.inMilliseconds - 90000).abs() < 800, why: 'guest seeks');
    expect(host.activity.any((a) => a.what.startsWith('Seeked')), isTrue);
  });
}
