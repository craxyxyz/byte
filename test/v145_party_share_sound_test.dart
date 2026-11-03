// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba): "Party ke time host chahe toh apni audio settings guests pe
// apply kar sake; guest ko notification aaye, woh accept kare ya na kare".
// Builds on 1.4.2's "Share my sound" (test/v142_party_sound_test.dart).
import 'dart:convert';

import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/data/party_sound.dart';
import 'package:flutter_test/flutter_test.dart';

import 'v142_party_sound_test.dart' show Bus, FakeLink, hostSettings, guestSettings;

class P {
  final bus = Bus();
  late final hostLab = AudioLab()..openForTest({...hostSettings(), 'preset': 'Bass Booster'});
  late final host = FakeLink(bus, 'host-1', 'Apurba', isHost: true);
  late final hostSound = PartySound(lab: hostLab, link: host);
  late final guest = FakeLink(bus, 'guest-1', 'Riya');
  late final guestLab = AudioLab()..openForTest(guestSettings());
  late final guestSound = PartySound(lab: guestLab, link: guest, caps: () => SoundCaps.android);
  P({bool auto = false}) {
    hostSound;
    guestSound;
    if (auto) guestLab.autoAcceptPartySound = true;
    bus.changed();
  }
  String lent(AudioLab l) => jsonEncode(l.partySound());
  int asks() => bus.sent.where((m) => m.$2 == 'sound').length;
}

Future<void> tick([int ms = 10]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  setUp(() => PartySound.debounce = const Duration(milliseconds: 60));

  test('host shares → guest is asked with the sound\'s name; Apply → his player uses the host\'s sound', () async {
    final p = P();
    await p.hostSound.setSharing(true);
    final o = p.guestSound.offer!;
    expect(o.hostName, 'Apurba');
    expect(o.name, 'Bass Booster + Reverb');
    expect(o.skipped, isEmpty);
    await p.guestSound.accept();
    expect(p.lent(p.guestLab), p.lent(p.hostLab));
    expect(p.guestLab.nativeConfig()['eqOn'], isTrue, reason: 'what the effects engine gets');
    expect(p.hostSound.answerOf('guest-1'), GuestAnswer.accepted);
  });

  test('Keep mine → nothing changes', () async {
    final p = P();
    final before = jsonEncode(p.guestLab.debugAll);
    await p.hostSound.setSharing(true);
    await p.guestSound.decline();
    expect(jsonEncode(p.guestLab.debugAll), before);
    expect(p.hostSound.answerOf('guest-1'), GuestAnswer.declined);
  });

  test('leaving the party restores his own settings exactly; "Use my own sound" any time too', () async {
    final p = P();
    final before = jsonEncode(p.guestLab.debugAll);
    await p.hostSound.setSharing(true);
    await p.guestSound.accept();
    await p.guestSound.turnOff();
    expect(jsonEncode(p.guestLab.debugAll), before);
    // asked again only for a different sound; accept again, then leave
    p.hostLab.applyPreset('Treble Booster');
    await tick(120);
    expect(p.guestSound.offer, isNotNull);
    await p.guestSound.accept();
    expect(p.guestLab.preset, 'Treble Booster');
    p.guest.leave();
    expect(jsonEncode(p.guestLab.debugAll), before);
    expect(p.guestSound.usingHostSound, isFalse);
  });

  test('auto-accept (off by default): the host\'s sound is used without a question', () async {
    expect(AudioLab().autoAcceptPartySound, isFalse);
    final p = P(auto: true);
    await p.hostSound.setSharing(true);
    await tick();
    expect(p.guestSound.offer, isNull);
    expect(p.guestSound.usingHostSound, isTrue);
    expect(p.lent(p.guestLab), p.lent(p.hostLab));
    expect(p.hostSound.answerOf('guest-1'), GuestAnswer.accepted);
    p.guest.leave();
    expect(p.guestLab.autoAcceptPartySound, isTrue, reason: 'his own setting, kept');
    expect(p.guestLab.preset, 'Bass Booster', reason: 'his own sound back (his preset)');
    expect(p.guestLab.eqOn, isFalse);
  });

  test('host changes while sharing → accepted guests get them live (debounced: one message)', () async {
    final p = P();
    await p.hostSound.setSharing(true);
    await p.guestSound.accept();
    final n = p.asks();
    p.hostLab.balance = 0.2;
    p.hostLab.balance = 0.3;
    p.hostLab.balance = 0.4;
    await tick(150);
    expect(p.asks(), n + 1);
    expect(p.guestLab.balance, 0.4);
    expect(p.guestSound.offer, isNull, reason: 'no new question while he uses it');
  });

  test('a guest who said no: one re-ask per new sound, none for the same sound, none after "Don\'t ask again"', () async {
    final p = P();
    await p.hostSound.setSharing(true);
    await p.guestSound.decline();
    p.hostLab.balance = 0.1; // same sound name: no new question
    await tick(120);
    expect(p.guestSound.offer, isNull);
    p.hostLab.applyPreset('Treble Booster'); // a new sound: asked once
    await tick(120);
    expect(p.guestSound.offer?.name, 'Treble Booster + Reverb');
    await p.guestSound.decline();
    p.hostLab.applyPreset('Bass Booster'); // back to one he already declined
    await tick(120);
    expect(p.guestSound.offer, isNull);
    p.hostLab.applyPreset('Vocal Booster');
    await tick(120);
    expect(p.guestSound.offer, isNotNull);
    await p.guestSound.declineForParty();
    p.hostLab.applyPreset('Rock');
    await tick(120);
    expect(p.guestSound.offer, isNull, reason: 'don\'t ask again this party');
    await p.hostSound.sendNow();
    expect(p.guestSound.offer, isNull);
  });

  test('"Send now" goes out at once (no debounce) and turns sharing on', () async {
    final p = P();
    await p.hostSound.sendNow();
    expect(p.hostSound.sharing, isTrue);
    expect(p.guestSound.offer, isNotNull);
    await p.guestSound.accept();
    p.hostLab.pitchSemis = -3;
    final n = p.asks();
    await p.hostSound.sendNow();
    expect(p.asks(), n + 1);
    expect(p.guestLab.pitchSemis, -3);
  });

  test('the prompt says what this device can\'t play; the rest is applied', () async {
    final bus = Bus();
    final host = PartySound(lab: AudioLab()..openForTest({...hostSettings(), 'preset': 'Rock'}), link: FakeLink(bus, 'h', 'Apurba', isHost: true));
    final lab = AudioLab()..openForTest(guestSettings());
    final g = PartySound(lab: lab, link: FakeLink(bus, 'g', 'Riya'), caps: () => SoundCaps.ios);
    bus.changed();
    await host.setSharing(true);
    final o = g.offer!;
    expect(o.skipped, ['reverb', 'loudness', 'crossfeed', 'pitch']);
    expect(o.skippedLine('on iPhone'), "Reverb, loudness, crossfeed and pitch can't play on iPhone; the rest will.");
    await g.accept();
    expect(lab.eqOn, isTrue);
    expect(lab.balance, -0.25);
    expect(g.skippedNow, ['reverb', 'loudness', 'crossfeed', 'pitch']);
  });

  test('older apps: a guest without this feature ignores the message; an old host (no name) still works', () async {
    final bus = Bus();
    final host = FakeLink(bus, 'h', 'Apurba', isHost: true);
    final oldGuest = FakeLink(bus, 'old', 'Old phone'); // registers no "sound" handler
    final lab = AudioLab()..openForTest(guestSettings());
    final g = PartySound(lab: lab, link: FakeLink(bus, 'g', 'Riya'), caps: () => SoundCaps.android);
    bus.changed();
    // a 1.4.2 host: no "p", plus a key nobody knows yet
    await host.send('sound', {'on': true, 'g': 7, 's': {'eqOn': true, 'preset': 'Rock'}, 'h': 'Apurba', 'from': 'h', 'future': 1});
    expect(oldGuest.handlers, isEmpty);
    expect(g.offer!.name, 'Rock');
    await g.accept();
    expect(lab.preset, 'Rock');
    // an unknown message type changes nothing
    await host.send('sound_v9', {'x': 1});
    expect(g.usingHostSound, isTrue);
  });
}
