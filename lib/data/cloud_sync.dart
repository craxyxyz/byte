import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:supabase/supabase.dart';

import '../core/models.dart';

/// One synced entry: (collection, id) → JSON, newest edit wins.
class SyncRow {
  final String collection;
  final String id;
  final Object? payload;
  final int updatedAt;
  final bool deleted;
  final String? device;
  final int seq;
  const SyncRow({required this.collection, required this.id, this.payload, required this.updatedAt, this.deleted = false, this.device, this.seq = 0});

  Map<String, Object?> toJson() => {'collection': collection, 'id': id, 'payload': deleted ? null : payload, 'updated_at': updatedAt, 'deleted': deleted, 'device': device};
  factory SyncRow.fromJson(Map m) => SyncRow(
    collection: m['collection'] as String,
    id: m['id'] as String,
    payload: m['payload'],
    updatedAt: (m['updated_at'] as num).toInt(),
    deleted: m['deleted'] == true,
    device: m['device'] as String?,
    seq: (m['seq'] as num?)?.toInt() ?? 0,
  );
}

/// The server side has not been set up yet (Byte-v1.3-sync.sql not run).
class SyncNotReady implements Exception {
  final String detail;
  const SyncNotReady(this.detail);
  @override
  String toString() => 'SyncNotReady($detail)';
}

/// Where synced rows live. Every query is scoped to the signed-in account
/// by row level security on the server (auth.uid() = user_id).
abstract class SyncBackend {
  Future<void> push(List<SyncRow> rows);
  Future<List<SyncRow>> pull(int afterSeq, {int limit = 500});

  /// A ping whenever another device saved something.
  Stream<void> changes();
  Future<void> close() async {}
}

class SupabaseSyncBackend implements SyncBackend {
  final SupabaseClient client;
  SupabaseSyncBackend(this.client);
  RealtimeChannel? _ch;
  StreamController<void>? _changes;

  static bool _missing(PostgrestException e) {
    final m = '${e.message} ${e.details ?? ''} ${e.hint ?? ''}'.toLowerCase();
    return const {'PGRST205', 'PGRST202', '42P01', '42883'}.contains(e.code) || (m.contains('byte_') && (m.contains('could not find') || m.contains('does not exist')));
  }

  @override
  Future<void> push(List<SyncRow> rows) async {
    if (rows.isEmpty) return;
    try {
      await client.rpc('byte_push', params: {'rows': rows.map((r) => r.toJson()).toList()});
    } on PostgrestException catch (e) {
      if (_missing(e)) throw SyncNotReady(e.message);
      rethrow;
    }
  }

  @override
  Future<List<SyncRow>> pull(int afterSeq, {int limit = 500}) async {
    try {
      final r = await client.from('byte_records').select('collection,id,payload,updated_at,deleted,device,seq').gt('seq', afterSeq).order('seq', ascending: true).limit(limit);
      return [for (final m in r) SyncRow.fromJson(m)];
    } on PostgrestException catch (e) {
      if (_missing(e)) throw SyncNotReady(e.message);
      rethrow;
    }
  }

  @override
  Stream<void> changes() {
    final uid = client.auth.currentUser?.id;
    _changes ??= StreamController<void>.broadcast();
    if (uid != null && _ch == null) {
      _ch = client
          .channel('byte-sync-$uid')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'byte_records',
            filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'user_id', value: uid),
            callback: (_) => _changes?.add(null),
          )
          .subscribe();
    }
    return _changes!.stream;
  }

  @override
  Future<void> close() async {
    final ch = _ch;
    _ch = null;
    if (ch != null) await client.removeChannel(ch);
  }
}

/// The Byte account: the person's Gmail address on Apurba's own server.
/// Three ways in, all to the same account: a code (or link) mailed to the
/// Gmail, a Byte password, or Google sign-in once it is set up.
class CloudAccount extends ChangeNotifier {
  final SupabaseClient client;
  final FlutterSecureStorage _secure;
  StreamSubscription<AuthState>? _sub;
  /// The server connection for sign-in: email links and codes are checked by
  /// the app itself (no browser hand-off), so the plain (implicit) flow.
  static SupabaseClient makeClient(String url, String key) => SupabaseClient(url, key, authOptions: const AuthClientOptions(authFlowType: AuthFlowType.implicit, autoRefreshToken: false));

  CloudAccount(this.client, {FlutterSecureStorage? secure}) : _secure = secure ?? const FlutterSecureStorage();

  User? get user => client.auth.currentUser;
  String? get email => user?.email;
  String? get uid => user?.id;
  bool get signedIn => user != null;

  Future<void> restore() async {
    // keeps the sign-in fresh while the app runs (started here, not when
    // the connection is made, so screens that only read the state start no timers)
    try {
      client.auth.startAutoRefresh();
    } catch (_) {}
    _sub ??= client.auth.onAuthStateChange.listen((s) async {
      final session = s.session;
      try {
        if (session != null) {
          await _secure.write(key: 'byte_sync_session', value: jsonEncode(session.toJson()));
        } else if (s.event == AuthChangeEvent.signedOut) {
          await _secure.delete(key: 'byte_sync_session');
        }
      } catch (_) {}
      notifyListeners();
    });
    try {
      final raw = await _secure.read(key: 'byte_sync_session');
      if (raw != null && raw.isNotEmpty) await client.auth.recoverSession(raw);
    } catch (_) {
      // expired and couldn't refresh (offline): kept, tried again next start
    }
    notifyListeners();
  }

  static String clean(String email) => email.trim().toLowerCase();

  /// Mails a sign-in code (and link) to [email]. Makes the account the first time.
  Future<void> sendCode(String email) => client.auth.signInWithOtp(email: clean(email), shouldCreateUser: true);

  Future<void> verifyCode(String email, String code) async {
    final c = code.replaceAll(RegExp(r'\s'), '');
    try {
      await client.auth.verifyOTP(email: clean(email), token: c, type: OtpType.email);
    } on AuthException {
      // a brand-new account's first code
      await client.auth.verifyOTP(email: clean(email), token: c, type: OtpType.signup);
    }
    notifyListeners();
  }

  /// The link from the email, copied and pasted (or opened with Byte).
  Future<void> verifyLink(String link) async {
    final u = Uri.tryParse(link.trim());
    if (u == null) throw const FormatException('not a sign-in link');
    final q = {...u.queryParameters, ...Uri.splitQueryString(u.fragment)};
    if (q['access_token'] != null && q['refresh_token'] != null) {
      await client.auth.setSession(q['refresh_token']!);
    } else {
      final token = q['token_hash'] ?? q['token'];
      if (token == null) throw const FormatException('not a sign-in link');
      final type = switch (q['type']) {
        'signup' => OtpType.signup,
        'invite' => OtpType.invite,
        'email' => OtpType.email,
        _ => OtpType.magiclink,
      };
      await client.auth.verifyOTP(tokenHash: token, type: type);
    }
    notifyListeners();
  }

  /// Gmail + Byte password. [create] makes the account (no email confirmation
  /// on this server, so it signs straight in).
  Future<void> withPassword(String email, String password, {bool create = false, String? name}) async {
    if (create) {
      final n = name?.trim() ?? '';
      final r = await client.auth.signUp(email: clean(email), password: password, data: n.isEmpty ? null : {'name': n});
      if (r.session == null) await client.auth.signInWithPassword(email: clean(email), password: password);
    } else {
      await client.auth.signInWithPassword(email: clean(email), password: password);
    }
    notifyListeners();
  }

  Future<void> signOut() async {
    try {
      await client.auth.signOut();
    } catch (_) {}
    await _secure.delete(key: 'byte_sync_session');
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

enum SyncState { signedOut, syncing, synced, offline, notReady, error }

/// What is playing on another device (to carry on here).
class RemoteNow {
  final List<Item> items;
  final int index;
  final Duration position;
  final String deviceName;
  final DateTime at;
  const RemoteNow(this.items, this.index, this.position, this.deviceName, this.at);
  Item? get item => index >= 0 && index < items.length ? items[index] : null;
}

/// Hive values ⇄ JSON (dates kept).
Object? encodeHive(Object? v) {
  if (v is DateTime) return {r'$dt': v.millisecondsSinceEpoch};
  if (v is Map) return {for (final e in v.entries) '${e.key}': encodeHive(e.value)};
  if (v is List) return [for (final x in v) encodeHive(x)];
  return v;
}

Object? decodeHive(Object? v) {
  if (v is Map) {
    if (v.length == 1 && v[r'$dt'] is int) return DateTime.fromMillisecondsSinceEpoch(v[r'$dt'] as int);
    return {for (final e in v.entries) e.key: decodeHive(e.value)};
  }
  if (v is List) return [for (final x in v) decodeHive(x)];
  return v;
}

/// Keeps everything the person makes in Byte the same on every device signed
/// in to the same Gmail: likes, playlists (and their order and pins), saved
/// podcasts, history, searches, every setting, listening stats, the DJ's
/// play log, the downloads list and what is playing. Changes made offline wait
/// in a queue on the phone and go up when the connection is back.
class CloudSync extends ChangeNotifier {
  /// Hive box → synced collection.
  static const boxes = {
    'likes': 'likes',
    'playlists': 'playlists',
    'history': 'history',
    'library_misc': 'library',
    'settings': 'settings',
    'downloads': 'downloads',
    'stats': 'stats',
    'play_log': 'playlog',
  };

  /// Settings that belong to this phone (its hardware, its id), not to the person.
  static const deviceSettings = {'deviceId', 'firstSeen', 'qBest13', 'usbDac', 'bitPerfect', 'highPerf', 'automixPerf', 'djTabSeen'};

  /// Lists merged (not replaced) the first time a device joins.
  static const unionKeys = {'searches', 'pinned_playlists', 'playlist_order', 'recentItems', 'later', 'podcasts', 'dl_playlists'};

  /// Collections that change all the time: sent at most every [lazyEvery].
  static const lazy = {'stats', 'playlog', 'now'};

  final SyncBackend Function() backendFor;
  final String deviceId;
  final String Function() deviceName;
  final VoidCallback? onApplied;
  final Duration debounce;
  final Duration lazyEvery;
  final int Function() clock;

  /// Box names start with this (tests run two "devices" in one process).
  final String boxPrefix;

  CloudSync({
    required this.backendFor,
    required this.deviceId,
    String Function()? deviceName,
    this.onApplied,
    this.debounce = const Duration(seconds: 2),
    this.lazyEvery = const Duration(minutes: 2),
    int Function()? clock,
    this.boxPrefix = '',
  }) : deviceName = deviceName ?? (() => 'another device'),
       clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  Box? _meta;
  final Map<String, Box> _boxes = {};
  final List<StreamSubscription> _subs = [];
  SyncBackend? _backend;
  StreamSubscription<void>? _remoteSub;
  Timer? _timer, _poll;
  bool _busy = false, _again = false;
  String? _uid;
  AppLifecycleListener? _life;

  SyncState state = SyncState.signedOut;
  String? message;
  DateTime? lastSynced;

  /// Something playing on another device, newer than anything played here.
  final ValueNotifier<RemoteNow?> remoteNow = ValueNotifier(null);

  /// Songs downloaded on the person's other devices and not on this one.
  final Map<String, Item> otherDownloads = {};

  // Remote writes we made ourselves (so the box events they cause are not
  // sent back up as local edits).
  final Map<String, int> _echo = {};

  bool get active => _uid != null;
  int get pending => _pending.length;
  Set<String> get _pending => {...((_meta?.get('pending') as List?) ?? const []).cast<String>()};
  Future<void> _setPending(Set<String> s) async => _meta?.put('pending', s.toList());

  int _ts(String coll, String id) => (_meta?.get('t|$coll|$id') as int?) ?? 0;
  Future<void> _setTs(String coll, String id, int t) async => _meta?.put('t|$coll|$id', t);

  Future<void> open() async {
    Future<Box> box(String n) async => Hive.isBoxOpen('$boxPrefix$n') ? Hive.box('$boxPrefix$n') : await Hive.openBox('$boxPrefix$n');
    _meta ??= await box('sync_meta');
    for (final name in boxes.keys) {
      _boxes[name] ??= await box(name);
    }
    _boxes['cloud_downloads'] ??= await box('cloud_downloads');
    _loadOtherDownloads();
    if (_subs.isEmpty) {
      for (final e in boxes.entries) {
        _subs.add(_boxes[e.key]!.watch().listen((ev) => _local(e.key, '${ev.key}', ev.deleted)));
      }
    }
  }

  /// Signed in (or the app started signed in): start syncing for [uid].
  Future<void> start(String uid) async {
    await open();
    if (_uid == uid && _backend != null) return;
    await _stopBackend();
    _uid = uid;
    if (_meta!.get('uid') != uid) {
      // First time this device meets this account: everything here goes up
      // as "old" (anything already in the account wins), lists are merged.
      await _meta!.put('uid', uid);
      await _meta!.put('seq', 0);
      await _meta!.put('merge', true);
      final p = <String>{};
      for (final e in boxes.entries) {
        for (final k in _boxes[e.key]!.keys) {
          final key = '$k';
          if (!_tracked(e.key, key)) continue;
          final (coll, id) = _outKey(e.key, key);
          await _setTs(coll, id, 0); // sent as the oldest possible edit

          p.add('$coll|$id');
        }
      }
      await _setPending(p);
    }
    _backend = backendFor();
    _remoteSub = _backend!.changes().listen((_) => _schedule(const Duration(milliseconds: 400)));
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => syncNow());
    _life ??= _lifecycle();
    await syncNow();
  }

  AppLifecycleListener? _lifecycle() {
    try {
      return AppLifecycleListener(onResume: () => syncNow(), onPause: () => syncNow(flush: true));
    } catch (_) {
      return null;
    }
  }

  /// Signed out: stop, and forget which account this device belonged to
  /// (the data stays on the phone).
  Future<void> stop() async {
    await _stopBackend();
    _uid = null;
    await _meta?.delete('uid');
    await _meta?.delete('pending');
    state = SyncState.signedOut;
    message = null;
    remoteNow.value = null;
    notifyListeners();
  }

  Future<void> _stopBackend() async {
    _timer?.cancel();
    _poll?.cancel();
    await _remoteSub?.cancel();
    _remoteSub = null;
    await _backend?.close();
    _backend = null;
  }

  bool _tracked(String box, String key) {
    if (box == 'settings') return !deviceSettings.contains(key);
    if (box == 'stats') return RegExp(r'^y\d{4}$').hasMatch(key);
    if (box == 'play_log') return key == 'events';
    return true;
  }

  /// Local (box, key) → synced (collection, id).
  (String, String) _outKey(String box, String key) {
    final coll = boxes[box]!;
    if (box == 'stats') return (coll, '$deviceId:$key');
    if (box == 'play_log') return (coll, deviceId);
    return (coll, key);
  }

  void _local(String box, String key, bool deleted) {
    final e = '$box|$key';
    final n = _echo[e];
    if (n != null) {
      if (n <= 1) {
        _echo.remove(e);
      } else {
        _echo[e] = n - 1;
      }
      return;
    }
    if (!_tracked(box, key)) return;
    final (coll, id) = _outKey(box, key);
    unawaited(_markDirty(coll, id));
  }

  Future<void> _markDirty(String coll, String id) async {
    await _setTs(coll, id, clock());
    final p = _pending..add('$coll|$id');
    await _setPending(p);
    if (!active) return;
    _schedule(lazy.contains(coll) && p.every((k) => lazy.contains(k.split('|').first)) ? lazyEvery : debounce);
  }

  void _schedule(Duration d) {
    if (!active) return;
    if (_timer?.isActive ?? false) {
      // a sooner sync wins over a later one
      if (d >= debounce) return;
      _timer!.cancel();
    }
    _timer = Timer(d, () => syncNow());
  }

  /// What is playing here (sent with the lazy batch, or now when paused).
  Future<void> notePlaying(List<Item> items, int index, Duration position, {required bool playing}) async {
    if (items.isEmpty || index < 0) return;
    final from = (index - 20).clamp(0, items.length);
    final list = items.sublist(from, (from + 100).clamp(0, items.length)).where((i) => !i.isLocal).toList();
    final cur = items[index];
    if (cur.isLocal) return;
    final now = clock();
    await _meta?.put('now', {
      'items': [for (final i in list) i.toJson()],
      'index': list.indexWhere((i) => i.id == cur.id),
      'pos': position.inMilliseconds,
      'playing': playing,
      'device': deviceId,
      'name': deviceName(),
      'at': now,
    });
    await _meta?.put('lastLocalPlay', now);
    await _setTs('now', 'playing', now);
    final p = _pending..add('now|playing');
    await _setPending(p);
    if (active) _schedule(playing ? lazyEvery : debounce);
  }

  /// Pull everything new, then send what changed here.
  Future<void> syncNow({bool flush = false}) async {
    final b = _backend;
    if (b == null || _uid == null) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    _timer?.cancel();
    state = SyncState.syncing;
    notifyListeners();
    try {
      do {
        _again = false;
        await _pullAll(b);
        await _pushAll(b);
      } while (_again);
      await _meta?.delete('merge');
      state = SyncState.synced;
      message = null;
      lastSynced = DateTime.now();
      await _meta?.put('lastSynced', lastSynced!.millisecondsSinceEpoch);
    } on SyncNotReady catch (e) {
      state = SyncState.notReady;
      message = 'Sync is not switched on on the server yet. Your data stays on this phone until it is.';
      debugPrint('sync not ready: ${e.detail}');
    } on AuthException catch (e) {
      state = SyncState.error;
      message = 'Sign in again to keep syncing (${e.message}).';
    } catch (e) {
      state = SyncState.offline;
      message = 'Offline. ${_pending.length} change${_pending.length == 1 ? '' : 's'} will sync when you are back online.';
      _schedule(const Duration(seconds: 30));
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> _pullAll(SyncBackend b) async {
    var seq = (_meta!.get('seq') as int?) ?? 0;
    var applied = false;
    while (true) {
      final rows = await b.pull(seq);
      if (rows.isEmpty) break;
      for (final r in rows) {
        if (await _apply(r)) applied = true;
        if (r.seq > seq) seq = r.seq;
      }
      await _meta!.put('seq', seq);
      if (rows.length < 500) break;
    }
    if (applied) onApplied?.call();
  }

  Future<bool> _apply(SyncRow r) async {
    final local = _ts(r.collection, r.id);
    if (r.collection == 'now') return _applyNow(r);
    if (r.collection == 'downloads') return _applyDownload(r);
    if (r.updatedAt <= local) return false; // ours is newer (or the same)
    final merging = _meta!.get('merge') == true;
    String? box;
    String key = r.id;
    switch (r.collection) {
      case 'stats':
        final i = r.id.indexOf(':');
        if (i < 0) return false;
        final dev = r.id.substring(0, i);
        box = 'stats';
        key = dev == deviceId ? r.id.substring(i + 1) : 'r:${r.id}';
      case 'playlog':
        box = 'play_log';
        if (r.id == deviceId) return false;
        key = 'r:${r.id}';
      default:
        box = boxes.entries.where((e) => e.value == r.collection).firstOrNull?.key;
    }
    if (box == null) return false; // something a newer Byte syncs
    if (box == 'settings' && deviceSettings.contains(key)) return false;
    final b = _boxes[box]!;
    final pend = _pending;
    final mine = '${r.collection}|${r.id}';
    if (r.deleted) {
      if (!b.containsKey(key)) {
        await _setTs(r.collection, r.id, r.updatedAt);
        return false;
      }
      _expectEcho(box, key);
      await b.delete(key);
    } else {
      var v = decodeHive((r.payload as Map?)?['v']);
      if (merging && box == 'library_misc' && unionKeys.contains(key) && b.get(key) is List && v is List) {
        final cur = b.get(key) as List;
        final merged = [...v, ...cur.where((x) => !v.contains(x))];
        if (merged.length != v.length) {
          // the union goes back up as a new edit
          _expectEcho(box, key);
          await b.put(key, merged);
          await _setTs(r.collection, r.id, clock());
          await _setPending(pend..add(mine));
          return true;
        }
      }
      _expectEcho(box, key);
      await b.put(key, v);
    }
    await _setTs(r.collection, r.id, r.updatedAt);
    if (pend.remove(mine)) await _setPending(pend);
    return true;
  }

  void _expectEcho(String box, String key) => _echo['$box|$key'] = (_echo['$box|$key'] ?? 0) + 1;

  Future<bool> _applyNow(SyncRow r) async {
    final m = r.payload is Map ? (r.payload as Map)['v'] : null;
    if (m is! Map || r.deleted || m['device'] == deviceId) return false;
    final at = (m['at'] as num?)?.toInt() ?? r.updatedAt;
    final lastHere = (_meta?.get('lastLocalPlay') as int?) ?? 0;
    if (at <= lastHere) return false;
    try {
      final items = [for (final x in (m['items'] as List)) Item.fromJson(x as Map)];
      remoteNow.value = RemoteNow(items, (m['index'] as num).toInt(), Duration(milliseconds: (m['pos'] as num).toInt()), '${m['name'] ?? 'another device'}', DateTime.fromMillisecondsSinceEpoch(at));
    } catch (_) {}
    return false;
  }

  Future<bool> _applyDownload(SyncRow r) async {
    final cd = _boxes['cloud_downloads']!;
    if (r.deleted) {
      await cd.delete(r.id);
    } else if (!_boxes['downloads']!.containsKey(r.id)) {
      final v = decodeHive((r.payload as Map?)?['v']);
      if (v is String) await cd.put(r.id, v);
    }
    await _setTs(r.collection, r.id, r.updatedAt > _ts(r.collection, r.id) ? r.updatedAt : _ts(r.collection, r.id));
    _loadOtherDownloads();
    return false;
  }

  void _loadOtherDownloads() {
    otherDownloads.clear();
    final cd = _boxes['cloud_downloads'];
    final mine = _boxes['downloads'];
    if (cd == null) return;
    for (final k in cd.keys) {
      if (mine?.containsKey(k) ?? false) continue;
      try {
        final m = jsonDecode(cd.get(k) as String) as Map;
        otherDownloads['$k'] = Item.fromJson(m['i'] as Map);
      } catch (_) {}
    }
  }

  /// "Continue here" was used or dismissed.
  void clearRemoteNow() => remoteNow.value = null;

  Object? _valueFor(String coll, String id) {
    if (coll == 'now') return _meta?.get('now');
    if (coll == 'stats') {
      final i = id.indexOf(':');
      return _boxes['stats']!.get(id.substring(i + 1));
    }
    if (coll == 'playlog') {
      final l = _boxes['play_log']!.get('events');
      return l is List && l.length > 500 ? l.sublist(l.length - 500) : l;
    }
    final box = boxes.entries.firstWhere((e) => e.value == coll).key;
    return _boxes[box]!.get(id);
  }

  bool _exists(String coll, String id) {
    if (coll == 'now') return _meta?.get('now') != null;
    if (coll == 'stats') return _boxes['stats']!.containsKey(id.substring(id.indexOf(':') + 1));
    if (coll == 'playlog') return _boxes['play_log']!.containsKey('events');
    final box = boxes.entries.firstWhere((e) => e.value == coll).key;
    return _boxes[box]!.containsKey(id);
  }

  Future<void> _pushAll(SyncBackend b) async {
    final keys = _pending.toList();
    if (keys.isEmpty) return;
    for (var i = 0; i < keys.length; i += 200) {
      final chunk = keys.sublist(i, (i + 200).clamp(0, keys.length));
      final sent = <String, int>{};
      final rows = <SyncRow>[];
      for (final k in chunk) {
        final j = k.indexOf('|');
        final coll = k.substring(0, j), id = k.substring(j + 1);
        final t = _ts(coll, id);
        sent[k] = t;
        final there = _exists(coll, id);
        rows.add(SyncRow(collection: coll, id: id, payload: there ? {'v': encodeHive(_valueFor(coll, id))} : null, updatedAt: t == 0 ? 1 : t, deleted: !there, device: deviceId));
      }
      await b.push(rows);
      // done, unless it changed again while it was on its way
      final p = _pending;
      for (final e in sent.entries) {
        if (_ts(e.key.split('|').first, e.key.substring(e.key.indexOf('|') + 1)) == e.value) p.remove(e.key);
      }
      await _setPending(p);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _poll?.cancel();
    _life?.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}
