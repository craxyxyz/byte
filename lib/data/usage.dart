import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase/supabase.dart';

import '../brand.dart';
import '../core/models.dart';

/// Byte © 2026 Apurba Laskar.
/// Who uses Byte and how, for Byte's owner only (Settings → Admin): each
/// phone reports its model, Android/iOS version, Byte version, when it was
/// last used, and the songs it plays (title + artist, how long). No
/// passwords, no messages, no location, no contacts. Settings → Your data →
/// "Share usage with Byte's owner" turns it off. Writes go only through the
/// server's byte_ping / byte_play functions (a per-phone secret), and only
/// the owner's account can read them (server-checked, not a hidden button).
class UsageReporter {
  final SupabaseClient Function() client;
  final String deviceId;
  final bool Function() enabled;
  final Map<String, Object?> Function() deviceInfo;
  final Future<String?> Function(String key) readSecret;
  final Future<void> Function(String key, String value) writeSecret;

  /// For tests: replaces the server call.
  final Future<dynamic> Function(String fn, Map<String, dynamic> params)? rpcForTest;

  Future<dynamic> _rpc(String fn, Map<String, dynamic> params) => rpcForTest != null ? rpcForTest!(fn, params) : client().rpc(fn, params: params);

  UsageReporter({
    this.rpcForTest,
    required this.client,
    required this.deviceId,
    required this.enabled,
    required this.deviceInfo,
    Future<String?> Function(String key)? readSecret,
    Future<void> Function(String key, String value)? writeSecret,
  }) : readSecret = readSecret ?? ((k) => const FlutterSecureStorage().read(key: k)),
       writeSecret = writeSecret ?? ((k, v) => const FlutterSecureStorage().write(key: k, value: v));

  /// The server has no usage tables yet (setup file not run): stay quiet.
  bool serverMissing = false;
  DateTime? _lastPing;
  String? _secret;
  final List<Map<String, Object?>> _pending = [];

  static const minHeard = Duration(seconds: 30);

  Future<String> _sec() async {
    final s = _secret ?? await readSecret('byte_usage_secret');
    if (s != null && s.length >= 16) return _secret = s;
    final r = Random.secure();
    final n = List.generate(32, (_) => r.nextInt(16).toRadixString(16)).join();
    await writeSecret('byte_usage_secret', n);
    return _secret = n;
  }

  static bool _isMissing(Object e) {
    final s = '$e';
    return s.contains('PGRST202') || s.contains('42883') || s.contains('PGRST205') || s.contains('Could not find the function');
  }

  /// "This phone is in use" (at most every 10 minutes).
  Future<void> ping({bool force = false}) async {
    if (!enabled() || serverMissing) return;
    final now = DateTime.now();
    if (!force && _lastPing != null && now.difference(_lastPing!) < const Duration(minutes: 10)) return;
    _lastPing = now;
    try {
      await _rpc('byte_ping', {
        'p_device': deviceId,
        'p_secret': await _sec(),
        'p_info': {...deviceInfo(), 'app_version': Brand.version},
      });
      await _flush();
    } catch (e) {
      if (_isMissing(e)) serverMissing = true;
    }
  }

  /// A song was listened to for [heard].
  Future<void> played(Item it, Duration heard) async {
    if (!enabled() || serverMissing || heard < minHeard || it.title.isEmpty) return;
    _pending.add({
      'song_id': it.id,
      'title': it.title.length > 200 ? it.title.substring(0, 200) : it.title,
      'artist': it.artistLine.length > 200 ? it.artistLine.substring(0, 200) : it.artistLine,
      'seconds': heard.inSeconds,
    });
    if (_pending.length > 200) _pending.removeRange(0, _pending.length - 200);
    await _flush();
  }

  bool _flushing = false;
  Future<void> _flush() async {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    try {
      while (_pending.isNotEmpty) {
        final p = _pending.first;
        await _rpc('byte_play', {'p_device': deviceId, 'p_secret': await _sec(), 'p_song': p});
        _pending.removeAt(0);
      }
    } catch (e) {
      if (_isMissing(e)) {
        serverMissing = true;
        _pending.clear();
      }
    } finally {
      _flushing = false;
    }
  }
}

/// What the owner's Admin screen shows (from byte_admin_overview).
class AdminOverview {
  final int devices, accounts, activeToday, active7d, plays7d, playsTotal;
  final List<(String, int)> daily; // day (yyyy-mm-dd), active phones
  final List<(String, String, int)> topSongs; // title, artist, plays
  final List<(String, int)> topArtists;
  final List<AdminUser> users;
  AdminOverview({
    this.devices = 0,
    this.accounts = 0,
    this.activeToday = 0,
    this.active7d = 0,
    this.plays7d = 0,
    this.playsTotal = 0,
    this.daily = const [],
    this.topSongs = const [],
    this.topArtists = const [],
    this.users = const [],
  });

  static int _i(Object? v) => (v as num?)?.toInt() ?? 0;

  factory AdminOverview.fromJson(Map m) {
    final t = (m['totals'] as Map?) ?? const {};
    return AdminOverview(
      devices: _i(t['devices']),
      accounts: _i(t['accounts']),
      activeToday: _i(t['active_today']),
      active7d: _i(t['active_7d']),
      plays7d: _i(t['plays_7d']),
      playsTotal: _i(t['plays_total']),
      daily: [for (final d in ((m['daily'] as List?) ?? const []).whereType<Map>()) ('${d['day']}', _i(d['users']))],
      topSongs: [for (final d in ((m['top_songs'] as List?) ?? const []).whereType<Map>()) ('${d['title'] ?? ''}', '${d['artist'] ?? ''}', _i(d['plays']))],
      topArtists: [for (final d in ((m['top_artists'] as List?) ?? const []).whereType<Map>()) ('${d['artist'] ?? ''}', _i(d['plays']))],
      users: [for (final d in ((m['users'] as List?) ?? const []).whereType<Map>()) AdminUser.fromJson(d)],
    );
  }
}

class AdminUser {
  final String name, email, device, platform, appVersion;
  final DateTime? firstSeen, lastActive;
  final int plays;
  final int minutes;
  AdminUser({this.name = '', this.email = '', this.device = '', this.platform = '', this.appVersion = '', this.firstSeen, this.lastActive, this.plays = 0, this.minutes = 0});
  factory AdminUser.fromJson(Map m) => AdminUser(
    name: '${m['name'] ?? ''}',
    email: '${m['email'] ?? ''}',
    device: '${m['device_model'] ?? ''}',
    platform: [m['platform'], m['os_version']].where((x) => x != null && '$x'.isNotEmpty).join(' '),
    appVersion: '${m['app_version'] ?? ''}',
    firstSeen: DateTime.tryParse('${m['first_seen'] ?? ''}')?.toLocal(),
    lastActive: DateTime.tryParse('${m['last_active'] ?? ''}')?.toLocal(),
    plays: AdminOverview._i(m['plays']),
    minutes: AdminOverview._i(m['minutes']),
  );
}

/// Reads the owner's overview. Throws [AdminProblem] with a plain reason.
class AdminApi {
  static const ownerEmail = 'justapurbapoco1@gmail.com';
  final SupabaseClient Function() client;
  AdminApi(this.client);

  static bool isOwner(String? email) => email != null && email.trim().toLowerCase() == ownerEmail;

  Future<AdminOverview> overview({int days = 30}) async {
    try {
      final r = await client().rpc('byte_admin_overview', params: {'p_days': days});
      return AdminOverview.fromJson(r is Map ? r : const {});
    } catch (e) {
      final s = '$e';
      if (s.contains('PGRST202') || s.contains('42883') || s.contains('Could not find the function')) {
        throw const AdminProblem('Server setup pending: run Byte\'s server setup file (Byte-v1.3.1-setup.sql) once.');
      }
      if (s.contains('verify')) {
        throw const AdminProblem('To open Admin, sign in to your Byte account with an email code once (it proves the email is really yours).');
      }
      if (s.contains('42501') || s.contains('not admin')) throw const AdminProblem('Only Byte\'s owner can see this.');
      if (s.contains('SocketException') || s.contains('ClientException') || s.contains('Failed host lookup')) {
        throw const AdminProblem('No internet connection.');
      }
      debugPrint('admin: $e');
      throw const AdminProblem('Couldn\'t load the numbers. Try again.');
    }
  }
}

class AdminProblem implements Exception {
  final String message;
  const AdminProblem(this.message);
  @override
  String toString() => message;
}
