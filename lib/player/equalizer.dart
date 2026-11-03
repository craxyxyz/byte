import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../audiolab/sound_backend.dart';
import '../data/settings.dart';

/// Ready-made shapes, as dB per band from low to high. Stretched to however
/// many bands the phone's equalizer has.
const eqPresets = <String, List<double>>{
  'Flat': [0, 0, 0, 0, 0],
  'Bass boost': [6, 4, 0, 0, 0],
  'Treble boost': [0, 0, 0, 3, 6],
  'Vocal': [-2, 0, 4, 3, 0],
  'Pop': [-1, 2, 4, 2, -1],
  'Rock': [4, 2, -2, 2, 4],
  'Acoustic': [3, 1, 1, 2, 3],
  'Loudness': [5, 2, 0, 2, 4],
  'Late night': [-3, 0, 2, 1, -3],
};

List<double> stretchPreset(List<double> shape, int bands) {
  if (bands <= 0) return const [];
  if (bands == shape.length) return List.of(shape);
  return List.generate(bands, (i) {
    final x = bands == 1 ? 0.0 : i * (shape.length - 1) / (bands - 1);
    final a = x.floor().clamp(0, shape.length - 1);
    final b = (a + 1).clamp(0, shape.length - 1);
    final t = x - a;
    return shape[a] * (1 - t) + shape[b] * t;
  });
}

/// Band info shown on the Equalizer screen.
class EqBandInfo {
  final double centerHz;
  final double minDb;
  final double maxDb;
  const EqBandInfo(this.centerHz, this.minDb, this.maxDb);
  String get label => centerHz >= 1000 ? '${(centerHz / 1000).toStringAsFixed(centerHz >= 10000 ? 0 : 1)}k' : '${centerHz.round()}';
}

/// Android: the phone's built-in equalizer, applied to both of Byte's players
/// so crossfades sound the same. iPhone: Byte's own 10-band equalizer (native
/// filters on the player's audio, see ios/Runner/ByteEQ.m).
class ByteEqualizer extends ChangeNotifier {
  final Settings settings;
  final List<AndroidEqualizer> _eqs = [];
  List<EqBandInfo> bands = const [];
  final bool ios;
  static const _ch = MethodChannel('byte/eq');
  static const iosBands = [32.0, 64.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

  ByteEqualizer(this.settings, {bool? ios}) : ios = ios ?? (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    if (this.ios) {
      bands = [for (final f in iosBands) EqBandInfo(f, -12, 12)];
      apply();
    }
  }

  static bool get supported => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);
  static bool get android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// What the iPhone side was last told (tests read it).
  Map<String, Object>? lastIosCall;

  /// Automix bass swap: how much low end is cut on each Android deck (0..1).
  final Map<AndroidEqualizer, double> _lowCut = {};

  /// Every bass-swap change, for tests: (deck key, amount).
  final List<(String, double)> lowCutLog = [];

  /// Automix: cut the low end of one player (0 = none, 1 = full). Android
  /// uses that player's own equalizer; it's switched on just for the sweep
  /// when the user's equalizer is off.
  Future<void> setDeckLowCut(AndroidEqualizer eq, double amount) async {
    final a = amount.clamp(0.0, 1.0);
    if ((_lowCut[eq] ?? 0) == a) return;
    if (a == 0) {
      _lowCut.remove(eq);
    } else {
      _lowCut[eq] = a;
    }
    lowCutLog.add(('deck${_eqs.indexOf(eq)}', a));
    await _applyTo(eq);
  }

  /// Automix on iPhone: the bass cut is a filter in Byte's own audio tap,
  /// applied to the song whose file name is [fileKey].
  Future<void> setIosLowCut(String fileKey, double amount) async {
    final a = amount.clamp(0.0, 1.0);
    lowCutLog.add((fileKey, a));
    try {
      await _ch.invokeMethod('lowcut', {'key': fileKey, 'amount': a});
    } catch (_) {}
  }

  /// dB to add per band for a bass cut of [amount]: full cut on the lowest
  /// bands, half around 250 Hz, nothing above ~500 Hz.
  static double lowCutDb(double centerHz, double amount) {
    if (amount <= 0) return 0;
    final depth = centerHz <= 160 ? 1.0 : (centerHz <= 330 ? 0.55 : (centerHz <= 600 ? 0.15 : 0.0));
    return -15 * depth * amount;
  }

  /// A new equalizer for one AudioPlayer (pass it in its AudioPipeline).
  AndroidEqualizer create() {
    final eq = AndroidEqualizer();
    _eqs.add(eq);
    eq.parameters.then((p) {
      if (bands.isEmpty) {
        bands = [for (final b in p.bands) EqBandInfo(b.centerFrequency, p.minDecibels, p.maxDecibels)];
        notifyListeners();
      }
      _applyTo(eq);
    }).catchError((_) {});
    return eq;
  }

  List<double> get gains {
    final n = bands.length;
    if (n == 0) return const [];
    if (settings.eqPreset != 'Manual') return stretchPreset(eqPresets[settings.eqPreset] ?? eqPresets['Flat']!, n);
    final g = settings.eqBands;
    return List.generate(n, (i) => i < g.length ? g[i] : 0.0);
  }

  Future<void> _applyTo(AndroidEqualizer eq) async {
    try {
      final cut = _lowCut[eq] ?? 0;
      await eq.setEnabled(settings.eqEnabled || cut > 0);
      final p = await eq.parameters;
      final g = settings.eqEnabled ? gains : List<double>.filled(p.bands.length, 0);
      for (var i = 0; i < p.bands.length && i < g.length; i++) {
        final v = g[i] + lowCutDb(p.bands[i].centerFrequency, cut);
        await p.bands[i].setGain(v.clamp(p.minDecibels, p.maxDecibels));
      }
    } catch (_) {}
  }

  Future<void> apply() async {
    // 1.4.5: while the Audio Lab equalizer is on it owns the iPhone tap.
    if (ios && !(IosSoundBackend.labOwnsEq && !settings.eqEnabled)) {
      final call = <String, Object>{'enabled': settings.eqEnabled, 'freqs': iosBands, 'gains': gains};
      lastIosCall = call;
      try {
        await _ch.invokeMethod('set', call);
      } catch (_) {}
    }
    for (final e in _eqs) {
      await _applyTo(e);
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    settings.eqEnabled = v;
    await apply();
  }

  Future<void> setPreset(String name) async {
    settings.eqPreset = name;
    await apply();
  }

  Future<void> setBand(int i, double db) async {
    final g = List.of(gains);
    if (i >= g.length) return;
    g[i] = db;
    settings.eqBands = g;
    settings.eqPreset = 'Manual';
    await apply();
  }
}
