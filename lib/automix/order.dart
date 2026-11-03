import 'dart:math';

import 'analysis.dart';

/// How rough a hand-over from [a] to [b] would be (lower = smoother):
/// tempo distance (octaves allowed), energy jump, and an unknown penalty.
double transitionCost(TrackAnalysis? a, TrackAnalysis? b) {
  if (a == null || b == null) return 1.0;
  var cost = 0.0;
  if (a.hasBeat && b.hasBeat) {
    final bb = b.bpm;
    var best = bb;
    for (final c in [bb / 2, bb * 2]) {
      if ((log(c / a.bpm)).abs() < (log(best / a.bpm)).abs()) best = c;
    }
    cost += min(1.5, (best / a.bpm - 1).abs() * 10); // 5 % apart = 0.5
  } else if (a.hasBeat != b.hasBeat) {
    cost += 0.6;
  } else {
    cost += 0.3;
  }
  cost += (a.energy - b.energy).abs() * 1.2;
  return cost;
}

/// Smart shuffle for Automix: among the next [window] songs, which one
/// should play next so the blend is smoothest. Returns the index within
/// [upcoming] (0 = keep the order). Songs not analysed yet are left alone
/// unless nothing better is known.
int pickSmoothestNext(TrackAnalysis? current, List<TrackAnalysis?> upcoming, {int window = 4}) {
  if (current == null || upcoming.isEmpty) return 0;
  final n = min(window, upcoming.length);
  var best = 0;
  var bestCost = transitionCost(current, upcoming[0]);
  for (var i = 1; i < n; i++) {
    final a = upcoming[i];
    if (a == null) continue;
    // a small bias towards the original shuffle order
    final c = transitionCost(current, a) + 0.08 * i;
    if (c < bestCost - 0.05) {
      best = i;
      bestCost = c;
    }
  }
  return best;
}
