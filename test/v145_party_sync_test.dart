// Byte © 2026 Apurba Laskar.
//
// 1.4.5 party sync (Apurba: "host wale ka screen off ho jaye toh guest wale
// mah bhi woh song ke 3-4 second repeat mah chalta ha" and "dono device ke
// song ekdum sync hone chahiye, 1% bhi lag nahi").
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:flutter_test/flutter_test.dart';

import 'party_bus.dart';

const song1 = Item(kind: ItemKind.song, id: 's1', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], durationSec: 260);
const song2 = Item(kind: ItemKind.song, id: 's2', title: 'Kesariya', artists: [ArtistRef('Arijit Singh')], durationSec: 268);
const song3 = Item(kind: ItemKind.song, id: 's3', title: 'Apna Bana Le', artists: [ArtistRef('Arijit Singh')], durationSec: 200);
const radio = Item(kind: ItemKind.song, id: 'r1', title: 'Radio pick', artists: [ArtistRef('Someone')], durationSec: 180);

late FakePartyBus bus;

Future<(Phone, Phone)> twoPhones({Item song = song1, int atMs = 0, int guestSkewMs = 0, int latencyMs = 5, int jitterMs = 0}) async {
  bus = FakePartyBus()
    ..latencyMs = latencyMs
    ..jitterMs = jitterMs;
  final h = Phone(bus, 'host-1', 'Apurba');
  final g = Phone(bus, 'guest-1', 'Rahul', skewMs: guestSkewMs);
  h.player.userPlay(song, atMs: atMs);
  expect(await h.party.host(capacity: 5), isTrue, reason: h.party.error);
  expect(await g.party.join(h.party.code!), isTrue, reason: g.party.error);
  await until(() => h.party.people.length == 2 && g.party.people.length == 2, what: 'both in');
  await until(() => g.player.item?.id == song.id && g.player.playing, what: 'guest playing');
  return (h, g);
}

/// Samples [p]'s position every 25 ms for [ms]; returns the biggest jump back.
Future<int> worstJumpBack(FakeSyncPlayer p, int ms) async {
  var worst = 0;
  var prev = p.position.inMilliseconds;
  var prevId = p.item?.id;
  final end = DateTime.now().millisecondsSinceEpoch + ms;
  while (DateTime.now().millisecondsSinceEpoch < end) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final now = p.position.inMilliseconds;
    if (p.item?.id == prevId && prev - now > worst) worst = prev - now;
    prev = now;
    prevId = p.item?.id;
  }
  return worst;
}

void main() {
  setUp(() {
    ListenTogether.hostAnswerWait = const Duration(seconds: 2);
    ListenTogether.resumeWait = const Duration(milliseconds: 600);
    ListenTogether.heartbeat = const Duration(milliseconds: 300);
    ListenTogether.reconnectAfter = const Duration(milliseconds: 300);
  });

  test('ROOT CAUSE: host screen off → its stream stalls but it still says "playing" → guest must not jump back every heartbeat', () async {
    final (h, g) = await twoPhones(atMs: 120000);
    await settle(400);
    h.player.stall(); // screen off: the host's audio stops getting data, its position freezes
    final back = await worstJumpBack(g.player, 2500);
    expect(back, lessThan(300), reason: 'guest jumped back ${back}ms (the 3-4 s repeat); log ${g.player.log}');
  });

  test('ROOT CAUSE: at the song end a stale host heartbeat must not reload the ended song on the guest', () async {
    final (h, g) = await twoPhones(song: song3, atMs: 197000);
    h.player.stall(); // host stuck near the end (screen off)
    await settle(3200); // guest reaches the end of the song
    g.player.autoNext(radio); // the guest's own queue moves on
    g.player.log.clear();
    await settle(1500);
    expect(g.player.log.where((l) => l.startsWith('load s3')), isEmpty, reason: 'ended song reloaded: ${g.player.log}');
  });

  test('host screen off then back: the host catches up by itself, the guest is never pulled back', () async {
    final (h, g) = await twoPhones(atMs: 60000);
    await settle(500);
    h.player.stall();
    final back1 = await worstJumpBack(g.player, 1200);
    h.player.unstall(); // screen on / data flows again: the host is ~1.2 s behind
    final back2 = await worstJumpBack(g.player, 1200);
    expect(back1, lessThan(300));
    expect(back2, lessThan(300), reason: 'guest log ${g.player.log}');
    expect((h.player.position.inMilliseconds - g.player.position.inMilliseconds).abs(), lessThan(150), reason: 'host log ${h.player.log}');
  });

  test('an older host that hides its stuck stream: the guest still does not jump back', () async {
    final (h, g) = await twoPhones(atMs: 60000);
    h.player.hideStall = true;
    await settle(400);
    h.player.stall();
    final back = await worstJumpBack(g.player, 2000);
    expect(back, lessThan(300), reason: 'guest log ${g.player.log}');
  });

  test('host app backgrounded (socket half dead) then resumed: guests carry on, then resync gently', () async {
    final (h, g) = await twoPhones(atMs: 30000);
    await settle(400);
    h.net.presenceTimeout(); // screen off, the server times the host out
    await until(() => g.party.hostAway, what: 'away');
    final back = await worstJumpBack(g.player, 800);
    expect(back, lessThan(300));
    expect(g.player.playing, isTrue, reason: 'the music keeps going');
    h.net.noticeDrop();
    h.net.restore();
    await h.party.appResumed();
    await until(() => !g.party.hostAway && h.party.connected, ms: 5000, what: 'back');
    await settle(900);
    expect((h.player.position.inMilliseconds - g.player.position.inMilliseconds).abs(), lessThan(150));
  });

  test('host network drop + reconnect: no jump back, in sync after', () async {
    final (h, g) = await twoPhones(atMs: 30000);
    await settle(300);
    h.net.drop();
    await until(() => g.party.hostAway, what: 'away');
    await settle(500);
    h.net.restore();
    await until(() => !g.party.hostAway, ms: 5000, what: 'back');
    final back = await worstJumpBack(g.player, 1000);
    expect(back, lessThan(300));
    expect((h.player.position.inMilliseconds - g.player.position.inMilliseconds).abs(), lessThan(150));
  });

  test('guest screen off (its own stream stuck): it catches up forward when it plays again', () async {
    final (h, g) = await twoPhones(atMs: 30000);
    await settle(300);
    g.player.stall();
    await settle(1500);
    g.player.unstall();
    await settle(900);
    expect((h.player.position.inMilliseconds - g.player.position.inMilliseconds).abs(), lessThan(150), reason: g.player.log.toString());
  });

  test('guest joins mid-song with a skewed clock and 150 ms latency: lands within 60 ms', () async {
    final (h, g) = await twoPhones(atMs: 95000, guestSkewMs: -4321, latencyMs: 75);
    await settle(1500);
    final d = (h.player.position.inMilliseconds - g.player.position.inMilliseconds).abs();
    expect(d, lessThan(60), reason: 'offset ${g.party.clockOffsetMs} log ${g.player.log}');
  });

  test('song end: 2.5 s pause then the next song starts on host and both guests together', () async {
    final (h, g) = await twoPhones(song: song3, atMs: 197000, latencyMs: 40, jitterMs: 20);
    final g2 = Phone(bus, 'guest-2', 'Priya', skewMs: 2500);
    expect(await g2.party.join(h.party.code!), isTrue, reason: g2.party.error);
    await until(() => g2.player.playing && g2.player.item?.id == 's3');
    g.player.log.clear();
    h.player.upNext = song2;
    // the host's song ends ~3 s from now; the guests' own copies end too
    await until(() => h.player.position.inMilliseconds >= 200000, ms: 5000);
    h.player.gapTo(song2);
    await settle(150);
    if (g.player.item?.id == 's3') g.player.autoNext(null);
    if (g2.player.item?.id == 's3') g2.player.autoNext(null);
    await until(() => g.player.item?.id == 's2' && g2.player.item?.id == 's2', what: 'guests show the next song');
    expect(g.player.playing || g2.player.playing, isFalse, reason: 'silent during the pause');
    await until(() => h.player.playing, ms: 3500);
    await settle(600);
    for (final x in [g, g2]) {
      expect(x.player.playing, isTrue);
      expect((h.player.position.inMilliseconds - x.player.position.inMilliseconds).abs(), lessThan(80), reason: '${x.id} ${x.player.log}');
    }
    expect(g.player.log.where((l) => l.startsWith('load s3')), isEmpty);
  });

  test('late join during the pause between songs: starts at the same moment', () async {
    bus = FakePartyBus()..latencyMs = 60;
    final h = Phone(bus, 'host-1', 'Apurba');
    h.player.userPlay(song3, atMs: 100000);
    expect(await h.party.host(), isTrue);
    h.player.gapTo(song2, gapMs: 2500);
    await settle(300);
    final g = Phone(bus, 'guest-1', 'Rahul', skewMs: 900);
    expect(await g.party.join(h.party.code!), isTrue, reason: g.party.error);
    expect(g.player.item?.id, 's2');
    expect(g.player.playing, isFalse);
    await until(() => h.player.playing, ms: 3000);
    await settle(400);
    expect(g.player.playing, isTrue);
    expect((h.player.position.inMilliseconds - g.player.position.inMilliseconds).abs(), lessThan(80));
  });

  test('host goes quiet at a song end (app closed): guests play its next song after the pause, no loop', () async {
    final (h, g) = await twoPhones(song: song3, atMs: 196500);
    g.player.log.clear();
    h.player.upNext = song2;
    await settle(700); // a heartbeat carries the next song
    h.relaunch(bus, 'Apurba'); // host app killed
    await until(() => g.party.hostAway, what: 'away');
    await until(() => g.player.position.inMilliseconds >= 200000, ms: 5000);
    g.player.autoNext(radio); // the guest's own queue would pick something else
    await until(() => g.player.item?.id == 's2' && g.player.playing, ms: 5000, what: 'follows the host\'s next song');
    expect(g.player.log.where((l) => l.startsWith('load s3')), isEmpty);
    expect(g.party.activity.any((a) => a.what.startsWith('Away')), isTrue);
  });

  test('host pause / seek / next / previous / queue edit while guests listen', () async {
    final (h, g) = await twoPhones(atMs: 10000, latencyMs: 60, jitterMs: 30);
    h.player.userPause();
    await until(() => !g.player.playing, what: 'pause');
    h.player.userResume();
    await until(() => g.player.playing, what: 'resume');
    h.player.userSeek(120000);
    await until(() => (g.player.position.inMilliseconds - 120000).abs() < 400, what: 'seek');
    h.player.userPlay(song2);
    await until(() => g.player.item?.id == 's2', what: 'next');
    h.player.userPlay(song1); // previous
    await until(() => g.player.item?.id == 's1', what: 'previous');
    h.player.upNext = song3; // queue edit
    await until(() => g.party.last?.v == h.party.last?.v);
    await settle(700);
    expect(h.party.isHost, isTrue);
    await settle(400);
    expect((h.player.position.inMilliseconds - g.player.position.inMilliseconds).abs(), lessThan(100));
  });

  test('host changes song twice while the guest is still loading: guest ends on the newest', () async {
    final (h, g) = await twoPhones(atMs: 10000);
    g.player.loadDelayMs = 400;
    h.player.userPlay(song2);
    await settle(50);
    h.player.userPlay(song3);
    await until(() => g.player.item?.id == 's3' && g.player.playing, ms: 3000, what: 'newest song');
    await settle(800);
    expect(g.player.item?.id, 's3');
  });

  test('repeat one: the same song again after the pause (not blocked as an ended song)', () async {
    final (h, g) = await twoPhones(song: song3, atMs: 198000);
    await until(() => h.player.position.inMilliseconds >= 200000, ms: 4000);
    if (g.player.playing) g.player.autoNext(null);
    h.player.gapTo(song3, gapMs: 1000);
    await until(() => h.player.playing, ms: 2000);
    await until(() => g.player.playing && g.player.position.inMilliseconds < 3000, ms: 2000, what: 'guest restarts it');
  });

  test('desktop host: position updates only every 1 s and blips to 0:00 now and then: guests never loop', () async {
    final (h, g) = await twoPhones(atMs: 50000);
    h.player.coarseMs = 1000;
    await settle(300);
    var worst = 0;
    for (var i = 0; i < 4; i++) {
      h.player.blipZeroUntil = DateTime.now().millisecondsSinceEpoch + 350;
      final back = await worstJumpBack(g.player, 700);
      if (back > worst) worst = back;
    }
    expect(worst, lessThan(300), reason: 'guest log ${g.player.log}');
    expect(g.player.log.where((l) => l.startsWith('seek') || l.startsWith('load')).length, lessThanOrEqualTo(1), reason: '${g.player.log}');
    expect((h.player.truePosition.inMilliseconds - g.player.position.inMilliseconds).abs(), lessThan(400));
  });

  test('a guest\'s change no longer makes two clocks fight (host ignores heartbeats)', () async {
    final (h, g) = await twoPhones(atMs: 50000);
    await settle(1600);
    g.player.userSeek(80000); // the guest seeks (anyone may control)
    await until(() => (h.player.position.inMilliseconds - 80000).abs() < 600, what: 'host follows the guest\'s seek');
    h.player.log.clear();
    g.player.log.clear();
    await settle(1500);
    expect(bus.sent.where((s) => s == 'beat guest-1'), isEmpty, reason: 'only the host keeps the clock');
    expect(h.player.log.where((l) => l.startsWith('seek')), isEmpty, reason: 'host not pulled by a guest heartbeat: ${h.player.log}');
  });

  group('measured drift (host vs guest audio position)', () {
    for (final rtt in [30, 100, 300]) {
      test('RTT $rtt ms ± 50 ms jitter, guest clock off by 7.3 s, guest audio 0.2 % fast', () async {
        ListenTogether.heartbeat = const Duration(milliseconds: 500);
        final (h, g) = await twoPhones(atMs: 40000, guestSkewMs: 7300, latencyMs: rtt ~/ 2, jitterMs: 50);
        g.player.clockRate = 1.002;
        await settle(2500); // clock samples + first corrections
        final d = <int>[];
        final end = DateTime.now().millisecondsSinceEpoch + 6000;
        while (DateTime.now().millisecondsSinceEpoch < end) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          d.add((h.player.position.inMilliseconds - g.player.position.inMilliseconds).abs());
        }
        d.sort();
        final mean = d.reduce((a, b) => a + b) / d.length;
        final p95 = d[(d.length * 0.95).floor() - 1];
        final mx = d.last;
        // ignore: avoid_print
        print('DRIFT rtt=$rtt jitter=±50: mean ${mean.toStringAsFixed(1)} ms, p95 $p95 ms, max $mx ms, '
            'offset error ${g.party.clockOffsetMs + 7300} ms, seeks ${g.player.log.where((l) => l.startsWith('seek')).length}, nudges ${g.player.rates.length}');
        expect(mean, lessThan(50));
        expect(mx, lessThan(100));
      });
    }
  });
}
