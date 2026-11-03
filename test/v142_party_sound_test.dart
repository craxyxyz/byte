import 'dart:convert';

import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/data/party_sound.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/party_sound_section.dart';
import 'package:byte/ui/style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'helpers.dart';

// Byte © 2026 Apurba Laskar.
// 1.4.2: Listen together → "Share my sound with guests".

/// A party's live channel in memory: every message reaches everyone else.
class Bus {
  final List<FakeLink> links = [];
  final List<(String, String, Map)> sent = []; // (from, event, payload)
  List<Listener2> get people => [for (final l in links) if (l.active) Listener2(l.deviceId, l.name, l.isHost)];
  void changed() {
    for (final l in links) {
      l.ping();
    }
  }
}

class FakeLink extends ChangeNotifier implements PartyLink {
  final Bus bus;
  @override
  final String deviceId;
  final String name;
  @override
  final bool isHost;
  @override
  bool active = true;
  final Map<String, void Function(Map)> handlers = {};
  final List<void Function(Map)> needState = [];
  FakeLink(this.bus, this.deviceId, this.name, {this.isHost = false}) {
    bus.links.add(this);
  }
  void ping() => notifyListeners();
  @override
  String? get hostId => bus.links.where((l) => l.isHost && l.active).firstOrNull?.deviceId;
  @override
  String? get hostName => bus.links.where((l) => l.isHost && l.active).firstOrNull?.name;
  @override
  List<Listener2> get people => active ? bus.people : const [];
  @override
  Future<void> send(String event, Map<String, dynamic> payload) async {
    if (!active) return;
    // Over the wire: JSON, like the real channel.
    final wire = jsonDecode(jsonEncode(payload)) as Map;
    bus.sent.add((deviceId, event, wire));
    for (final l in [...bus.links]) {
      if (l != this && l.active) l.handlers[event]?.call(wire);
    }
  }

  @override
  void on(String event, void Function(Map) handler) => handlers[event] = handler;
  @override
  void onNeedState(void Function(Map) handler) => needState.add(handler);
  void leave() {
    active = false;
    bus.changed();
  }
}

Map<String, Object?> hostSettings() => {
  'eqOn': true,
  'nodes': [
    {'t': 0, 'f': 80.0, 'g': 7.5, 'q': 0.71},
    {'t': 1, 'f': 1200.0, 'g': -2.0, 'q': 1.41},
    {'t': 2, 'f': 9000.0, 'g': 3.0, 'q': 0.71},
  ],
  'preset': null,
  'preamp': -3.5,
  'autoPre': false,
  'rvOn': true,
  'rvPreset': 3,
  'rv_mix': 0.3, 'rv_size': 0.6, 'rv_damping': 0.3, 'rv_wet': 0.7, 'rv_dry': 1.0, 'rv_width': 1.0, 'rv_preDelay': 20.0,
  'ldOn': true, 'ldMode': 1, 'ldBoost': 6.0, 'ldComp': 0.55,
  'xfOn': true, 'xfSpk': false, 'xfStr': 2, 'xfDb': -4.5, 'xfHz': 650.0, 'xfAmt': 0.8,
  'mono': true, 'bal': -0.25, 'semis': -2.0,
  // not lent:
  'keepPitch': false, 'gapless': false, 'fadeMs': 900, 'f32': true,
};

Map<String, Object?> guestSettings() => {
  'eqOn': false,
  'preset': 'Bass Booster',
  'nodes': [
    {'t': 1, 'f': 60.0, 'g': 5.0, 'q': 1.0},
  ],
  'rvOn': false,
  'bal': 0.4,
  'keepPitch': true,
  'gapless': true,
  'fadePause': false,
  'curve': 1,
  'f32': false,
  'custom': {
    'Mine': [
      {'t': 1, 'f': 300.0, 'g': 2.0, 'q': 1.0},
    ],
  },
};

class Party {
  final bus = Bus();
  late final hostLab = AudioLab()..openForTest(hostSettings());
  late final host = FakeLink(bus, 'host-1', 'Apurba', isHost: true);
  late final hostSound = PartySound(lab: hostLab, link: host);
  final guests = <FakeLink>[];
  final guestLabs = <AudioLab>[];
  final guestSounds = <PartySound>[];
  bool classic = true;
  Party(int n) {
    hostSound;
    for (var i = 0; i < n; i++) {
      final l = FakeLink(bus, 'guest-$i', 'Guest $i');
      final lab = AudioLab()..openForTest(guestSettings());
      guests.add(l);
      guestLabs.add(lab);
      guestSounds.add(PartySound(lab: lab, link: l, readClassicEq: () => classic, writeClassicEq: (v) => classic = v));
    }
    bus.changed();
  }
  int soundsSent() => bus.sent.where((m) => m.$2 == 'sound').length;
}

void main() {
  setUp(() => PartySound.debounce = const Duration(milliseconds: 500));

  group('the host\'s sound', () {
    test('serialize → apply → restore: exactly the host\'s sound, then exactly his own', () {
      final host = AudioLab()..openForTest(hostSettings());
      final guest = AudioLab()..openForTest(guestSettings());
      final before = jsonEncode(guest.debugAll);
      final beforeCfg = guest.nativeConfig();
      final wire = jsonDecode(jsonEncode(host.partySound())) as Map;
      // Only sound is lent: no speed/slowed, transitions, output or presets.
      expect(wire.keys.toSet(), AudioLab.partyKeys.intersection(hostSettings().keys.toSet()));
      for (final k in ['keepPitch', 'gapless', 'fadeMs', 'f32', 'custom']) {
        expect(wire.containsKey(k), isFalse, reason: k);
      }
      guest.borrow(wire);
      expect(guest.borrowing, isTrue);
      expect(jsonEncode(guest.partySound()), jsonEncode(host.partySound()));
      final h = host.nativeConfig(), g = guest.nativeConfig();
      for (final k in h.keys) {
        if (k == 'float32') continue; // each phone's own output
        expect(jsonEncode(g[k]), jsonEncode(h[k]), reason: k);
      }
      expect(guest.pitchSemis, -2);
      expect(guest.preservePitch, isTrue); // his own: speed/slowed are not lent
      expect(guest.gapless, isTrue);
      expect(guest.float32, isFalse);
      expect(guest.customPresets.keys, ['Mine']);
      guest.restoreOwn();
      expect(guest.borrowing, isFalse);
      expect(jsonEncode(guest.debugAll), before);
      expect(jsonEncode(guest.nativeConfig()), jsonEncode(beforeCfg));
    });

    test('keys the host never touched fall back to the defaults, like on his phone', () {
      final host = AudioLab()..openForTest({'mono': true});
      final guest = AudioLab()..openForTest(guestSettings());
      guest.borrow(host.partySound());
      expect(guest.eqOn, isFalse);
      expect(guest.balance, 0);
      expect(guest.preset, isNull);
      expect(guest.mono, isTrue);
      guest.restoreOwn();
      expect(guest.balance, 0.4);
      expect(guest.preset, 'Bass Booster');
    });

    test('his own changes to what is not lent are kept; changes to the lent sound are not', () {
      final guest = AudioLab()..openForTest(guestSettings());
      guest.borrow(AudioLab().partySound());
      guest.fadeMs = 1200; // his own transition setting
      guest.balance = 1; // fiddling with the host's sound
      guest.restoreOwn();
      expect(guest.fadeMs, 1200);
      expect(guest.balance, 0.4);
    });

    test('his own settings stay on disk the whole time (a crash comes back to his sound)', () async {
      await makeServices();
      final lab = AudioLab();
      await lab.open();
      lab.balance = 0.4;
      lab.mono = false;
      lab.borrow(hostSettings());
      lab.fadeMs = 700;
      final box = Hive.box('audiolab');
      final disk = jsonDecode(box.get('v') as String) as Map;
      expect(disk['bal'], 0.4);
      expect(disk['mono'], false);
      expect(disk['fadeMs'], 700);
      lab.restoreOwn();
      final again = AudioLab();
      await again.open();
      expect(again.balance, 0.4);
      expect(again.fadeMs, 700);
      expect(again.mono, isFalse);
    });
  });

  group('sharing in a party', () {
    test('a guest is asked; Accept uses the host\'s sound and tells the host', () async {
      final p = Party(2);
      await p.hostSound.setSharing(true);
      final g = p.guestSounds[0];
      expect(g.offer, isNotNull);
      expect(g.offer!.hostName, 'Apurba');
      expect(p.guestLabs[0].borrowing, isFalse); // nothing changes before he answers
      await g.accept();
      expect(g.usingHostSound, isTrue);
      expect(g.usingHost, 'Apurba');
      expect(jsonEncode(p.guestLabs[0].partySound()), jsonEncode(p.hostLab.partySound()));
      expect(p.hostSound.answerOf('guest-0'), GuestAnswer.accepted);
      expect(p.hostSound.answerOf('guest-1'), GuestAnswer.waiting);
      expect(p.hostSound.hostLine, 'Sharing with 1 of 2 guests');
    });

    test('Decline changes nothing and he is not asked again until sharing goes off and on', () async {
      final p = Party(1);
      final before = jsonEncode(p.guestLabs[0].debugAll);
      await p.hostSound.setSharing(true);
      final g = p.guestSounds[0];
      await g.decline();
      expect(g.offer, isNull);
      expect(jsonEncode(p.guestLabs[0].debugAll), before);
      expect(p.guestLabs[0].borrowing, isFalse);
      expect(p.hostSound.answerOf('guest-0'), GuestAnswer.declined);
      expect(p.hostSound.hostLine, 'Sharing with 0 of 1 guest');
      // The host changes his sound and a late joiner asks for the state: no second question.
      p.hostLab.mono = false;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      for (final f in p.host.needState) {
        f({'from': 'guest-9'});
      }
      expect(g.offer, isNull);
      expect(jsonEncode(p.guestLabs[0].debugAll), before);
      // Off and on again: asked again.
      await p.hostSound.setSharing(false);
      await p.hostSound.setSharing(true);
      expect(g.offer, isNotNull);
    });

    test('leaving the party brings his own sound back exactly', () async {
      final p = Party(1);
      final before = jsonEncode(p.guestLabs[0].debugAll);
      p.hostLab.eqOn = true;
      await p.hostSound.setSharing(true);
      await p.guestSounds[0].accept();
      p.classic = false; // the Audio Lab equalizer switched the classic one off
      expect(p.guestLabs[0].borrowing, isTrue);
      p.guests[0].leave();
      expect(p.guestSounds[0].usingHostSound, isFalse);
      expect(p.guestLabs[0].borrowing, isFalse);
      expect(jsonEncode(p.guestLabs[0].debugAll), before);
      expect(p.classic, isTrue);
    });

    test('the host ending the party brings it back too', () async {
      final p = Party(1);
      final before = jsonEncode(p.guestLabs[0].debugAll);
      await p.hostSound.setSharing(true);
      await p.guestSounds[0].accept();
      // The real party: "closed" → the guest leaves.
      p.guests[0].leave();
      p.host.leave();
      expect(jsonEncode(p.guestLabs[0].debugAll), before);
      expect(p.hostSound.sharing, isFalse);
    });

    test('the host stopping sharing restores; Turn off restores and answers no', () async {
      final p = Party(2);
      final before0 = jsonEncode(p.guestLabs[0].debugAll);
      final before1 = jsonEncode(p.guestLabs[1].debugAll);
      await p.hostSound.setSharing(true);
      await p.guestSounds[0].accept();
      await p.guestSounds[1].accept();
      await p.guestSounds[1].turnOff();
      expect(jsonEncode(p.guestLabs[1].debugAll), before1);
      expect(p.hostSound.answerOf('guest-1'), GuestAnswer.declined);
      expect(p.guestSounds[1].offer, isNull); // not asked again this round
      await p.hostSound.setSharing(false);
      expect(p.guestSounds[0].usingHostSound, isFalse);
      expect(jsonEncode(p.guestLabs[0].debugAll), before0);
    });

    test('the host\'s changes are re-sent once, ~500 ms after he stops moving', () async {
      final p = Party(1);
      await p.hostSound.setSharing(true);
      await p.guestSounds[0].accept();
      final n = p.soundsSent();
      p.hostLab.balance = 0.1;
      p.hostLab.balance = 0.2;
      p.hostLab.reverbOn = false;
      p.hostLab.fadeMs = 1500; // not lent: no message of its own
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(p.soundsSent(), n);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(p.soundsSent(), n + 1);
      expect(p.guestLabs[0].balance, 0.2);
      expect(p.guestLabs[0].reverbOn, isFalse);
      expect(p.guestLabs[0].fadeMs, isNot(1500));
      // A change to something not lent alone sends nothing.
      p.hostLab.gapless = true;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(p.soundsSent(), n + 1);
    });

    test('a guest who joins late is asked when he asks the host for the party\'s state', () async {
      final p = Party(0);
      await p.hostSound.setSharing(true);
      final l = FakeLink(p.bus, 'late', 'Late');
      final lab = AudioLab()..openForTest(guestSettings());
      final g = PartySound(lab: lab, link: l);
      p.bus.changed();
      expect(g.offer, isNull);
      for (final f in p.host.needState) {
        f({'from': 'late'});
      }
      expect(g.offer, isNotNull);
    });

    test('only the host can share', () async {
      final p = Party(2);
      await p.guests[1].send('sound', {'on': true, 'g': 1, 's': <String, Object?>{'mono': true}, 'h': 'Guest 1', 'from': 'guest-1'});
      expect(p.guestSounds[0].offer, isNull);
      await p.guestSounds[0].link.send('sound', {'on': true});
      expect(p.hostSound.sharing, isFalse);
    });
  });

  group('party screen', () {
    Widget wrap(Widget w) => MaterialApp(home: Scaffold(body: SingleChildScrollView(child: w)));

    testWidgets('the guest sees the question, Accept / Decline, then "Using …\'s sound · Turn off"', (tester) async {
      final p = Party(1);
      await tester.pumpWidget(wrap(PartySoundSection(sound: p.guestSounds[0])));
      expect(find.textContaining('wants to share'), findsNothing);
      await tester.runAsync(() => p.hostSound.setSharing(true));
      await tester.pump();
      // 1.4.5 wording: names the sound; Apply / Keep mine.
      expect(find.text('Apurba wants to share their sound settings (Custom EQ + Reverb)'), findsOneWidget);
      expect(find.text('Apply'), findsOneWidget);
      expect(find.text('Keep mine'), findsOneWidget);
      await tester.tap(find.text('Apply'));
      await tester.pump();
      expect(find.text("Using Apurba's sound"), findsOneWidget);
      expect(find.text('Use my own sound'), findsOneWidget);
      await tester.tap(find.text('Use my own sound'));
      await tester.pump();
      expect(find.textContaining('Using'), findsNothing);
      expect(p.guestLabs[0].borrowing, isFalse);
    });

    testWidgets('Decline in the screen changes nothing', (tester) async {
      final p = Party(1);
      final before = jsonEncode(p.guestLabs[0].debugAll);
      await tester.pumpWidget(wrap(PartySoundSection(sound: p.guestSounds[0])));
      await tester.runAsync(() => p.hostSound.setSharing(true));
      await tester.pump();
      await tester.tap(find.text('Keep mine'));
      await tester.pump();
      expect(find.textContaining('wants to share'), findsNothing);
      expect(jsonEncode(p.guestLabs[0].debugAll), before);
    });

    testWidgets('the host has the switch and sees who accepted', (tester) async {
      final p = Party(3);
      await tester.pumpWidget(wrap(PartySoundSection(sound: p.hostSound)));
      expect(find.text('Share my sound settings with guests'), findsOneWidget);
      expect(find.textContaining('Not speed'), findsOneWidget);
      await tester.tap(find.byType(ByteSwitch));
      await tester.pump();
      expect(p.hostSound.sharing, isTrue);
      await tester.runAsync(() async {
        await p.guestSounds[0].accept();
        await p.guestSounds[1].accept();
        await p.guestSounds[2].decline();
      });
      await tester.pump();
      expect(find.text('Sharing with 2 of 3 guests'), findsOneWidget);
      expect(find.text('Using your sound'), findsNWidgets(2));
      expect(find.text('Kept theirs'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));
    });

    test('the app wires it to the real party channel', () async {
      final s = await makeServices();
      expect(s.party.extraEvents.keys, containsAll(['sound', 'sound_ack']));
      expect(s.party.onNeedState, isNotEmpty);
      expect(Services.i.partySound.sharing, isFalse);
    });
  });
}
