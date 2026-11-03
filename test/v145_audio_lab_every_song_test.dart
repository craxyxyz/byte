// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba): "Audio Lab wale features saare songs mein achhe se kaam
// karein". The Audio Lab must reach every song: the next one after the 2.5 s
// gap, after a skip, on the other deck, radio songs, a party guest, after a
// restart, across pause/resume. The real player against the fake audio
// engine, which hands out a new Android player session per player like the
// phone does; a fake effects backend records what each session got.
import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/audiolab/mpv_filters.dart';
import 'package:byte/core/models.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/player/sync_adapter.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_sound_backend.dart';
import 'helpers.dart';
import 'v145_song_gap_test.dart' show FakeClock;

Item s(String id, {int sec = 2}) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: sec);

Map<String, Object?> mySound() => {
  'eqOn': true,
  'preset': 'Bass Booster',
  'nodes': [for (final n in nodesFromBands(eqPresets['Bass Booster']!)) n.toJson()],
  'rvOn': true,
  'ldOn': true,
  'bal': -0.3,
  'mono': false,
  'semis': 0.0,
};

void main() {
  late Services sv;
  late ByteAudioHandler p;
  late FakeClock clock;
  late FakeSoundBackend fx;
  late AudioLabEngine engine;
  late List<StreamSubscription<int?>> subs;

  setUp(() async {
    FakePlayerPlatform.androidSessions = true;
    sv = await makeServices();
    p = sv.player;
    clock = FakeClock();
    p.gapTimer = clock.make;
    sv.settings.autoplay = false;
    sv.settings.normalizeVolume = false;
    sv.settings.crossfadeSeconds = 0;
    sv.settings.automix = false;
    await p.setRepeatMode(AudioServiceRepeatMode.none);
    fakeAudio.durationFor = (_) => const Duration(milliseconds: 1200);
    sv.lab.openForTest(mySound());
    fx = FakeSoundBackend();
    engine = AudioLabEngine(sv.lab, backend: fx);
    subs = engine.watch([for (final d in p.decks) d.androidAudioSessionIdStream]);
    await engine.start();
  });
  tearDown(() async {
    for (final x in subs) {
      await x.cancel();
    }
    await p.stop();
    FakePlayerPlatform.androidSessions = false;
  });

  Future<void> until(bool Function() ok, {int ms = 8000, String? why}) async {
    final end = DateTime.now().add(Duration(milliseconds: ms));
    while (!ok()) {
      if (DateTime.now().isAfter(end)) fail('timed out${why == null ? '' : ': $why'}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The session of the player making sound right now.
  int? soundingSession() {
    for (final x in fakeAudio.players.values) {
      if (x.playing && x.state.name == 'ready') return x.session;
    }
    return null;
  }

  String? sounding() {
    for (final x in fakeAudio.players.values) {
      if (x.playing && x.state.name == 'ready') return RegExp(r'media\.example/([^/]+)/').firstMatch(x.uri ?? '')?.group(1);
    }
    return null;
  }

  String want() => jsonEncode(sv.lab.nativeConfig());

  /// The song playing now has exactly the Audio Lab's sound, and no old
  /// player still holds effects.
  Future<void> expectSoundOn(String id, String why) async {
    await until(() => sounding() == id, why: '$why: $id plays');
    final sess = soundingSession()!;
    await until(() => fx.perSession[sess] != null, ms: 2000, why: '$why: effects on the new player');
    expect(jsonEncode(fx.perSession[sess]), want(), reason: why);
    expect(fx.sessions.length, lessThanOrEqualTo(2), reason: '$why: old players released (${fx.log.join(', ')})');
  }

  test('every song gets the sound: first song, after the 2.5 s gap, after a skip, after Prev', () async {
    await p.playItems([s('lab0000001'), s('lab0000002'), s('lab0000003'), s('lab0000004')]);
    await expectSoundOn('lab0000001', 'first song');
    await until(() => clock.pending != null, why: 'first song ends, gap starts');
    clock.elapse(const Duration(milliseconds: 2500));
    await expectSoundOn('lab0000002', 'after the gap');
    await p.skipToNext();
    await expectSoundOn('lab0000003', 'after a skip');
    await p.skipToPrevious();
    await expectSoundOn('lab0000002', 'after Prev');
  });

  test('ten songs in a row, each on a fresh player: effects never pile up on old players (the 1.4.4 cause)', () async {
    sv.settings.preloadNext = true; // the default: the next song waits loaded on the other deck
    await p.playItems([for (var i = 0; i < 10; i++) s('labmany${i.toString().padLeft(3, '0')}')]);
    for (var i = 0; i < 10; i++) {
      await expectSoundOn('labmany${i.toString().padLeft(3, '0')}', 'song ${i + 1}');
      if (i < 9) {
        await until(() => clock.pending != null, why: 'song ${i + 1} ends');
        clock.elapse(const Duration(milliseconds: 2500));
      }
    }
    final attached = fx.log.where((l) => l.startsWith('attach')).length;
    expect(attached, greaterThanOrEqualTo(8), reason: 'songs alternate decks; a stopped deck comes back on a new session (${fx.log})');
    expect(fx.log.where((l) => l.startsWith('detach')).length, attached - fx.sessions.length);
  });

  test('a change in the Audio Lab reaches the song playing now and the next one', () async {
    await p.playItems([s('labchg0001'), s('labchg0002')]);
    await expectSoundOn('labchg0001', 'before');
    sv.lab.applyPreset('Treble Booster');
    sv.lab.balance = 0.5;
    await until(() => jsonEncode(fx.perSession[soundingSession()]) == want(), ms: 2000, why: 'live change');
    await p.skipToNext();
    await expectSoundOn('labchg0002', 'next song keeps the change');
    expect(fx.perSession[soundingSession()]!['balance'], 0.5);
  });

  test('pause / resume keeps the sound (same player, nothing re-made)', () async {
    await p.playItems([s('labpau0001', sec: 30)]);
    fakeAudio.durationFor = (_) => const Duration(seconds: 30);
    await expectSoundOn('labpau0001', 'playing');
    final before = soundingSession();
    await p.pause();
    await p.play();
    await expectSoundOn('labpau0001', 'after resume');
    expect(soundingSession(), before);
  });

  test('the prepared second deck: when it takes over it already has the sound', () async {
    sv.settings.crossfadeSeconds = 2; // a real hand-off onto the other deck
    fakeAudio.durationFor = (_) => const Duration(milliseconds: 3500);
    await p.playItems([s('labdeck001', sec: 4), s('labdeck002', sec: 4)]);
    await expectSoundOn('labdeck001', 'deck A');
    await until(() => p.current.value?.id == 'labdeck002', ms: 9000, why: 'hand-off');
    await expectSoundOn('labdeck002', 'deck B');
  });

  test('radio / autoplay songs get it too', () async {
    sv.settings.autoplay = true;
    await p.playItems([s('labseed001')]);
    await expectSoundOn('labseed001', 'seed');
    await until(() => p.upcomingCount > 0, why: 'radio fills');
    await p.skipToNext();
    await until(() => p.current.value != null && p.current.value!.id != 'labseed001', why: 'a radio song');
    await expectSoundOn(p.current.value!.id, 'radio song');
  });

  test('a party guest\'s songs (loaded by the party) get it', () async {
    final guest = HandlerSyncPlayer(p);
    await guest.load(s('labguest01'), Duration.zero, play: true);
    await expectSoundOn('labguest01', 'guest song 1');
    await guest.load(s('labguest02'), const Duration(milliseconds: 200), play: true);
    await expectSoundOn('labguest02', 'guest song 2');
  });

  test('after a restart the saved sound is applied before the first song', () async {
    // what a fresh start does: open the saved settings, start the engine
    final again = AudioLab()..openForTest(sv.lab.debugAll);
    final fx2 = FakeSoundBackend();
    final e2 = AudioLabEngine(again, backend: fx2);
    await e2.start();
    expect(jsonEncode(fx2.applied.last), jsonEncode(again.nativeConfig()));
    await e2.deckSession(0, 4242);
    expect(jsonEncode(fx2.perSession[4242]), jsonEncode(again.nativeConfig()));
    expect(fx2.perSession[4242]!['eqOn'], isTrue);
  });

  test('two decks share nothing wrong: a session still used by the other deck is kept', () async {
    final f = FakeSoundBackend();
    final e = AudioLabEngine(AudioLab()..openForTest(mySound()), backend: f);
    await e.deckSession(0, 10);
    await e.deckSession(1, 11);
    await e.deckSession(0, 12);
    expect(f.sessions, {11, 12});
    await e.deckSession(1, 12); // both on one (never on a phone, but safe)
    expect(f.sessions, {12});
    expect(f.log, ['attach 10', 'attach 11', 'attach 12', 'detach 10', 'detach 11']);
  });

  group('what each device can play', () {
    test('a guest is told what his device skips of the host\'s sound', () {
      final host = {...mySound(), 'semis': -2.0, 'xfOn': true};
      expect(SoundCaps.android.skippedIn(host), isEmpty);
      expect(SoundCaps.ios.skippedIn(host), ['reverb', 'loudness', 'crossfeed', 'pitch']);
      expect(SoundCaps.web.skippedIn(host), ['equalizer', 'reverb', 'loudness', 'crossfeed', 'balance', 'pitch']);
      expect(SoundCaps.desktop.skippedIn(host), isEmpty);
    });

    test('computer: the equalizer, balance, loudness become the player\'s filter chain', () {
      final lab = AudioLab()..openForTest(mySound());
      final g = mpvFilterGraph(lab);
      expect(g, contains('lowshelf=f='));
      expect(g, contains('equalizer=f='));
      expect(g, contains('pan=stereo|c0=1.00*c0|c1=0.70*c1'));
      expect(g, contains('acompressor='));
      expect(g, contains('alimiter=limit=0.89'));
      expect(g, contains('aecho='));
      expect(mpvAf(lab, tempo: 'scaletempo:scale=1.00000000'), startsWith('scaletempo:scale=1.00000000,lavfi=['));
      expect(mpvFilterGraph(AudioLab()..openForTest()), '', reason: 'untouched sound = no filters');
      final mono = AudioLab()..openForTest({'mono': true});
      expect(mpvFilterGraph(mono), 'aformat=channel_layouts=stereo,pan=stereo|c0=0.50*c0+0.50*c1|c1=0.50*c0+0.50*c1');
    });

    test('iPhone: the Audio Lab curve goes to the tap as 10 points, plus balance and mono', () async {
      final b = IosSoundBackend();
      final lab = AudioLab()..openForTest(mySound());
      await b.apply(lab, lab.nativeConfig());
      expect(b.lastEq!['enabled'], isTrue);
      final gains = (b.lastEq!['gains'] as List).cast<double>();
      expect(gains.first, greaterThan(3), reason: 'bass boosted');
      expect(gains.last.abs(), lessThan(0.5));
      expect(b.lastChannels, {'mono': false, 'balance': -0.3});
      var restored = false;
      IosSoundBackend.restoreClassic = () => restored = true;
      lab.eqOn = false;
      await b.apply(lab, lab.nativeConfig());
      expect(b.lastEq!['enabled'], isFalse);
      expect(restored, isTrue, reason: 'the classic equalizer gets the tap back');
      IosSoundBackend.restoreClassic = null;
      IosSoundBackend.labOwnsEq = false;
    });
  });
}
