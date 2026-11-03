// Byte © 2026 Apurba Laskar.
//
// 1.4.3 Listen together screen: "End party" (host, with "End the party for
// everyone?") takes everyone out with "Host ended the party"; "Leave party"
// (guest) takes only him out; leaving the page never touches the party; a
// killed app offers "Resume your party". Real ListenTogether objects on the
// in-memory live server.
import 'dart:convert';

import 'package:byte/app.dart';
import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/data/party_sound.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/listen_together_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'party_bus.dart' hide settle;
import 'screens_test.dart' show settle;

const song1 = Item(kind: ItemKind.song, id: 's1', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], durationSec: 260);

void main() {
  late FakePartyBus bus;
  late Phone other; // the phone not on screen
  late PartyStore myStore;

  setUp(() {
    ListenTogether.hostAnswerWait = const Duration(seconds: 2);
    ListenTogether.resumeWait = const Duration(milliseconds: 400);
    ListenTogether.heartbeat = const Duration(hours: 1); // no timers left running in widget tests
    ListenTogether.reconnectAfter = const Duration(milliseconds: 300);
    bus = FakePartyBus();
    myStore = MemoryPartyStore();
  });

  Future<Services> phoneOnScreen(String id, String name) => makeServices(
    party: (st) => ListenTogether(player: FakeSyncPlayer(name), deviceId: id, displayName: () => name, net: FakePartyNet(bus), store: myStore),
  );

  Future<void> openScreen(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 3200); // the whole room page at once
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const ByteApp());
    await settle(tester);
    pushInCurrentTab!(const ListenTogetherScreen());
    await settle(tester);
  }

  Future<void> scrollTo(WidgetTester tester, String text) async {
    final f = find.text(text);
    if (f.evaluate().isEmpty) await tester.scrollUntilVisible(f, 300, scrollable: find.byType(Scrollable).first);
    await tester.pump();
  }

  /// Work started from a tap runs on the test's clock, the other phone's on
  /// the real one: move both until [ok].
  Future<void> both(WidgetTester tester, bool Function() ok, String what) async {
    for (var i = 0; i < 200 && !ok(); i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    }
    expect(ok(), isTrue, reason: what);
  }

  Future<void> done(WidgetTester tester) async {
    await tester.runAsync(() async {
      if (Services.i.party.active) await Services.i.party.endParty();
      if (other.party.active) await other.party.endParty();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 30));
  }

  testWidgets('host: "End party" asks "End the party for everyone?", then every guest is out with "Host ended the party"', (tester) async {
    final s = (await tester.runAsync(() => phoneOnScreen('host-1', 'Apurba')))!;
    other = Phone(bus, 'guest-1', 'Rahul');
    await tester.runAsync(() async {
      (s.party.player as FakeSyncPlayer).userPlay(song1);
      expect(await s.party.host(), isTrue);
      expect(await other.party.join(s.party.code!), isTrue);
    });
    await openScreen(tester);
    expect(find.text('Leave party'), findsNothing, reason: 'the host has no "leave without ending"');
    await scrollTo(tester, 'End party');
    await tester.tap(find.text('End party').first);
    await settle(tester);
    expect(find.text('End the party for everyone?'), findsOneWidget);
    // Cancel keeps it
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(s.party.active, isTrue);
    await tester.tap(find.text('End party').first);
    await settle(tester);
    await tester.tap(find.text('End party').last); // the dialog's button
    await both(tester, () => !other.party.active, 'guest taken out');
    await settle(tester);
    expect(s.party.active, isFalse);
    expect(other.party.error, 'Host ended the party');
    expect(find.text('Create a party'), findsOneWidget);
    await done(tester);
  });

  testWidgets('guest: "Leave party" takes only him out; the 2-person party carries on; he sees no "End party"', (tester) async {
    final s = (await tester.runAsync(() => phoneOnScreen('guest-1', 'Rahul')))!;
    other = Phone(bus, 'host-1', 'Apurba');
    await tester.runAsync(() async {
      other.player.userPlay(song1);
      expect(await other.party.host(), isTrue);
      expect(await s.party.join(other.party.code!), isTrue, reason: s.party.error);
    });
    await openScreen(tester);
    expect(find.text('End party'), findsNothing);
    await scrollTo(tester, 'Leave party');
    await tester.tap(find.text('Leave party'));
    await settle(tester);
    expect(find.text('Leave the party?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await both(tester, () => !s.party.active && other.party.people.length == 1, 'only the guest left');
    await settle(tester);
    expect(other.party.active, isTrue);
    expect(other.party.isHost, isTrue);
    expect(bus.sent.where((m) => m.startsWith('closed')), isEmpty);
    await done(tester);
  });

  testWidgets('host leaving the Listen-together page (and coming back) keeps the party', (tester) async {
    final s = (await tester.runAsync(() => phoneOnScreen('host-1', 'Apurba')))!;
    other = Phone(bus, 'guest-1', 'Rahul');
    await tester.runAsync(() async {
      (s.party.player as FakeSyncPlayer).userPlay(song1);
      expect(await s.party.host(), isTrue);
      expect(await other.party.join(s.party.code!), isTrue);
    });
    await openScreen(tester);
    final code = s.party.code;
    Navigator.of(tester.element(find.text('Copy code'))).pop();
    await settle(tester);
    expect(find.text('Copy code'), findsNothing);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    expect(s.party.active, isTrue);
    expect(other.party.active, isTrue);
    expect(other.party.hostAway, isFalse);
    pushInCurrentTab!(const ListenTogetherScreen());
    await settle(tester);
    expect(find.text(code!.split('').join(' ')), findsOneWidget);
    await done(tester);
  });

  testWidgets('host app killed: the screen offers "Resume your party" and he is the host again', (tester) async {
    other = Phone(bus, 'guest-1', 'Rahul');
    // before the "kill": this phone hosted, with a guest
    final before = Phone(bus, 'host-1', 'Apurba', store: myStore);
    await tester.runAsync(() async {
      before.player.userPlay(song1);
      expect(await before.party.host(), isTrue);
      expect(await other.party.join(before.party.code!), isTrue);
      before.net.kill();
      before.party.dispose();
      await until(() => other.party.hostAway, what: 'guest sees host away');
    });
    expect(other.party.active, isTrue);
    final s = (await tester.runAsync(() => phoneOnScreen('host-1', 'Apurba')))!;
    await openScreen(tester);
    expect(find.text('Resume your party'), findsOneWidget);
    await tester.tap(find.text('Resume your party'));
    await both(tester, () => s.party.isHost && !other.party.hostAway, 'host back');
    await settle(tester);
    expect(s.party.code, other.party.code);
    expect(find.text('End party'), findsOneWidget);
    await done(tester);
  });

  test('host sound sharing survives the new end rules: guest gets his own sound back on Leave, End, and a resumed host', () async {
    ListenTogether.heartbeat = const Duration(milliseconds: 200);
    Map<String, Object?> mine() => {'eqOn': false, 'bal': 0.4, 'preset': 'Bass Booster', 'mono': false};
    Map<String, Object?> his() => {'eqOn': true, 'bal': -0.25, 'mono': true, 'preamp': -3.0};
    final h = Phone(bus, 'host-1', 'Apurba');
    final g = Phone(bus, 'guest-1', 'Rahul');
    final hLab = AudioLab()..openForTest(his());
    final gLab = AudioLab()..openForTest(mine());
    final own = jsonEncode(gLab.partySound());
    final hs = PartySound(lab: hLab, link: ListenTogetherLink(h.party));
    final gs = PartySound(lab: gLab, link: ListenTogetherLink(g.party));
    h.player.userPlay(song1);
    expect(await h.party.host(), isTrue);
    expect(await g.party.join(h.party.code!), isTrue);
    await until(() => h.party.people.length == 2);
    await hs.setSharing(true);
    await until(() => gs.offer != null, what: 'offer');
    await gs.accept();
    expect(gLab.borrowing, isTrue);
    await until(() => hs.acceptedCount == 1, what: 'ack');
    // the host's app is killed: the guest keeps listening (host away)
    h.relaunch(bus, 'Apurba');
    await until(() => g.party.hostAway);
    expect(g.party.active, isTrue);
    // the host comes back without sharing → the guest's own sound returns
    final hs2 = PartySound(lab: hLab, link: ListenTogetherLink(h.party));
    expect(await h.party.resume(), isTrue);
    await until(() => !gLab.borrowing, what: 'own sound back after host resume');
    expect(jsonEncode(gLab.partySound()), own);
    // share again, accept, then the host ends the party → own sound back
    await hs2.setSharing(true);
    await until(() => gs.offer != null);
    await gs.accept();
    expect(gLab.borrowing, isTrue);
    await h.party.endParty();
    await until(() => !g.party.active && !gLab.borrowing, what: 'restored on End');
    expect(jsonEncode(gLab.partySound()), own);
    hs.dispose();
    hs2.dispose();
    gs.dispose();
  });
}
