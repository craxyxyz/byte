import 'dart:math';

import 'package:byte/core/models.dart';
import 'package:byte/player/queue.dart';
import 'package:flutter_test/flutter_test.dart';

Item s(String id) => Item(kind: ItemKind.song, id: id, title: 'Song $id');
List<Item> songs(int n) => List.generate(n, (i) => s('$i'));

void main() {
  test('plays in order and stops at the end with repeat off', () {
    final q = PlayQueue()..load(songs(3));
    expect(q.current!.id, '0');
    expect(q.next(), isTrue);
    expect(q.next(), isTrue);
    expect(q.current!.id, '2');
    expect(q.next(), isFalse);
    expect(q.current!.id, '2');
  });

  test('repeat all wraps around both ways', () {
    final q = PlayQueue()
      ..load(songs(3))
      ..repeat = RepeatMode.all;
    q.next();
    q.next();
    expect(q.next(), isTrue);
    expect(q.current!.id, '0');
    expect(q.previous(), isTrue);
    expect(q.current!.id, '2');
  });

  test('repeat one repeats on its own but the next button still moves on', () {
    final q = PlayQueue()
      ..load(songs(3))
      ..repeat = RepeatMode.one;
    expect(q.next(), isTrue);
    expect(q.current!.id, '0');
    expect(q.next(userInitiated: true), isTrue);
    expect(q.current!.id, '1');
  });

  test('shuffle keeps the current song first and plays everything once', () {
    final q = PlayQueue(rng: Random(7))..load(songs(10), start: 4);
    q.setShuffle(true);
    expect(q.current!.id, '4');
    expect(q.position, 0);
    final seen = <String>{q.current!.id};
    while (q.next()) {
      seen.add(q.current!.id);
    }
    expect(seen.length, 10);
  });

  test('turning shuffle off returns to the original order at the same song', () {
    final q = PlayQueue(rng: Random(1))..load(songs(6), start: 1, shuffle: true);
    q.next();
    q.next();
    final cur = q.current!.id;
    q.setShuffle(false);
    expect(q.current!.id, cur);
    expect(q.playOrder.map((e) => e.id), ['0', '1', '2', '3', '4', '5']);
    expect(q.position, int.parse(cur));
  });

  test('a new shuffled lap never starts with the song that just played', () {
    for (var seed = 0; seed < 50; seed++) {
      final q = PlayQueue(rng: Random(seed))
        ..load(songs(4), shuffle: true)
        ..repeat = RepeatMode.all;
      q.next();
      q.next();
      q.next();
      final last = q.current!.id;
      expect(q.next(), isTrue);
      expect(q.current!.id, isNot(last), reason: 'seed $seed');
    }
  });

  test('play next / add to queue', () {
    final q = PlayQueue()..load(songs(3));
    q.playNext(s('x'));
    q.add(s('y'));
    expect(q.playOrder.map((e) => e.id), ['0', 'x', '1', '2', 'y']);
    q.next();
    expect(q.current!.id, 'x');
  });

  test('removing before the current song keeps the current song', () {
    final q = PlayQueue()..load(songs(5), start: 3);
    q.removeAt(1);
    expect(q.current!.id, '3');
    expect(q.playOrder.length, 4);
    q.removeAt(3); // the one after
    expect(q.current!.id, '3');
    expect(q.nextItem, isNull);
  });

  test('drag to reorder keeps track of the playing song', () {
    final q = PlayQueue()..load(songs(5), start: 2);
    q.move(4, 0); // 4 to the top
    expect(q.playOrder.map((e) => e.id), ['4', '0', '1', '2', '3']);
    expect(q.current!.id, '2');
    q.move(3, 4); // move the current song down
    expect(q.current!.id, '2');
    expect(q.position, 4);
    q.move(0, 4);
    expect(q.current!.id, '2');
  });

  test('clearUpcoming leaves only what has played', () {
    final q = PlayQueue()..load(songs(5), start: 1);
    q.clearUpcoming();
    expect(q.playOrder.map((e) => e.id), ['0', '1']);
    expect(q.current!.id, '1');
  });

  test('empty queue is safe', () {
    final q = PlayQueue();
    expect(q.current, isNull);
    expect(q.next(), isFalse);
    expect(q.previous(), isFalse);
    q.removeAt(0);
    q.move(0, 1);
    q.add(s('a'));
    expect(q.current!.id, 'a');
  });
}
