import 'dart:math';

import '../core/models.dart';

enum RepeatMode { off, all, one }

/// The play queue: original order, shuffle order, position, repeat.
/// Pure Dart so every rule is unit-tested.
class PlayQueue {
  final List<Item> _items = [];
  List<int> _order = [];
  int _pos = -1;
  bool _shuffle = false;
  RepeatMode repeat = RepeatMode.off;
  final Random _rng;

  PlayQueue({Random? rng}) : _rng = rng ?? Random();

  bool get shuffle => _shuffle;
  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  int get position => _pos;
  Item? get current => _pos >= 0 && _pos < _order.length ? _items[_order[_pos]] : null;

  /// The queue in the order it will play (what the "Up next" list shows).
  List<Item> get playOrder => [for (final i in _order) _items[i]];
  List<Item> get originalOrder => List.unmodifiable(_items);

  void load(List<Item> items, {int start = 0, bool? shuffle}) {
    _items
      ..clear()
      ..addAll(items);
    _order = List.generate(items.length, (i) => i);
    _pos = items.isEmpty ? -1 : start.clamp(0, items.length - 1);
    if (shuffle != null) _shuffle = shuffle;
    if (_shuffle) _shuffleKeepingCurrent();
  }

  void setShuffle(bool on) {
    if (on == _shuffle) return;
    _shuffle = on;
    if (on) {
      _shuffleKeepingCurrent();
    } else {
      final cur = _pos >= 0 ? _order[_pos] : 0;
      _order = List.generate(_items.length, (i) => i);
      _pos = _items.isEmpty ? -1 : cur;
    }
  }

  void _shuffleKeepingCurrent() {
    if (_items.isEmpty) return;
    final cur = _pos >= 0 ? _order[_pos] : 0;
    final rest = List.generate(_items.length, (i) => i)..remove(cur);
    rest.shuffle(_rng);
    _order = [cur, ...rest];
    _pos = 0;
  }

  /// Index (in play order) of the track after the current one, honouring
  /// repeat. [userInitiated] = the next button (repeat-one doesn't trap it).
  int? peekNext({bool userInitiated = false}) {
    if (_items.isEmpty) return null;
    if (repeat == RepeatMode.one && !userInitiated) return _pos;
    if (_pos + 1 < _order.length) return _pos + 1;
    if (repeat == RepeatMode.all || (repeat == RepeatMode.one && userInitiated)) return 0;
    return null;
  }

  Item? get nextItem {
    final n = peekNext();
    return n == null ? null : _items[_order[n]];
  }

  /// Moves to the next track. Returns false at the end of the queue.
  bool next({bool userInitiated = false}) {
    final n = peekNext(userInitiated: userInitiated);
    if (n == null) return false;
    if (n == 0 && _pos == _order.length - 1 && _shuffle && _order.length > 2) {
      // a new lap of a shuffled queue gets a new order (but not the same song first)
      final last = _order[_pos];
      final idx = List.generate(_items.length, (i) => i)..shuffle(_rng);
      if (idx.first == last) {
        idx.add(idx.removeAt(0));
      }
      _order = idx;
    }
    _pos = n;
    return true;
  }

  bool previous() {
    if (_items.isEmpty) return false;
    if (_pos > 0) {
      _pos--;
      return true;
    }
    if (repeat == RepeatMode.all) {
      _pos = _order.length - 1;
      return true;
    }
    return false;
  }

  void jumpTo(int playIndex) {
    if (playIndex < 0 || playIndex >= _order.length) return;
    _pos = playIndex;
  }

  /// Plays right after the current track.
  void playNext(Item it) {
    _items.add(it);
    _order.insert(_pos + 1, _items.length - 1);
    if (_pos < 0) _pos = 0;
  }

  void add(Item it) {
    _items.add(it);
    _order.add(_items.length - 1);
    if (_pos < 0) _pos = 0;
  }

  void addAll(Iterable<Item> its) {
    for (final i in its) {
      add(i);
    }
  }

  /// Removes the item at [playIndex] (in play order).
  void removeAt(int playIndex) {
    if (playIndex < 0 || playIndex >= _order.length) return;
    final orig = _order.removeAt(playIndex);
    _items.removeAt(orig);
    _order = [for (final o in _order) o > orig ? o - 1 : o];
    if (playIndex < _pos) {
      _pos--;
    } else if (playIndex == _pos) {
      if (_pos >= _order.length) _pos = _order.length - 1;
    }
    if (_items.isEmpty) _pos = -1;
  }

  /// Drag-to-reorder in the Up next list.
  void move(int from, int to) {
    if (from == to || from < 0 || to < 0 || from >= _order.length || to >= _order.length) return;
    final v = _order.removeAt(from);
    _order.insert(to, v);
    if (_pos == from) {
      _pos = to;
    } else if (from < _pos && to >= _pos) {
      _pos--;
    } else if (from > _pos && to <= _pos) {
      _pos++;
    }
  }

  /// Drops everything after the current track (used before refilling radio).
  void clearUpcoming() {
    while (_order.length > _pos + 1) {
      removeAt(_order.length - 1);
    }
  }

  bool contains(String id) => _items.any((i) => i.id == id);

  /// Swaps the current track for another version of it (audio ⇄ music video).
  void replaceCurrent(Item it) {
    if (_pos < 0 || _pos >= _order.length) return;
    _items[_order[_pos]] = it;
  }
}
