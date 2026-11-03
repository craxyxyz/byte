// Byte © 2026 Apurba Laskar.
// 1.4.3 Listen together on Apurba's REAL server (live channel only, no
// tables): host, two guests, the new end rules. Network test:
//   flutter test test_live/v143_party_live_test.dart
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/party_bus.dart' show FakeSyncPlayer, until;

void main() {
  const song1 = Item(kind: ItemKind.song, id: 'abc123', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], durationSec: 262);
  const song2 = Item(kind: ItemKind.song, id: 'def456', title: 'Kesariya', artists: [ArtistRef('Arijit Singh')], durationSec: 268);
  test('live: create → join → sync → guest leaves/rejoins → host killed → late join → resume → End party', () async {
    final t = DateTime.now().millisecondsSinceEpoch;
    final log = <String>[];
    void say(String s) {
      log.add('${DateTime.now().millisecondsSinceEpoch - t} ms  $s');
      // ignore: avoid_print
      print(log.last);
    }

    final hp = FakeSyncPlayer('host'), gp = FakeSyncPlayer('guest'), g2p = FakeSyncPlayer('guest2');
    final store = MemoryPartyStore();
    var host = ListenTogether(player: hp, deviceId: 'qa-h-$t', displayName: () => 'QA Host', store: store);
    final guest = ListenTogether(player: gp, deviceId: 'qa-g-$t', displayName: () => 'QA Guest');
    final g2 = ListenTogether(player: g2p, deviceId: 'qa-g2-$t', displayName: () => 'QA Late');
    hp.userPlay(song1);
    expect(await host.host(capacity: 5), isTrue, reason: host.error);
    final code = host.code!;
    say('host up, code $code (throwaway), liveOnly=${host.liveOnly}');
    expect(await guest.join(code), isTrue, reason: guest.error);
    say('guest joined by code; hears ${gp.item?.id}');
    expect(gp.item?.id, 'abc123');
    hp.userSeek(60000);
    await until(() => (gp.position.inMilliseconds - hp.position.inMilliseconds).abs() < 1500, ms: 6000, what: 'seek');
    say('seek synced; drift ${(gp.position.inMilliseconds - hp.position.inMilliseconds).abs()} ms');
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    hp.userPlay(song2);
    await until(() => gp.item?.id == 'def456', ms: 6000, what: 'skip');
    say('skip synced');
    // guest leaves: only him
    await guest.leave();
    await until(() => host.people.length == 1, ms: 8000, what: 'host sees guest go');
    expect(host.active, isTrue);
    say('guest left; host still in party (${host.people.length} person)');
    expect(await guest.join(code), isTrue, reason: guest.error);
    await until(() => host.people.length == 2, ms: 8000);
    say('guest rejoined');
    // host "killed": drops off with no last words
    host.dispose();
    await until(() => guest.hostAway, ms: 15000, what: 'guest sees host away');
    expect(guest.active, isTrue);
    say('host gone; guest still in party, host shown away');
    // late join while the host is away: the guest answers
    expect(await g2.join(code), isTrue, reason: g2.error);
    say('late joiner got in while host away; hears ${g2p.item?.id}');
    expect(g2p.item?.id, 'def456');
    // host comes back as host
    final hp2 = FakeSyncPlayer('host-again');
    host = ListenTogether(player: hp2, deviceId: 'qa-h-$t', displayName: () => 'QA Host', store: store);
    expect(host.saved?.host, isTrue);
    expect(await host.resume(), isTrue, reason: host.error);
    await until(() => !guest.hostAway && !g2.hostAway, ms: 10000, what: 'host back');
    say('host resumed as host; picks up ${hp2.item?.id}');
    expect(hp2.item?.id, 'def456');
    // End party → everyone out with the message
    await host.endParty();
    await until(() => !guest.active && !g2.active, ms: 8000, what: 'guests out');
    say('End party → guests: "${guest.error}" / "${g2.error}"');
    expect(guest.error, 'Host ended the party');
    expect(store.load(), isNull);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
