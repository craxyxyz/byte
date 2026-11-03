// Byte © 2026 Apurba Laskar.
//
// An in-memory stand-in for the party's live server (1.4.3): several phones
// (ListenTogether objects) on one bus that behaves like Supabase Realtime
// broadcast + presence — others get each message (not the sender), presence
// leaves when a phone's connection goes, and a channel subscribes again when
// the connection comes back. Optionally the saved-room table too.
import 'dart:async';
import 'dart:convert';

import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:flutter/foundation.dart';

class FakePartyBus {
  /// Server has Byte's tables (false = Apurba's server today: live only).
  bool tables;
  FakePartyBus({this.tables = false});

  final Map<String, List<FakePartyChannel>> _subs = {}; // topic → joined channels
  final Map<String, Map<String, Map>> _presence = {}; // topic → key → payload
  final Map<String, Map<String, dynamic>> rooms = {}; // code → row
  final List<String> sent = []; // "event from key" log

  List<Map> presenceOf(String topic) => [...?_presence[topic]?.values];

  void _attach(FakePartyChannel c) => (_subs[c.topic] ??= []).add(c);
  void _detach(FakePartyChannel c) {
    _subs[c.topic]?.remove(c);
    _setPresence(c, null);
  }

  void _setPresence(FakePartyChannel c, Map? payload) {
    final m = _presence[c.topic] ??= {};
    final had = m.containsKey(c.key);
    if (payload == null) {
      m.remove(c.key);
      if (!had) return;
    } else {
      m[c.key] = jsonDecode(jsonEncode(payload)) as Map;
    }
    for (final o in [...?_subs[c.topic]]) {
      scheduleMicrotask(o._presenceChanged);
    }
  }

  void _broadcast(FakePartyChannel from, String event, Map<String, dynamic> payload) {
    sent.add('$event ${from.key}');
    final wire = jsonEncode(payload);
    for (final o in [...?_subs[from.topic]]) {
      if (identical(o, from) || o.net.halfOpen) continue; // self: false
      Timer(const Duration(milliseconds: 5), () {
        if (o._joined && !o.net.halfOpen) o._deliver(event, jsonDecode(wire) as Map);
      });
    }
  }

  Never _missing() => throw Exception('PGRST202 Could not find the function public.byte_lt_open in the schema cache');
}

class FakePartyNet implements PartyNet {
  final FakePartyBus bus;
  FakePartyNet(this.bus);
  bool online = true;

  /// The server dropped this phone but the phone hasn't noticed yet.
  bool halfOpen = false;
  final List<FakePartyChannel> _mine = [];

  /// Net gone (airplane mode, lift, tunnel): the server drops this phone's
  /// presence and the channel reports the drop.
  void drop() {
    online = false;
    for (final c in [..._mine]) {
      if (c._joined) {
        c._joined = false;
        bus._detach(c);
        c._status(PartyStatus.error);
      }
    }
  }

  /// Net back: like the real client, joined channels subscribe again.
  void restore() {
    online = true;
    halfOpen = false;
    for (final c in [..._mine]) {
      if (c._wanted && !c._joined) c._doJoin();
    }
  }

  /// The server timed this phone's presence out while its socket still looks
  /// open (phone asleep). Nothing reaches it until [noticeDrop].
  void presenceTimeout() {
    halfOpen = true;
    for (final c in [..._mine]) {
      bus._setPresence(c, null);
    }
  }

  /// The phone finally notices (socket heartbeat missed): channel error.
  void noticeDrop() {
    halfOpen = false;
    online = false;
    drop();
  }

  /// The app process is killed: the server sees the socket close. No last
  /// words from the phone.
  void kill() {
    for (final c in [..._mine]) {
      c._joined = false;
      c._wanted = false;
      bus._detach(c);
    }
    _mine.clear();
    online = false;
  }

  @override
  void reset() {}

  @override
  bool get socketConnected => online && !halfOpen;

  @override
  PartyChannel channel(String code, String key) {
    final c = FakePartyChannel(this, 'byte-lt-$code', key);
    _mine.add(c);
    return c;
  }

  @override
  Future<void> removeChannel(PartyChannel ch) async {
    if (ch is! FakePartyChannel) return;
    ch._wanted = false;
    if (ch._joined) {
      ch._joined = false;
      bus._detach(ch);
    }
    _mine.remove(ch);
    ch._status(PartyStatus.closed);
  }

  void _needNet() {
    if (!online) throw Exception('SocketException: Failed host lookup');
  }

  @override
  Future<bool> openRoom(String code, String secret, String hostName, Map<String, dynamic> state) async {
    _needNet();
    if (!bus.tables) bus._missing();
    final r = bus.rooms[code];
    if (r != null && r['secret'] != secret && r['closed'] != true) return false;
    bus.rooms[code] = {'code': code, 'host_name': hostName, 'secret': secret, 'state': jsonDecode(jsonEncode(state)), 'closed': false};
    return true;
  }

  @override
  Future<bool> updateRoom(String code, String secret, Map<String, dynamic> state) async {
    _needNet();
    if (!bus.tables) bus._missing();
    final r = bus.rooms[code];
    if (r == null || r['closed'] == true || r['secret'] != secret) return false;
    r['state'] = jsonDecode(jsonEncode(state));
    return true;
  }

  @override
  Future<void> closeRoom(String code, String secret) async {
    _needNet();
    if (!bus.tables) bus._missing();
    final r = bus.rooms[code];
    if (r != null && r['secret'] == secret) r['closed'] = true;
  }

  @override
  Future<List<Map>> readRoom(String code) async {
    _needNet();
    if (!bus.tables) bus._missing();
    final r = bus.rooms[code];
    if (r == null || r['closed'] == true) return [];
    return [
      {'code': code, 'host_name': r['host_name'], 'state': r['state']},
    ];
  }
}

class FakePartyChannel implements PartyChannel {
  final FakePartyNet net;
  final String topic;
  final String key;
  FakePartyChannel(this.net, this.topic, this.key);
  final Map<String, void Function(Map)> _on = {};
  final List<void Function()> _presenceCbs = [];
  void Function(PartyStatus, Object?)? _cb;
  bool _joined = false;
  bool _wanted = false;
  Map? _tracked;

  void _status(PartyStatus s) => _cb?.call(s, s == PartyStatus.subscribed ? null : Exception('channel $s'));
  void _deliver(String event, Map p) => _on[event]?.call(p);
  void _presenceChanged() {
    for (final f in [..._presenceCbs]) {
      f();
    }
  }

  void _doJoin() {
    scheduleMicrotask(() {
      if (!_wanted || _joined) return;
      if (!net.online) {
        _status(PartyStatus.error);
        return;
      }
      _joined = true;
      net.bus._attach(this);
      _status(PartyStatus.subscribed);
      if (_tracked != null) net.bus._setPresence(this, _tracked);
      _presenceChanged();
    });
  }

  @override
  void onBroadcast(String event, void Function(Map payload) cb) => _on[event] = cb;
  @override
  void onPresence(void Function() cb) => _presenceCbs.add(cb);
  @override
  void subscribe(void Function(PartyStatus status, Object? err) cb) {
    _cb = cb;
    _wanted = true;
    _doJoin();
  }

  @override
  Future<void> track(Map<String, dynamic> payload) async {
    _tracked = payload;
    if (!_joined) throw Exception('not joined');
    net.bus._setPresence(this, payload);
  }

  @override
  Future<void> untrack() async {
    _tracked = null;
    if (_joined) net.bus._setPresence(this, null);
  }

  @override
  Future<void> send(String event, Map<String, dynamic> payload) async {
    if (!_joined || !net.online) throw Exception('channel not joined');
    if (net.halfOpen) return; // goes nowhere
    net.bus._broadcast(this, event, payload);
  }

  @override
  List<(String, Map)> presences() => [
    for (final e in (net.bus._presence[topic] ?? const <String, Map>{}).entries) (e.key, e.value),
  ];
}

/// A pretend player: user actions fire [changes]; the party drives it too.
class FakeSyncPlayer implements SyncPlayer {
  final String name;
  FakeSyncPlayer(this.name);
  @override
  Item? item;
  bool playing = false;
  int _posMs = 0;
  int _at = DateTime.now().millisecondsSinceEpoch;
  final ValueNotifier<int> _changes = ValueNotifier(0);
  final List<String> log = [];
  @override
  Listenable get changes => _changes;
  @override
  bool get isPlaying => playing;
  @override
  Duration get position => Duration(milliseconds: playing ? _posMs + DateTime.now().millisecondsSinceEpoch - _at : _posMs);
  void _mark(int pos) {
    _posMs = pos;
    _at = DateTime.now().millisecondsSinceEpoch;
  }

  void userPlay(Item it, {int atMs = 0}) {
    item = it;
    playing = true;
    _mark(atMs);
    _changes.value++;
  }

  void userPause() {
    _mark(position.inMilliseconds);
    playing = false;
    _changes.value++;
  }

  void userResume() {
    _mark(position.inMilliseconds);
    playing = true;
    _changes.value++;
  }

  void userSeek(int ms) {
    _mark(ms);
    _changes.value++;
  }

  /// The song ended and this phone's own queue moved on (or stopped).
  void autoNext(Item? next) {
    if (next == null) {
      _mark(position.inMilliseconds);
      playing = false;
    } else {
      item = next;
      playing = true;
      _mark(0);
    }
    _changes.value++;
  }

  @override
  Future<void> load(Item it, Duration at, {required bool play}) async {
    log.add('load ${it.id} ${at.inMilliseconds} $play');
    item = it;
    playing = play;
    _mark(at.inMilliseconds);
  }

  @override
  Future<void> seekTo(Duration d) async {
    log.add('seek ${d.inMilliseconds}');
    _mark(d.inMilliseconds);
  }

  @override
  Future<void> setPlaying(bool play) async {
    log.add('play $play');
    _mark(position.inMilliseconds);
    playing = play;
  }
}

/// One phone in the test party.
class Phone {
  final String id;
  final FakeSyncPlayer player;
  FakePartyNet net;
  final PartyStore store;
  late ListenTogether party;
  Phone(FakePartyBus bus, this.id, String name, {PartyStore? store})
    : player = FakeSyncPlayer(name),
      net = FakePartyNet(bus),
      store = store ?? MemoryPartyStore() {
    party = ListenTogether(player: player, deviceId: id, displayName: () => name, net: net, store: this.store);
  }

  /// The app was killed and opened again: same phone, same saved data, a
  /// fresh party object and connection.
  void relaunch(FakePartyBus bus, String name) {
    net.kill();
    party.dispose(); // its timers die with the process
    net = FakePartyNet(bus);
    party = ListenTogether(player: player, deviceId: id, displayName: () => name, net: net, store: store);
  }
}

Future<void> settle([int ms = 120]) => Future<void>.delayed(Duration(milliseconds: ms));

/// Wait until [ok] holds (or fail after [ms]).
Future<void> until(bool Function() ok, {int ms = 4000, String? what}) async {
  final end = DateTime.now().millisecondsSinceEpoch + ms;
  while (!ok()) {
    if (DateTime.now().millisecondsSinceEpoch > end) throw StateError('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
