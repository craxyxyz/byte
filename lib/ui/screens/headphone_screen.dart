import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../audiolab/audio_lab.dart';
import '../../audiolab/headphone_eq.dart';
import '../../services.dart';
import '../page.dart';
import '../style.dart';
import '../widgets.dart' show toast;

// Byte 2.0 © 2026 Apurba Laskar.
//
// Audio Lab → Headphones: search your headphones, apply their correction
// (it flattens them toward a neutral target, under your own EQ curve), and
// see the curve that really plays.

class LabHeadphoneScreen extends StatefulWidget {
  const LabHeadphoneScreen({super.key});
  @override
  State<LabHeadphoneScreen> createState() => _LabHeadphoneScreenState();
}

class _LabHeadphoneScreenState extends State<LabHeadphoneScreen> {
  final _q = TextEditingController();
  List<HeadphoneEntry> _all = const [];
  List<HeadphoneEntry> _hits = const [];
  String? _loading; // name being downloaded
  bool _listFailed = false; // the bundled list could not be read
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  void _loadList() {
    setState(() => _listFailed = false);
    unawaited(HeadphoneIndex.all().then((a) {
      if (mounted) setState(() => _all = a);
    }).catchError((Object _) {
      // Never leave the box saying "Loading…" for ever: say it, offer a retry.
      if (mounted) setState(() => _listFailed = true);
    }));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _search(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (mounted) setState(() => _hits = HeadphoneIndex.search(_all, v));
    });
  }

  Future<void> _pick(HeadphoneEntry e) async {
    setState(() => _loading = e.name);
    try {
      final p = await HeadphoneIndex.fetch(Services.i.net, e);
      Services.i.lab.setHeadphone(e.name, e.source, p.preamp, p.nodes);
      if (!mounted) return;
      _q.clear();
      setState(() => _hits = const []);
      FocusScope.of(context).unfocus();
      toast(context, 'Correction for ${e.name} is on');
    } catch (err) {
      if (mounted) toast(context, '$err'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: Services.i.lab,
      builder: (context, _) {
        final lab = Services.i.lab;
        final name = lab.hpName;
        return SubPage(
          capWidth: true,
          title: 'Headphones',
          showProfile: false,
          slivers: [
            SliverList.list(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                  child: Text(
                    'Pick your headphones and Byte flattens them toward a neutral sound. It plays under your own equalizer curve, so both work together.',
                    style: BT.sub.copyWith(color: p.secondary),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: RepaintBoundary(child: ResponseGraph(key: const ValueKey('hp-graph'), lab: lab, height: 170)),
                ),
                const SizedBox(height: 14),
                if (name != null)
                  GroupCard(
                    children: [
                      GroupRow(
                        key: const ValueKey('hp-current'),
                        icon: Icons.headphones_rounded,
                        title: name,
                        subtitle: '${lab.hpSource ?? ''} · ${lab.hpNodes.length} filters',
                        trailing: ByteSwitch(value: lab.hpOn, onChanged: (v) => lab.hpOn = v),
                        onTap: () => lab.hpOn = !lab.hpOn,
                      ),
                      GroupRow(
                        key: const ValueKey('hp-remove'),
                        icon: Icons.close_rounded,
                        title: 'Remove these headphones',
                        onTap: lab.clearHeadphone,
                      ),
                    ],
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                  child: TextField(
                    key: const ValueKey('hp-search'),
                    controller: _q,
                    onChanged: _search,
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: _all.isEmpty ? (_listFailed ? 'The list did not load' : 'Loading the list…') : 'Search ${_all.length} headphones',
                      prefixIcon: const Icon(Icons.search_rounded),
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                if (_listFailed && _all.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Row(
                      children: [
                        Expanded(child: Text('Byte could not read its headphone list.', style: BT.sub.copyWith(color: p.secondary))),
                        TextButton(key: const ValueKey('hp-retry'), onPressed: _loadList, child: const Text('Try again')),
                      ],
                    ),
                  ),
                if (_q.text.trim().isNotEmpty && _hits.isEmpty && _all.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                    child: Text('No headphones match "${_q.text.trim()}". Try just the brand or model.', style: BT.sub.copyWith(color: p.secondary)),
                  ),
                for (final e in _hits)
                  ListTile(
                    key: ValueKey('hp-hit-${e.path}'),
                    leading: _loading == e.name ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.headphones_outlined),
                    title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(e.source, maxLines: 1, overflow: TextOverflow.ellipsis),
                    onTap: _loading == null ? () => _pick(e) : null,
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
                  child: Text('Correction profiles: AutoEq project (MIT License).', style: BT.caption.copyWith(color: p.secondary)),
                ),
                const SizedBox(height: 120),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// The frequency response that plays: the headphone correction (dashed), your
/// own curve (thin) and both together (bold). Drawn once per change.
class ResponseGraph extends StatelessWidget {
  final AudioLab lab;
  final double height;
  const ResponseGraph({super.key, required this.lab, this.height = 160});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(color: p.grouped, borderRadius: BorderRadius.circular(18)),
      child: CustomPaint(
        painter: ResponsePainter(
          correction: lab.hpOn ? lab.hpNodes : const [],
          own: lab.eqOn ? lab.nodes : const [],
          accent: p.accent,
          grid: p.separator,
          label: p.secondary,
        ),
        size: Size.infinite,
      ),
    );
  }
}

class ResponsePainter extends CustomPainter {
  final List<EqNode> correction, own;
  final Color accent, grid, label;
  ResponsePainter({required this.correction, required this.own, required this.accent, required this.grid, required this.label});

  static const range = 15.0;

  @override
  void paint(Canvas canvas, Size s) {
    const padL = 8.0, padR = 8.0, padT = 12.0, padB = 22.0;
    final w = s.width - padL - padR, h = s.height - padT - padB;
    double x(double f) => padL + w * (math.log(f / EqMath.minF) / math.log(EqMath.maxF / EqMath.minF));
    double y(double db) => padT + h / 2 - (db.clamp(-range, range) / range) * (h / 2);
    final g = Paint()
      ..color = grid
      ..strokeWidth = 0.6;
    for (final db in [-10.0, 0.0, 10.0]) {
      canvas.drawLine(Offset(padL, y(db)), Offset(padL + w, y(db)), g..strokeWidth = db == 0 ? 1 : 0.5);
    }
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final f in [100.0, 1000.0, 10000.0]) {
      canvas.drawLine(Offset(x(f), padT), Offset(x(f), padT + h), g..strokeWidth = 0.5);
      tp.text = TextSpan(text: f >= 1000 ? '${(f / 1000).round()}k' : '${f.round()}', style: TextStyle(color: label, fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(x(f) - tp.width / 2, padT + h + 5));
    }
    final freqs = EqMath.logFreqs(120);
    Path curve(List<EqNode> n) {
      final path = Path();
      for (var i = 0; i < freqs.length; i++) {
        final pt = Offset(x(freqs[i]), y(EqMath.curveDb(n, freqs[i])));
        i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
      }
      return path;
    }

    if (correction.isNotEmpty) {
      final dash = Paint()
        ..color = label.withValues(alpha: 0.8)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4;
      // dashed: every other short piece of the path
      for (final m in curve(correction).computeMetrics()) {
        for (var d = 0.0; d < m.length; d += 9) {
          canvas.drawPath(m.extractPath(d, math.min(d + 5, m.length)), dash);
        }
      }
    }
    if (own.isNotEmpty && correction.isNotEmpty) {
      canvas.drawPath(
        curve(own),
        Paint()
          ..color = accent.withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
    final all = [...correction, ...own];
    canvas.drawPath(
      curve(all),
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(covariant ResponsePainter o) => !_same(o.correction, correction) || !_same(o.own, own) || o.accent != accent || o.grid != grid;

  static bool _same(List<EqNode> a, List<EqNode> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
