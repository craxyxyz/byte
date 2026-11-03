// Byte © 2026 Apurba Laskar.
//
// 1.4.6, Apurba on a real phone (1.4.5 Android, party): "jab party mah next
// song chala raha toh next song aha seh chalu ho raha ha" — in a party, after
// Next the next song started from the middle. Cause: the player says "new
// song" (current changes) before the old song has stopped, so the host's
// party state carried the new song with the OLD song's position, playing;
// guests loaded the new song there, and heartbeats never pull a guest back.
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/sync_adapter.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;

import 'helpers.dart';
import 'party_bus.dart' as pb;

/// The 1.4.5 player as the party saw it: the deck's own spot and sound, even
/// while the next song is being switched in (a 1.4.5 host, for mixed parties).
class OldHostPlayer extends HandlerSyncPlayer {
  OldHostPlayer(super.h);
  @override
  Duration get position => h.inGap ? Duration.zero : h.activePlayer.position;
  @override
  bool get isPlaying => h.activePlayer.playing && h.activePlayer.processingState != ProcessingState.completed;
}

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

  Future<void> start(String a, String b) async {
    await hostH.playItems([s(a), s(b)]);
    await until(() => hostH.audible, why: 'host plays');
    await hostH.seek(const Duration(seconds: 60));
    expect(await host.host(capacity: 5), isTrue, reason: host.error);
    expect(await guest.join(host.code!), isTrue, reason: guest.error);
    await until(() => guestH.current.value?.id == a && guestH.audible, why: 'guest hears it');
    await settle(800);
  }

  /// Every party state the host sent that already names [id].
  List<RoomState> statesFor(String id, List<RoomState> sent) => sent.where((x) => x.item?.id == id).toList();

  test('host presses Next at 1:00: host and guest both start the next song at 0:00', () async {
    await start('ptynext0001', 'ptynext0002');
    final sent = <RoomState>[];
    void rec() {
      final l = host.last;
      if (l != null && (sent.isEmpty || !identical(sent.last, l))) sent.add(l);
    }
    host.addListener(rec);
    await hostH.skipToNext();
    await until(() => guestH.current.value?.id == 'ptynext0002' && guestH.audible, why: 'guest on the next song');
    await settle(300);
    host.removeListener(rec);
    final first = statesFor('ptynext0002', sent).first;
    expect(first.positionMs, lessThan(1500), reason: 'the "changed the song" state carried the old song\'s spot: ${first.positionMs} ms');
    expect(hostH.position.inMilliseconds, lessThan(3000));
    expect(guestH.position.inMilliseconds, lessThan(3000), reason: 'guest started the next song in the middle');
    expect((hostH.position.inMilliseconds - guestH.position.inMilliseconds).abs(), lessThan(400), reason: 'host and guest together');
    expect(host.activity.where((a) => a.what == 'Played'), isEmpty, reason: 'the new song starting is not a "Played" tap: ${host.activity.map((a) => a.what).toList()}');
  });

  test('Next spam on the host: the guest ends on the host\'s song, near 0:00', () async {
    await hostH.playItems([s('ptyspam0001'), s('ptyspam0002'), s('ptyspam0003'), s('ptyspam0004')]);
    await until(() => hostH.audible, why: 'host plays');
    await hostH.seek(const Duration(seconds: 70));
    expect(await host.host(capacity: 5), isTrue, reason: host.error);
    expect(await guest.join(host.code!), isTrue, reason: guest.error);
    await until(() => guestH.current.value?.id == 'ptyspam0001' && guestH.audible, why: 'guest hears it');
    await settle(500);
    for (var i = 0; i < 3; i++) {
      await hostH.skipToNext();
      await settle(40);
    }
    await until(() => guestH.current.value?.id == 'ptyspam0004' && guestH.audible, why: 'guest on the last one');
    await settle(400);
    expect(guestH.position.inMilliseconds, lessThan(3500));
  });

  test('a song ending by itself (with the pause between songs): the next one starts at 0:00 on both', () async {
    await start('ptyend00001', 'ptyend00002');
    await hostH.seek(const Duration(seconds: 117));
    await until(() => guestH.current.value?.id == 'ptyend00002' && guestH.audible, ms: 12000, why: 'guest on the next song');
    await settle(300);
    expect(hostH.current.value?.id, 'ptyend00002');
    expect(hostH.position.inMilliseconds, lessThan(3000));
    expect(guestH.position.inMilliseconds, lessThan(3000));
  });

  test('a 1.4.5 host (still sends the old spot): a 1.4.6 guest starts the next song at 0:00 anyway', () async {
    host.leave();
    hp.dispose();
    final bus = pb.FakePartyBus()..latencyMs = 30;
    final old = OldHostPlayer(hostH);
    hp = old;
    await guest.leave();
    guest = ListenTogether(player: gp, deviceId: 'guest-1', displayName: () => 'Rahul', net: pb.FakePartyNet(bus), store: MemoryPartyStore());
    host = ListenTogether(player: old, deviceId: 'host-1', displayName: () => 'Apurba', net: pb.FakePartyNet(bus), store: MemoryPartyStore());
    await start('ptyold00001', 'ptyold00002');
    await hostH.skipToNext();
    await until(() => guestH.current.value?.id == 'ptyold00002' && guestH.audible, why: 'guest on the next song');
    await settle(300);
    expect(guestH.position.inMilliseconds, lessThan(3000), reason: 'a 1.4.5 host\'s old spot was taken');
  });

  test('carriedOver: only a new song at the old song\'s exact spot is reset', () {
    final a = s('cvA00000001'), b = s('cvB00000001');
    final prev = RoomState(item: a, positionMs: 60000, playing: true, atMs: 1000, v: 3, by: 'h', byName: 'H', capacity: 5, hostOnly: false);
    RoomState next({int p = 61000, String? action = 'Changed the song to "x"', Item? item}) =>
        RoomState(item: item ?? b, positionMs: p, playing: true, atMs: 2000, v: 4, by: 'h', byName: 'H', capacity: 5, hostOnly: false, action: action);
    expect(ListenTogether.carriedOver(prev, next()).positionMs, 0);
    expect(ListenTogether.carriedOver(prev, next()).action, startsWith('Changed the song'));
    expect(ListenTogether.carriedOver(prev, next(p: 30000)).positionMs, 30000, reason: 'a real start point elsewhere stays');
    expect(ListenTogether.carriedOver(prev, next(p: 1200)).positionMs, 1200);
    expect(ListenTogether.carriedOver(prev, next(item: a)).positionMs, 61000, reason: 'same song: a seek, untouched');
    expect(ListenTogether.carriedOver(prev, next(action: 'Seeked to 1:01')).positionMs, 61000);
    expect(ListenTogether.carriedOver(null, next()).positionMs, 61000);
  });
}
