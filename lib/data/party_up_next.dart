import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import 'party_sound.dart' show PartyLink;

// Byte © 2026 Apurba Laskar.
//
// Listen together → the host's up next (1.4.5). A guest plays one song at a
// time (the host's phone decides what comes next), so its own queue was
// always empty and showed "Nothing next". Now the host sends the next songs
// in his queue and every guest's Queue shows the same list. Only the list
// travels; the guest never starts a song from it on its own.
//
// Rides the party's own live channel (no server tables, no change to the
// party's state messages):
//   upnext   host → all  {from, for: current song id, it: [up to 15 songs]}

class PartyUpNext {
  final PartyLink link;

  /// The host's queue after the current song.
  final List<Item> Function() upcoming;

  /// The song playing now on this phone.
  final Item? Function() current;

  /// Bumps when this phone's queue changes.
  final Listenable queueChanges;

  /// Where a guest's copy of the host's list goes (null = not a guest).
  final ValueNotifier<List<Item>?> target;

  static int maxItems = 15;
  static Duration debounce = const Duration(milliseconds: 400);
  static Duration resendEvery = const Duration(seconds: 15);

  Timer? _soon;
  Timer? _resend;
  String? _lastSent;

  PartyUpNext({required this.link, required this.upcoming, required this.current, required this.queueChanges, required this.target}) {
    link.on('upnext', _onUpNext);
    link.onNeedState((_) {
      if (link.active && link.isHost) unawaited(send(force: true));
    });
    link.addListener(_partyChanged);
    queueChanges.addListener(_queueChanged);
    _partyChanged();
  }

  bool get _guest => link.active && !link.isHost;

  void _partyChanged() {
    if (_guest) {
      // joined as a guest: a loading row until the host's list lands
      target.value ??= const [];
      _resend?.cancel();
      _resend = null;
    } else {
      if (target.value != null) target.value = null;
      if (link.active && link.isHost) {
        _resend ??= Timer.periodic(resendEvery, (_) => unawaited(send(force: true)));
        _queueChanged();
      } else {
        _resend?.cancel();
        _resend = null;
        _lastSent = null;
      }
    }
  }

  void _queueChanged() {
    if (!link.active || !link.isHost) return;
    _soon?.cancel();
    _soon = Timer(debounce, () => unawaited(send()));
  }

  /// Host: send the list now (only when it changed, unless [force]).
  Future<void> send({bool force = false}) async {
    if (!link.active || !link.isHost) return;
    final list = [for (final it in upcoming().take(maxItems)) _compact(it)];
    final payload = <String, dynamic>{'from': link.deviceId, 'for': current()?.id, 'it': list};
    final key = jsonEncode([payload['for'], list.map((e) => e['id']).toList()]);
    if (!force && key == _lastSent) return;
    _lastSent = key;
    await link.send('upnext', payload);
  }

  void _onUpNext(Map p) {
    if (!_guest) return;
    if (p['from'] == link.deviceId) return;
    final host = link.hostId;
    if (host != null && p['from'] != null && p['from'] != host) return; // only the host's list
    final raw = p['it'];
    if (raw is! List) return;
    final items = <Item>[];
    for (final m in raw) {
      if (m is! Map) continue;
      try {
        final it = Item.fromJson(m);
        if (it.id.isNotEmpty) items.add(it);
      } catch (_) {}
    }
    target.value = List.unmodifiable(items);
  }

  /// What a guest needs to show a row (and play it if the host picks it).
  static Map<String, dynamic> _compact(Item it) {
    final m = it.toJson();
    m.remove('s');
    return m;
  }

  void dispose() {
    _soon?.cancel();
    _resend?.cancel();
    link.removeListener(_partyChanged);
    queueChanges.removeListener(_queueChanged);
  }
}
