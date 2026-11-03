// Byte © 2026 Apurba Laskar.
//
// 1.4.3 Listen together: a party ends ONLY when the host taps "End party".
// Every path that used to end or break a party, on several phones sharing
// one in-memory live server (test/party_bus.dart).
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:flutter_test/flutter_test.dart';

import 'party_bus.dart';

const song1 = Item(kind: ItemKind.song, id: 's1', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], durationSec: 260);
const song2 = Item(kind: ItemKind.song, id: 's2', title: 'Kesariya', artists: [ArtistRef('Arijit Singh')], durationSec: 268);
const song3 = Item(kind: ItemKind.song, id: 's3', title: 'Apna Bana Le', artists: [ArtistRef('Arijit Singh')], durationSec: 200);

late FakePartyBus bus;

Future<(Phone, Phone)> twoPhones({bool tables = false}) async {
  bus = FakePartyBus(tables: tables);
  final h = Phone(bus, 'host-1', 'Apurba');
  final g = Phone(bus, 'guest-1', 'Rahul');
  h.player.userPlay(song1);
  expect(await h.party.host(capacity: 5), isTrue, reason: h.party.error);
  expect(await g.party.join(h.party.code!), isTrue, reason: g.party.error);
  await until(() => h.party.people.length == 2 && g.party.people.length == 2, what: 'both in');
  return (h, g);
}

void main() {
  setUp(() {
    ListenTogether.hostAnswerWait = const Duration(seconds: 2);
    ListenTogether.resumeWait = const Duration(milliseconds: 600);
    ListenTogether.heartbeat = const Duration(milliseconds: 200);
    ListenTogether.reconnectAfter = const Duration(milliseconds: 300);
  });

  test('end rules are behind one switch', () {
    expect(ListenTogether.onlyHostEndsForAll, isTrue);
    expect(ListenTogether.endedMessage, 'Host ended the party');
  });

  test('create → code → join by code: guest hears the host\'s song', () async {
    final (h, g) = await twoPhones();
    expect(h.party.liveOnly, isTrue);
    expect(g.party.isHost, isFalse);
    expect(g.player.item?.id, 's1');
    expect(g.party.hostName, 'Apurba');
    expect(g.party.hostAway, isFalse);
    expect(g.party.activity.any((a) => a.what.startsWith('Away')), isFalse, reason: 'no false "host away" while joining');
  });

  test('play / pause / seek / skip sync both ways', () async {
    final (h, g) = await twoPhones();
    h.player.userSeek(60000);
    await until(() => (g.player.position.inMilliseconds - 60000).abs() < 1500, what: 'seek');
    h.player.userPause();
    await until(() => !g.player.playing, what: 'pause');
    await settle(1600); // a tap right after a remote change is taken as the echo
    g.player.userResume(); // guest can control (host-only is off)
    await until(() => h.player.playing, what: 'guest play reaches host');
    h.player.userPlay(song2); // skip
    await until(() => g.player.item?.id == 's2', what: 'skip');
    await h.party.setHostOnly(true);
    await until(() => g.party.hostOnly, what: 'host only');
    g.player.userPause(); // local only now
    await settle(300);
    expect(h.player.playing, isTrue);
  });

  test('guest "Leave party": only he leaves, the 2-person party carries on', () async {
    final (h, g) = await twoPhones();
    await g.party.leave();
    expect(g.party.active, isFalse);
    expect(g.party.saved, isNull, reason: 'he chose to leave: nothing to rejoin');
    await until(() => h.party.people.length == 1, what: 'host sees him go');
    expect(h.party.active, isTrue);
    expect(h.party.isHost, isTrue);
    expect(bus.sent.where((s) => s.startsWith('closed')), isEmpty);
    // and he (or anyone) can come back into the same party
    expect(await g.party.join(h.party.code!), isTrue, reason: g.party.error);
    await until(() => h.party.people.length == 2);
  });

  test('last guest of three leaving: the host keeps the party', () async {
    final (h, g) = await twoPhones();
    final g2 = Phone(bus, 'guest-2', 'Priya');
    expect(await g2.party.join(h.party.code!), isTrue, reason: g2.party.error);
    await until(() => h.party.people.length == 3);
    await g.party.leave();
    await until(() => h.party.people.length == 2 && g2.party.people.length == 2);
    expect(g2.party.active, isTrue);
    await g2.party.leave();
    await until(() => h.party.people.length == 1);
    expect(h.party.active, isTrue);
    h.player.userPlay(song2);
    await settle(200);
    final late = Phone(bus, 'guest-3', 'Late');
    expect(await late.party.join(h.party.code!), isTrue, reason: late.party.error);
    expect(late.player.item?.id, 's2');
  });

  test('host "End party": everyone is taken out with "Host ended the party"', () async {
    final (h, g) = await twoPhones();
    final g2 = Phone(bus, 'guest-2', 'Priya');
    expect(await g2.party.join(h.party.code!), isTrue);
    await h.party.endParty();
    expect(h.party.active, isFalse);
    expect(h.party.saved, isNull);
    await until(() => !g.party.active && !g2.party.active, what: 'guests out');
    expect(g.party.error, 'Host ended the party');
    expect(g.party.endedByHost, isTrue);
    expect(g2.party.error, 'Host ended the party');
    expect(g.party.saved, isNull);
  });

  test('a guest\'s "closed" message cannot end the party', () async {
    final (h, g) = await twoPhones();
    final g2 = Phone(bus, 'guest-2', 'Priya');
    expect(await g2.party.join(h.party.code!), isTrue);
    await g.party.sendExtra('closed', {'by': 'guest-1', 'host': false});
    await settle(200);
    expect(g2.party.active, isTrue);
    expect(h.party.active, isTrue);
    await g.party.endParty(); // a guest can't end for all: he just leaves
    expect(g.party.active, isFalse);
    await settle(200);
    expect(g2.party.active, isTrue);
  });

  test('dispose (app shutting the object down) does not end the party', () async {
    final (h, g) = await twoPhones();
    h.party.dispose();
    await settle(300);
    expect(g.party.active, isTrue);
    expect(bus.sent.where((s) => s.startsWith('closed')), isEmpty);
    await until(() => g.party.hostAway, what: 'host shown away');
    expect(h.store.load()?['code'], isNotNull, reason: 'kept for "Resume your party"');
  });

  test('host app in the background / phone locked: socket drop → back, party alive', () async {
    final (h, g) = await twoPhones();
    h.net.drop();
    await until(() => g.party.hostAway, what: 'guest sees host away');
    expect(g.party.active, isTrue);
    expect(h.party.active, isTrue);
    expect(h.party.connected, isFalse);
    g.player.userSeek(30000); // the party goes on without him
    await settle(100);
    h.net.restore();
    await until(() => !g.party.hostAway && h.party.connected, what: 'host back');
    expect(h.party.isHost, isTrue);
    h.player.userPlay(song3);
    await until(() => g.player.item?.id == 's3', what: 'host controls again');
  });

  test('network blip without the client noticing: the heartbeat rejoins', () async {
    final (h, g) = await twoPhones();
    h.net.drop();
    // the client library does NOT come back by itself this time
    h.net.online = true;
    await until(() => h.party.connected && !g.party.hostAway, ms: 5000, what: 'heartbeat rejoin');
    expect(h.party.activity.any((a) => a.what == 'Reconnected'), isTrue);
  });

  test('presence timeout (asleep, socket half open): back on noticing, nothing ends', () async {
    final (h, g) = await twoPhones();
    h.net.presenceTimeout();
    await until(() => g.party.hostAway, what: 'away');
    expect(g.party.active, isTrue);
    h.net.noticeDrop();
    expect(h.party.active, isTrue);
    h.net.online = true;
    await until(() => h.party.connected && !g.party.hostAway, ms: 5000, what: 'back');
  });

  test('app comes back to the front: reconnects at once', () async {
    final (h, g) = await twoPhones();
    ListenTogether.reconnectAfter = const Duration(minutes: 5); // heartbeat won't
    h.net.drop();
    h.net.online = true;
    await h.party.appResumed();
    expect(h.party.connected, isTrue);
    await until(() => !g.party.hostAway);
  });

  test('host app killed: party lives on, host resumes as host', () async {
    final (h, g) = await twoPhones();
    h.relaunch(bus, 'Apurba');
    await until(() => g.party.hostAway, what: 'away, not ended');
    expect(g.party.active, isTrue);
    expect(g.party.error, isNull);
    g.player.userPlay(song2, atMs: 40000); // music carries on
    await settle(100);
    final s = h.party.saved;
    expect(s, isNotNull);
    expect(s!.host, isTrue);
    expect(s.code, g.party.code);
    expect(await h.party.resume(), isTrue, reason: h.party.error);
    expect(h.party.isHost, isTrue);
    expect(h.party.code, g.party.code);
    await until(() => !g.party.hostAway, what: 'host back');
    expect(h.player.item?.id, 's2', reason: 'host picks up where the party is');
    h.player.userPlay(song3);
    await until(() => g.player.item?.id == 's3');
    await h.party.endParty();
    await until(() => !g.party.active);
    expect(g.party.error, 'Host ended the party');
  });

  test('late join while the host is away (live-only server): a guest answers', () async {
    final (h, g) = await twoPhones();
    h.relaunch(bus, 'Apurba');
    await until(() => g.party.hostAway);
    final late = Phone(bus, 'guest-9', 'Late');
    expect(await late.party.join(g.party.code!), isTrue, reason: late.party.error);
    expect(late.player.item?.id, 's1');
    expect(late.party.hostAway, isTrue);
  });

  test('guest app killed: "Rejoin" puts him back in', () async {
    final (h, g) = await twoPhones();
    g.relaunch(bus, 'Rahul');
    await until(() => h.party.people.length == 1);
    expect(h.party.active, isTrue);
    expect(g.party.saved?.host, isFalse);
    expect(await g.party.resume(), isTrue, reason: g.party.error);
    await until(() => h.party.people.length == 2);
  });

  test('a song ending: the guest\'s own queue does not hijack the party', () async {
    final (h, g) = await twoPhones();
    h.player.userSeek(258000); // 2 s before the end
    await until(() => (g.player.position.inMilliseconds - 258000).abs() < 1500);
    await settle(1600); // past the quiet time after applying
    g.player.autoNext(song3); // guest's own queue
    await settle(200);
    expect(h.player.item?.id, 's1', reason: 'host not pulled to the guest\'s next song');
    h.player.autoNext(song2); // the host's queue decides
    await until(() => g.player.item?.id == 's2', what: 'guest follows the host');
  });

  test('kick: the guest is out, the party isn\'t', () async {
    final (h, g) = await twoPhones();
    await h.party.remove('guest-1');
    await until(() => !g.party.active);
    expect(g.party.error, contains('removed'));
    expect(h.party.active, isTrue);
  });

  test('saved-room server: join, host killed, late join, resume, end', () async {
    final (h, g) = await twoPhones(tables: true);
    expect(h.party.liveOnly, isFalse);
    h.player.userSeek(90000);
    await settle(3300); // saved copy refreshed
    h.relaunch(bus, 'Apurba');
    final late = Phone(bus, 'guest-9', 'Late');
    expect(await late.party.join(g.party.code!), isTrue, reason: late.party.error);
    expect(await h.party.resume(), isTrue, reason: h.party.error);
    await until(() => !g.party.hostAway && !late.party.hostAway);
    await h.party.endParty();
    await until(() => !g.party.active && !late.party.active);
    expect(bus.rooms.values.first['closed'], isTrue);
  });
}
