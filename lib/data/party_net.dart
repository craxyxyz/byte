import 'dart:async';

import 'package:supabase/supabase.dart';

// Byte © 2026 Apurba Laskar.
//
// What Listen together needs from the network (1.4.3): the saved room on the
// server (optional; a party also runs on the live channel alone) and one live
// channel per party with broadcast + presence. The real one is Supabase; the
// tests run several phones on one in-memory bus that behaves the same way.

enum PartyStatus { subscribed, error, closed }

abstract class PartyChannel {
  void onBroadcast(String event, void Function(Map payload) cb);

  /// Presence changed (sync, join or leave).
  void onPresence(void Function() cb);

  /// Called on every (re)subscribe and every drop.
  void subscribe(void Function(PartyStatus status, Object? err) cb);
  Future<void> track(Map<String, dynamic> payload);
  Future<void> untrack();
  Future<void> send(String event, Map<String, dynamic> payload);

  /// Everyone tracked on the channel right now: (presence key, payload).
  List<(String, Map)> presences();
}

abstract class PartyNet {
  /// Saved room. Each throws what the server says; a server with no Byte
  /// tables throws an error [ListenTogether.isSetupMissing] recognises.
  Future<bool> openRoom(String code, String secret, String hostName, Map<String, dynamic> state);
  Future<bool> updateRoom(String code, String secret, Map<String, dynamic> state);
  Future<void> closeRoom(String code, String secret);
  Future<List<Map>> readRoom(String code);

  PartyChannel channel(String code, String key);
  Future<void> removeChannel(PartyChannel ch);

  /// The socket under the channels is open (false when it died quietly).
  bool get socketConnected;

  /// Forget the connection (a new server was picked).
  void reset();
}

class SupabasePartyNet implements PartyNet {
  final SupabaseClient Function() _factory;
  SupabasePartyNet(this._factory);
  SupabaseClient? _c;
  SupabaseClient get client => _c ??= _factory();

  @override
  void reset() => _c = null;

  @override
  Future<bool> openRoom(String code, String secret, String hostName, Map<String, dynamic> state) async =>
      await client.rpc('byte_lt_open', params: {'p_code': code, 'p_secret': secret, 'p_host_name': hostName, 'p_state': state}) == true;

  @override
  Future<bool> updateRoom(String code, String secret, Map<String, dynamic> state) async =>
      await client.rpc('byte_lt_update', params: {'p_code': code, 'p_secret': secret, 'p_state': state}) == true;

  @override
  Future<void> closeRoom(String code, String secret) => client.rpc('byte_lt_close', params: {'p_code': code, 'p_secret': secret});

  @override
  Future<List<Map>> readRoom(String code) async {
    final rows = await client.from('byte_listen_rooms').select('code, host_name, state').eq('code', code).limit(1);
    return [for (final r in rows) r];
  }

  @override
  PartyChannel channel(String code, String key) =>
      _SupaChannel(client.channel('byte-lt-$code', opts: RealtimeChannelConfig(key: key, self: false, ack: true)));

  @override
  Future<void> removeChannel(PartyChannel ch) async {
    if (ch is _SupaChannel) await client.removeChannel(ch.ch);
  }

  @override
  bool get socketConnected => client.realtime.isConnected;
}

class _SupaChannel implements PartyChannel {
  final RealtimeChannel ch;
  _SupaChannel(this.ch);
  @override
  void onBroadcast(String event, void Function(Map payload) cb) => ch.onBroadcast(event: event, callback: (p) => cb(p));
  @override
  void onPresence(void Function() cb) {
    ch
      ..onPresenceSync((_) => cb())
      ..onPresenceJoin((_) => cb())
      ..onPresenceLeave((_) => cb());
  }

  @override
  void subscribe(void Function(PartyStatus status, Object? err) cb) {
    ch.subscribe((s, err) {
      switch (s) {
        case RealtimeSubscribeStatus.subscribed:
          cb(PartyStatus.subscribed, null);
        case RealtimeSubscribeStatus.closed:
          cb(PartyStatus.closed, err);
        case RealtimeSubscribeStatus.channelError:
        case RealtimeSubscribeStatus.timedOut:
          cb(PartyStatus.error, err);
      }
    });
  }

  @override
  Future<void> track(Map<String, dynamic> payload) async => await ch.track(payload);
  @override
  Future<void> untrack() async => await ch.untrack();
  @override
  Future<void> send(String event, Map<String, dynamic> payload) async =>
      await ch.sendBroadcastMessage(event: event, payload: payload).timeout(const Duration(seconds: 6));
  @override
  List<(String, Map)> presences() => [
    for (final s in ch.presenceState())
      for (final p in s.presences) (s.key, p.payload),
  ];
}
