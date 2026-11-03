// Byte © 2026 Apurba Laskar.
//
// 1.4.6, Apurba (11:41 PM): "android mah party mood mah guest wala app seh
// bahar jayeh toh uska song off jata ha" — in a party, when the GUEST leaves
// the app, its song stops; the host is fine.
// Cause: Android keeps a phone awake and in the foreground only while the
// media session says "playing". A guest's player holds just the party's
// song, so at every song end it said "stopped" (wake lock let go) until the
// host's next song was loaded and started; out of the app / screen off the
// phone slept in that window and the next song never started. The host
// stays "playing" through its own 2.5 s gap. Now the guest does too.
import 'package:audio_service/audio_service.dart' show AudioProcessingState;
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
  late pb.FakePartyNet gnet;

  Future<void> settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));
  Future<void> until(bool Function() ok, {int ms = 6000, String? why}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out${why == null ? '' : ': $why'}');
      await settle(20);
    }
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
    gnet = pb.FakePartyNet(bus);
    guest = ListenTogether(player: gp, deviceId: 'guest-1', displayName: () => 'Rahul', net: gnet, store: MemoryPartyStore());
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

  Future<void> start(String a, String b) async {
    await hostH.playItems([s(a), s(b)]);
    await until(() => hostH.audible, why: 'host plays');
    await hostH.seek(const Duration(seconds: 60));
    expect(await host.host(capacity: 5), isTrue, reason: host.error);
    expect(await guest.join(host.code!), isTrue, reason: guest.error);
    await until(() => guestH.current.value?.id == a && guestH.audible, why: 'guest hears it');
    await settle(800);
  }


  /// Every "playing" the media session said (what Android keeps awake on).
  List<bool> watchSession(ByteAudioHandler h) {
    final out = <bool>[];
    h.playbackState.listen((p) => out.add(p.playing));
    return out;
  }

  test('song ends in a party: the guest\'s phone stays "playing" (awake) until the next song plays, like the host', () async {
    await hostH.playItems([s('pbg00000001'), s('pbg00000002')]);
    await until(() => hostH.audible, why: 'host plays');
    expect(await host.host(capacity: 5), isTrue, reason: host.error);
    expect(await guest.join(host.code!), isTrue, reason: guest.error);
    await until(() => guestH.current.value?.id == 'pbg00000001' && guestH.audible, why: 'guest hears it');
    await settle(500);
    await hostH.seek(const Duration(seconds: 116));
    await settle(1500);
    final g = watchSession(guestH), h = watchSession(hostH);
    await until(() => guestH.current.value?.id == 'pbg00000002' && guestH.audible, ms: 20000, why: 'guest on the next song');
    await settle(300);
    expect(g, isNotEmpty);
    expect(g.where((p) => !p), isEmpty, reason: 'the guest\'s session said "not playing" between songs (phone may sleep): $g');
    expect(h.where((p) => !p), isEmpty, reason: 'host: $h');
    expect(guestH.playbackState.value.playing, isTrue);
  });

  test('a guest who pauses by hand shows paused (not held "playing"), also across heartbeats', () async {
    await start('pbg00000011', 'pbg00000012');
    await guestH.pause();
    await settle(900); // several heartbeats
    expect(guestH.audible, isFalse);
    expect(guestH.playbackState.value.playing, isFalse, reason: 'held "playing" after a pause by hand');
  });

  test('host pauses the party: the guest is not held "playing"', () async {
    await start('pbg00000021', 'pbg00000022');
    await hostH.pause();
    await until(() => !guestH.audible, why: 'guest pauses with the host');
    await settle(700);
    expect(guestH.playbackState.value.playing, isFalse);
  });

  test('guest leaves the party: nothing held', () async {
    await start('pbg00000031', 'pbg00000032');
    await guestH.pause();
    await guest.leave();
    await settle(300);
    expect(guestH.partyHold, isFalse);
    expect(guestH.playbackState.value.playing, isFalse);
  });

  test('host quiet after the song ends: the guest lets go after the grace (no endless wake lock)', () async {
    ListenTogether.holdGraceMs = 1500;
    addTearDown(() => ListenTogether.holdGraceMs = 20000);
    await start('pbg00000041', 'pbg00000042');
    expect(guestH.partyHold, isTrue);
    await host.leave(); // the host's phone is gone; no next song comes
    await hostH.pause();
    await guestH.seek(const Duration(seconds: 119));
    await until(() => !guestH.partyHold, ms: 75000, why: 'hold released');
    expect(guestH.playbackState.value.processingState == AudioProcessingState.error, isFalse);
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('guest out of the app (connection drops, comes back, app resumes): keeps playing', () async {
    ListenTogether.reconnectAfter = const Duration(milliseconds: 800);
    addTearDown(() => ListenTogether.reconnectAfter = const Duration(seconds: 5));
    await start('pbg00000051', 'pbg00000052');
    gnet.presenceTimeout();
    await settle(1200);
    expect(guestH.audible, isTrue);
    gnet.noticeDrop();
    await settle(2000);
    expect(guestH.audible, isTrue);
    gnet.restore();
    await settle(2000);
    await guest.appResumed();
    await settle(1200);
    expect(guestH.audible, isTrue);
    expect(guestH.current.value?.id, 'pbg00000051');
    expect((hostH.position.inMilliseconds - guestH.position.inMilliseconds).abs(), lessThan(600), reason: 'back in sync');
  });
}
