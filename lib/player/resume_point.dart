// Byte © 2026 Apurba Laskar.
//
// 1.4.5: the last song, its spot and the queue around it, kept on the phone
// so a Byte that Android closed (or that was swiped away) opens again on the
// same song, paused at the same second, with the lock screen showing it.
import 'dart:convert';

import '../core/models.dart';

class ResumePoint {
  /// The queue around the song (at most [keep] items).
  final List<Item> items;

  /// The song's place in [items].
  final int index;
  final int positionMs;
  final String? from;
  final DateTime savedAt;

  const ResumePoint({required this.items, required this.index, required this.positionMs, this.from, required this.savedAt});

  /// Items kept around the current one (the whole queue would be too big).
  static const keep = 100;

  Item get item => items[index];

  /// A slice of [order] around [position]; null when nothing plays.
  static ResumePoint? of(List<Item> order, int position, {required int positionMs, String? from, DateTime? at}) {
    if (position < 0 || position >= order.length) return null;
    var start = position - 20;
    if (start < 0) start = 0;
    var end = start + keep;
    if (end > order.length) end = order.length;
    return ResumePoint(
      items: order.sublist(start, end),
      index: position - start,
      positionMs: positionMs < 0 ? 0 : positionMs,
      from: from,
      savedAt: at ?? DateTime.now(),
    );
  }

  String encode() => jsonEncode({
    'v': 1,
    'i': index,
    'p': positionMs,
    if (from != null) 'f': from,
    't': savedAt.millisecondsSinceEpoch,
    'q': [for (final it in items) it.toJson()],
  });

  /// Reads a saved point; null for nothing saved or anything unreadable.
  static ResumePoint? decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map;
      final items = [for (final e in (m['q'] as List? ?? const [])) if (e is Map) Item.fromJson(e)];
      final i = (m['i'] as num?)?.toInt() ?? 0;
      if (items.isEmpty || i < 0 || i >= items.length) return null;
      return ResumePoint(
        items: items,
        index: i,
        positionMs: ((m['p'] as num?)?.toInt() ?? 0).clamp(0, 1 << 31),
        from: m['f'] as String?,
        savedAt: DateTime.fromMillisecondsSinceEpoch((m['t'] as num?)?.toInt() ?? 0),
      );
    } catch (_) {
      return null;
    }
  }
}
