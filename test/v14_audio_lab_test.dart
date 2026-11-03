import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/player/crossfade.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/screens/audio_lab_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

// Byte 1.4: Settings → Audio Lab.
void main() {
  group('equalizer math (what you see is what you hear)', () {
    test('flat is exactly 0 dB everywhere', () {
      final n = nodesFromBands(eqPresets['Flat']!);
      for (final f in EqMath.logFreqs(50)) {
        expect(EqMath.curveDb(n, f), closeTo(0, 1e-9));
      }
    });
    test('a peak gives its gain at its own frequency and nothing far away', () {
      const n = [EqNode(EqNodeType.peak, 1000, 6, 1.41)];
      expect(EqMath.curveDb(n, 1000), closeTo(6, 0.05));
      expect(EqMath.curveDb(n, 50).abs(), lessThan(0.2));
      expect(EqMath.curveDb(n, 15000).abs(), lessThan(0.3));
    });
    test('shelves lift one end only', () {
      const lo = [EqNode(EqNodeType.lowShelf, 100, 8, 0.71)];
      expect(EqMath.curveDb(lo, 25), closeTo(8, 0.5));
      expect(EqMath.curveDb(lo, 5000).abs(), lessThan(0.2));
      const hi = [EqNode(EqNodeType.highShelf, 8000, -6, 0.71)];
      expect(EqMath.curveDb(hi, 19000), closeTo(-6, 0.8));
      expect(EqMath.curveDb(hi, 200).abs(), lessThan(0.2));
    });
    test('auto preamp lowers by the biggest boost; the phone gets 32 bands', () {
      final n = nodesFromBands(eqPresets['Bass Booster']!);
      final pre = EqMath.autoPreamp(n);
      expect(pre, lessThan(-4));
      expect(pre, greaterThan(-9));
      final b = EqMath.bands(n);
      expect(b.cutoffs.length, 32);
      expect(b.gains.first, greaterThan(3));
      expect(b.gains.last.abs(), lessThan(0.5));
      for (var i = 1; i < b.cutoffs.length; i++) {
        expect(b.cutoffs[i], greaterThan(b.cutoffs[i - 1]));
      }
    });
    test('every preset has 10 points within ±15 dB', () {
      for (final e in eqPresets.entries) {
        expect(e.value.length, 10, reason: e.key);
        expect(e.value.every((g) => g.abs() <= 15), isTrue);
      }
      expect(eqPresets.keys, containsAll(['Flat', 'Acoustic', 'Bass Booster', 'Bass Reducer']));
    });
  });

  group('Audio Lab settings → the phone', () {
    late AudioLab lab;
    setUp(() => lab = AudioLab()..openForTest());

    test('editing points: add, move (clamped), remove, presets, custom save', () {
      lab.applyPreset('Rock');
      expect(lab.preset, 'Rock');
      lab.addNode(3000);
      expect(lab.nodes.length, 11);
      expect(lab.preset, isNull, reason: 'edited = custom');
      final i = lab.nodes.indexWhere((n) => n.f == 3000);
      lab.setNode(i, lab.nodes[i].copyWith(g: 40, f: 99999));
      expect(lab.nodes.last.g, 15);
      expect(lab.nodes.last.f, 20000);
      lab.removeNode(lab.nodes.length - 1);
      expect(lab.nodes.length, 10);
      lab.saveCustom('Mine');
      lab.resetEq();
      expect(lab.nodes.every((n) => n.g == 0), isTrue);
      lab.applyCustom('Mine');
      expect(lab.preset, 'Mine');
      expect(lab.nodes.any((n) => n.g != 0), isTrue);
    });

    test('equalizer off sends a flat curve and no preamp', () {
      lab.applyPreset('Bass Booster');
      lab.eqOn = false;
      final c = lab.nativeConfig();
      expect((c['gains'] as List).every((g) => g == 0), isTrue);
      expect(c['inputGain'], 0);
      lab.eqOn = true;
      final c2 = lab.nativeConfig();
      expect((c2['gains'] as List).first as double, greaterThan(3));
      expect(c2['inputGain'] as double, lessThan(0), reason: 'auto preamp');
      expect(c2['limiterOn'], isTrue);
    });

    test('loudness modes set boost + compression; the limiter is on', () {
      lab.loudOn = true;
      lab.loudMode = LoudMode.night;
      final c = lab.nativeConfig();
      expect(c['mbcOn'], isTrue);
      expect(c['inputGain'], 5.0);
      expect(c['ratio'] as double, greaterThan(4));
      expect(c['limiterOn'], isTrue);
    });

    test('reverb maps into the phone\'s units, within its limits', () {
      lab.reverbOn = true;
      for (final p in ReverbPreset.values) {
        lab.applyReverbPreset(p);
        final r = AudioLab.reverbNative(lab.nativeConfig());
        expect(r['decayTime']!, inInclusiveRange(100, 20000));
        expect(r['roomLevel']!, inInclusiveRange(-9000, 0));
        expect(r['reverbLevel']!, inInclusiveRange(-9000, 2000));
        expect(r['decayHFRatio']!, inInclusiveRange(100, 2000));
      }
      lab.applyReverbPreset(ReverbPreset.room);
      final small = AudioLab.reverbNative(lab.nativeConfig())['decayTime']!;
      lab.setRv('size', 1);
      expect(AudioLab.reverbNative(lab.nativeConfig())['decayTime']!, greaterThan(small));
    });

    test('crossfeed rests on speakers; mono and balance pass through', () {
      lab.crossfeedOn = true;
      lab.crossfeedStrength = CrossfeedStrength.strong;
      expect(lab.nativeConfig()['crossfeed'], isTrue);
      expect(lab.nativeConfig()['xfDb'], -4.5);
      lab.crossfeedSpeakers = true;
      expect(lab.nativeConfig()['crossfeed'], isFalse);
      lab.mono = true;
      lab.balance = -0.3;
      expect(lab.nativeConfig()['mono'], isTrue);
      expect(lab.nativeConfig()['balance'], -0.3);
    });

    test('speed and pitch: kept pitch, the slowed way, semitones', () {
      expect(lab.pitchFor(0.85), 1.0);
      lab.preservePitch = false;
      expect(lab.pitchFor(0.85), closeTo(0.85, 1e-9));
      lab.preservePitch = true;
      lab.pitchSemis = 12;
      expect(lab.pitchFor(1), closeTo(2, 1e-9));
    });

    test('gapless albums stay together (only when turned on, 1.4.5); other songs blend', () {
      expect(lab.gapless, isFalse, reason: '1.4.5: off unless turned on by hand');
      expect(lab.keepTogether('alb1', 'alb1'), isFalse);
      lab.gapless = true;
      expect(lab.keepTogether('alb1', 'alb1'), isTrue);
      expect(lab.keepTogether('alb1', 'alb2'), isFalse);
      expect(lab.keepTogether(null, null), isFalse);
      lab.gapless = false;
      expect(lab.keepTogether('alb1', 'alb1'), isFalse);
    });

    test('blend style "Straight" is a linear fade; default is equal power', () {
      CrossfadePlan.linear = false;
      final (o, i) = CrossfadePlan.volumes(0.5);
      expect(o, closeTo(0.7071, 1e-3));
      expect(i, closeTo(0.7071, 1e-3));
      CrossfadePlan.linear = true;
      expect(CrossfadePlan.volumes(0.5), (0.5, 0.5));
      CrossfadePlan.linear = false;
    });

    test('the engine sends every change to the phone (debounced)', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('byte/audiolab'), (c) async {
        calls.add(c);
        return c.method == 'caps' ? {'bandProcessor': true} : true;
      });
      final eng = AudioLabEngine(lab);
      await eng.start();
      await eng.attach(42);
      await eng.attach(42);
      expect(calls.where((c) => c.method == 'attach').length, 1);
      lab.eqOn = true;
      lab.mono = true;
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final last = calls.lastWhere((c) => c.method == 'config').arguments as Map;
      expect(last['mono'], isTrue);
      expect(last['eqOn'], isTrue);
      expect(last['reverb'], isA<Map>());
    });
  });

  group('Audio Lab screens', () {
    setUp(() async {
      final sv = await makeServices();
      Services.i = sv;
      sv.lab.openForTest();
    });
    Future<void> show(WidgetTester t, Widget w) async {
      t.view.physicalSize = const Size(390 * 3, 4200 * 3);
      t.view.devicePixelRatio = 3;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(home: w));
      await t.pump(const Duration(milliseconds: 300));
    }

    testWidgets('hub: five cards, each opens its page', (t) async {
      await show(t, const AudioLabScreen());
      for (final k in ['lab-eq', 'lab-fx', 'lab-quality', 'lab-transition', 'lab-pass']) {
        expect(find.byKey(ValueKey(k)), findsOneWidget);
      }
      await t.tap(find.byKey(const ValueKey('lab-eq')));
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('eq-graph')), findsOneWidget);
    });

    testWidgets('equalizer: switch on, pick a preset, drag a point', (t) async {
      await show(t, const LabEqualizerScreen());
      final lab = Services.i.lab;
      await t.tap(find.byKey(const ValueKey('eq-on')));
      await t.pump();
      expect(lab.eqOn, isTrue);
      await t.tap(find.text('Bass Booster'));
      await t.pump();
      expect(lab.preset, 'Bass Booster');
      // drag the 1 kHz point up
      final g = t.getRect(find.byKey(const ValueKey('eq-graph')));
      final x = g.left + EqGraph.xOf(1000, g.width);
      final y = g.top + EqGraph.yOf(0, g.height);
      await t.dragFrom(Offset(x, y), const Offset(0, -50));
      await t.pump();
      final n = lab.nodes.firstWhere((n) => (n.f - 1000).abs() < 300);
      expect(n.g, greaterThan(2));
      await t.pump(const Duration(seconds: 1)); // let the double-tap window close
    });

    testWidgets('effects: reverb, crossfeed and mono switches work', (t) async {
      await show(t, const LabEffectsScreen());
      final lab = Services.i.lab;
      for (final k in ['fx-reverb', 'fx-loud', 'fx-crossfeed', 'fx-mono']) {
        await t.tap(find.byKey(ValueKey(k)));
        await t.pump();
      }
      expect([lab.reverbOn, lab.loudOn, lab.crossfeedOn, lab.mono], [true, true, true, true]);
      expect(find.text('Atmos surround decoder'), findsOneWidget);
    });

    testWidgets('transition: Off / Auto / Manual set the player', (t) async {
      await show(t, const LabTransitionScreen());
      final st = Services.i.settings;
      await t.tap(find.text('Manual'));
      await t.pump();
      expect(st.automix, isFalse);
      expect(st.crossfadeSeconds, greaterThan(0));
      await t.tap(find.text('Off'));
      await t.pump();
      expect(st.crossfadeSeconds, 0);
      await t.tap(find.text('Auto'));
      await t.pump();
      expect(st.automix, isTrue);
      await t.tap(find.byKey(const ValueKey('fade-pause')));
      await t.pump();
      expect(Services.i.lab.fadeOnPause, isFalse);
    });

    testWidgets('audio pass: 32-bit switch and honest limits', (t) async {
      await show(t, const LabAudioPassScreen());
      await t.tap(find.byKey(const ValueKey('pass-float')));
      await t.pump();
      expect(Services.i.lab.float32, isTrue);
      expect(find.textContaining('no app can take this over'), findsOneWidget);
    });
  });
}
