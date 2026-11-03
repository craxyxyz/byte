// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba, with a screen recording): "Nothing next kyu dikha raha,
// next song ka list kyu nahi aa raha … similar songs suggest karna …
// Spotify ki tarah ekdum kadak algorithm." With autoplay (∞) on, the queue
// always shows the next similar songs ahead of time — filled as the song
// starts, topped up as they play, solo and in a party (a guest sees the
// host's list) — and up next is ranked better (no remix/live/slowed copies,
// artist variety, the song's language, skips learnt at once).
import 'dart:async';

import 'package:byte/app.dart';
import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/data/party_sound.dart';
import 'package:byte/data/party_up_next.dart';
import 'package:byte/dj/recommender.dart';
import 'package:byte/dj/up_next.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/sync_adapter.dart';
import 'package:byte/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'party_bus.dart' as pb;

Item s(String id, String title, String artist, {ItemKind kind = ItemKind.song, int sec = 240, String? artistId}) =>
    Item(kind: kind, id: id, title: title, artists: [ArtistRef(artist, artistId)], durationSec: sec);

/// A fake catalogue of similar songs: 30 songs by 10 artists.
List<Item> catalogueFor(String seedId, {int n = 30}) => [
  for (var i = 0; i < n; i++) s('${seedId.substring(0, 3)}sim${i.toString().padLeft(4, '0')}', 'Similar song $i', 'Artist ${i % 10}'),
];

Future<void> until(bool Function() ok, {int ms = 4000, String? why}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timed out${why == null ? '' : ': $why'}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('the queue fills ahead with autoplay on', () {
    late Services sv;
    late ByteAudioHandler p;
    var calls = 0;

    setUp(() async {
      sv = await makeServices();
      p = sv.player;
      sv.settings.autoplay = true;
      sv.settings.crossfadeSeconds = 0;
      sv.settings.automix = false;
      calls = 0;
      fakeAudio.durationFor = (_) => const Duration(minutes: 4);
      p.personalRadio = (seed, exclude) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 150)); // the fetch takes a moment
        return [for (final x in catalogueFor(seed.id)) if (!exclude.contains(x.id)) x].take(20).toList();
      };
    });
    tearDown(() async {
      await p.stop();
      ByteAudioHandler.radioTimeout = const Duration(seconds: 20);
    });

    test('one song, no queue (a party load / resume): 10+ similar songs right at the start, not in its last 30 s', () async {
      await p.playItems([s('aaaSeed0001', 'Aashiq Banjaare', 'Seed Artist')]);
      expect(p.radioLoading.value || p.upcomingCount >= 10, isTrue);
      await until(() => p.upcomingCount >= 10, why: 'filled from the fake catalogue');
      expect(p.position.inSeconds, lessThan(10), reason: 'filled at the start of a 4 min song');
      expect(p.isRadioPick(p.queueModel.nextItem!.id), isTrue);
      expect(calls, 1);
    });

    test('tops up as songs play: always 10 ahead', () async {
      await p.playItems([s('bbbSeed0001', 'Seed', 'Seed Artist')]);
      await until(() => p.upcomingCount >= 10);
      for (var i = 0; i < 12; i++) {
        await p.skipToNext();
        await until(() => p.upcomingCount >= 10, why: 'still 10 ahead after $i skips');
      }
      final ids = p.queueModel.playOrder.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'no song twice in the queue');
    });

    test('a fetch that hangs lets go; the song\'s own radio fills instead', () async {
      ByteAudioHandler.radioTimeout = const Duration(milliseconds: 300);
      p.personalRadio = (seed, exclude) async {
        calls++;
        await Future<void>.delayed(const Duration(seconds: 5));
        return const [];
      };
      await p.playItems([s('cccSeed0001', 'Seed', 'Seed Artist')]);
      await until(() => p.upcomingCount >= 5, ms: 6000, why: 'the radio fixture fills');
      expect(calls, 1);
    });

    test('everything down: a loading state, retries with a back-off, fills once it works (never stuck)', () async {
      // a phone whose catalogue answers no "next" questions
      final sv2 = await makeServices(net: FakeNet((r, body) => r.url.toString().contains('/next') ? throw Exception('down') : catalogue(r, body)));
      final p2 = sv2.player;
      sv2.settings.autoplay = true;
      ByteAudioHandler.radioTimeout = const Duration(milliseconds: 300);
      var n = 0;
      p2.personalRadio = (seed, exclude) async {
        n++;
        if (n <= 2) throw Exception('offline');
        return catalogueFor(seed.id).take(15).toList();
      };
      try {
        await p2.playItems([s('cc2Seed0001', 'Seed', 'Seed Artist')]);
        await until(() => n >= 1);
        expect(p2.upcomingCount, 0);
        await until(() => p2.upcomingCount >= 10, ms: 20000, why: 'filled after retries');
        expect(n, 3);
      } finally {
        await p2.stop();
      }
    });

    test('autoplay off: no fetch, the queue stays empty', () async {
      sv.settings.autoplay = false;
      await p.playItems([s('dddSeed0001', 'Seed', 'Seed Artist')]);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(p.upcomingCount, 0);
      expect(calls, 0);
    });

    test('a hand skip within 30 s: the artist\'s other autoplay picks leave the queue, others refill', () async {
      p.personalRadio = (seed, exclude) async => [
        for (final x in [
          s('eeeSkip0001', 'Song A1', 'Skipped Artist'),
          s('eeeKeep0001', 'Song B1', 'Kept Artist'),
          s('eeeSkip0002', 'Song A2', 'Skipped Artist'),
          for (var i = 0; i < 15; i++) s('eeeMore${i.toString().padLeft(4, '0')}', 'More $i', 'Other $i'),
        ])
          if (!exclude.contains(x.id)) x,
      ];
      await p.playItems([s('eeeSeed0001', 'Seed', 'Seed Artist')]);
      await until(() => p.upcomingCount >= 10);
      await p.skipToNext(); // → Song A1
      expect(p.current.value!.id, 'eeeSkip0001');
      await p.skipToNext(); // skipped A1 at once
      final upcoming = p.queueModel.playOrder.skip(p.queueModel.position + 1).map((e) => e.id).toList();
      expect(upcoming, isNot(contains('eeeSkip0002')));
      expect(PersonalRadio.feedback.artistSkips['skipped artist'], greaterThan(0));
      PersonalRadio.feedback.clear();
    });
  });

  group('Queue sheet', () {
    late Services sv;
    setUp(() async {
      sv = await makeServices();
      sv.settings.autoplay = true;
      fakeAudio.durationFor = (_) => const Duration(minutes: 4);
    });
    tearDown(() async => sv.player.stop());

    Future<void> openQueue(WidgetTester tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(const ByteApp());
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('mini')));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byTooltip('Queue').first);
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets('autoplay on: a loading row while the songs come, never "Nothing next"; then the list', (tester) async {
      addTearDown(tester.view.reset);
      final gate = Completer<List<Item>>();
      sv.player.personalRadio = (seed, exclude) => gate.future;
      await tester.runAsync(() => sv.player.playItems([s('fffSeed0001', 'Seed Song', 'Seed Artist')]));
      await tester.runAsync(() => sv.player.pause());
      await openQueue(tester);
      expect(find.text('Nothing next'), findsNothing);
      expect(find.text('Finding similar songs…'), findsOneWidget);
      gate.complete(catalogueFor('fff', n: 12));
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Finding similar songs…'), findsNothing);
      expect(find.text('Similar song 0'), findsWidgets);
      expect(find.text('Similar songs next'), findsWidgets);
      await tester.runAsync(() => sv.player.stop());
    });

    testWidgets('"Nothing next" only with autoplay off and an empty queue', (tester) async {
      addTearDown(tester.view.reset);
      sv.settings.autoplay = false;
      await tester.runAsync(() => sv.player.playItems([s('gggSeed0001', 'Seed Song', 'Seed Artist')]));
      await tester.runAsync(() => sv.player.pause());
      await openQueue(tester);
      expect(find.text('Nothing next'), findsOneWidget);
      expect(find.text('Finding similar songs…'), findsNothing);
      await tester.runAsync(() => sv.player.stop());
    });
  });

  test('Listen together: the host fills; the guest shows the same upcoming list and never picks its own', () async {
    final sv = await makeServices();
    final host = sv.player;
    sv.settings.autoplay = true;
    sv.settings.automix = false;
    fakeAudio.durationFor = (_) => const Duration(minutes: 4);
    ListenTogether.heartbeat = const Duration(milliseconds: 200);
    PartyUpNext.debounce = const Duration(milliseconds: 50);
    host.personalRadio = (seed, exclude) async => [for (final x in catalogueFor(seed.id)) if (!exclude.contains(x.id)) x].take(15).toList();
    final guestH = ByteAudioHandler(resolver: sv.resolver, yt: sv.yt, library: sv.library, settings: sv.settings);
    var guestFetches = 0;
    guestH.personalRadio = (seed, exclude) async {
      guestFetches++;
      return catalogueFor('zzz');
    };
    final bus = pb.FakePartyBus();
    final hp = HandlerSyncPlayer(host), gp = HandlerSyncPlayer(guestH);
    final hl = ListenTogether(player: hp, deviceId: 'host-1', displayName: () => 'Apurba', net: pb.FakePartyNet(bus), store: MemoryPartyStore());
    final gl = ListenTogether(player: gp, deviceId: 'guest-1', displayName: () => 'Rahul', net: pb.FakePartyNet(bus), store: MemoryPartyStore());
    List<Item> upOf(ByteAudioHandler h) {
      final o = h.queueModel.playOrder;
      return o.sublist((h.queueModel.position + 1).clamp(0, o.length));
    }

    final hu = PartyUpNext(link: ListenTogetherLink(hl), upcoming: () => upOf(host), current: () => host.current.value, queueChanges: host.queueVersion, target: host.partyUpNext);
    final gu = PartyUpNext(link: ListenTogetherLink(gl), upcoming: () => upOf(guestH), current: () => guestH.current.value, queueChanges: guestH.queueVersion, target: guestH.partyUpNext);
    try {
      expect(await hl.host(capacity: 5), isTrue, reason: hl.error);
      await host.playItems([s('hhhSeed0001', 'Aashiq Banjaare', 'Seed Artist')]);
      expect(await gl.join(hl.code!), isTrue, reason: gl.error);
      await until(() => guestH.current.value?.id == 'hhhSeed0001', why: 'guest follows the song');
      expect(guestH.partyUpNext.value, isNotNull, reason: 'a guest');
      await until(() => host.upcomingCount >= 10, why: 'host fills');
      await until(() => (guestH.partyUpNext.value ?? const []).length >= 10, why: 'guest gets the list');
      expect(guestH.partyUpNext.value!.map((e) => e.id).toList(), upOf(host).take(PartyUpNext.maxItems).map((e) => e.id).toList());
      // the host's queue changes → the guest's list follows
      await host.skipToNext();
      await until(() => guestH.current.value?.id == host.current.value?.id, why: 'guest on the host\'s next song');
      await until(() => guestH.partyUpNext.value!.first.id == upOf(host).first.id, why: 'list follows');
      // the guest's own queue never fetched or picked
      expect(guestFetches, 0);
      expect(guestH.upcomingCount, 0);
      expect(host.partyUpNext.value, isNull, reason: 'the host shows his own queue');
      await gl.leave();
      expect(guestH.partyUpNext.value, isNull, reason: 'out of the party: own queue again');
    } finally {
      await hl.leave();
      await gl.leave();
      hu.dispose();
      gu.dispose();
      hp.dispose();
      gp.dispose();
      await guestH.stop();
      await guestH.disposeAll();
      await host.stop();
    }
  });

  group('up next ranking', () {
    final seed = s('seed', 'Tum Hi Ho', 'Arijit Singh');
    TasteProfile taste() => TasteProfile();

    test('no copies of one song: remix, live, reprise, slowed + reverb, lofi, unplugged count once (and never the seed again)', () {
      final radio = [
        s('r1', 'Tum Hi Ho (Remix)', 'DJ Someone'),
        s('r2', 'Tum Hi Ho - Live at Wembley', 'Arijit Singh'),
        s('r3', 'Tum Hi Ho Slowed + Reverb', 'Lofi Boy'),
        s('a1', 'Chahun Main Ya Naa', 'Arijit Singh'),
        s('a2', 'Chahun Main Ya Naa (Unplugged)', 'Arijit Singh'),
        s('a3', 'Chahun Main Ya Naa - Lofi Flip', 'Lofi Boy'),
        s('b1', 'Sun Raha Hai', 'Ankit Tiwari'),
        s('b2', 'Sun Raha Hai (Reprise)', 'Ankit Tiwari'),
      ];
      final out = PersonalRadio.rank(seed, [radio], taste()).map((p) => p.item.id).toList();
      expect(out, isNot(contains('r1')));
      expect(out, isNot(contains('r2')));
      expect(out, isNot(contains('r3')));
      expect(out.where((id) => id.startsWith('a')).length, 1);
      expect(out.where((id) => id.startsWith('b')).length, 1);
    });

    test('artist variety: at most 2 by one artist in any 10, never 3 in a row', () {
      final radio = [
        for (var i = 0; i < 10; i++) s('ar$i', 'Arijit song $i', 'Arijit Singh'),
        for (var i = 0; i < 10; i++) s('ot$i', 'Other song $i', 'Singer $i'),
      ];
      final out = PersonalRadio.rank(seed, [radio], taste(), count: 20).map((p) => p.item).toList();
      for (var i = 0; i + 10 <= 10; i++) {
        expect(out.sublist(i, i + 10).where((x) => x.artists.first.name == 'Arijit Singh').length, lessThanOrEqualTo(2));
      }
      for (var i = 2; i < out.length; i++) {
        final a = out[i].artists.first.name;
        expect(a == out[i - 1].artists.first.name && a == out[i - 2].artists.first.name, isFalse, reason: 'three in a row at $i');
      }
      expect(out.where((x) => x.id.startsWith('ot')).length, 10, reason: 'every other artist used');
      expect(out.length, greaterThan(10), reason: 'the loved artist still fills in, spaced out');
    });

    test('a skip learnt at once: songs by the skipped artist sink, the skipped song never comes back in any upload', () {
      final radio = [s('x1', 'Gerua', 'Pritam'), s('x2', 'Kabira', 'Pritam'), s('y1', 'Raabta', 'Shreya Ghoshal'), s('y2', 'Agar Tum Saath Ho', 'Alka Yagnik')];
      final fb = RadioFeedback();
      final before = PersonalRadio.rank(seed, [radio], taste(), session: fb).map((p) => p.item.id).toList();
      expect(before.first, 'x1');
      fb.skip(s('zz', 'Gerua (Official Video)', 'Pritam'));
      final after = PersonalRadio.rank(seed, [radio], taste(), session: fb).map((p) => p.item.id).toList();
      expect(after, isNot(contains('x1')), reason: 'the skipped song, another upload');
      expect(after.indexOf('x2'), greaterThan(after.indexOf('y1')));
      expect(after.indexOf('x2'), greaterThan(after.indexOf('y2')));
      // a song of theirs played to the end forgives it a little
      fb.fullListen(s('x3', 'Tum Se Hi', 'Pritam'));
      expect(fb.artistSkips['pritam'], lessThan(1));
    });

    test('the song\'s language is kept; when they play mixed, softer', () {
      final hindi = s('seedhi', 'Kesariya', 'Arijit Singh');
      final radio = [s('en1', 'Shape of You', 'Ed Sheeran'), s('en2', 'Perfect', 'Ed Sheeran'), s('hi1', 'Raabta', 'Arijit Singh'), s('hi2', 'Tujhe Kitna Chahne Lage', 'Arijit Singh')];
      final out = PersonalRadio.rank(hindi, [radio], taste()).map((p) => p.item.id).toList();
      expect(out.take(2).toSet(), {'hi1', 'hi2'});
      final bengali = s('seedbn', 'Tomake Chai', 'Arijit Singh');
      final bn = [s('bn1', 'Amake Amar Moto Thakte Dao', 'Anupam Roy'), s('hi3', 'Raabta', 'Arijit Singh')];
      final outBn = PersonalRadio.rank(bengali, [bn], taste()).map((p) => p.item.id).toList();
      expect(outBn, contains('bn1'));
    });

    test('covers only when they like that upload', () {
      final radio = [s('c1', 'Kabira (Cover)', 'Someone Singing'), s('o1', 'Ilahi', 'Arijit Singh')];
      final out = PersonalRadio.rank(seed, [radio], taste()).map((p) => p.item.id).toList();
      expect(out.first, 'o1');
      final t = taste()
        ..songs['c1'] = radio[0]
        ..liked.add('c1')
        ..plays['c1'] = 6;
      expect(PersonalRadio.rank(seed, [radio], t).first.item.id, 'c1');
    });

    test('offline: up next still comes from their own history and likes', () async {
      final yt = InnerTube(FakeNet((r, body) => throw Exception('offline')));
      final t = TasteProfile();
      for (var i = 0; i < 12; i++) {
        final it = s('mine$i', 'My song $i', 'Singer $i');
        t.songs[it.id] = it;
        t.liked.add(it.id);
        t.plays[it.id] = 3;
        t.recent.add(it); // even played lately
      }
      final out = await PersonalRadio.forSeed(yt, seed, t, timeout: const Duration(milliseconds: 500));
      expect(out.length, greaterThanOrEqualTo(10));
    });
  });
}
