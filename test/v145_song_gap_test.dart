// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba): "ek song khatam hone ke baad dusra song turant suru ho ja
// raha hai, thoda 2-3 sec baad next song play karna". When a song ends on
// its own, 2.5 s of silence, then the next one. The real player against the
// fake audio engine (test/helpers.dart); the gap runs on a fake clock.
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/data/settings.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/sync_adapter.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'helpers.dart';
import 'party_bus.dart' as pb;

/// A clock the test moves by hand; only the gap uses it.
class FakeClock {
  int now = 0;
  final List<FakeTimer> made = [];
  Timer make(Duration d, void Function() cb) {
    final t = FakeTimer(this, d, cb);
    made.add(t);
    return t;
  }

  FakeTimer? get pending {
    for (final t in made.reversed) {
      if (t.isActive) return t;
    }
    return null;
  }

  void elapse(Duration by) {
    now += by.inMilliseconds;
    for (final t in [...made]) {
      if (t.isActive && t.dueMs <= now) t.fire();
    }
  }
}

class FakeTimer implements Timer {
  final FakeClock clock;
  final Duration duration;
  final void Function() cb;
  final int dueMs;
  bool _active = true;
  FakeTimer(this.clock, this.duration, this.cb) : dueMs = clock.now + duration.inMilliseconds;
  void fire() {
    _active = false;
    cb();
  }

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

Item s(String id, {int sec = 2, String? album}) =>
    Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: sec, album: album);

void main() {
  late Services sv;
  late ByteAudioHandler p;
  late FakeClock clock;
  final durations = <String, int>{};

  setUp(() async {
    sv = await makeServices();
    p = sv.player;
    clock = FakeClock();
    p.gapTimer = clock.make;
    sv.settings.autoplay = false;
    sv.settings.normalizeVolume = false;
    sv.settings.crossfadeSeconds = 0;
    await p.setRepeatMode(AudioServiceRepeatMode.none);
    durations.clear();
    fakeAudio.durationFor = (uri) {
      final m = RegExp(r'media\.example/([^/]+)/').firstMatch(uri);
      return Duration(milliseconds: durations[m?.group(1)] ?? 1500);
    };
  });
  tearDown(() async {
    await p.stop();
  });

  Future<void> until(bool Function() ok, {int ms = 8000, String? why}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out${why == null ? '' : ': $why'}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  Future<void> settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

  /// Which song the engine is really playing (null = silence).
  String? sounding() {
    for (final x in fakeAudio.players.values) {
      if (x.playing && x.state.name == 'ready') return RegExp(r'media\.example/([^/]+)/').firstMatch(x.uri ?? '')?.group(1);
    }
    return null;
  }

  /// Plays [ids] and waits until the first one has ended on its own.
  Future<void> playUntilGap(List<String> ids) async {
    await p.playItems([for (final id in ids) s(id)]);
    await until(() => sounding() == ids.first, ms: 1000, why: 'first song plays at once');
    await until(() => clock.pending != null, why: 'first song ends, gap starts');
  }

  test('defaults: the gap is 2.5 s; crossfade 0; Automix stays on (it no longer overlaps); gapless albums off', () {
    expect(p.autoAdvanceGap, const Duration(milliseconds: 2500));
    expect(sv.settings.crossfadeSeconds, 0);
    expect(Settings().automix, isTrue, reason: 'Automix keeps its default (Apurba: "automix karna")');
    expect(sv.lab.gapless, isFalse, reason: '"Keep gapless albums intact" only when turned on by hand');
  });

  test('natural end → the next song shows at once but starts only after 2.5 s', () async {
    await playUntilGap(['gapaaaaaaa1', 'gapaaaaaaa2']);
    expect(clock.pending!.duration, const Duration(milliseconds: 2500));
    // the next song is already on the player / lock screen, waiting at 0:00
    expect(p.current.value!.id, 'gapaaaaaaa2');
    expect(p.mediaItem.value!.id, 'gapaaaaaaa2');
    expect(p.waitingForNext.value, isTrue);
    expect(p.inGap, isTrue);
    expect(p.playing, isTrue, reason: 'pause button stays (no play/pause flicker)');
    expect(p.audible, isFalse);
    expect(sounding(), isNull, reason: 'silence during the gap');
    expect(p.playbackState.value.playing, isTrue);
    expect(p.playbackState.value.speed, 0, reason: 'lock screen progress waits at 0:00');
    expect(p.playbackState.value.updatePosition, Duration.zero);

    clock.elapse(const Duration(milliseconds: 2400));
    await settle();
    expect(sounding(), isNull, reason: 'not yet at 2.4 s');
    clock.elapse(const Duration(milliseconds: 100));
    await until(() => sounding() == 'gapaaaaaaa2', why: 'starts at 2.5 s');
    expect(p.inGap, isFalse);
    expect(p.waitingForNext.value, isFalse);
    expect(p.playbackState.value.speed, 1);
    // only one gap for one song end
    expect(clock.made.length, 1);
  });

  test('next song not loaded early (Settings → Performance off): still waits the gap', () async {
    sv.settings.preloadNext = false;
    try {
      await playUntilGap(['gapoooooo01', 'gapoooooo02']);
      await settle(300); // its load finishes during the gap
      expect(p.current.value!.id, 'gapoooooo02');
      expect(sounding(), isNull, reason: 'a deck that ended must not start the new song on load');
      clock.elapse(const Duration(milliseconds: 2500));
      await until(() => sounding() == 'gapoooooo02', ms: 1000);
    } finally {
      sv.settings.preloadNext = true;
    }
  });

  test('Next during the gap → the song after starts immediately', () async {
    await playUntilGap(['gapbbbbbbb1', 'gapbbbbbbb2', 'gapbbbbbbb3']);
    await p.skipToNext();
    expect(p.current.value!.id, 'gapbbbbbbb3');
    await until(() => sounding() == 'gapbbbbbbb3', ms: 1000, why: 'instant');
    expect(clock.pending, isNull, reason: 'the gap is gone');
    expect(p.inGap, isFalse);
  });

  test('Play during the gap → the waiting song starts now', () async {
    await playUntilGap(['gapccccccc1', 'gapccccccc2']);
    await p.play();
    await until(() => sounding() == 'gapccccccc2', ms: 1000, why: 'instant');
    expect(clock.pending, isNull);
  });

  test('Pause during the gap → nothing starts; Play later starts it', () async {
    await playUntilGap(['gapddddddd1', 'gapddddddd2']);
    await p.pause();
    expect(p.playing, isFalse);
    expect(p.playbackState.value.playing, isFalse);
    expect(clock.pending, isNull);
    clock.elapse(const Duration(seconds: 10));
    await settle(200);
    expect(sounding(), isNull, reason: 'Pause cancels the start');
    expect(p.current.value!.id, 'gapddddddd2');
    await p.play();
    await until(() => sounding() == 'gapddddddd2', ms: 1000);
  });

  test('Previous during the gap → back to the song that just ended, at once', () async {
    await playUntilGap(['gapeeeeeee1', 'gapeeeeeee2']);
    await p.skipToPrevious();
    expect(p.current.value!.id, 'gapeeeeeee1');
    await until(() => sounding() == 'gapeeeeeee1', ms: 1000);
    expect(clock.pending, isNull);
  });

  test('Seek during the gap → the waiting song starts from there', () async {
    durations['gapfffffff2'] = 30000;
    await playUntilGap(['gapfffffff1', 'gapfffffff2']);
    await p.seek(const Duration(seconds: 10));
    await until(() => sounding() == 'gapfffffff2', ms: 1000);
    expect(p.position.inMilliseconds, greaterThanOrEqualTo(9900));
    expect(clock.pending, isNull);
  });

  test('manual Next / tapping a song in the queue → instant, no gap', () async {
    durations['gaphhhhhhh1'] = 30000;
    durations['gaphhhhhhh2'] = 30000;
    await p.playItems([s('gaphhhhhhh1'), s('gaphhhhhhh2'), s('gaphhhhhhh3')]);
    await until(() => sounding() == 'gaphhhhhhh1', ms: 1000);
    await p.skipToNext();
    await until(() => sounding() == 'gaphhhhhhh2', ms: 500);
    await p.skipToQueueItem(2);
    await until(() => sounding() == 'gaphhhhhhh3', ms: 500);
    await p.playItems([s('gaphhhhhhh1')]);
    await until(() => sounding() == 'gaphhhhhhh1', ms: 500);
    expect(clock.made, isEmpty);
  });

  test('Crossfade set (> 0 s) → the old overlap, no gap', () async {
    sv.settings.crossfadeSeconds = 2; // capped to a third of 2.5 s
    durations['gapiiiiiii1'] = 2500;
    durations['gapiiiiiii2'] = 2500;
    await p.playItems([s('gapiiiiiii1'), s('gapiiiiiii2')]);
    var sawOverlap = false;
    await until(() {
      final playing = fakeAudio.players.values.where((x) => x.playing).toList();
      if (playing.length == 2) sawOverlap = true;
      return p.current.value!.id == 'gapiiiiiii2' && !fakeAudio.players.values.any((x) => x.playing && x.uri!.contains('gapiiiiiii1'));
    });
    expect(sawOverlap, isTrue);
    expect(clock.made, isEmpty);
  });

  test('gapless albums: only when turned on, same album back to back stays gapless', () async {
    p.keepTogether = (a, b) => sv.lab.keepTogether(a.album, b.album);
    await p.playItems([s('gapjjjjjjj1', album: 'Rockstar'), s('gapjjjjjjj2', album: 'Rockstar')]);
    await until(() => clock.pending != null, why: 'gapless albums off by default → gap');
    await p.stop();
    clock.made.clear();
    sv.lab.gapless = true;
    await p.playItems([s('gapjjjjjjj3', album: 'Rockstar'), s('gapjjjjjjj4', album: 'Rockstar')]);
    await until(() => sounding() == 'gapjjjjjjj4', why: 'gapless hand-off');
    expect(clock.made, isEmpty);
    sv.lab.gapless = false;
  });

  test('sleep timer "end of song" still stops at the end, no next song, no gap', () async {
    await p.playItems([s('gapkkkkkkk1'), s('gapkkkkkkk2')]);
    p.sleepAtEndOfTrack();
    await until(() => !p.playing, why: 'stops');
    await settle(300);
    expect(p.current.value!.id, 'gapkkkkkkk1');
    expect(sounding(), isNull);
    expect(clock.made, isEmpty);
  });

  test('repeat all wraps around after the gap; repeat one replays after the gap', () async {
    await p.setRepeatMode(AudioServiceRepeatMode.all);
    await playUntilGap(['gaplllllll1', 'gaplllllll2']);
    clock.elapse(const Duration(milliseconds: 2500));
    await until(() => sounding() == 'gaplllllll2');
    await until(() => clock.made.length == 2 && clock.pending != null, why: 'second song ends');
    expect(p.current.value!.id, 'gaplllllll1', reason: 'wrapped to the first');
    expect(sounding(), isNull);
    clock.elapse(const Duration(milliseconds: 2500));
    await until(() => sounding() == 'gaplllllll1');

    await p.setRepeatMode(AudioServiceRepeatMode.one);
    await until(() => clock.made.length == 3 && clock.pending != null, why: 'repeat one: gap too');
    expect(p.current.value!.id, 'gaplllllll1');
    expect(sounding(), isNull);
    clock.elapse(const Duration(milliseconds: 2500));
    await until(() => sounding() == 'gaplllllll1');
    await p.setRepeatMode(AudioServiceRepeatMode.none);
  });

  test('autoplay radio: the added song also waits out the gap', () async {
    sv.settings.autoplay = true;
    await p.playItems([s('gapmmmmmmm1')]);
    await until(() => clock.pending != null, why: 'radio song after the gap');
    expect(p.current.value!.id, isNot('gapmmmmmmm1'));
    expect(sounding(), isNull);
    clock.elapse(const Duration(milliseconds: 2500));
    await until(() => sounding() != null);
  });

  test('real clock: the next song starts ~2.5 s after the end', () async {
    p.gapTimer = Timer.new;
    await p.playItems([s('gapnnnnnnn1'), s('gapnnnnnnn2')]);
    await until(() => p.inGap, why: 'gap');
    final t0 = DateTime.now();
    await until(() => sounding() == 'gapnnnnnnn2', ms: 6000);
    final waited = DateTime.now().difference(t0).inMilliseconds;
    expect(waited, inInclusiveRange(2300, 3200));
  });

  test('a hand-set Automix keeps its pick across restarts (no switch-off on upgrade)', () async {
    final b = await Hive.openBox('settings');
    await b.put('automix', true);
    final s1 = Settings();
    await s1.open();
    expect(s1.automix, isTrue);
    s1.automix = false;
    await settle();
    final s2 = Settings();
    await s2.open();
    expect(s2.automix, isFalse);
    await b.delete('automix');
  });

  test('Listen together: the guest gets the next song when the host\'s gap ends, in sync', () async {
    ListenTogether.hostAnswerWait = const Duration(seconds: 2);
    ListenTogether.heartbeat = const Duration(milliseconds: 200);
    durations['gapparty001'] = 3000;
    durations['gapparty002'] = 30000;
    final guestH = ByteAudioHandler(resolver: sv.resolver, yt: sv.yt, library: sv.library, settings: sv.settings);
    guestH.gapTimer = clock.make; // the guest never waits on its own: the host leads
    final bus = pb.FakePartyBus();
    final hp = HandlerSyncPlayer(p), gp = HandlerSyncPlayer(guestH);
    final host = ListenTogether(player: hp, deviceId: 'host-1', displayName: () => 'Apurba', net: pb.FakePartyNet(bus), store: MemoryPartyStore());
    final guest = ListenTogether(player: gp, deviceId: 'guest-1', displayName: () => 'Rahul', net: pb.FakePartyNet(bus), store: MemoryPartyStore());
    try {
      await p.playItems([s('gapparty001', sec: 3), s('gapparty002', sec: 30)]);
      expect(await host.host(capacity: 5), isTrue, reason: host.error);
      expect(await guest.join(host.code!), isTrue, reason: guest.error);
      await until(() => guestH.current.value?.id == 'gapparty001' && guestH.audible, why: 'guest hears song 1');
      // song 1 ends on the host → the gap; the guest gets song 2 paused
      await until(() => p.inGap, why: 'host gap');
      final hostGap = clock.pending!;
      final t0 = DateTime.now();
      while (guestH.current.value?.id != 'gapparty002') {
        if (DateTime.now().difference(t0).inSeconds > 6) {
          fail('guest never showed song 2: guest ${guestH.current.value?.id} audible ${guestH.audible}; '
              'guest log ${guest.activity.map((a) => '${a.who}: ${a.what}').toList()} / host log ${host.activity.map((a) => '${a.who}: ${a.what}').toList()} last ${guest.last?.item?.id} v${guest.last?.v} host last v${host.last?.v} ${host.last?.item?.id}');
        }
        await settle(20);
      }
      await settle(400);
      expect(guestH.audible, isFalse, reason: 'guest silent while the host waits');
      expect(hostGap.isActive, isTrue);
      // the host's gap ends → both play song 2 together
      hostGap.fire();
      await until(() => p.audible, ms: 1000);
      await until(() => guestH.audible, ms: 2000, why: 'guest starts with the host');
      await settle(300);
      final drift = (p.position.inMilliseconds - guestH.position.inMilliseconds).abs();
      expect(drift, lessThan(ListenTogether.driftLimitMs), reason: 'in sync');
      expect(guest.activity.where((a) => a.what == 'Played'), isEmpty, reason: 'the auto start is not logged as a tap: ${guest.activity.map((a) => '${a.who}: ${a.what}').toList()} / host ${host.activity.map((a) => '${a.who}: ${a.what}').toList()}');
    } finally {
      await host.leave();
      await guest.leave();
      hp.dispose();
      gp.dispose();
      await guestH.stop();
      await guestH.disposeAll();
    }
  });
}
