import 'dart:math';

import 'package:byte/automix/planner.dart';
import 'package:byte/data/settings.dart';
import 'package:byte/player/crossfade.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'helpers.dart';

void main() {
  group('Automix lead: 8.5 s default, one-time migration', () {
    late Services sv;
    Box box() => Hive.box('settings');
    setUp(() async {
      sv = await makeServices();
      await box().delete('automixLead');
      await box().delete('automixLead2');
    });


    test('fresh install: 8.5 s', () {
      expect(Settings.automixLeadDefault, 8.5);
      expect(sv.settings.automixSeconds, 8.5);
    });

    test('old install with the 4.5 s default (old key): everybody gets 8.5 s once', () async {
      await box().put('automixLead', 4.5);
      expect(sv.settings.automixSeconds, 8.5);
    });

    test('old install with a custom value (old key): also moved to 8.5 s once', () async {
      await box().put('automixLead', 7.0);
      expect(sv.settings.automixSeconds, 8.5);
      await box().put('automixLead', 2.0);
      expect(sv.settings.automixSeconds, 8.5);
    });

    test('a change made after the migration sticks and ignores the old key', () async {
      await box().put('automixLead', 4.5);
      sv.settings.automixSeconds = 11;
      expect(sv.settings.automixSeconds, 11);
      expect(box().get('automixLead2'), 11);
      expect(box().get('automixLead'), 4.5, reason: 'the old key is left alone');
    });

    test('range 2–15 s in half-second steps', () {
      sv.settings.automixSeconds = 99;
      expect(sv.settings.automixSeconds, 15);
      sv.settings.automixSeconds = 0;
      expect(sv.settings.automixSeconds, 2);
      sv.settings.automixSeconds = 8.74;
      expect(sv.settings.automixSeconds, 8.5);
    });
  });

  group('blend curve', () {
    test('endpoints', () {
      expect(equalPowerS(0), (1.0, 0.0));
      final (o, i) = equalPowerS(1);
      expect(o, closeTo(0, 1e-12));
      expect(i, closeTo(1, 1e-12));
      expect(equalPowerS(-3), equalPowerS(0));
      expect(equalPowerS(7), equalPowerS(1));
    });

    test('equal power (out² + in² = 1) and monotonic', () {
      var po = 1.0, pi_ = 0.0;
      for (var k = 0; k <= 200; k++) {
        final (o, i) = equalPowerS(k / 200);
        expect(o * o + i * i, closeTo(1, 1e-9));
        expect(o, lessThanOrEqualTo(po + 1e-12));
        expect(i, greaterThanOrEqualTo(pi_ - 1e-12));
        po = o;
        pi_ = i;
      }
    });

    test('eased: it starts and ends softer than the plain equal-power curve', () {
      final (o, i) = equalPowerS(0.1);
      expect(o, greaterThan(cos(0.1 * pi / 2)));
      expect(i, lessThan(sin(0.1 * pi / 2)));
      final (om, im) = equalPowerS(0.5);
      expect(om, closeTo(sqrt(0.5), 1e-9));
      expect(im, closeTo(sqrt(0.5), 1e-9));
    });

    test('Simple plan uses it; Smart plan is monotonic with an own incoming ramp', () {
      const simple = TransitionPlan(startAtMs: 0, incomingFromMs: 0, fadeMs: 8500, kind: 'simple');
      for (final t in [0.0, 0.2, 0.5, 0.9, 1.0]) {
        expect(simple.volumes(t), equalPowerS(t));
      }
      for (final fades in [false, true]) {
        final smart = TransitionPlan(startAtMs: 0, incomingFromMs: 0, fadeMs: 8500, outFadesItself: fades, kind: 'smart');
        var po = 1.0, pi_ = 0.0;
        for (var k = 0; k <= 100; k++) {
          final (o, i) = smart.volumes(k / 100);
          expect(o, lessThanOrEqualTo(po + 1e-12));
          expect(i, greaterThanOrEqualTo(pi_ - 1e-12));
          po = o;
          pi_ = i;
        }
        expect(smart.volumes(0), (1.0, 0.0));
        expect(smart.volumes(0.75).$2, closeTo(1, 1e-9), reason: 'incoming is up before the outgoing is gone');
        expect(smart.volumes(1).$1, closeTo(0, 1e-12));
      }
    });
  });

  group('planner edge cases at 8.5 s', () {
    test('a normal song: starts 8.5 s before the music ends', () {
      final p = planTransition(outDurationMs: 200000, inDurationMs: 180000, seconds: 8.5, mode: AutomixMode.simple);
      expect((p.startAtMs, p.fadeMs), (191500, 8500));
    });

    test('short song: at most a third of it', () {
      final p = planTransition(outDurationMs: 12000, inDurationMs: 180000, seconds: 8.5, mode: AutomixMode.simple);
      expect(p.fadeMs, 4000);
      expect(p.startAtMs, 8000);
      final q = planTransition(outDurationMs: 180000, inDurationMs: 9000, seconds: 8.5, mode: AutomixMode.simple);
      expect(q.fadeMs, 3000);
    });

    test('long blend hands the bass over; short ones do not (no analysis: fallback never)', () {
      final fb = planTransition(outDurationMs: 200000, inDurationMs: 180000, seconds: 8.5, mode: AutomixMode.simple);
      expect(fb.kind, 'fallback');
      expect(fb.bassSwap, isFalse);
    });

    test('a blend started late shrinks to what is left of the music', () {
      final p = planTransition(outDurationMs: 200000, inDurationMs: 180000, seconds: 8.5, mode: AutomixMode.simple);
      final late = p.startingLate(196000, 200000);
      expect(late.fadeMs, 4000);
      expect(late.startAtMs, 196000);
      final veryLate = p.startingLate(199800, 200000);
      expect(veryLate.fadeMs, 1500);
    });
  });
}
