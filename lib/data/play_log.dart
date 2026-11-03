import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';

import '../core/models.dart';

/// One time a song was played: when, how much was heard, how long it is.
class PlayEvent {
  final Item item;
  final DateTime at;
  int heardMs;
  final int? durationMs;
  PlayEvent(this.item, this.at, this.heardMs, this.durationMs);

  String get id => item.id;

  /// Left within 30 s (and before half of a short song): a skip.
  bool get skipped => heardMs < 30000 && (durationMs == null || heardMs < durationMs! * 0.5);

  /// Heard (nearly) to the end.
  bool get completed => durationMs != null ? heardMs >= durationMs! * 0.8 : heardMs >= 150000;

  Map<String, dynamic> toJson() => {'i': item.toJson(), 'a': at.millisecondsSinceEpoch, 'h': heardMs, if (durationMs != null) 'd': durationMs};
  factory PlayEvent.fromJson(Map m) => PlayEvent(
    Item.fromJson(m['i'] as Map),
    DateTime.fromMillisecondsSinceEpoch((m['a'] as num).toInt()),
    (m['h'] as num?)?.toInt() ?? 0,
    (m['d'] as num?)?.toInt(),
  );
}

/// Every play with how much of it was heard (skips, full listens, time of
/// day, what was played together). Kept on the phone, newest 3000. Feeds the
/// DJ's recommendations. Byte © 2026 Apurba Laskar.
class PlayLog extends ChangeNotifier {
  static const keep = 3000;
  Box? _box;
  final List<PlayEvent> _events = []; // oldest first
  String? _session;
  PlayEvent? _open;
  Timer? _flush;

  Future<void> open({Box? box}) async {
    _box = box ?? await Hive.openBox('play_log');
    _events.clear();
    final seen = <String>{};
    // this phone's plays, then the ones synced from other devices ("r:<device>")
    for (final k in ['events', ..._box!.keys.whereType<String>().where((k) => k.startsWith('r:'))]) {
      final raw = _box!.get(k);
      if (raw is! List) continue;
      for (final m in raw) {
        if (m is Map) {
          try {
            final e = PlayEvent.fromJson(m);
            if (seen.add('${e.item.id}@${e.at.millisecondsSinceEpoch ~/ 1000}')) _events.add(e);
          } catch (_) {}
        }
      }
    }
    _events.sort((a, b) => a.at.compareTo(b.at));
    if (_events.length > keep) _events.removeRange(0, _events.length - keep);
  }

  /// Read again (synced plays from other devices arrived).
  Future<void> reload() async {
    await save();
    await open(box: _box);
    notifyListeners();
  }

  /// Newest first (the one playing now included).
  List<PlayEvent> get events => _events.reversed.toList();

  /// Called every second something plays (from the stats ticker).
  void heard(Item it, int ms, String session, DateTime at) {
    if (session != _session || _open == null) {
      _session = session;
      _open = PlayEvent(it, at.subtract(Duration(milliseconds: ms)), 0, it.durationSec == null ? null : it.durationSec! * 1000);
      _events.add(_open!);
      if (_events.length > keep) _events.removeRange(0, _events.length - keep);
    }
    _open!.heardMs += ms;
    _flush ??= Timer(const Duration(seconds: 20), save);
  }

  /// Adds a finished play (backup import, tests).
  void add(PlayEvent e) {
    _events.add(e);
    _events.sort((a, b) => a.at.compareTo(b.at));
    if (_events.length > keep) _events.removeRange(0, _events.length - keep);
    notifyListeners();
  }

  Future<void> save() async {
    _flush?.cancel();
    _flush = null;
    final b = _box;
    if (b == null) return;
    await b.put('events', _events.map((e) => e.toJson()).toList());
  }

  Future<void> clear() async {
    _events.clear();
    _open = null;
    _session = null;
    await _box?.delete('events');
    notifyListeners();
  }

  @override
  void dispose() {
    _flush?.cancel();
    super.dispose();
  }
}
