import 'package:byte/player/crossfade.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('off = gapless hand-off at the very end', () {
    const p = CrossfadePlan(0);
    expect(p.effectiveMs(200000), 0);
    expect(p.startNextAt(200000), 200000);
    expect(p.prepareAt(200000), 180000);
  });

  test('overlap as asked, but at most a third of a short track', () {
    const p = CrossfadePlan(12);
    expect(p.effectiveMs(240000), 12000);
    expect(p.startNextAt(240000), 228000);
    expect(p.effectiveMs(24000), 8000);
    expect(p.prepareAt(240000), 208000);
    expect(p.prepareAt(10000), 0);
  });

  test('equal-power curve: loudness stays even through the fade', () {
    for (var i = 0; i <= 10; i++) {
      final (o, n) = CrossfadePlan.volumes(i / 10);
      expect(o * o + n * n, closeTo(1, 1e-9));
    }
    expect(CrossfadePlan.volumes(0), (1.0, 0.0));
    final (o1, n1) = CrossfadePlan.volumes(1);
    expect(o1, closeTo(0, 1e-9));
    expect(n1, 1.0);
    expect(CrossfadePlan.volumes(-1), CrossfadePlan.volumes(0));
  });

  test('sleep timer fades over the last 10 s', () {
    expect(sleepFadeVolume(60000), 1);
    expect(sleepFadeVolume(5000), 0.5);
    expect(sleepFadeVolume(0), 0);
  });

  test('loudness normalisation only turns loud tracks down', () {
    expect(normalisationGain(null), 1);
    expect(normalisationGain(-3), 1);
    expect(normalisationGain(6), closeTo(0.501, 0.001));
    expect(normalisationGain(40), 0.25);
  });
}
