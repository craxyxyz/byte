import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/settings.dart';
import 'package:byte/lock/handler_lock_player.dart';
import 'package:byte/lock/lock_bridge.dart';
import 'package:byte/lock/lock_player.dart';
import 'package:byte/lock/lock_screen_view.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/screens/lock_screen_settings.dart';
import 'package:byte/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// A player double for the lock screen: records what was pressed.
class FakeLockPlayer extends LockPlayer {
  LockSnapshot _s;
  final List<String> calls = [];
  FakeLockPlayer(this._s);
  set snapshot(LockSnapshot s) {
    _s = s;
    notifyListeners();
  }

  @override
  LockSnapshot get state => _s;
  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> next() async => calls.add('next');
  @override
  Future<void> previous() async => calls.add('previous');
  @override
  Future<void> seek(Duration to) async => calls.add('seek ${to.inSeconds}');
  @override
  Future<void> setVolume(double v) async => calls.add('volume ${v.toStringAsFixed(1)}');
}

final _now = DateTime(2026, 11, 2, 15, 7);

LockSnapshot _snap({bool playing = false, double? volume = 0.5}) => LockSnapshot(
  track: const LockTrack(title: 'Kesariya', artist: 'Arijit Singh', duration: Duration(minutes: 4, seconds: 28)),
  playing: playing,
  position: const Duration(seconds: 6),
  positionAt: _now,
  volume: volume,
);

Future<void> _pumpView(WidgetTester t, LockPlayer p, {VoidCallback? onUnlock, VoidCallback? onHide}) async {
  t.view.devicePixelRatio = 2;
  t.view.physicalSize = const Size(800, 1800);
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: LockScreenView(player: p, now: () => _now, onUnlock: onUnlock, onHide: onHide),
      ),
    ),
  );
}

/// Settings notify after the value is written to disk.
Future<void> _saved() => Future<void>.delayed(const Duration(milliseconds: 60));

Rect _artRect(WidgetTester t) => t.getRect(find.byKey(const ValueKey('lock-art')));

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    Services.i = sv;
  });

  group('bridge (what Android is told)', () {
    late List<String> sent;
    setUp(() {
      sent = [];
      LockScreenBridge.invoke = (m, [a]) async {
        sent.add(m);
        return null;
      };
    });
    tearDown(() => LockScreenBridge.invoke = (m, [a]) => LockScreenBridge.channel.invokeMethod<Object?>(m, a));

    PlaybackState ps(bool playing, [AudioProcessingState p = AudioProcessingState.ready]) => PlaybackState(playing: playing, processingState: p);

    test('armed while playing, disarmed when the setting is off, re-armed when on', () async {
      final ctl = StreamController<PlaybackState>.broadcast();
      sv.settings.lockScreenPlayer = true;
      await _saved();
      final b = LockScreenBridge(settings: sv.settings, playback: ctl.stream)..start();
      await pumpEventQueue();
      expect(sent, ['disarm']); // nothing playing yet: no receiver
      ctl.add(ps(true));
      await pumpEventQueue();
      expect(sent.last, 'arm');
      sv.settings.lockScreenPlayer = false;
      await _saved();
      expect(sent.last, 'disarm');
      expect(b.armed, isFalse);
      ctl.add(ps(true)); // still playing, setting off → stays off
      await pumpEventQueue();
      expect(sent.where((m) => m == 'arm').length, 1);
      sv.settings.lockScreenPlayer = true;
      await _saved();
      expect(sent.last, 'arm');
      b.stop();
      await ctl.close();
      expect(sent.last, 'disarm');
    });

    test('a pause keeps it for the grace period, then disarms; stop disarms at once', () async {
      final ctl = StreamController<PlaybackState>.broadcast();
      sv.settings.lockScreenPlayer = true;
      await _saved();
      final b = LockScreenBridge(settings: sv.settings, playback: ctl.stream, pausedGrace: const Duration(milliseconds: 60))..start();
      ctl.add(ps(true));
      await pumpEventQueue();
      expect(b.armed, isTrue);
      ctl.add(ps(false));
      await pumpEventQueue();
      expect(b.armed, isTrue, reason: 'still armed right after a pause');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(b.armed, isFalse);
      ctl.add(ps(true));
      await pumpEventQueue();
      expect(b.armed, isTrue);
      ctl.add(ps(false, AudioProcessingState.idle));
      await pumpEventQueue();
      expect(b.armed, isFalse);
      b.stop();
      await ctl.close();
    });
  });

  group('setting', () {
    test('Lock screen player is on by default and can be turned off', () async {
      final st = Settings();
      expect(st.lockScreenPlayer, isTrue);
      sv.settings.lockScreenPlayer = false;
      expect(sv.settings.lockScreenPlayer, isFalse);
      sv.settings.lockScreenPlayer = true;
      expect(sv.settings.lockScreenPlayer, isTrue);
    });

    testWidgets('settings page: the switch turns it off and on; brand help shows', (t) async {
      sv.settings.lockScreenPlayer = true;
      const status = LockScreenStatus(sdk: 34, manufacturer: 'xiaomi', brand: 'redmi', miui: true, canFullScreenIntent: false);
      await t.pumpWidget(
        MaterialApp(
          theme: ByteTheme.build(Brightness.light),
          home: const LockScreenSettingsScreen(status: status),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Lock screen player'), findsWidgets);
      expect(find.text('Xiaomi permissions'), findsOneWidget);
      expect(find.textContaining('Show on Lock screen'), findsWidgets);
      expect(find.text('Not allowed yet: tap to allow'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('lock-toggle')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80))); // the setting is saved to disk first
      await t.pump(const Duration(milliseconds: 300));
      expect(sv.settings.lockScreenPlayer, isFalse);
      expect(find.textContaining('Off: Byte doesn'), findsOneWidget);
      expect(find.text('Xiaomi permissions'), findsNothing);
      await t.tap(find.byKey(const ValueKey('lock-toggle')));
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80))); // the setting is saved to disk first
      await t.pump(const Duration(milliseconds: 300));
      expect(sv.settings.lockScreenPlayer, isTrue);
      await t.pumpWidget(const SizedBox());
      await t.runAsync(_saved);
    });

    test('brand notes: Samsung, vivo, OPPO, others', () {
      expect(oemNote(const LockScreenStatus(manufacturer: 'samsung', brand: 'samsung')), contains('Samsung'));
      expect(oemNote(const LockScreenStatus(manufacturer: 'vivo', brand: 'iqoo')), contains('vivo'));
      expect(oemNote(const LockScreenStatus(manufacturer: 'oneplus', brand: 'oneplus')), contains('OnePlus'));
      expect(oemNote(const LockScreenStatus(manufacturer: 'google', brand: 'google')), contains('lock screen'));
      expect(const LockScreenStatus(sdk: 33, canFullScreenIntent: false).needsFullScreenPermission, isFalse);
      expect(const LockScreenStatus(sdk: 34, canFullScreenIntent: false).needsFullScreenPermission, isTrue);
    });
  });

  group('expand / shrink artwork', () {
    testWidgets('tap the art: grows to full width with the animation, tap again: back to small', (t) async {
      final p = FakeLockPlayer(_snap());
      await _pumpView(t, p);
      final state = t.state<LockScreenViewState>(find.byType(LockScreenView));
      final small = _artRect(t);
      expect(small.width, 56);
      expect(state.expanded, isFalse);

      await t.tap(find.byKey(const ValueKey('lock-art')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 200));
      final mid = _artRect(t);
      expect(mid.width, greaterThan(56));
      expect(mid.width, lessThan(400));
      expect(state.expanded, isTrue);
      await t.pumpAndSettle();
      final big = _artRect(t);
      expect(state.progress, 1.0);
      // edge to edge from the top, no box: the poster fades into the background
      expect(big.width, 400);
      expect(big.left, 0);
      expect(big.top, 0);
      expect(big.height, lessThanOrEqualTo(400));
      expect(find.byKey(const ValueKey('lock-art-fade')), findsOneWidget);
      // Controls moved under the big cover.
      expect(t.getRect(find.byKey(const ValueKey('lock-play'))).top, greaterThan(big.bottom));
      expect(find.byKey(const ValueKey('lock-clock-small')), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('lock-art')));
      await t.pumpAndSettle();
      expect(state.progress, 0.0);
      expect(state.expanded, isFalse);
      expect(_artRect(t).width, 56);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('system "remove animations" switches at once', (t) async {
      final p = FakeLockPlayer(_snap());
      t.view.physicalSize = const Size(800, 1800);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(size: Size(400, 900), disableAnimations: true),
            child: Scaffold(
              body: LockScreenView(player: p, now: () => _now),
            ),
          ),
        ),
      );
      await t.tap(find.byKey(const ValueKey('lock-art')));
      await t.pump();
      expect(_artRect(t).width, 400);
      await t.pumpWidget(const SizedBox());
    });
  });

  group('lock-screen UI', () {
    testWidgets('shows clock, date, title, artist, times and controls; buttons drive the player', (t) async {
      final p = FakeLockPlayer(_snap());
      var unlocked = 0, hidden = 0;
      await _pumpView(t, p, onUnlock: () => unlocked++, onHide: () => hidden++);
      expect(find.text('3:07'), findsWidgets);
      expect(find.text('Monday, 2 November'), findsOneWidget);
      expect(find.text('Kesariya'), findsOneWidget);
      expect(find.text('Arijit Singh'), findsOneWidget);
      expect(find.text('0:06'), findsOneWidget);
      expect(find.text('-4:22'), findsOneWidget);
      expect(find.byKey(const ValueKey('lock-volume')), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('lock-play')));
      await t.tap(find.byKey(const ValueKey('lock-next')));
      await t.tap(find.byKey(const ValueKey('lock-prev')));
      expect(p.calls, ['play', 'next', 'previous']);
      p.snapshot = _snap(playing: true);
      await t.pump();
      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('lock-play')));
      expect(p.calls.last, 'pause');
      // Live position: 2 s later the elapsed time moved on.
      p.snapshot = LockSnapshot(
        track: _snap().track,
        playing: true,
        position: const Duration(seconds: 6),
        positionAt: _now.subtract(const Duration(seconds: 2)),
      );
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('0:08'), findsOneWidget);
      expect(find.byKey(const ValueKey('lock-volume')), findsNothing, reason: 'no volume when the phone can\'t set it');
      p.snapshot = _snap();
      await t.pump();
      // Tap the progress bar halfway → seek to the middle.
      final bar = t.getRect(find.byKey(const ValueKey('lock-progress')));
      await t.tapAt(bar.center);
      await t.pump();
      expect(p.calls.last, 'seek 134');
      // Swipe up unlocks, swipe down hides.
      await t.fling(find.byType(LockScreenView), const Offset(0, -300), 1500);
      await t.pump();
      expect(unlocked, 1);
      await t.fling(find.byType(LockScreenView), const Offset(0, 300), 1500);
      await t.pump();
      expect(hidden, 1);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('nothing playing: placeholder, disabled buttons', (t) async {
      final p = FakeLockPlayer(LockSnapshot());
      await _pumpView(t, p);
      expect(find.text('Nothing playing'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('lock-play')));
      expect(p.calls, isEmpty);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('driven by the app\'s real player (fake audio): title, artist, play state', (t) async {
      sv.settings.autoplay = false;
      sv.settings.verifyStreams = false;
      final item = Item(kind: ItemKind.song, id: 'lockAAAAAA1', title: 'Tum Hi Ho', artists: const [ArtistRef('Arijit Singh')], durationSec: 262);
      await t.runAsync(() => sv.player.playItems([item]));
      final p = HandlerLockPlayer(sv.player);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await _pumpView(t, p);
      await t.pump();
      expect(find.text('Tum Hi Ho'), findsOneWidget);
      expect(find.text('Arijit Singh'), findsOneWidget);
      expect(p.state.track?.duration, isNotNull);
      expect(find.byKey(const ValueKey('lock-remaining')), findsOneWidget);
      expect(p.state.playing, isTrue);
      await t.runAsync(() => sv.player.pause());
      await t.pump();
      expect(p.state.playing, isFalse);
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
      await t.runAsync(() => p.play());
      expect(sv.player.playing, isTrue);
      await t.runAsync(() => sv.player.stop());
      p.dispose();
      await t.pumpWidget(const SizedBox());
    });
  });

  group('native bridge of the lock window', () {
    test('parses the media-session snapshot', () {
      final s = ChannelLockPlayer.stateFromMap({
        'title': 'Thuli Thuli',
        'artist': ' ',
        'durationMs': 215000,
        'artUri': 'https://lh3.googleusercontent.com/abc=w544-h544-l90-rj',
        'playing': true,
        'positionMs': 30000,
        'speed': 1.0,
        'volume': 0.4,
      }, now: _now);
      expect(s.track!.title, 'Thuli Thuli');
      expect(s.track!.artist, isNull);
      expect(s.track!.duration, const Duration(seconds: 215));
      expect(s.positionNow(_now.add(const Duration(seconds: 5))), const Duration(seconds: 35));
      expect(s.positionNow(_now.add(const Duration(minutes: 9))), const Duration(seconds: 215), reason: 'clamped to the end');
      expect(s.volume, 0.4);
      expect(hiResArt(s.track!.artUrl!), 'https://lh3.googleusercontent.com/abc=w1080-h1080-l90-rj');
      expect(ChannelLockPlayer.stateFromMap(const {}).track, isNull);
    });

    test('buttons go to the native side', () async {
      const ch = MethodChannel('byte/lockplayer.test');
      final got = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (c) async {
        got.add('${c.method}${c.arguments == null ? '' : ' ${c.arguments}'}');
        return null;
      });
      final p = ChannelLockPlayer(ch);
      await p.play();
      await p.next();
      await p.previous();
      await p.seek(const Duration(seconds: 12));
      await p.unlock();
      await p.hide();
      expect(got, ['play', 'next', 'previous', 'seek {ms: 12000}', 'unlock', 'hide']);
    });

    test('clock text', () {
      expect(lockTime(DateTime(2026, 11, 2, 15, 7)), '3:07');
      expect(lockTime(DateTime(2026, 11, 2, 0, 5)), '12:05');
      expect(lockTime(DateTime(2026, 11, 2, 15, 7), h24: true), '15:07');
      expect(lockDateShort(DateTime(2026, 11, 2)), 'Mon 2 Nov');
    });
  });
}
