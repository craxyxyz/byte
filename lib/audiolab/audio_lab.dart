import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive.dart';

// Byte © 2026 Apurba Laskar.
//
// Audio Lab: Byte's own sound tools, all real processing on the song as it
// plays (Android): a graph equalizer (any number of shelf/peak points, drawn
// exactly as the sound is shaped), reverb, loudness with a limiter that never
// clips, crossfeed for headphones, mono, balance, speed/pitch, and how songs
// hand over to each other.

enum EqNodeType { lowShelf, peak, highShelf }

class EqNode {
  final EqNodeType type;
  final double f; // Hz
  final double g; // dB
  final double q;
  const EqNode(this.type, this.f, this.g, [this.q = 1.0]);
  EqNode copyWith({EqNodeType? type, double? f, double? g, double? q}) => EqNode(type ?? this.type, f ?? this.f, g ?? this.g, q ?? this.q);
  Map<String, Object> toJson() => {'t': type.index, 'f': f, 'g': g, 'q': q};
  static EqNode fromJson(Map m) => EqNode(EqNodeType.values[(m['t'] as num).toInt().clamp(0, 2)], (m['f'] as num).toDouble(), (m['g'] as num).toDouble(), (m['q'] as num?)?.toDouble() ?? 1.0);
  @override
  bool operator ==(Object other) => other is EqNode && other.type == type && other.f == f && other.g == g && other.q == q;
  @override
  int get hashCode => Object.hash(type, f, g, q);
}

/// Exact frequency response of the equalizer (standard audio-cookbook biquads).
class EqMath {
  static const sampleRate = 48000.0;
  static const minF = 20.0, maxF = 20000.0;

  /// Gain in dB of one point at frequency [f].
  static double nodeDb(EqNode n, double f) {
    if (n.g.abs() < 1e-6) return 0;
    final a = math.pow(10, n.g / 40).toDouble();
    final w0 = 2 * math.pi * n.f.clamp(minF, maxF) / sampleRate;
    final cw = math.cos(w0), sw = math.sin(w0);
    final q = n.q.clamp(0.1, 18.0);
    final alpha = sw / (2 * q);
    double b0, b1, b2, a0, a1, a2;
    switch (n.type) {
      case EqNodeType.peak:
        b0 = 1 + alpha * a;
        b1 = -2 * cw;
        b2 = 1 - alpha * a;
        a0 = 1 + alpha / a;
        a1 = -2 * cw;
        a2 = 1 - alpha / a;
      case EqNodeType.lowShelf:
        final s = 2 * math.sqrt(a) * alpha;
        b0 = a * ((a + 1) - (a - 1) * cw + s);
        b1 = 2 * a * ((a - 1) - (a + 1) * cw);
        b2 = a * ((a + 1) - (a - 1) * cw - s);
        a0 = (a + 1) + (a - 1) * cw + s;
        a1 = -2 * ((a - 1) + (a + 1) * cw);
        a2 = (a + 1) + (a - 1) * cw - s;
      case EqNodeType.highShelf:
        final s = 2 * math.sqrt(a) * alpha;
        b0 = a * ((a + 1) + (a - 1) * cw + s);
        b1 = -2 * a * ((a - 1) + (a + 1) * cw);
        b2 = a * ((a + 1) + (a - 1) * cw - s);
        a0 = (a + 1) - (a - 1) * cw + s;
        a1 = 2 * ((a - 1) - (a + 1) * cw);
        a2 = (a + 1) - (a - 1) * cw - s;
    }
    final w = 2 * math.pi * f / sampleRate;
    // |H(e^jw)|
    final c1 = math.cos(w), s1 = math.sin(w), c2 = math.cos(2 * w), s2 = math.sin(2 * w);
    final nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
    final dr = a0 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
    final mag = math.sqrt((nr * nr + ni * ni) / (dr * dr + di * di));
    return 20 * math.log(mag) / math.ln10;
  }

  static double curveDb(List<EqNode> nodes, double f) {
    var s = 0.0;
    for (final n in nodes) {
      s += nodeDb(n, f);
    }
    return s;
  }

  /// [n] frequencies spread evenly on a log scale from 20 Hz to 20 kHz.
  static List<double> logFreqs(int n) => [for (var i = 0; i < n; i++) minF * math.pow(maxF / minF, i / (n - 1)).toDouble()];

  /// The curve as the phone's band processor takes it: each band's top edge
  /// and the gain at its middle.
  static ({List<double> cutoffs, List<double> gains}) bands(List<EqNode> nodes, {int count = 32}) {
    final edges = logFreqs(count + 1);
    final cut = <double>[], g = <double>[];
    for (var i = 0; i < count; i++) {
      final mid = math.sqrt(edges[i] * edges[i + 1]);
      cut.add(edges[i + 1]);
      g.add(double.parse(curveDb(nodes, mid).toStringAsFixed(2)));
    }
    return (cutoffs: cut, gains: g);
  }

  /// "Auto preamp": lowers the level by the curve's highest boost, so a boost
  /// never pushes the song into clipping.
  static double autoPreamp(List<EqNode> nodes) {
    var mx = 0.0;
    for (final f in logFreqs(200)) {
      mx = math.max(mx, curveDb(nodes, f));
    }
    return -double.parse(mx.toStringAsFixed(1));
  }
}

const eqBandFreqs = [31.0, 62.0, 125.0, 250.0, 500.0, 1000.0, 2000.0, 4000.0, 8000.0, 16000.0];

List<EqNode> nodesFromBands(List<double> g) => [
  for (var i = 0; i < eqBandFreqs.length; i++)
    EqNode(i == 0 ? EqNodeType.lowShelf : (i == eqBandFreqs.length - 1 ? EqNodeType.highShelf : EqNodeType.peak), eqBandFreqs[i], g[i], i == 0 || i == eqBandFreqs.length - 1 ? 0.71 : 1.41),
];

/// Ready-made sounds (10 points each).
const eqPresets = <String, List<double>>{
  'Flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Acoustic': [4, 4, 3, 1, 1.5, 1.5, 3, 3.5, 3, 2],
  'Bass Booster': [5.5, 4.5, 3.5, 2, 1, 0, 0, 0, 0, 0],
  'Bass Reducer': [-5.5, -4.5, -3.5, -2, -1, 0, 0, 0, 0, 0],
  'Classical': [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 3.5],
  'Dance': [3.5, 6, 5, 0, 2, 3.5, 5, 4.5, 3.5, 0],
  'Deep': [4.5, 3.5, 1.5, 0.5, 3, 2.5, 1.5, -2, -3.5, -4.5],
  'Electronic': [4, 3.5, 1, 0, -2, 2, 1, 1, 4, 4.5],
  'Hip-Hop': [5, 4, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3],
  'Jazz': [4, 3, 1.5, 2, -1.5, -1.5, 0, 1.5, 3, 3.5],
  'Latin': [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5],
  'Loudness': [6, 4, 0, 0, -2, 0, -1, -5, 5, 1],
  'Lounge': [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1],
  'Piano': [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5],
  'Pop': [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5],
  'R&B': [2.5, 7, 5.5, 1.5, -2.5, -1.5, 2, 2.5, 3, 3.5],
  'Rock': [5, 4, 3, 1.5, -0.5, -1, 0.5, 2.5, 3.5, 4.5],
  'Small Speakers': [5.5, 4, 3.5, 2.5, 1, 0, -1, -2.5, -3.5, -4.5],
  'Spoken Word': [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 5, 4, 2.5, 0],
  'Treble Booster': [0, 0, 0, 0, 0, 1, 2.5, 4, 4.5, 5.5],
  'Treble Reducer': [0, 0, 0, 0, 0, -1, -2.5, -4, -4.5, -5.5],
  'Vocal Booster': [-1.5, -3, -3, 1.5, 4, 4, 3, 1.5, 0, -1.5],
};

enum ReverbPreset { room, studio, bathroom, plate }

const reverbPresets = <ReverbPreset, Map<String, double>>{
  ReverbPreset.room: {'mix': 0.25, 'size': 0.35, 'damping': 0.5, 'wet': 0.6, 'dry': 1.0, 'width': 0.8, 'preDelay': 12},
  ReverbPreset.studio: {'mix': 0.18, 'size': 0.25, 'damping': 0.65, 'wet': 0.5, 'dry': 1.0, 'width': 0.7, 'preDelay': 8},
  ReverbPreset.bathroom: {'mix': 0.35, 'size': 0.3, 'damping': 0.15, 'wet': 0.8, 'dry': 0.9, 'width': 0.6, 'preDelay': 4},
  ReverbPreset.plate: {'mix': 0.3, 'size': 0.6, 'damping': 0.3, 'wet': 0.7, 'dry': 1.0, 'width': 1.0, 'preDelay': 20},
};

enum LoudMode { gentle, punchy, night, max }

const loudModes = <LoudMode, ({double boost, double comp})>{
  LoudMode.gentle: (boost: 2, comp: 0.2),
  LoudMode.punchy: (boost: 4, comp: 0.35),
  LoudMode.night: (boost: 5, comp: 0.7),
  LoudMode.max: (boost: 8, comp: 0.6),
};

enum CrossfeedStrength { light, natural, strong }

const crossfeedPresets = <CrossfeedStrength, ({double db, double hz})>{
  CrossfeedStrength.light: (db: -9.5, hz: 650),
  CrossfeedStrength.natural: (db: -6, hz: 700),
  CrossfeedStrength.strong: (db: -4.5, hz: 800),
};

enum FadeCurve { equalPower, linear, filterSweep }

class AudioLab extends ChangeNotifier {
  Box? _b;
  Map<String, Object?> _m = {};

  Future<void> open() async {
    _b = await Hive.openBox('audiolab');
    try {
      _m = Map<String, Object?>.from(jsonDecode((_b?.get('v') as String?) ?? '{}') as Map);
    } catch (_) {
      _m = {};
    }
  }

  @visibleForTesting
  void openForTest([Map<String, Object?>? m]) => _m = {...?m};

  T _g<T>(String k, T d) {
    final v = _m[k];
    if (v is T) return v;
    if (d is double && v is num) return v.toDouble() as T;
    return d;
  }

  void _s(String k, Object? v) {
    _m[k] = v;
    _keepOwn();
    unawaited(_b?.put('v', jsonEncode(_own ?? _m)));
    notifyListeners();
  }

  // ── Listen together: the host's sound (1.4.2) ──
  //
  // What a party host can lend his guests: everything that shapes the sound.
  // Not lent: playback speed and "pitch follows speed" (the "slowed" way) —
  // they change the tempo, and the party keeps phones together by the clock
  // at normal speed; song transitions (they change when songs hand over);
  // 32-bit output (a property of each phone); the guest's saved EQ presets.
  static const partyKeys = <String>{
    'eqOn', 'nodes', 'preset', 'preamp', 'autoPre', //
    'rvOn', 'rvPreset', 'rv_mix', 'rv_size', 'rv_damping', 'rv_wet', 'rv_dry', 'rv_width', 'rv_preDelay', //
    'ldOn', 'ldMode', 'ldBoost', 'ldComp', //
    'xfOn', 'xfSpk', 'xfStr', 'xfDb', 'xfHz', 'xfAmt', //
    'mono', 'bal', 'semis',
  };

  /// The guest's own settings while he uses the host's sound (null = his own).
  Map<String, Object?>? _own;
  bool get borrowing => _own != null;

  static Map<String, Object?> _copy(Map m) => Map<String, Object?>.from(jsonDecode(jsonEncode(m)) as Map);

  /// Every saved Audio Lab value (tests).
  @visibleForTesting
  Map<String, Object?> get debugAll => _copy(_m);

  /// This phone's sound, ready to send to a party (only [partyKeys]).
  Map<String, Object?> partySound() => _copy({
    for (final e in _m.entries)
      if (partyKeys.contains(e.key)) e.key: e.value,
  });

  /// Use [host]'s sound for now. The first call keeps an exact copy of this
  /// phone's own settings, which stays on disk the whole time, so even a
  /// crash comes back to the guest's own sound.
  void borrow(Map host) {
    _own ??= _copy(_m);
    final next = _copy(_own!)..removeWhere((k, _) => partyKeys.contains(k));
    for (final e in _copy(host).entries) {
      if (partyKeys.contains(e.key)) next[e.key] = e.value;
    }
    _m = next;
    notifyListeners();
  }

  /// Back to exactly the guest's own settings.
  void restoreOwn() {
    final o = _own;
    if (o == null) return;
    _keepOwn();
    _m = _copy(_own!);
    _own = null;
    unawaited(_b?.put('v', jsonEncode(_m)));
    notifyListeners();
  }

  /// While borrowing, his own changes to anything not lent (transitions,
  /// saved presets…) still go to his own settings.
  void _keepOwn() {
    final o = _own;
    if (o == null) return;
    for (final e in _copy(_m).entries) {
      if (!partyKeys.contains(e.key)) o[e.key] = e.value;
    }
  }

  // ── Equalizer ──
  bool get eqOn => _g('eqOn', false);
  set eqOn(bool v) => _s('eqOn', v);
  List<EqNode> get nodes {
    final l = _m['nodes'];
    if (l is List && l.isNotEmpty) return [for (final x in l.whereType<Map>()) EqNode.fromJson(x)];
    return nodesFromBands(eqPresets['Flat']!);
  }

  set nodes(List<EqNode> n) {
    final s = [...n]..sort((a, b) => a.f.compareTo(b.f));
    _m['preset'] = null;
    _s('nodes', [for (final x in s) x.toJson()]);
  }

  String? get preset => _m['preset'] as String?;
  void applyPreset(String name) {
    final g = eqPresets[name];
    if (g == null) return;
    _m['nodes'] = [for (final x in nodesFromBands(g)) x.toJson()];
    _s('preset', name);
  }

  Map<String, List<EqNode>> get customPresets {
    final c = _m['custom'];
    if (c is! Map) return {};
    return {for (final e in c.entries) '${e.key}': [for (final x in (e.value as List).whereType<Map>()) EqNode.fromJson(x)]};
  }

  void saveCustom(String name) {
    final c = Map<String, Object?>.from((_m['custom'] as Map?) ?? {});
    c[name] = [for (final x in nodes) x.toJson()];
    _m['custom'] = c;
    _s('preset', name);
  }

  void applyCustom(String name) {
    final n = customPresets[name];
    if (n == null) return;
    _m['nodes'] = [for (final x in n) x.toJson()];
    _s('preset', name);
  }

  void resetEq() => applyPreset('Flat');

  void setNode(int i, EqNode n) {
    final l = nodes;
    if (i < 0 || i >= l.length) return;
    l[i] = n.copyWith(f: n.f.clamp(EqMath.minF, EqMath.maxF), g: n.g.clamp(-15.0, 15.0), q: n.q.clamp(0.1, 18.0));
    nodes = l;
  }

  void addNode(double f) {
    nodes = [...nodes, EqNode(EqNodeType.peak, f.clamp(EqMath.minF, EqMath.maxF), 0, 1.41)];
  }

  void removeNode(int i) {
    final l = nodes;
    if (l.length <= 1 || i < 0 || i >= l.length) return;
    l.removeAt(i);
    nodes = l;
  }

  double get preamp => _g('preamp', 0.0);
  set preamp(double v) => _s('preamp', v.clamp(-15.0, 6.0));
  bool get autoPreamp => _g('autoPre', true);
  set autoPreamp(bool v) => _s('autoPre', v);
  double get effectivePreamp => !eqOn ? 0 : (autoPreamp ? EqMath.autoPreamp(nodes) : preamp);

  // ── Reverb ──
  bool get reverbOn => _g('rvOn', false);
  set reverbOn(bool v) => _s('rvOn', v);
  ReverbPreset? get reverbPreset {
    final i = _m['rvPreset'];
    return i is int ? ReverbPreset.values[i] : ReverbPreset.room;
  }

  void applyReverbPreset(ReverbPreset p) {
    final v = reverbPresets[p]!;
    for (final e in v.entries) {
      _m['rv_${e.key}'] = e.value;
    }
    _s('rvPreset', p.index);
  }

  double rv(String k) => _g('rv_$k', reverbPresets[ReverbPreset.room]![k]!);
  void setRv(String k, double v) {
    _m['rvPreset'] = null;
    _s('rv_$k', v);
  }

  // ── Loudness ──
  bool get loudOn => _g('ldOn', false);
  set loudOn(bool v) => _s('ldOn', v);
  LoudMode get loudMode => LoudMode.values[_g('ldMode', 0)];
  set loudMode(LoudMode m) {
    _m['ldBoost'] = loudModes[m]!.boost;
    _m['ldComp'] = loudModes[m]!.comp;
    _s('ldMode', m.index);
  }

  double get loudBoost => _g('ldBoost', loudModes[loudMode]!.boost);
  set loudBoost(double v) => _s('ldBoost', v.clamp(0.0, 12.0));
  double get loudComp => _g('ldComp', loudModes[loudMode]!.comp);
  set loudComp(double v) => _s('ldComp', v.clamp(0.0, 1.0));

  // ── Crossfeed ("spatial" for headphones) ──
  bool get crossfeedOn => _g('xfOn', false);
  set crossfeedOn(bool v) => _s('xfOn', v);
  bool get crossfeedSpeakers => _g('xfSpk', false);
  set crossfeedSpeakers(bool v) => _s('xfSpk', v);
  CrossfeedStrength get crossfeedStrength => CrossfeedStrength.values[_g('xfStr', 1)];
  set crossfeedStrength(CrossfeedStrength s) {
    _m['xfDb'] = crossfeedPresets[s]!.db;
    _m['xfHz'] = crossfeedPresets[s]!.hz;
    _s('xfStr', s.index);
  }

  double get crossfeedDb => _g('xfDb', -6.0);
  set crossfeedDb(double v) => _s('xfDb', v.clamp(-15.0, -1.0));
  double get crossfeedHz => _g('xfHz', 700.0);
  set crossfeedHz(double v) => _s('xfHz', v.clamp(300.0, 2000.0));
  double get crossfeedAmount => _g('xfAmt', 1.0);
  set crossfeedAmount(double v) => _s('xfAmt', v.clamp(0.0, 1.0));

  // ── Mono, balance ──
  bool get mono => _g('mono', false);
  set mono(bool v) => _s('mono', v);
  double get balance => _g('bal', 0.0);
  set balance(double v) => _s('bal', v.clamp(-1.0, 1.0));

  // ── Speed & pitch ──
  bool get preservePitch => _g('keepPitch', true);
  set preservePitch(bool v) => _s('keepPitch', v);
  double get pitchSemis => _g('semis', 0.0);
  set pitchSemis(double v) => _s('semis', v.clamp(-12.0, 12.0).roundToDouble());

  /// The pitch factor for a playback [speed]: kept (1.0 × semitones) or
  /// following the speed, the "slowed" way.
  double pitchFor(double speed) => (preservePitch ? 1.0 : speed) * math.pow(2, pitchSemis / 12).toDouble();

  // ── Transition ──
  bool get gapless => _g('gapless', true);
  set gapless(bool v) => _s('gapless', v);
  bool get fadeOnPause => _g('fadePause', true);
  set fadeOnPause(bool v) => _s('fadePause', v);
  int get fadeMs => _g('fadeMs', 300);
  set fadeMs(int v) => _s('fadeMs', v.clamp(50, 2000));
  FadeCurve get fadeCurve => FadeCurve.values[_g('curve', 0)];
  set fadeCurve(FadeCurve c) => _s('curve', c.index);

  /// 32-bit float output (Playback → Output precision).
  bool get float32 => _g('f32', false);
  set float32(bool v) => _s('f32', v);

  /// Two songs from the same album play back to back with no blend.
  bool keepTogether(String? albumA, String? albumB) => gapless && albumA != null && albumA.isNotEmpty && albumA == albumB;

  /// Everything the phone's sound processor needs.
  Map<String, Object?> nativeConfig() {
    final b = EqMath.bands(nodes);
    final ld = loudOn;
    final xfOn = crossfeedOn && !crossfeedSpeakers;
    return {
      'eqOn': eqOn,
      'cutoffs': b.cutoffs,
      'gains': eqOn ? b.gains : List<double>.filled(b.gains.length, 0),
      'inputGain': effectivePreamp + (ld ? loudBoost : 0),
      'mbcOn': ld,
      'ratio': 1 + loudComp * 5,
      'threshold': -6 - loudComp * 24,
      'limiterOn': eqOn || ld,
      'rvOn': reverbOn,
      'rvMix': rv('mix'),
      'rvSize': rv('size'),
      'rvDamping': rv('damping'),
      'rvWet': rv('wet'),
      'rvDry': rv('dry'),
      'rvWidth': rv('width'),
      'rvPreDelay': rv('preDelay'),
      'mono': mono,
      'balance': balance,
      'crossfeed': xfOn,
      'xfDb': crossfeedDb,
      'xfHz': crossfeedHz,
      'xfAmount': crossfeedAmount,
      'float32': float32,
    };
  }

  /// Reverb in the phone's units (millibels / milliseconds / per-mille).
  static Map<String, int> reverbNative(Map<String, Object?> c) {
    double d(String k) => (c[k] as num).toDouble();
    final wetMix = (d('rvMix') * d('rvWet')).clamp(0.0001, 1.0);
    final dry = d('rvDry').clamp(0.0001, 1.0);
    int mb(double lin) => (2000 * math.log(lin) / math.ln10).round();
    return {
      'roomLevel': mb(dry).clamp(-9000, 0),
      'reverbLevel': mb(wetMix * 2).clamp(-9000, 2000),
      'reflectionsLevel': mb(wetMix).clamp(-9000, 1000),
      'decayTime': (300 + d('rvSize') * 5700).round().clamp(100, 20000),
      'decayHFRatio': (1500 - d('rvDamping') * 1300).round().clamp(100, 2000),
      'reflectionsDelay': d('rvPreDelay').round().clamp(0, 300),
      'reverbDelay': (d('rvPreDelay') / 2 + 10).round().clamp(0, 100),
      'diffusion': (d('rvWidth') * 1000).round().clamp(0, 1000),
      'density': (500 + d('rvSize') * 500).round().clamp(0, 1000),
    };
  }
}

/// Sends the Audio Lab to the phone's sound processor for every player.
class AudioLabEngine {
  static const _ch = MethodChannel('byte/audiolab');
  final AudioLab lab;
  final Set<int> _sessions = {};
  Timer? _debounce;
  AudioLabEngine(this.lab) {
    lab.addListener(_changed);
  }

  /// What this phone can do (filled on start).
  Map<String, Object?> caps = const {};

  Future<void> start() async {
    if (kIsWeb) return;
    try {
      caps = Map<String, Object?>.from((await _ch.invokeMethod<Map>('caps')) ?? const {});
    } catch (_) {}
    await push();
  }

  Future<void> attach(int? session) async {
    if (kIsWeb || session == null || session <= 0 || !_sessions.add(session)) return;
    try {
      await _ch.invokeMethod('attach', {'session': session});
      await push();
    } catch (_) {}
  }

  void _changed() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 30), push);
  }

  Future<void> push() async {
    if (kIsWeb) return;
    final c = lab.nativeConfig();
    try {
      await _ch.invokeMethod('config', {...c, 'reverb': AudioLab.reverbNative(c)});
    } catch (_) {}
  }
}
