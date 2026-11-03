import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:supabase/supabase.dart';

import '../core/models.dart';
import 'party_net.dart';

export 'party_net.dart';

/// Apurba's own Supabase project, "Byte" (1.4.5: moved from the older shared
/// project): sign-in, sync, Listen together, admin and the web proxy all
/// live here. Both can be swapped at build time:
/// --dart-define=BYTE_SUPABASE_URL=... / --dart-define=BYTE_SUPABASE_KEY=...
class Backend {
  static const _url = 'https://ymnmrxgbjgvtavzyohdp.supabase.co';
  static const _key = 'sb_publishable_UX9Y8IqwgT-MXeaKpK0S_Q_BDBOXOqh'; // public by design
  static const _urlOverride = String.fromEnvironment('BYTE_SUPABASE_URL');
  static const _keyOverride = String.fromEnvironment('BYTE_SUPABASE_KEY');
  static const url = _urlOverride == '' ? _url : _urlOverride;
  static const anonKey = _keyOverride == '' ? _key : _keyOverride;
  static const publishableKey = anonKey;
}

/// What Listen together needs from the music player (so it can be tested
/// without a real audio engine).
abstract class SyncPlayer {
  Item? get item;
  Duration get position;
  bool get isPlaying;

  /// Fires whenever the song, play/pause or position jumps.
  Listenable get changes;
  Future<void> load(Item item, Duration at, {required bool play});
  Future<void> seekTo(Duration d);
  Future<void> setPlaying(bool play);
}

/// 1.4.5: what a player can add for tight party sync. Optional: a
/// [SyncPlayer] that also implements this gets rate nudges instead of seeks,
/// tells the party when its stream is stuck, and shares the scheduled start
/// of the next song and what comes after it.
abstract class PartyClockPlayer {
  /// Meant to be playing but no sound is coming (buffering: the host's
  /// screen went off and its net is throttled). Its position stands still.
  bool get stalled;

  /// Play a touch faster or slower (0.98–1.02) to close a small drift
  /// without a jump; 1.0 = normal. The person's own speed is kept.
  Future<void> setRate(double r);

  /// How many times the stream has got stuck so far (counts up).
  int get stallCount;

  /// The song this phone's queue plays next (null: none / unknown).
  Item? get upNext;

  /// The next song starts by itself in this many ms (the pause between
  /// songs); null when nothing is waiting.
  int? get startsInMs;
}

/// The host's view of "now": song, where it is, playing or not.
class RoomState {
  final Item? item;
  final int positionMs;
  final bool playing;
  final int atMs; // sender's clock (converted to the host's) when positionMs was read
  final int v; // version: bumps on every real change (song, play/pause, seek)
  final String by; // device that made the change
  final String byName;
  final int capacity;
  final bool hostOnly;
  final String? action; // what changed, for the activity list
  /// 1.4.5: the sender's stream is stuck (its position stands still).
  final bool stalled;

  /// 1.4.5: paused now, starts by itself at this host-clock time (the pause
  /// between songs): every phone starts the song at the same moment.
  final int? startAt;

  /// 1.4.5: the song after this one on the host's queue, so the party can
  /// carry on if the host goes quiet (screen off, net gone).
  final Item? next;
  const RoomState({
    this.item,
    this.positionMs = 0,
    this.playing = false,
    required this.atMs,
    this.v = 0,
    this.by = '',
    this.byName = '',
    this.capacity = 5,
    this.hostOnly = false,
    this.action,
    this.stalled = false,
    this.startAt,
    this.next,
  });
  Map<String, dynamic> toJson() => {
    'i': item?.toJson(),
    'p': positionMs,
    'pl': playing,
    'at': atMs,
    'v': v,
    'by': by,
    'bn': byName,
    'cap': capacity,
    'ho': hostOnly,
    'a': ?action,
    if (stalled) 'st': true,
    'sa': ?startAt,
    'nx': ?next?.toJson(),
  };
  factory RoomState.fromJson(Map m) => RoomState(
    item: m['i'] is Map ? Item.fromJson(m['i'] as Map) : null,
    positionMs: (m['p'] as num?)?.toInt() ?? 0,
    playing: m['pl'] == true,
    atMs: (m['at'] as num?)?.toInt() ?? 0,
    v: (m['v'] as num?)?.toInt() ?? 0,
    by: m['by'] as String? ?? '',
    byName: m['bn'] as String? ?? '',
    capacity: ((m['cap'] as num?)?.toInt() ?? 5).clamp(2, 10),
    hostOnly: m['ho'] == true,
    action: m['a'] as String?,
    stalled: m['st'] == true,
    startAt: (m['sa'] as num?)?.toInt(),
    next: m['nx'] is Map ? Item.fromJson(m['nx'] as Map) : null,
  );

  /// Newer than [o]? (ties broken by device id so everyone agrees)
  bool newerThan(RoomState? o) => o == null || v > o.v || (v == o.v && by.compareTo(o.by) > 0 && by != o.by);

  /// Where the song should be at [hostNowMs] on the host's clock.
  int expectedAt(int hostNowMs) {
    if (playing) return positionMs + max(0, hostNowMs - atMs);
    final sa = startAt;
    if (sa != null && hostNowMs >= sa) return positionMs + (hostNowMs - sa);
    return positionMs;
  }

  /// Is the song meant to be sounding at [hostNowMs] (a scheduled start counts)?
  bool playingAt(int hostNowMs) => playing || (startAt != null && hostNowMs >= startAt!);

  /// The same state with a few things changed (this phone's own view).
  RoomState copyWith({Item? item, int? positionMs, bool? playing, int? atMs, int? startAt, bool clearNext = false}) => RoomState(
    item: item ?? this.item,
    positionMs: positionMs ?? this.positionMs,
    playing: playing ?? this.playing,
    atMs: atMs ?? this.atMs,
    v: v,
    by: by,
    byName: byName,
    capacity: capacity,
    hostOnly: hostOnly,
    startAt: startAt,
    next: clearNext ? null : next,
  );
}

class Listener2 {
  final String id;
  final String name;
  final bool host;
  const Listener2(this.id, this.name, this.host);
}

class Activity {
  final DateTime at;
  final String who;
  final String what;
  const Activity(this.at, this.who, this.what);
  String get line {
    String two(int n) => n.toString().padLeft(2, '0');
    return '[${two(at.hour)}:${two(at.minute)}:${two(at.second)}] $who: $what';
  }
}

enum RoomRole { none, host, guest }

String _mmss(int ms) {
  final s = ms ~/ 1000;
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// Where a party this phone was in is kept, so it survives the app being
/// closed or killed (1.4.3: "Resume your party").
abstract class PartyStore {
  Map<String, dynamic>? load();
  void save(Map<String, dynamic> m);
  void clear();
}

class MemoryPartyStore implements PartyStore {
  Map<String, dynamic>? _m;
  @override
  Map<String, dynamic>? load() => _m == null ? null : Map.of(_m!);
  @override
  void save(Map<String, dynamic> m) => _m = Map.of(m);
  @override
  void clear() => _m = null;
}

/// The saved party as one JSON string (Settings keeps it).
class JsonStringPartyStore implements PartyStore {
  final String Function() read;
  final void Function(String) write;
  JsonStringPartyStore(this.read, this.write);
  @override
  Map<String, dynamic>? load() {
    final s = read();
    if (s.isEmpty) return null;
    try {
      final m = jsonDecode(s);
      return m is Map ? Map<String, dynamic>.from(m) : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void save(Map<String, dynamic> m) => write(jsonEncode(m));
  @override
  void clear() => write('');
}

/// A party this phone can go back into.
class SavedParty {
  final String code;
  final bool host;
  final String? secret;
  final String server;
  final int capacity;
  final bool hostOnly;
  final bool liveOnly;
  final String? hostName;
  const SavedParty({required this.code, required this.host, this.secret, this.server = '', this.capacity = 5, this.hostOnly = false, this.liveOnly = false, this.hostName});
  Map<String, dynamic> toJson() => {'code': code, 'role': host ? 'host' : 'guest', 'secret': secret, 'server': server, 'cap': capacity, 'ho': hostOnly, 'live': liveOnly, 'hn': hostName};
  static SavedParty? fromJson(Map? m) {
    final c = m?['code'];
    if (m == null || c is! String || ListenTogether.normaliseCode(c) != c) return null;
    final host = m['role'] == 'host';
    if (host && (m['secret'] is! String)) return null;
    return SavedParty(
      code: c,
      host: host,
      secret: m['secret'] as String?,
      server: m['server'] as String? ?? '',
      capacity: ((m['cap'] as num?)?.toInt() ?? 5).clamp(2, 10),
      hostOnly: m['ho'] == true,
      liveOnly: m['live'] == true,
      hostName: m['hn'] as String?,
    );
  }
}

/// "Listen together": one phone starts a party (6-character code); everyone
/// who joins hears the same song at the same moment. Anyone can control the
/// music unless the host turns on "Only I control the music". Runs on
/// Apurba's own Supabase project (Realtime broadcast + presence, and the
/// byte_listen_rooms table so late joiners start at the right place).
///
/// 1.4.3 end rules: a party ends ONLY when the host taps "End party". A
/// guest leaving takes only that guest out, even when the host is left alone.
/// The host's app in the background, on another screen, locked, offline or
/// even killed does not end it: guests see the host as away, and the host
/// can resume as host from the Listen-together screen.
class ListenTogether extends ChangeNotifier {
  final SyncPlayer player;
  final String deviceId;
  final String Function() displayName;
  final PartyNet net;
  final PartyStore store;

  /// Which server this phone uses now ('' = Byte's), kept with a saved party.
  final String Function() serverLabel;
  final int Function() _now;

  /// true: only the host's "End party" ends it for everyone; a guest's
  /// "Leave party" takes only him out. false: guests can also end it for all.
  static const onlyHostEndsForAll = true;

  /// What guests see when the host ends the party.
  static const endedMessage = 'Host ended the party';

  /// Re-sync when a device drifts more than this from the party.
  static const driftLimitMs = 700;
  static Duration heartbeat = const Duration(seconds: 4);
  static const maxActivity = 100;
  static Duration reconnectAfter = const Duration(seconds: 5);

  /// A song change or stop this close to the end of the party's song is the
  /// phone moving on by itself; only the host's phone picks what comes next.
  static const songEndWindowMs = 4000;

  // ── 1.4.5 tight sync ("1% bhi lag nahi") ──────────────────────────────
  /// Drift bigger than this is fixed with a jump (seek); smaller drift is
  /// closed by playing a touch faster or slower for a moment.
  static const seekLimitMs = 300;

  /// Drift this small is left alone (inaudible).
  static const nudgeDeadbandMs = 15;

  /// A small drift is closed over about this long (capped at [maxNudge]).
  static const nudgeOverMs = 1500;
  static const maxNudge = 0.02;

  /// The pause between songs (ByteAudioHandler.autoAdvanceGap): a guest
  /// whose host has gone quiet waits this long after the song's end before
  /// it starts the host's next song by itself.
  static const followGapMs = 2500;

  ListenTogether({
    required this.player,
    required this.deviceId,
    required this.displayName,
    SupabaseClient Function()? client,
    PartyNet? net,
    PartyStore? store,
    String Function()? serverLabel,
    int Function()? now,
  }) : net = net ?? SupabasePartyNet(client ?? (() => SupabaseClient(Backend.url, Backend.publishableKey))),
       store = store ?? MemoryPartyStore(),
       serverLabel = serverLabel ?? (() => ''),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// Use another server from now on (Settings → Use your own server).
  void resetClient() => net.reset();

  RoomRole role = RoomRole.none;
  String? code;
  String? hostName;
  String? hostId;
  String? error;
  bool connecting = false;
  bool connected = false;

  /// Guest: the host's phone has dropped out (net gone, app closed or
  /// killed). The party carries on and waits for it to come back.
  bool hostAway = false;

  /// Guest: the host ended the party (the lobby says so).
  bool endedByHost = false;
  RoomState? last; // newest party state
  int clockOffsetMs = 0; // host clock - my clock
  int? roundTripMs;
  int capacity = 5;
  bool hostOnly = false;
  List<Listener2> people = const [];
  final List<Activity> activity = [];

  PartyChannel? _ch;
  String? _secret;

  /// The server has no Byte tables yet (setup file not run): parties still
  /// work over the live channel alone; only the saved copy for late joiners
  /// is skipped, and the phones in the party answer them instead.
  bool liveOnly = false;

  /// How long a guest waits for the party to answer on a live-only party.
  static Duration hostAnswerWait = const Duration(seconds: 6);

  /// How long a resuming host waits for the guests to say where the music is.
  static Duration resumeWait = const Duration(milliseconds: 2500);

  static bool isSetupMissing(Object e) {
    final s = '$e';
    return s.contains('PGRST202') || s.contains('PGRST205') || s.contains('42P01') || s.contains('42883') || s.contains('Could not find the function') || s.contains('Could not find the table');
  }

  Timer? _beat;
  Timer? _dbSave;
  Timer? _afterEnd;
  bool _applying = false;
  bool _beating = false;
  bool _seenHost = false;
  int _quietUntil = 0; // ignore our own player's change events until then
  Set<String> _known = {};
  int _lostAt = 0; // when the connection dropped (0 = connected)
  bool _rejoining = false;
  bool _listening = false;

  bool get active => role != RoomRole.none;
  bool get isHost => role == RoomRole.host;
  bool get canControl => role == RoomRole.host || (role == RoomRole.guest && !hostOnly);

  /// May this phone end the party for everyone?
  bool get canEndForAll => isHost || (role == RoomRole.guest && !onlyHostEndsForAll);
  int get hostNow => _now() + clockOffsetMs;

  /// A party this phone was in and can go back into (app closed or killed).
  SavedParty? get saved => active ? null : SavedParty.fromJson(store.load());

  static String newCode([Random? r]) {
    const abc = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789'; // no letter O or I
    final rnd = r ?? Random.secure();
    return List.generate(6, (_) => abc[rnd.nextInt(abc.length)]).join();
  }

  static String? normaliseCode(String input) {
    var c = input.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    // Codes never use the letters O and I, so those are always 0 and 1.
    c = c.replaceAll('O', '0').replaceAll('I', '1');
    return RegExp(r'^[A-Z0-9]{6}$').hasMatch(c) ? c : null;
  }

  void _log(String who, String what) {
    activity.insert(0, Activity(DateTime.now(), who, what));
    if (activity.length > maxActivity) activity.removeRange(maxActivity, activity.length);
  }

  PartyClockPlayer? get _pc {
    final p = player;
    return p is PartyClockPlayer ? p as PartyClockPlayer : null;
  }

  RoomState _snapshot({bool bump = false, String? action}) {
    final v = (last?.v ?? 0) + (bump ? 1 : 0);
    final pc = _pc;
    final startsIn = pc?.startsInMs;
    final now = hostNow;
    return RoomState(
      stalled: pc?.stalled ?? false,
      startAt: !player.isPlaying && startsIn != null && player.item != null ? now + max(0, startsIn) : null,
      next: pc?.upNext,
      item: player.item,
      positionMs: player.position.inMilliseconds,
      playing: player.isPlaying,
      atMs: now,
      v: v,
      by: bump ? deviceId : (last?.by ?? deviceId),
      byName: bump ? displayName() : (last?.byName ?? displayName()),
      capacity: capacity,
      hostOnly: hostOnly,
      action: action,
    );
  }

  void _remember() {
    final c = code;
    if (c == null || !active) return;
    store.save(SavedParty(code: c, host: isHost, secret: isHost ? _secret : null, server: serverLabel(), capacity: capacity, hostOnly: hostOnly, liveOnly: liveOnly, hostName: hostName).toJson());
  }

  /// Before starting or joining another party: a host ends his, a guest leaves.
  Future<void> _leaveCurrent() async {
    if (isHost) {
      await endParty();
    } else if (active) {
      await leave();
    }
  }

  // ── start / join ──────────────────────────────────────────────────────
  Future<bool> host({int capacity = 5}) async {
    await _leaveCurrent();
    this.capacity = capacity.clamp(2, 10);
    hostOnly = false;
    connecting = true;
    error = null;
    endedByHost = false;
    notifyListeners();
    final rnd = Random.secure();
    _secret = List.generate(32, (_) => rnd.nextInt(16).toRadixString(16)).join();
    try {
      String? c;
      last = _snapshot(bump: true, action: 'Started the party');
      liveOnly = false;
      for (var i = 0; i < 5 && c == null; i++) {
        final tryCode = newCode(rnd);
        try {
          if (await net.openRoom(tryCode, _secret!, displayName(), last!.toJson())) c = tryCode;
        } catch (e) {
          if (!isSetupMissing(e)) rethrow;
          // No Byte tables on the server: run the party on the live channel.
          liveOnly = true;
          c = tryCode;
        }
      }
      if (c == null) throw Exception('no free room code');
      code = c;
      role = RoomRole.host;
      hostName = displayName();
      hostId = deviceId;
      _log(displayName(), 'Started the party');
      await _join(c);
      _remember();
      _startBeat();
      return true;
    } catch (e) {
      error = _explain(e);
      await _disconnect();
      return false;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<bool> join(String input) async {
    final c = normaliseCode(input);
    if (c == null) {
      error = 'Room codes are 6 letters or numbers';
      notifyListeners();
      return false;
    }
    await _leaveCurrent();
    connecting = true;
    error = null;
    endedByHost = false;
    notifyListeners();
    try {
      List<Map> rows;
      liveOnly = false;
      try {
        rows = await net.readRoom(c);
      } catch (e) {
        if (!isSetupMissing(e)) rethrow;
        liveOnly = true;
        rows = const [];
      }
      if (liveOnly) return await _joinLive(c);
      if (rows.isEmpty) {
        error = 'No party with code $c. Check the code, or ask the host to start it again.';
        return false;
      }
      final row = rows.first;
      code = c;
      hostName = row['host_name'] as String?;
      role = RoomRole.guest;
      final st = row['state'];
      RoomState? saved;
      if (st is Map) {
        saved = RoomState.fromJson(st);
        capacity = saved.capacity;
        hostOnly = saved.hostOnly;
      }
      await _join(c);
      // Party full? (presence includes us)
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (people.length > capacity) {
        final cap = capacity;
        await leave();
        error = 'This party is full ($cap people).';
        return false;
      }
      _log(displayName(), 'Joined');
      await _syncClock();
      if (saved != null && last == null) await _apply(saved, force: true);
      await _send('need_state', {'from': deviceId});
      _remember();
      _startBeat();
      return true;
    } catch (e) {
      error = _explain(e);
      await _disconnect();
      return false;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  /// Joining a party that lives only on the live channel: someone in it (the
  /// host, or a guest while the host is away) must answer within a few seconds.
  Future<bool> _joinLive(String c) async {
    code = c;
    role = RoomRole.guest;
    await _join(c);
    _log(displayName(), 'Joined');
    final until = _now() + hostAnswerWait.inMilliseconds;
    var asked = 0;
    bool answered() => last != null && people.any((p) => p.id != deviceId);
    while (_now() < until && !answered()) {
      if (asked++ % 5 == 0) {
        await _syncClock();
        await _send('need_state', {'from': deviceId});
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!answered()) {
      await _disconnect();
      error = 'No party with code $c right now. Check the code, and ask the host to open Byte.';
      return false;
    }
    if (people.length > capacity) {
      final cap = capacity;
      await leave();
      error = 'This party is full ($cap people).';
      return false;
    }
    _remember();
    _startBeat();
    return true;
  }

  /// Go back into the saved party (the app was closed or killed). A host comes
  /// back as the host; the guests carry on where the music is.
  Future<bool> resume() async {
    final s = saved;
    if (s == null) return false;
    if (s.server != serverLabel()) {
      error = 'This party was on ${s.server.isEmpty ? 'Byte\'s server' : s.server}. Switch back to it under "Use your own server" to resume.';
      notifyListeners();
      return false;
    }
    if (!s.host) {
      final ok = await join(s.code);
      if (!ok) {
        // The party is gone or can't be reached right now: keep it for a retry
        // unless it's really gone.
        if (error != null && !error!.startsWith('No party')) store.save(s.toJson());
      }
      return ok;
    }
    connecting = true;
    error = null;
    endedByHost = false;
    notifyListeners();
    try {
      code = s.code;
      _secret = s.secret;
      capacity = s.capacity;
      hostOnly = s.hostOnly;
      liveOnly = s.liveOnly;
      role = RoomRole.host;
      hostName = displayName();
      hostId = deviceId;
      last = null;
      RoomState? kept;
      if (!liveOnly) {
        try {
          final rows = await net.readRoom(s.code);
          if (rows.isNotEmpty && rows.first['state'] is Map) kept = RoomState.fromJson(rows.first['state'] as Map);
        } catch (e) {
          if (isSetupMissing(e)) liveOnly = true;
        }
      }
      await _join(s.code);
      _log(displayName(), 'Came back');
      // Where is the music now? Ask the guests; else the saved copy; else this phone.
      await _send('need_state', {'from': deviceId, 'resume': true});
      final until = _now() + resumeWait.inMilliseconds;
      while (_now() < until && last == null) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (last == null && kept != null) await _apply(kept, force: true);
      last ??= _snapshot(bump: true);
      _remember();
      _startBeat();
      await _send('state', _snapshot().toJson());
      // A fresh app isn't sharing its sound: guests who were using the
      // host's sound get their own back (party_sound.dart).
      await _send('sound', {'on': false, 'g': 0, 'from': deviceId});
      if (!liveOnly && _secret != null) {
        try {
          if (!await net.updateRoom(s.code, _secret!, last!.toJson())) await net.openRoom(s.code, _secret!, displayName(), last!.toJson());
        } catch (_) {}
      }
      return true;
    } catch (e) {
      error = _explain(e);
      await _disconnect(keepSaved: true);
      return false;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  /// Forget the saved party (the person doesn't want to go back).
  void forgetSaved() {
    store.clear();
    notifyListeners();
  }

  void _startBeat() {
    if (!_listening) {
      player.changes.addListener(_onLocalChange);
      _listening = true;
    }
    _beat?.cancel();
    _beat = Timer.periodic(heartbeat, (_) => _heartbeat());
  }

  // ── local changes → party ─────────────────────────────────────────────
  /// The party's song was about to end when this change came: the phone is
  /// just moving on (or stopping) by itself.
  bool _atSongEnd(RoomState? prev) {
    final d = prev?.item?.durationSec;
    if (prev == null || d == null || d <= 0 || !prev.playing) return false;
    return prev.expectedAt(hostNow) >= d * 1000 - songEndWindowMs;
  }

  void _onLocalChange() {
    if (!active || _applying) return;
    // Just after following the party the player echoes what was applied
    // (and may flicker while loading); only a different song is a real tap.
    if (_now() < _quietUntil && (player.item == null || player.item?.id == last?.item?.id)) return;
    if (!canControl) return; // listen along; local pause stays local
    final prev = last;
    final it = player.item;
    if (!isHost && !hostAway && _atSongEnd(prev) && (it?.id != prev?.item?.id || !player.isPlaying)) {
      // Each phone's own queue would pick a different next song: the host's
      // phone decides; this one asks for it.
      _songEnded(prev!);
      return;
    }
    if (!isHost && hostAway && _atSongEnd(prev) && _nextAfter(prev) != null) {
      // 1.4.5: the host is away but told us what comes next: every guest
      // plays that (at the same moment), not its own queue's pick.
      _songEnded(prev!);
      _followNext(prev);
      return;
    }
    String? action;
    if (it?.id != prev?.item?.id) {
      action = it == null ? 'Stopped' : 'Changed the song to "${it.title}"';
    } else if (player.isPlaying != prev?.playing) {
      // 1.4.5: the next song starting by itself after the short pause
      // between songs isn't a "Played" tap; it only moves everyone on.
      final autoStart =
          player.isPlaying &&
          prev?.by == deviceId &&
          prev?.playing == false &&
          (prev?.action?.startsWith('Changed the song') ?? false) &&
          player.position.inMilliseconds < 4000;
      // ...nor is the stop at the very end of a song before the next one.
      final d = it?.durationSec;
      final atEnd = !player.isPlaying && d != null && d > 0 && player.position.inMilliseconds >= d * 1000 - 1500;
      action = autoStart || atEnd ? null : (player.isPlaying ? 'Played' : 'Paused');
    } else {
      action = 'Seeked to ${_mmss(player.position.inMilliseconds)}';
    }
    final s = _snapshot(bump: true, action: action);
    last = s;
    _setAnchor(s);
    if (action != null) _log(displayName(), action);
    notifyListeners();
    _send('state', s.toJson());
    _saveSoon();
  }

  /// The app came back to the front: reconnect at once if the connection
  /// died while it was away, and catch up with the party.
  Future<void> appResumed() async {
    if (!active) return;
    if (!connected || !net.socketConnected) {
      connected = false;
      if (_lostAt == 0) _lostAt = _now();
      await _rejoin();
    } else if (!isHost) {
      await resync();
    } else {
      // 1.4.5: the host's screen comes back on: a fresh state right away
      // (its timers may have been held back while it was off).
      await _heartbeat();
      if (last != null) await _send('state', _snapshot().toJson());
    }
  }

  /// The guest's song reached its end: ask the host what's next; if the host
  /// stays quiet, play the next song it told us about, after the pause.
  void _songEnded(RoomState prev) {
    _endedId = prev.item?.id;
    _afterEnd?.cancel();
    _afterEnd = Timer(const Duration(milliseconds: 1500), () {
      if (!active) return;
      _send('need_state', {'from': deviceId});
      final wait = _songEndHostMs(prev) + followGapMs - hostNow;
      _afterEnd = Timer(Duration(milliseconds: max(0, wait) + 200), () {
        if (active && identical(last, prev)) _followNext(prev);
      });
    });
  }

  /// When [s]'s song ends on the host's clock.
  int _songEndHostMs(RoomState s) {
    final d = s.item?.durationSec ?? 0;
    return s.atMs + d * 1000 - s.positionMs;
  }

  /// Play the host's next song at the moment the host would have (the end
  /// of this one + the pause). Not sent to the party: the host decides; its
  /// next state (a newer version) wins.
  void _followNext(RoomState prev) {
    final nx = _nextAfter(prev);
    if (nx == null || !active) return;
    final s = prev.copyWith(item: nx, positionMs: 0, playing: false, atMs: hostNow, startAt: _songEndHostMs(prev) + followGapMs, clearNext: true);
    last = s;
    _log(hostName ?? 'Host', 'Next: "${nx.title}"');
    notifyListeners();
    _apply(s, force: true);
  }

  Future<void> _heartbeat() async {
    if (!active || _beating) return;
    _beating = true;
    try {
      await _beatOnce();
    } finally {
      _beating = false;
    }
  }

  Future<void> _beatOnce() async {
    if (connected && !net.socketConnected) {
      // The socket died without telling the channel (phone slept, net gone).
      connected = false;
      _lostAt = _now();
      _log(displayName(), 'Connection lost, reconnecting…');
      notifyListeners();
    }
    if (!connected) {
      // Lost the connection (net drop, server restart): join again until it works.
      if (_lostAt == 0) _lostAt = _now();
      if (_now() - _lostAt > reconnectAfter.inMilliseconds) await _rejoin();
      return;
    }
    // 1.4.5: one clock for the party: the host's (or, while the host is
    // away, the one guest standing in for it). Everyone else measures the
    // host's clock (ping) and follows its heartbeat.
    if (isHost || (hostAway && _standIn)) {
      if (player.item != null) await _sendBeat();
    } else if (!hostAway) {
      await _send('ping', {'from': deviceId, 't0': _now()});
    }
    if (isHost) _saveSoon();
  }

  /// The heartbeat: where this phone's song really is right now.
  Future<void> _sendBeat() async {
    final pc = _pc;
    if (pc != null && pc.stalled) {
      // Stream stuck (screen off, net throttled): say so, so guests keep
      // their own clock instead of jumping back to a frozen position.
      _hostSlipped = true;
      await _send('beat', _snapshot().toJson());
      return;
    }
    final a = _anchor;
    final it = player.item;
    if (isHost && a != null && it != null && a.item?.id == it.id && a.playingAt(hostNow) && player.isPlaying && !_applying) {
      // The host's own sound fell behind the time it told everyone (it was
      // stuck, or its timers were held back with the screen off): the host
      // catches up; the guests don't get pulled back.
      final want = a.expectedAt(hostNow);
      final d = it.durationSec;
      final behind = want - player.position.inMilliseconds;
      final slipped = _hostSlipped || (pc != null && pc.stallCount != _anchorStalls);
      if (slipped && behind > seekLimitMs && (d == null || d <= 0 || want < d * 1000 - 1000)) {
        _applying = true;
        try {
          await player.seekTo(Duration(milliseconds: want));
        } catch (_) {
        } finally {
          _applying = false;
          _quietUntil = _now() + 1500;
        }
      }
    }
    _hostSlipped = false;
    final s = _snapshot();
    _setAnchor(s);
    await _send('beat', s.toJson());
  }

  /// Host: the timeline it last told everyone.
  void _setAnchor(RoomState s) {
    _anchor = s;
    _anchorStalls = _pc?.stallCount ?? 0;
  }

  void _saveSoon() {
    if (!isHost) return;
    _dbSave ??= Timer(const Duration(seconds: 3), () async {
      _dbSave = null;
      final c = code;
      if (c == null || _secret == null || liveOnly) return;
      try {
        await net.updateRoom(c, _secret!, (last ?? _snapshot()).toJson());
      } catch (_) {}
    });
  }

  /// Host: how many people can be in the party (2–10).
  Future<void> setCapacity(int n) async {
    if (!isHost) return;
    capacity = n.clamp(2, 10);
    final s = _snapshot(bump: true);
    last = s;
    _log(displayName(), 'Set the party size to $capacity');
    _remember();
    notifyListeners();
    await _send('state', s.toJson());
    _saveSoon();
  }

  /// Host: only the host can change the music.
  Future<void> setHostOnly(bool v) async {
    if (!isHost) return;
    hostOnly = v;
    final s = _snapshot(bump: true);
    last = s;
    _log(displayName(), v ? 'Turned on "Only I control the music"' : 'Let everyone control the music');
    _remember();
    notifyListeners();
    await _send('state', s.toJson());
    _saveSoon();
  }

  /// Host: remove someone from the party.
  Future<void> remove(String id) async {
    if (!isHost || id == deviceId) return;
    final who = people.where((p) => p.id == id).firstOrNull?.name ?? 'Someone';
    _log(displayName(), 'Removed $who');
    notifyListeners();
    await _send('kick', {'id': id});
  }

  // ── party → this phone ────────────────────────────────────────────────
  RoomState? _anchor; // host: the timeline it last told everyone
  int _anchorStalls = 0;
  bool _hostSlipped = false;
  String? _endedId; // guest: the song that already ended here
  RoomState? _beatRef; // guest: the last heartbeat it trusted
  int _lastBeatAt = 0;
  final List<RoomState> _doubted = []; // heartbeats that went backwards
  Timer? _startTimer;
  Timer? _rateTimer;
  double _rate = 1.0;
  int _seekLagMs = 0; // how long this phone's seeks take (learned)

  /// The last measured gap to the party's clock (ms, + = this phone ahead);
  /// for the screen and the tests.
  int? lastDriftMs;
  (int, Item?)? _beatNext; // the host's next song as its last heartbeat said

  /// What the host plays after [prev]'s song (its newest word on it).
  Item? _nextAfter(RoomState? prev) {
    if (prev == null) return null;
    final b = _beatNext;
    return b != null && b.$1 == prev.v && b.$2 != null ? b.$2 : prev.next;
  }

  Future<void> _apply(RoomState s, {bool force = false, bool again = false}) async {
    if (!active) return;
    final prev = last;
    if (!again) {
      if (!force && !s.newerThan(prev)) return;
      last = s;
      capacity = s.capacity;
      hostOnly = s.hostOnly;
      if (s.action != null && s.by != deviceId) _log(s.byName.isEmpty ? 'Someone' : s.byName, s.action!);
      _afterEnd?.cancel();
      _beatRef = s;
      _lastBeatAt = s.atMs;
      _doubted.clear();
      if (isHost) _setAnchor(s);
      notifyListeners();
    }
    final it = s.item;
    if (it == null) return;
    if (_applying) {
      // 1.4.5: a change that lands while the last one is still being
      // applied (a song end: "paused" then "next song" a few ms apart) was
      // dropped, and a paused guest ignores heartbeats, so it stayed on the
      // old song. Apply the newest state once this one is done.
      _reapply = true;
      return;
    }
    _applying = true;
    try {
      final now = hostNow;
      final playNow = s.playingAt(now);
      var want = s.expectedAt(now);
      final d = it.durationSec;
      final endMs = d != null && d > 0 ? d * 1000 : null;
      // The song is over on the party's clock (or it already ended here and
      // only its last seconds are left): never load it again. Only the host
      // explicitly changing to it (from the start) brings it back.
      final over = endMs != null && playNow && (want >= endMs - 1000 || (_endedId == it.id && want >= endMs - songEndWindowMs));
      if (endMs != null) want = want.clamp(0, endMs);
      if (player.item?.id != it.id) {
        if (!over) {
          _setRate(1);
          final lead = playNow ? _seekLagMs : 0;
          await player.load(it, Duration(milliseconds: want + lead), play: playNow);
          if (_endedId == it.id) _endedId = null;
        }
      } else {
        if (player.isPlaying != playNow) await player.setPlaying(playNow);
        if (!over) {
          final drift = player.position.inMilliseconds - s.expectedAt(hostNow);
          if (drift.abs() > seekLimitMs) await _seek(s);
        }
      }
      _startTimer?.cancel();
      final sa = s.startAt;
      if (!s.playing && sa != null && hostNow < sa) {
        // The next song starts by itself at the host's moment: so does ours.
        _startTimer = Timer(Duration(milliseconds: sa - hostNow), () {
          if (active && identical(last, s)) _apply(s, again: true);
        });
      }
    } catch (_) {
    } finally {
      _applying = false;
      _quietUntil = _now() + 1500;
      if (_reapply) {
        _reapply = false;
        final l = last;
        if (l != null && active) unawaited(_apply(l, again: true));
      }
    }
  }

  bool _reapply = false;

  /// Jump to where [s] says the song is now (aiming a little ahead by how
  /// long this phone's seeks take).
  Future<void> _seek(RoomState s) async {
    _setRate(1);
    final t0 = _now();
    await player.seekTo(Duration(milliseconds: s.expectedAt(hostNow) + _seekLagMs));
    final took = _now() - t0;
    _seekLagMs = ((_seekLagMs * 3 + took.clamp(0, 400)) / 4).round();
  }

  void _setRate(double r) {
    _rateTimer?.cancel();
    _rateTimer = null;
    if (r == _rate) return;
    _rate = r;
    final pc = _pc;
    if (pc != null) unawaited(pc.setRate(r).catchError((_) {}));
  }

  /// A heartbeat: where the party's song really is. Fixes drift on the
  /// current song only; never loads a song, never pulls back to a stale or
  /// stuck position.
  void _onBeat(RoomState s) {
    if (!active || isHost) return;
    final l = last;
    if (l == null) return;
    if (s.v > l.v) {
      // missed a change: take it as one
      _apply(s);
      return;
    }
    if (s.v != l.v || s.item?.id != l.item?.id || s.atMs <= _lastBeatAt) return; // old or out of order
    if (s.stalled) {
      // The host's stream is stuck (its screen is off): keep our own clock.
      _lastBeatAt = s.atMs;
      _setRate(1);
      return;
    }
    final ref = _beatRef;
    if (ref != null && ref.item?.id == s.item?.id && ref.playingAt(s.atMs) && s.playing) {
      final predicted = ref.expectedAt(s.atMs);
      // A host that plays normally moves on as much as its clock does; one
      // that moved less than half of that (or jumped back) is stuck.
      final slack = min(seekLimitMs, max(120, (s.atMs - ref.atMs) ~/ 2));
      if (s.positionMs < predicted - slack) {
        // The host is behind where it said it would be (stuck, or an old
        // message): don't jump back to it. Only if it keeps a steady new
        // clock for a few beats is that taken as the party's clock.
        _doubted.add(s);
        if (_doubted.length < 3 || !_steady(_doubted)) {
          if (_doubted.length >= 3) _doubted.removeAt(0);
          return;
        }
      }
    }
    _doubted.clear();
    _lastBeatAt = s.atMs;
    _beatRef = s;
    _beatNext = (s.v, s.next); // the host's queue may have changed
    if (player.item?.id != s.item?.id || _applying) return; // moved on at the song end, or loading
    if (!player.isPlaying || !s.playingAt(hostNow)) return; // paused here on purpose
    final now = hostNow;
    final want = s.expectedAt(now);
    final d = s.item?.durationSec;
    if (d != null && d > 0 && want >= d * 1000 - 1000) {
      _setRate(1); // the song is finishing: leave it be
      return;
    }
    final drift = player.position.inMilliseconds - want;
    lastDriftMs = drift;
    if (drift.abs() > seekLimitMs) {
      _applying = true;
      _seek(s).catchError((_) {}).whenComplete(() {
        _applying = false;
        _quietUntil = _now() + 1500;
      });
    } else if (drift.abs() > nudgeDeadbandMs && _pc != null) {
      // Close it smoothly: a touch slower when ahead, faster when behind.
      final r = (1 - drift / nudgeOverMs).clamp(1 - maxNudge, 1 + maxNudge).toDouble();
      _setRate(r);
      final ms = (drift.abs() / (r - 1).abs()).round();
      _rateTimer = Timer(Duration(milliseconds: ms), () => _setRate(1));
    } else {
      _setRate(1);
    }
  }

  /// Do these heartbeats agree with each other (a clock running normally)?
  static bool _steady(List<RoomState> b) {
    for (var i = 1; i < b.length; i++) {
      final slack = min(seekLimitMs, max(120, (b[i].atMs - b[i - 1].atMs) ~/ 2));
      if ((b[i].positionMs - b[i - 1].expectedAt(b[i].atMs)).abs() > slack) return false;
    }
    return true;
  }

  /// NTP-style: several pings; the reply that came back fastest says the
  /// most about the host's clock (the least time for the net to skew it).
  Future<void> _syncClock() async {
    for (var i = 0; i < 5; i++) {
      await _send('ping', {'from': deviceId, 't0': _now()});
      await Future<void>.delayed(const Duration(milliseconds: 60));
    }
  }

  final List<(int, int, int)> _samples = []; // (round trip, offset, when)

  void _onPong(Map p) {
    if (p['to'] != deviceId) return;
    final t0 = (p['t0'] as num).toInt();
    final hostClock = (p['h'] as num).toInt();
    final t3 = _now();
    final rtt = t3 - t0;
    if (rtt < 0 || rtt > 3000) return;
    roundTripMs = rtt;
    _samples.add((rtt, hostClock - (t0 + t3) ~/ 2, t3));
    // keep the last 2 minutes / 16 samples
    _samples.removeWhere((x) => t3 - x.$3 > 120000);
    while (_samples.length > 16) {
      _samples.removeAt(0);
    }
    var best = _samples.first;
    for (final x in _samples) {
      if (x.$1 < best.$1) best = x;
    }
    clockOffsetMs = best.$2;
    notifyListeners();
  }

  /// Extra message types other features ride on this party's live channel
  /// (1.4.2: the host's sound). Register before joining.
  final Map<String, void Function(Map payload)> extraEvents = {};

  /// Host: called when a guest asks for the party's state (a late joiner,
  /// a reconnect), so extra features can answer too.
  final List<void Function(Map payload)> onNeedState = [];

  /// Send an extra message type on the party's live channel.
  Future<void> sendExtra(String event, Map<String, dynamic> payload) => _send(event, payload);

  Future<void> _send(String event, Map<String, dynamic> payload) async {
    final ch = _ch;
    if (ch == null) return;
    try {
      await ch.send(event, payload);
    } catch (_) {}
  }

  /// While the host is away, one guest (the same one on every phone) answers
  /// for the party.
  bool get _standIn {
    if (isHost || last == null) return false;
    final others = people.where((p) => !p.host).map((p) => p.id).toList()..sort();
    return others.isNotEmpty && others.first == deviceId;
  }

  void _onNeedState(Map p) {
    final from = p['from'];
    if (from == deviceId) return;
    if (isHost) {
      if (last != null) _send('state', _snapshot().toJson());
      for (final f in [...onNeedState]) {
        f(p);
      }
      return;
    }
    // A host coming back, or a late joiner while the host is away: the guests
    // know where the music is.
    final hostHere = people.any((x) => x.host && x.id != from);
    if ((p['resume'] == true || !hostHere) && _standIn) {
      _send('state', _snapshot().toJson());
    }
  }

  Future<void> _join(String c) async {
    final done = Completer<void>();
    final ch = net.channel(c, deviceId);
    ch
      ..onBroadcast('state', (p) => _apply(RoomState.fromJson(p)))
      ..onBroadcast('beat', (p) => _onBeat(RoomState.fromJson(p)))
      ..onBroadcast('need_state', _onNeedState)
      ..onBroadcast('ping', (p) {
        if (isHost) _send('pong', {'to': p['from'], 't0': p['t0'], 'h': _now()});
      })
      ..onBroadcast('pong', _onPong)
      ..onBroadcast('kick', (p) {
        if (p['id'] == deviceId && role == RoomRole.guest) {
          leave().then((_) {
            error = 'The host removed you from the party';
            notifyListeners();
          });
        }
      })
      ..onBroadcast('closed', (p) {
        if (role != RoomRole.guest) return;
        // Only the host ends a party (unless the switch says anyone may).
        final byHost = p['host'] == true || (hostId != null && p['by'] == hostId);
        if (onlyHostEndsForAll && !byHost && p.containsKey('by')) return;
        leave().then((_) {
          endedByHost = true;
          error = endedMessage;
          notifyListeners();
        });
      })
      ..onPresence(_readPresence);
    for (final e in extraEvents.keys) {
      ch.onBroadcast(e, (p) => extraEvents[e]?.call(p));
    }
    _ch = ch;
    ch.subscribe((status, err) async {
      if (!identical(_ch, ch)) return; // an old channel
      if (status == PartyStatus.subscribed) {
        final wasLost = done.isCompleted && !connected;
        connected = true;
        _lostAt = 0;
        try {
          await ch.track({'id': deviceId, 'name': displayName(), 'host': role == RoomRole.host});
        } catch (_) {}
        if (!done.isCompleted) done.complete();
        if (wasLost) _onReconnected();
      } else {
        // A drop (net gone, server restart, presence timeout): never the end
        // of the party. The heartbeat joins again.
        if (connected && active) _log(displayName(), 'Connection lost, reconnecting…');
        connected = false;
        if (_lostAt == 0) _lostAt = _now();
        if (!done.isCompleted) done.completeError(err ?? Exception('could not connect'));
      }
      notifyListeners();
    });
    await done.future.timeout(const Duration(seconds: 12));
  }

  Future<void> _rejoin() async {
    final c = code;
    if (_rejoining || c == null || !active) return;
    _rejoining = true;
    final old = _ch;
    try {
      if (old != null) {
        _ch = null;
        try {
          await net.removeChannel(old);
        } catch (_) {}
      }
      await _join(c);
      _onReconnected();
    } catch (_) {
      connected = false;
      _lostAt = _now(); // try again after [reconnectAfter]
    } finally {
      _rejoining = false;
      notifyListeners();
    }
  }

  void _onReconnected() {
    if (!active) return;
    _log(displayName(), 'Reconnected');
    if (isHost) {
      // Everyone gets the newest state; the saved copy is refreshed too.
      final s = _snapshot();
      _send('state', s.toJson());
      _saveSoon();
    } else {
      resync();
    }
    notifyListeners();
  }

  void _readPresence() {
    final ch = _ch;
    if (ch == null) return;
    final out = <Listener2>[];
    final seen = <String>{};
    for (final (key, payload) in ch.presences()) {
      final id = '${payload['id'] ?? key}';
      if (!seen.add(id)) continue;
      out.add(Listener2(id, '${payload['name'] ?? ''}', payload['host'] == true));
    }
    out.sort((a, b) => a.host == b.host ? a.name.compareTo(b.name) : (a.host ? -1 : 1));
    final ids = out.map((e) => e.id).toSet();
    if (_known.isNotEmpty) {
      for (final p in out.where((p) => !_known.contains(p.id) && p.id != deviceId)) {
        _log(p.name.isEmpty ? 'Someone' : p.name, 'Joined');
      }
      for (final id in _known.difference(ids)) {
        final who = people.where((p) => p.id == id).firstOrNull?.name ?? 'Someone';
        if (id != deviceId) _log(who, 'Left');
      }
    }
    _known = ids;
    people = out;
    final h = out.where((p) => p.host).firstOrNull;
    if (h != null) {
      hostId = h.id;
      hostName = h.name;
      if (role == RoomRole.guest) _remember();
    }
    if (role == RoomRole.guest && out.any((p) => p.id == deviceId)) {
      final away = h == null;
      if (!away) _seenHost = true;
      if (away != hostAway) {
        hostAway = away;
        if (away) {
          if (_seenHost) _log(hostName ?? 'Host', 'Away. The party carries on…');
        } else {
          _log(hostName ?? 'Host', 'Is back');
          resync();
        }
      }
    }
    notifyListeners();
  }

  /// Jump back to exactly where the party is.
  Future<void> resync() async {
    if (!active) return;
    await _syncClock();
    await _send('need_state', {'from': deviceId});
  }

  /// "Leave party": only this phone leaves; the party carries on for
  /// everyone else (even when only the host is left). A host can't leave his
  /// own party without ending it, so for him this is [endParty].
  Future<void> leave() async {
    if (isHost) return endParty();
    await _disconnect();
  }

  /// Host: "End party" — it ends for everyone; guests see [endedMessage].
  Future<void> endParty() async {
    if (!canEndForAll) return leave();
    final c = code;
    final secret = _secret;
    final wasLive = liveOnly;
    await _send('closed', {'by': deviceId, 'host': isHost, 'name': displayName()});
    if (isHost && c != null && secret != null && !wasLive) {
      try {
        await net.closeRoom(c, secret);
      } catch (_) {}
    }
    _log(displayName(), 'Ended the party');
    await _disconnect();
  }

  /// Off the channel. Nothing is said to the others: to them this phone has
  /// just gone (a host is then "away"). [keepSaved]: it can come back.
  Future<void> _disconnect({bool keepSaved = false}) async {
    _beat?.cancel();
    _beat = null;
    _dbSave?.cancel();
    _dbSave = null;
    _afterEnd?.cancel();
    _startTimer?.cancel();
    _setRate(1);
    _anchor = null;
    _beatRef = null;
    _endedId = null;
    _beatNext = null;
    _doubted.clear();
    if (_listening) {
      player.changes.removeListener(_onLocalChange);
      _listening = false;
    }
    final ch = _ch;
    _ch = null;
    if (ch != null) {
      try {
        await ch.untrack();
      } catch (_) {}
      try {
        await net.removeChannel(ch);
      } catch (_) {}
    }
    if (!keepSaved) store.clear();
    role = RoomRole.none;
    code = null;
    connected = false;
    hostAway = false;
    _seenHost = false;
    _lostAt = 0;
    people = const [];
    _known = {};
    last = null;
    _secret = null;
    roundTripMs = null;
    hostId = null;
    liveOnly = false;
    notifyListeners();
  }

  String _explain(Object e) {
    final s = '$e';
    if (s.contains('PGRST202') || s.contains('byte_lt_open') || s.contains('byte_listen_rooms') || s.contains('42P01') || s.contains('PGRST205')) {
      return 'Server setup pending: run Byte\'s server setup file once on your server';
    }
    if (s.contains('SocketException') || s.contains('Failed host lookup') || s.contains('ClientException')) {
      return 'No internet connection';
    }
    if (s.contains('TimeoutException')) return 'The server didn\'t answer. Check your internet and try again.';
    return 'Couldn\'t connect to Listen together. Try again.';
  }

  /// The app is shutting this object down: the party is NOT ended. This
  /// phone just drops off the channel and can resume later.
  @override
  void dispose() {
    _disposed = true;
    _disconnect(keepSaved: true);
    super.dispose();
  }

  bool _disposed = false;
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }
}
