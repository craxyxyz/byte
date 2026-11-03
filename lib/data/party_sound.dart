import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../audiolab/audio_lab.dart';
import 'listen_together.dart';

// Byte © 2026 Apurba Laskar.
//
// Listen together → "Share my sound with guests" (1.4.2). The host lends his
// Audio Lab sound to the party; each guest is asked once and decides. A guest
// who says yes hears the host's sound until he turns it off, the host stops
// sharing or he leaves the party; then his own settings come back exactly.
//
// Messages ride the party's own live channel (no server tables):
//   sound      host → all  {on, g, s, h, from, p?}  g = this round of sharing,
//                                                 p = the sound's name (1.4.5)
//   sound_ack  guest → all {from, g, ok}
// Older versions ignore message types and keys they don't know.
//
// 1.4.5: the prompt names the host's sound ("Bass Booster") and what this
// device can't play; "Send now"; "Auto-accept host sound settings" (off by
// default); a guest who said no is asked once more only when the host picks a
// different sound, never after "Don't ask again this party".

/// What the party feature needs from a Listen together party.
abstract class PartyLink implements Listenable {
  bool get active;
  bool get isHost;
  String get deviceId;
  String? get hostId;
  String? get hostName;
  List<Listener2> get people;
  Future<void> send(String event, Map<String, dynamic> payload);
  void on(String event, void Function(Map payload) handler);
  void onNeedState(void Function(Map payload) handler);
}

/// The real party.
class ListenTogetherLink implements PartyLink {
  final ListenTogether party;
  ListenTogetherLink(this.party);
  @override
  bool get active => party.active;
  @override
  bool get isHost => party.isHost;
  @override
  String get deviceId => party.deviceId;
  @override
  String? get hostId => party.hostId;
  @override
  String? get hostName => party.hostName;
  @override
  List<Listener2> get people => party.people;
  @override
  Future<void> send(String event, Map<String, dynamic> payload) => party.sendExtra(event, payload);
  @override
  void on(String event, void Function(Map payload) handler) => party.extraEvents[event] = handler;
  @override
  void onNeedState(void Function(Map payload) handler) => party.onNeedState.add(handler);
  @override
  void addListener(VoidCallback l) => party.addListener(l);
  @override
  void removeListener(VoidCallback l) => party.removeListener(l);
}

/// A host's offer, as a guest sees it.
class SoundOffer {
  final int gen;
  final String hostName;
  final Map<String, Object?> sound;

  /// The sound's name ("Bass Booster", "Custom EQ + Reverb").
  final String name;

  /// What this device can't play of it ("reverb", "pitch").
  final List<String> skipped;
  const SoundOffer(this.gen, this.hostName, this.sound, {this.name = '', this.skipped = const []});

  /// "Reverb and pitch can't play on this device; the rest will."
  String? skippedLine(String place) {
    if (skipped.isEmpty) return null;
    final names = skipped.length == 1 ? skipped.first : '${skipped.sublist(0, skipped.length - 1).join(', ')} and ${skipped.last}';
    return '${names[0].toUpperCase()}${names.substring(1)} can\'t play $place; the rest will.';
  }
}

enum GuestAnswer { waiting, accepted, declined }

class PartySound extends ChangeNotifier {
  final AudioLab lab;
  final PartyLink link;

  /// The classic (Settings → Equalizer) on/off: the Audio Lab equalizer
  /// switches it off, so a guest's own value is kept and put back too.
  final bool Function()? readClassicEq;
  final void Function(bool on)? writeClassicEq;
  final int Function() _now;

  /// What this device's player can play (1.4.5; skipped effects are named).
  final SoundCaps Function() caps;

  static Duration debounce = const Duration(milliseconds: 500);

  PartySound({required this.lab, required this.link, this.readClassicEq, this.writeClassicEq, int Function()? now, SoundCaps Function()? caps})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
      caps = caps ?? (() => AudioLabEngine.current ?? SoundBackend.forPlatform().caps) {
    link.on('sound', _onSound);
    link.on('sound_ack', _onAck);
    link.onNeedState((_) {
      if (sharing && link.isHost) unawaited(_broadcast());
    });
    link.addListener(_partyChanged);
    lab.addListener(_labChanged);
  }

  // ── Host ──
  bool sharing = false;
  int gen = 0;
  final Map<String, bool> acks = {};
  Timer? _resend;
  String? _lastSent;

  /// Guests in the party right now (everyone but the host).
  List<Listener2> get guests => [
    for (final p in link.people)
      if (!p.host && p.id != link.deviceId) p,
  ];

  GuestAnswer answerOf(String id) => switch (acks[id]) {
    true => GuestAnswer.accepted,
    false => GuestAnswer.declined,
    null => GuestAnswer.waiting,
  };

  int get acceptedCount => guests.where((g) => acks[g.id] == true).length;

  /// "Sharing with 2 of 3 guests".
  String get hostLine {
    final n = guests.length;
    if (n == 0) return 'No guests yet. They\'re asked when they join';
    return 'Sharing with $acceptedCount of $n ${n == 1 ? 'guest' : 'guests'}';
  }

  Future<void> setSharing(bool on) async {
    if (!link.isHost || on == sharing) return;
    sharing = on;
    _resend?.cancel();
    acks.clear();
    _lastSent = null;
    if (on) {
      gen = _now();
      notifyListeners();
      await _broadcast();
    } else {
      notifyListeners();
      await link.send('sound', {'on': false, 'g': gen, 'from': link.deviceId});
    }
  }

  Future<void> _broadcast() async {
    final s = lab.partySound();
    _lastSent = jsonEncode(s);
    await link.send('sound', {'on': true, 'g': gen, 's': s, 'h': _myName(), 'p': soundName(s), 'from': link.deviceId});
  }

  /// "Send now": the host's sound goes out at once (no wait for the
  /// debounce); turns sharing on when it was off.
  Future<void> sendNow() async {
    if (!link.isHost) return;
    if (!sharing) return setSharing(true);
    _resend?.cancel();
    await _broadcast();
  }

  /// A short name for a lent sound: the equalizer preset, else what's on.
  static String soundName(Map s) {
    final eq = s['eqOn'] == true;
    final preset = s['preset'];
    final fx = [
      if (s['rvOn'] == true) 'Reverb',
      if (s['ldOn'] == true) 'Loudness',
      if (s['xfOn'] == true) 'Crossfeed',
      if (s['mono'] == true) 'Mono',
    ];
    final base = eq ? (preset is String && preset.isNotEmpty ? preset : 'Custom EQ') : null;
    final all = [?base, ...fx];
    if (all.isEmpty) return ((s['bal'] as num?)?.abs() ?? 0) > 0.009 || ((s['semis'] as num?) ?? 0) != 0 ? 'Custom' : 'Flat';
    return all.take(2).join(' + ');
  }

  String _myName() {
    for (final p in link.people) {
      if (p.id == link.deviceId && p.name.isNotEmpty) return p.name;
    }
    return link.hostName ?? 'The host';
  }

  void _labChanged() {
    if (!sharing || !link.isHost) return;
    if (jsonEncode(lab.partySound()) == _lastSent) return; // nothing lent changed
    _resend?.cancel();
    _resend = Timer(debounce, () {
      if (sharing && link.isHost) unawaited(_broadcast());
    });
  }

  void _onAck(Map p) {
    if (!link.isHost || !sharing) return;
    if ((p['g'] as num?)?.toInt() != gen) return;
    final from = p['from'];
    if (from is! String) return;
    acks[from] = p['ok'] == true;
    notifyListeners();
  }

  // ── Guest ──
  /// Asked and not answered yet.
  SoundOffer? offer;

  /// The round he said yes to (null = his own sound).
  int? usingGen;
  String? usingHost;
  final Set<int> _said = {}; // rounds he answered (no second question)
  bool? _classicWas;

  bool get usingHostSound => usingGen != null;

  /// The sound names he was already asked about this round (one re-ask per
  /// new name after a no).
  final Map<int, Set<String>> _askedNames = {};

  /// "Don't ask again this party".
  bool noMoreAsks = false;

  /// The latest sound the host is sharing (to re-ask or apply live).
  Map<String, Object?>? _latest;
  String? _latestName;

  /// What this device can't play of what he's using now.
  List<String> get skippedNow => _latest == null ? const [] : caps().skippedIn(_latest!);

  void _onSound(Map p) {
    if (link.isHost || !link.active) return;
    final from = p['from'];
    if (link.hostId != null && from is String && from != link.hostId) return; // only the host shares
    final g = (p['g'] as num?)?.toInt() ?? 0;
    if (p['on'] != true) {
      offer = null;
      _stopUsing();
      notifyListeners();
      return;
    }
    final s = p['s'];
    if (s is! Map) return;
    final name = (p['h'] as String?)?.trim();
    final host = (name == null || name.isEmpty) ? (link.hostName ?? 'The host') : name;
    final sound = Map<String, Object?>.from(s);
    final label = (p['p'] as String?)?.trim().isNotEmpty == true ? (p['p'] as String).trim() : soundName(sound);
    _latest = sound;
    _latestName = label;
    if (usingGen == g) {
      lab.borrow(s); // the host changed his sound: live
      usingHost = host;
      notifyListeners();
      return;
    }
    if (usingGen != null) _stopUsing(); // a new round: back to his own until he says yes
    final asked = _askedNames.putIfAbsent(g, () => {});
    if (_said.contains(g)) {
      // He said no (or went back to his own): one more ask only for a sound
      // he hasn't been asked about, and never after "Don't ask again".
      if (noMoreAsks || asked.contains(label)) return;
      _said.remove(g);
    }
    if (offer != null && offer!.gen == g) {
      // Still on screen: show the newest sound.
      offer = SoundOffer(g, host, sound, name: label, skipped: caps().skippedIn(sound));
      asked.add(label);
      notifyListeners();
      return;
    }
    asked.add(label);
    offer = SoundOffer(g, host, sound, name: label, skipped: caps().skippedIn(sound));
    if (lab.autoAcceptPartySound) {
      unawaited(accept());
      return;
    }
    notifyListeners();
  }

  /// "Don't ask again this party": no now, and no more questions.
  Future<void> declineForParty() async {
    noMoreAsks = true;
    await decline();
  }

  /// The name of the host's sound he's using (or was offered last).
  String? get hostSoundName => _latestName;

  Future<void> accept() async {
    final o = offer;
    if (o == null) return;
    offer = null;
    _said.add(o.gen);
    _classicWas ??= readClassicEq?.call();
    lab.borrow(o.sound);
    usingGen = o.gen;
    usingHost = o.hostName;
    notifyListeners();
    await link.send('sound_ack', {'from': link.deviceId, 'g': o.gen, 'ok': true});
  }

  Future<void> decline() async {
    final o = offer;
    if (o == null) return;
    offer = null;
    _said.add(o.gen);
    notifyListeners();
    await link.send('sound_ack', {'from': link.deviceId, 'g': o.gen, 'ok': false});
  }

  /// "Turn off": back to his own sound; not asked again this round.
  Future<void> turnOff() async {
    final g = usingGen;
    if (g == null) return;
    _stopUsing();
    notifyListeners();
    await link.send('sound_ack', {'from': link.deviceId, 'g': g, 'ok': false});
  }

  void _stopUsing() {
    if (usingGen == null && !lab.borrowing) return;
    usingGen = null;
    usingHost = null;
    lab.restoreOwn();
    final c = _classicWas;
    _classicWas = null;
    if (c != null && readClassicEq?.call() != c) writeClassicEq?.call(c);
  }

  void _partyChanged() {
    if (link.active) {
      if (link.isHost && sharing) notifyListeners(); // who's here changed
      return;
    }
    // Left the party (or it ended): everything back.
    final had = sharing || offer != null || usingGen != null || _said.isNotEmpty || acks.isNotEmpty;
    _resend?.cancel();
    sharing = false;
    acks.clear();
    _lastSent = null;
    offer = null;
    _said.clear();
    _askedNames.clear();
    noMoreAsks = false;
    _latest = null;
    _latestName = null;
    _stopUsing();
    if (had) notifyListeners();
  }

  @override
  void dispose() {
    _resend?.cancel();
    link.removeListener(_partyChanged);
    lab.removeListener(_labChanged);
    super.dispose();
  }
}
