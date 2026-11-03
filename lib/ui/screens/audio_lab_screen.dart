import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../audiolab/audio_lab.dart';
import '../../core/platform_caps.dart';
import '../../services.dart';
import '../nav.dart';
import '../page.dart';
import '../style.dart';
import '../widgets.dart';
import '../../player/equalizer.dart' show ByteEqualizer;
import 'settings_pages.dart' show QualityScreen, EqualizerScreen;
import 'settings_screen.dart' show qualityLabel;

// Byte © 2026 Apurba Laskar. Settings → Audio Lab.

class _LabPage extends StatelessWidget {
  final String title;
  final List<Widget> Function(BuildContext) children;
  const _LabPage({required this.title, required this.children});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([Services.i.lab, Services.i.settings]),
    builder: (context, _) => SubPage(capWidth: true, 
      title: title,
      showProfile: false,
      slivers: [
        SliverList.list(children: [...children(context), const SizedBox(height: 120)]),
      ],
    ),
  );
}

Widget _sw(String title, String? sub, bool v, ValueChanged<bool>? on, {IconData? icon, Key? key}) => GroupRow(
  key: key,
  icon: icon,
  leading: icon == null ? const SizedBox(width: 26) : null,
  title: title,
  subtitle: sub,
  enabled: on != null,
  trailing: ByteSwitch(value: v, onChanged: on),
  onTap: on == null ? null : () => on(!v),
);

class _Slider extends StatelessWidget {
  final String label;
  final double value, min, max;
  final String Function(double) show;
  final ValueChanged<double> onChanged;
  final int? divisions;
  final bool enabled;
  const _Slider(this.label, this.value, this.min, this.max, this.show, this.onChanged, {this.divisions, this.enabled = true});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(label, style: BT.body.copyWith(color: p.label))),
                Text(show(value), style: BT.body.copyWith(color: p.secondary, fontFeatures: const [FontFeature.tabularFigures()])),
              ],
            ),
            Slider(value: value.clamp(min, max), min: min, max: max, divisions: divisions, onChanged: enabled ? onChanged : null),
          ],
        ),
      ),
    );
  }
}

class _Chips<T> extends StatelessWidget {
  final List<T> values;
  final T? selected;
  final String Function(T) label;
  final ValueChanged<T>? onTap;
  const _Chips(this.values, this.selected, this.label, this.onTap, {super.key});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        itemCount: values.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final v = values[i];
          final on = v == selected;
          return Material(
            color: on ? p.accent : p.fill,
            borderRadius: BorderRadius.circular(18),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: onTap == null
                  ? null
                  : () {
                      HapticFeedback.selectionClick();
                      onTap!(v);
                    },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Text(label(v), style: BT.sub.copyWith(color: on ? Colors.white : p.label, fontWeight: FontWeight.w600)),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _db(double v) => '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)} dB';
String _hz(double f) => f >= 1000 ? '${(f / 1000).toStringAsFixed(f >= 10000 ? 0 : 1)} kHz' : '${f.round()} Hz';
String _pct(double v) => '${(v * 100).round()}%';

// ── Hub ────────────────────────────────────────────────────────────────
class AudioLabScreen extends StatelessWidget {
  const AudioLabScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return _LabPage(
      title: 'Audio Lab',
      children: (context) {
        final lab = Services.i.lab;
        final st = Services.i.settings;
        final fx = [
          if (lab.reverbOn) 'Reverb',
          if (lab.loudOn) 'Loudness',
          if (st.normalizeVolume) 'Even out',
          if (lab.crossfeedOn) 'Crossfeed',
          if (lab.mono) 'Mono',
          if (st.speed != 1 || lab.pitchSemis != 0) 'Speed',
        ];
        final cards = [
          _LabCard(const ValueKey('lab-eq'), Icons.equalizer_rounded, 'Equalizer', lab.eqOn ? 'On · ${lab.preset ?? 'Custom'}' : 'Off', () => pushPage(context, const LabEqualizerScreen())),
          _LabCard(const ValueKey('lab-fx'), Icons.auto_awesome_rounded, 'Audio effects', fx.isEmpty ? 'None on' : fx.join(' · '), () => pushPage(context, const LabEffectsScreen())),
          _LabCard(const ValueKey('lab-quality'), Icons.high_quality_rounded, 'Audio quality', 'Wi-Fi ${qualityLabel(st.wifiQuality)}', () => pushPage(context, const LabQualityScreen())),
          _LabCard(const ValueKey('lab-transition'), Icons.swap_horiz_rounded, 'Transition', _transitionLabel(), () => pushPage(context, const LabTransitionScreen())),
          _LabCard(const ValueKey('lab-pass'), Icons.cable_rounded, 'Audio pass', Services.i.route.info.label, () => pushPage(context, const LabAudioPassScreen())),
        ];
        return [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Shape how every song sounds. Everything here works on the music as it plays.', style: BT.sub.copyWith(color: BytePalette.of(context).secondary)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: LayoutBuilder(
              builder: (context, c) {
                final w = (c.maxWidth - 12) / 2;
                return Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [for (var i = 0; i < cards.length; i++) SizedBox(width: i == cards.length - 1 && cards.length.isOdd ? c.maxWidth : w, child: cards[i])],
                );
              },
            ),
          ),
        ];
      },
    );
  }
}

String _transitionLabel() {
  final st = Services.i.settings;
  if (st.automix) return 'Auto crossfade';
  if (st.crossfadeSeconds > 0) return 'Crossfade ${st.crossfadeSeconds.round()} s';
  return 'Off';
}

class _LabCard extends StatelessWidget {
  final IconData icon;
  final String title, status;
  final VoidCallback onTap;
  const _LabCard(Key key, this.icon, this.title, this.status, this.onTap) : super(key: key);
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Material(
      color: p.grouped,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: p.accent),
              ),
              const SizedBox(height: 14),
              Text(title, style: BT.bodyStrong.copyWith(color: p.label)),
              const SizedBox(height: 2),
              Text(status, maxLines: 2, overflow: TextOverflow.ellipsis, style: BT.sub.copyWith(color: p.secondary)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Equalizer ──────────────────────────────────────────────────────────
class LabEqualizerScreen extends StatefulWidget {
  const LabEqualizerScreen({super.key});
  @override
  State<LabEqualizerScreen> createState() => _LabEqualizerScreenState();
}

class _LabEqualizerScreenState extends State<LabEqualizerScreen> {
  int view = 0; // 0 graph, 1 bands
  int? sel;

  @override
  Widget build(BuildContext context) {
    return _LabPage(
      title: 'Equalizer',
      children: (context) {
        final lab = Services.i.lab;
        final p = BytePalette.of(context);
        final nodes = lab.nodes;
        if (sel != null && sel! >= nodes.length) sel = null;
        return [
          GroupCard(children: [_sw('Equalizer', lab.eqOn ? 'On' : 'Off', lab.eqOn, (v) => lab.eqOn = v, key: const ValueKey('eq-on'))]),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedPill(labels: const ['Graph', 'Bands'], index: view, onChanged: (i) => setState(() => view = i)),
          ),
          const SizedBox(height: 10),
          _Chips<String>(
            [...eqPresets.keys, ...lab.customPresets.keys],
            lab.preset,
            (s) => s,
            (s) => eqPresets.containsKey(s) ? lab.applyPreset(s) : lab.applyCustom(s),
            key: const ValueKey('eq-presets'),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                TextButton.icon(onPressed: lab.resetEq, icon: const Icon(Icons.restart_alt_rounded), label: const Text('Reset')),
                TextButton.icon(
                  onPressed: () async {
                    final name = await promptText(context, title: 'Save as', hint: 'My sound');
                    if (name != null && name.trim().isNotEmpty) lab.saveCustom(name.trim());
                  },
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Save'),
                ),
              ],
            ),
          ),
          if (view == 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Opacity(
                opacity: lab.eqOn ? 1 : 0.5,
                child: EqGraph(
                  key: const ValueKey('eq-graph'),
                  nodes: nodes,
                  selected: sel,
                  onSelect: (i) => setState(() => sel = i),
                  onMove: (i, f, g) => lab.setNode(i, nodes[i].copyWith(f: f, g: g)),
                  onAdd: (f) {
                    lab.addNode(f);
                    setState(() => sel = lab.nodes.indexWhere((n) => (n.f - f.clamp(EqMath.minF, EqMath.maxF)).abs() < 0.01));
                  },
                ),
              ),
            )
          else
            GroupCard(
              children: [
                for (var i = 0; i < nodes.length; i++)
                  _Slider(_hz(nodes[i].f), nodes[i].g, -15, 15, _db, (v) => lab.setNode(i, nodes[i].copyWith(g: (v * 2).roundToDouble() / 2)), enabled: lab.eqOn),
              ],
            ),
          if (view == 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
              child: Text(sel == null ? 'Drag a point to shape the sound. Double-tap the graph to add a point.' : 'Point ${sel! + 1}', style: BT.sub.copyWith(color: p.secondary)),
            ),
          if (view == 0 && sel != null) ...[
            const SizedBox(height: 8),
            _NodeEditor(index: sel!, node: nodes[sel!], onRemove: nodes.length > 1 ? () => setState(() {
              lab.removeNode(sel!);
              sel = null;
            }) : null),
          ],
          if (ByteEqualizer.supported)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: GroupCard(
                children: [
                  GroupRow(
                    icon: Icons.tune_rounded,
                    title: 'Classic phone equalizer',
                    subtitle: Services.i.settings.eqEnabled ? 'On: turns off when this one is on' : 'The phone\'s own fixed bands',
                    chevron: true,
                    onTap: () => pushPage(context, const EqualizerScreen()),
                  ),
                ],
              ),
            ),
          const GroupLabel('Output'),
          GroupCard(
            children: [
              _sw('Auto preamp', lab.autoPreamp ? 'Lowers the level by ${(-EqMath.autoPreamp(nodes)).toStringAsFixed(1)} dB so boosts never clip' : 'Nothing is lowered; the limiter catches any peaks', lab.autoPreamp, (v) => lab.autoPreamp = v),
              _Slider('Preamp', lab.autoPreamp ? EqMath.autoPreamp(nodes) : lab.preamp, -15, 6, _db, (v) => lab.preamp = (v * 2).roundToDouble() / 2, enabled: !lab.autoPreamp),
            ],
          ),
        ];
      },
    );
  }
}

class _NodeEditor extends StatelessWidget {
  final int index;
  final EqNode node;
  final VoidCallback? onRemove;
  const _NodeEditor({required this.index, required this.node, this.onRemove});
  @override
  Widget build(BuildContext context) {
    final lab = Services.i.lab;
    void set(EqNode n) => lab.setNode(index, n);
    return GroupCard(
      children: [
        _Chips<EqNodeType>(
          EqNodeType.values,
          node.type,
          (t) => switch (t) {
            EqNodeType.lowShelf => 'Low shelf',
            EqNodeType.peak => 'Peak',
            EqNodeType.highShelf => 'High shelf',
          },
          (t) => set(node.copyWith(type: t)),
        ),
        _Slider('Gain', node.g, -15, 15, _db, (v) => set(node.copyWith(g: (v * 2).roundToDouble() / 2))),
        _Slider('Frequency', math.log(node.f) / math.ln10, math.log(20) / math.ln10, math.log(20000) / math.ln10, (v) => _hz(math.pow(10, v).toDouble()), (v) => set(node.copyWith(f: math.pow(10, v).toDouble()))),
        _Slider('Width (Q)', node.q, 0.3, 8, (v) => v.toStringAsFixed(2), (v) => set(node.copyWith(q: v))),
        GroupRow(icon: Icons.delete_outline_rounded, title: 'Remove point', titleColor: const Color(0xFFFF3B30), enabled: onRemove != null, onTap: onRemove),
      ],
    );
  }
}

/// The equalizer's live response: grid, curve and draggable points.
class EqGraph extends StatefulWidget {
  final List<EqNode> nodes;
  final int? selected;
  final ValueChanged<int?> onSelect;
  final void Function(int i, double f, double g) onMove;
  final ValueChanged<double> onAdd;
  const EqGraph({super.key, required this.nodes, required this.selected, required this.onSelect, required this.onMove, required this.onAdd});

  static double xOf(double f, double w) => w * (math.log(f / EqMath.minF) / math.log(EqMath.maxF / EqMath.minF));
  static double fOf(double x, double w) => EqMath.minF * math.pow(EqMath.maxF / EqMath.minF, (x / w).clamp(0.0, 1.0)).toDouble();
  static double yOf(double g, double h) => h / 2 - g / 15 * (h / 2 - 12);
  static double gOf(double y, double h) => ((h / 2 - y) / (h / 2 - 12) * 15).clamp(-15.0, 15.0);

  @override
  State<EqGraph> createState() => _EqGraphState();
}

class _EqGraphState extends State<EqGraph> {
  int? drag;
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth, h = 230.0;
        int? hit(Offset o) {
          for (var i = 0; i < widget.nodes.length; i++) {
            final n = widget.nodes[i];
            if ((Offset(EqGraph.xOf(n.f, w), EqGraph.yOf(n.g, h)) - o).distance < 26) return i;
          }
          return null;
        }

        return RawGestureDetector(
          behavior: HitTestBehavior.opaque,
          gestures: {
            // A point grabs the finger at once (the page can't scroll it away);
            // anywhere else the page scrolls as usual.
            _PointDrag: GestureRecognizerFactoryWithHandlers<_PointDrag>(
              () => _PointDrag(),
              (r) => r
                ..hits = ((o) => hit(o) != null)
                ..onStart = (o) {
                  drag = hit(o);
                  if (drag != null) {
                    HapticFeedback.selectionClick();
                    widget.onSelect(drag);
                  }
                }
                ..onUpdate = (o) {
                  final i = drag;
                  if (i == null) return;
                  widget.onMove(i, EqGraph.fOf(o.dx, w), (EqGraph.gOf(o.dy, h) * 2).roundToDouble() / 2);
                }
                ..onEnd = () => drag = null,
            ),
            DoubleTapGestureRecognizer: GestureRecognizerFactoryWithHandlers<DoubleTapGestureRecognizer>(
              () => DoubleTapGestureRecognizer(),
              (r) => r
                ..onDoubleTapDown = (d) {
                  if (hit(d.localPosition) == null) widget.onAdd(EqGraph.fOf(d.localPosition.dx, w));
                }
                ..onDoubleTap = () {},
            ),
            TapGestureRecognizer: GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
              () => TapGestureRecognizer(),
              (r) => r..onTapUp = (d) => widget.onSelect(hit(d.localPosition)),
            ),
          },
          child: Container(
            height: h,
            decoration: BoxDecoration(color: p.grouped, borderRadius: BorderRadius.circular(16)),
            child: CustomPaint(size: Size(w, h), painter: _EqPainter(widget.nodes, widget.selected, p.accent, p.secondary, p.separator)),
          ),
        );
      },
    );
  }
}

class _EqPainter extends CustomPainter {
  final List<EqNode> nodes;
  final int? sel;
  final Color accent, text, grid;
  _EqPainter(this.nodes, this.sel, this.accent, this.text, this.grid);
  @override
  void paint(Canvas canvas, Size s) {
    final gp = Paint()
      ..color = grid
      ..strokeWidth = 0.7;
    for (final g in [-12.0, -6.0, 0.0, 6.0, 12.0]) {
      final y = EqGraph.yOf(g, s.height);
      canvas.drawLine(Offset(0, y), Offset(s.width, y), gp..strokeWidth = g == 0 ? 1.2 : 0.6);
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final f in [50.0, 100.0, 500.0, 1000.0, 5000.0, 10000.0]) {
      final x = EqGraph.xOf(f, s.width);
      canvas.drawLine(Offset(x, 0), Offset(x, s.height), gp..strokeWidth = 0.5);
      tp.text = TextSpan(text: _hz(f), style: TextStyle(color: text, fontSize: 9));
      tp.layout();
      tp.paint(canvas, Offset(x + 2, s.height - 12));
    }
    final path = Path();
    final fill = Path();
    const steps = 160;
    for (var i = 0; i <= steps; i++) {
      final x = s.width * i / steps;
      final y = EqGraph.yOf(EqMath.curveDb(nodes, EqGraph.fOf(x, s.width)).clamp(-15.0, 15.0), s.height);
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, EqGraph.yOf(0, s.height));
      }
      path.lineTo(x, y);
      fill.lineTo(x, y);
    }
    fill
      ..lineTo(s.width, EqGraph.yOf(0, s.height))
      ..close();
    canvas.drawPath(fill, Paint()..color = accent.withValues(alpha: 0.12));
    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4,
    );
    for (var i = 0; i < nodes.length; i++) {
      final o = Offset(EqGraph.xOf(nodes[i].f, s.width), EqGraph.yOf(nodes[i].g, s.height));
      canvas.drawCircle(o, i == sel ? 10 : 7, Paint()..color = i == sel ? accent : Colors.white);
      canvas.drawCircle(
        o,
        i == sel ? 10 : 7,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(_EqPainter o) => o.nodes != nodes || o.sel != sel || o.accent != accent;
}

// ── Effects ────────────────────────────────────────────────────────────
class LabEffectsScreen extends StatelessWidget {
  const LabEffectsScreen({super.key});
  @override
  Widget build(BuildContext context) => _LabPage(
    title: 'Audio effects',
    children: (context) {
      final lab = Services.i.lab;
      final st = Services.i.settings;
      final info = Services.i.route.info;
      String spd(double v) => '${v.toStringAsFixed(2)}×';
      return [
        const GroupLabel('Reverb'),
        GroupCard(
          children: [
            _sw('Reverb', 'Adds space around the music', lab.reverbOn, (v) => lab.reverbOn = v, key: const ValueKey('fx-reverb')),
            _Chips<ReverbPreset>(ReverbPreset.values, lab.reverbPreset, (r) => switch (r) {
              ReverbPreset.room => 'Room',
              ReverbPreset.studio => 'Studio',
              ReverbPreset.bathroom => 'Bathroom',
              ReverbPreset.plate => 'Plate',
            }, lab.reverbOn ? lab.applyReverbPreset : null),
            _Slider('Mix', lab.rv('mix'), 0, 1, _pct, (v) => lab.setRv('mix', v), enabled: lab.reverbOn),
            _Slider('Room size', lab.rv('size'), 0, 1, _pct, (v) => lab.setRv('size', v), enabled: lab.reverbOn),
            _Slider('Damping', lab.rv('damping'), 0, 1, _pct, (v) => lab.setRv('damping', v), enabled: lab.reverbOn),
            _Slider('Wet', lab.rv('wet'), 0, 1, _pct, (v) => lab.setRv('wet', v), enabled: lab.reverbOn),
            _Slider('Dry', lab.rv('dry'), 0, 1, _pct, (v) => lab.setRv('dry', v), enabled: lab.reverbOn),
            _Slider('Spread', lab.rv('width'), 0, 1, _pct, (v) => lab.setRv('width', v), enabled: lab.reverbOn),
            _Slider('Pre-delay', lab.rv('preDelay'), 0, 100, (v) => '${v.round()} ms', (v) => lab.setRv('preDelay', v.roundToDouble()), enabled: lab.reverbOn),
          ],
        ),
        const GroupLabel('Loudness'),
        GroupCard(
          children: [
            _sw('Loudness', 'Louder and fuller, never clipping', lab.loudOn, (v) => lab.loudOn = v, key: const ValueKey('fx-loud')),
            _Chips<LoudMode>(LoudMode.values, lab.loudMode, (m) => switch (m) {
              LoudMode.gentle => 'Gentle',
              LoudMode.punchy => 'Punchy',
              LoudMode.night => 'Night mode',
              LoudMode.max => 'Max',
            }, lab.loudOn ? (m) => lab.loudMode = m : null),
            _Slider('Boost', lab.loudBoost, 0, 12, _db, (v) => lab.loudBoost = (v * 2).roundToDouble() / 2, enabled: lab.loudOn),
            _Slider('Compression', lab.loudComp, 0, 1, _pct, (v) => lab.loudComp = v, enabled: lab.loudOn),
          ],
        ),
        const GroupLabel('Even out songs'),
        GroupCard(
          children: [
            _sw('Even out songs', 'Plays every song at a similar volume (uses each song\'s loudness)', st.normalizeVolume, (v) => st.normalizeVolume = v),
            _sw('Not on the phone speaker', 'Keeps the phone speaker at full level', st.normalizeOffOnSpeaker, (v) => st.normalizeOffOnSpeaker = v),
          ],
        ),
        const GroupLabel('Crossfeed'),
        GroupCard(
          children: [
            _sw('Crossfeed', 'Headphones sound like speakers in a room: easier on the ears', lab.crossfeedOn, (v) => lab.crossfeedOn = v, key: const ValueKey('fx-crossfeed')),
            _Chips<String>(const ['Headphones', 'Speakers'], lab.crossfeedSpeakers ? 'Speakers' : 'Headphones', (s) => s, lab.crossfeedOn ? (s) => lab.crossfeedSpeakers = s == 'Speakers' : null),
            if (lab.crossfeedSpeakers)
              const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 10), child: Text('Speakers already mix both sides in the room, so crossfeed rests while this is chosen.'))
            else ...[
              _Chips<CrossfeedStrength>(CrossfeedStrength.values, lab.crossfeedStrength, (s) => switch (s) {
                CrossfeedStrength.light => 'Light',
                CrossfeedStrength.natural => 'Natural',
                CrossfeedStrength.strong => 'Strong',
              }, lab.crossfeedOn ? (s) => lab.crossfeedStrength = s : null),
              _Slider('Head shadow', lab.crossfeedHz, 300, 2000, _hz, (v) => lab.crossfeedHz = v.roundToDouble(), enabled: lab.crossfeedOn),
              _Slider('Crossfeed level', lab.crossfeedDb, -15, -1, _db, (v) => lab.crossfeedDb = (v * 2).roundToDouble() / 2, enabled: lab.crossfeedOn),
              _Slider('Amount', lab.crossfeedAmount, 0, 1, _pct, (v) => lab.crossfeedAmount = v, enabled: lab.crossfeedOn),
            ],
          ],
        ),
        const GroupLabel('Channels'),
        GroupCard(
          children: [
            _sw('Mono audio', 'Both ears hear the whole song', lab.mono, (v) => lab.mono = v, key: const ValueKey('fx-mono')),
            _Slider('Balance', lab.balance, -1, 1, (v) => v.abs() < 0.01 ? 'Centre' : (v < 0 ? 'L ${(-v * 100).round()}' : 'R ${(v * 100).round()}'), (v) => lab.balance = v.abs() < 0.04 ? 0 : v),
          ],
        ),
        const GroupLabel('Surround'),
        GroupCard(
          children: [
            GroupRow(icon: Icons.surround_sound_outlined, title: 'Atmos surround decoder', value: info.atmos ? 'On this phone' : 'Not on this phone'),
            GroupRow(icon: Icons.spatial_audio_off_rounded, title: 'Android spatial audio', value: info.spatialAvailable ? (info.spatialEnabled ? 'On' : 'Available') : 'Not available'),
          ],
        ),
        const GroupLabel('Playback speed'),
        GroupCard(
          children: [
            _Chips<String>(const ['Normal', 'Slowed', 'Slowed + reverb'], st.speed == 1 && lab.pitchSemis == 0 ? 'Normal' : (st.speed == 0.85 && !lab.preservePitch ? (lab.reverbOn ? 'Slowed + reverb' : 'Slowed') : null), (s) => s, (s) async {
              if (s == 'Normal') {
                await Services.i.player.setSpeed(1);
                lab.preservePitch = true;
                lab.pitchSemis = 0;
              } else {
                await Services.i.player.setSpeed(0.85);
                lab.preservePitch = false;
                if (s == 'Slowed + reverb') {
                  lab.applyReverbPreset(ReverbPreset.plate);
                  lab.reverbOn = true;
                }
              }
            }),
            _Slider('Speed', st.speed, 0.5, 2, spd, (v) => Services.i.player.setSpeed((v * 20).roundToDouble() / 20), divisions: 30),
            _sw('Keep pitch', 'Off = slower songs sound deeper, the "slowed" way', lab.preservePitch, (v) => lab.preservePitch = v),
            _Slider('Pitch', lab.pitchSemis, -12, 12, (v) => '${v > 0 ? '+' : ''}${v.round()} semitones', (v) => lab.pitchSemis = v, divisions: 24),
          ],
        ),
      ];
    },
  );
}

// ── Quality ────────────────────────────────────────────────────────────
class LabQualityScreen extends StatelessWidget {
  const LabQualityScreen({super.key});
  @override
  Widget build(BuildContext context) => _LabPage(
    title: 'Audio quality',
    children: (context) {
      final st = Services.i.settings;
      return [
        const GroupLabel('Streaming'),
        GroupCard(
          children: [
            GroupRow(icon: Icons.wifi_rounded, title: 'On Wi-Fi', value: qualityLabel(st.wifiQuality), chevron: true, onTap: () => pushPage(context, const QualityScreen())),
            GroupRow(icon: Icons.signal_cellular_alt_rounded, title: 'On mobile data', value: qualityLabel(st.mobileQuality), chevron: true, onTap: () => pushPage(context, const QualityScreen(mobile: true))),
          ],
        ),
        const GroupLabel('Downloads'),
        GroupCard(
          children: [
            GroupRow(icon: Icons.arrow_circle_down_outlined, title: 'Download quality', chevron: true, onTap: () => pushPage(context, const QualityScreen(download: true))),
          ],
        ),
      ];
    },
  );
}

// ── Transition ─────────────────────────────────────────────────────────
class LabTransitionScreen extends StatelessWidget {
  const LabTransitionScreen({super.key});
  @override
  Widget build(BuildContext context) => _LabPage(
    title: 'Transition',
    children: (context) {
      final st = Services.i.settings;
      final lab = Services.i.lab;
      final mode = st.automix ? 1 : (st.crossfadeSeconds > 0 ? 2 : 0);
      return [
        const GroupLabel('Crossfade'),
        GroupCard(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: SegmentedPill(
                key: const ValueKey('xfade-mode'),
                labels: const ['Off', 'Auto', 'Manual'],
                index: mode,
                onChanged: (i) {
                  st.automix = i == 1;
                  st.crossfadeSeconds = i == 2 ? (st.crossfadeSeconds > 0 ? st.crossfadeSeconds : 6) : (i == 0 ? 0 : st.crossfadeSeconds);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(height: 70, child: CustomPaint(size: const Size(double.infinity, 70), painter: _FadePainter(mode == 0 ? 0 : (mode == 1 ? 6 : st.crossfadeSeconds), lab.fadeCurve, BytePalette.of(context).accent))),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Text(
                switch (mode) {
                  0 => 'Each song ends before the next one starts.',
                  1 => 'Byte picks the best moment and length for every blend.',
                  _ => 'The next song fades in while this one fades out.',
                },
                style: BT.sub.copyWith(color: BytePalette.of(context).secondary),
              ),
            ),
            _Slider('Length', st.crossfadeSeconds, 1, 12, (v) => '${v.round()} s', (v) => st.crossfadeSeconds = v.roundToDouble(), enabled: mode == 2, divisions: 11),
            _sw('Keep gapless albums intact', 'Songs from the same album play back to back, no blend', lab.gapless, (v) => lab.gapless = v),
          ],
        ),
        const GroupLabel('Pause, play and skip'),
        GroupCard(
          children: [
            _sw('Fade', 'Music fades out on pause and back in on play', lab.fadeOnPause, (v) => lab.fadeOnPause = v, key: const ValueKey('fade-pause')),
            _Slider('Fade length', lab.fadeMs.toDouble(), 50, 1500, (v) => '${v.round()} ms', (v) => lab.fadeMs = (v / 50).round() * 50, enabled: lab.fadeOnPause),
          ],
        ),
        const GroupLabel('Blend style'),
        GroupCard(
          children: [
            _Chips<FadeCurve>(FadeCurve.values, lab.fadeCurve, (c) => switch (c) {
              FadeCurve.equalPower => 'Smooth',
              FadeCurve.linear => 'Straight',
              FadeCurve.filterSweep => 'Bass swap',
            }, (c) {
              lab.fadeCurve = c;
              st.automixSmart = c == FadeCurve.filterSweep;
            }),
          ],
        ),
      ];
    },
  );
}

class _FadePainter extends CustomPainter {
  final double seconds;
  final FadeCurve curve;
  final Color accent;
  _FadePainter(this.seconds, this.curve, this.accent);
  @override
  void paint(Canvas c, Size s) {
    final mid = s.height / 2;
    final overlap = (seconds / 12).clamp(0.0, 1.0) * s.width * 0.45;
    final aEnd = s.width * 0.6 + overlap / 2, bStart = s.width * 0.4 - overlap / 2;
    double env(double x, double start, double end, bool out) {
      if (overlap <= 0) return 1;
      final t = ((x - start) / (end - start)).clamp(0.0, 1.0);
      final lin = out ? 1 - t : t;
      return curve == FadeCurve.linear ? lin : math.sin(lin * math.pi / 2);
    }

    void wave(double from, double to, Color col, bool out) {
      final p = Paint()
        ..color = col
        ..strokeWidth = 2;
      for (var x = from; x < to; x += 3) {
        final e = out ? env(x, s.width * 0.6 - overlap / 2, aEnd, true) : env(x, bStart, s.width * 0.4 + overlap / 2, false);
        final amp = (0.35 + 0.65 * (0.5 + 0.5 * math.sin(x * 0.37) * math.cos(x * 0.11))) * e * (mid - 4);
        c.drawLine(Offset(x, mid - amp), Offset(x, mid + amp), p);
      }
    }

    wave(0, overlap <= 0 ? s.width * 0.5 : aEnd, accent.withValues(alpha: 0.55), true);
    wave(overlap <= 0 ? s.width * 0.5 : bStart, s.width, accent, false);
  }

  @override
  bool shouldRepaint(_FadePainter o) => o.seconds != seconds || o.curve != curve || o.accent != accent;
}

// ── Audio pass ─────────────────────────────────────────────────────────
class LabAudioPassScreen extends StatelessWidget {
  const LabAudioPassScreen({super.key});
  @override
  Widget build(BuildContext context) => _LabPage(
    title: 'Audio pass',
    children: (context) {
      final st = Services.i.settings;
      final lab = Services.i.lab;
      final info = Services.i.route.info;
      return [
        const GroupLabel('Now playing through'),
        GroupCard(
          children: [
            GroupRow(icon: Icons.speaker_rounded, title: info.label, subtitle: [if (info.sampleRate != null) '${(info.sampleRate! / 1000).toStringAsFixed(1)} kHz mixer', info.outputType].join(' · ')),
            if (info.outputType == 'bluetooth') const GroupRow(icon: Icons.bluetooth_rounded, title: 'Bluetooth codec', subtitle: 'Android only shows the codec in Settings → Developer options; apps can\'t read it'),
          ],
        ),
        const GroupLabel('Options'),
        GroupCard(
          children: [
            if (!onWeb) _sw('Use the USB DAC when connected', 'Plays at your DAC\'s own best rate', st.preferUsbDac, (v) => st.preferUsbDac = v),
            _sw('Hi-res output (32-bit float)', 'More headroom through Byte\'s effects. Applies from the next app start. Skip silence doesn\'t work while it\'s on', lab.float32, (v) => lab.float32 = v, key: const ValueKey('pass-float')),
            if (!onWeb) _sw('Bit-perfect passthrough', 'USB DAC only (Android 14+): no mixing, no effects, phone volume fixed', st.bitPerfect, (v) => st.bitPerfect = v),
            const GroupRow(icon: Icons.lock_outline_rounded, title: 'Exclusive own resampler', subtitle: 'Android always mixes the speaker and headphone jack at its own rate, so no app can take this over', enabled: false),
          ],
        ),
      ];
    },
  );
}

/// Claims the pointer the moment it lands on an equalizer point.
class _PointDrag extends OneSequenceGestureRecognizer {
  bool Function(Offset local) hits = (_) => false;
  void Function(Offset local)? onStart;
  void Function(Offset local)? onUpdate;
  VoidCallback? onEnd;
  Matrix4? _tf;

  @override
  bool isPointerAllowed(PointerDownEvent event) => super.isPointerAllowed(event) && hits(event.localPosition);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _tf = event.transform;
    resolve(GestureDisposition.accepted);
    onStart?.call(event.localPosition);
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      onUpdate?.call(PointerEvent.transformPosition(_tf, event.position));
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      onEnd?.call();
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {}

  @override
  String get debugDescription => 'eq point drag';
}
