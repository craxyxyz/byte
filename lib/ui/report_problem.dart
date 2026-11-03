// Byte © 2026 Apurba Laskar.
//
// 1.4.5: Settings → About → Report a problem. Shows what Byte wrote down
// when something went wrong (core/crash_log.dart, plus Android's own crash
// reports and the reasons Android gave for closing Byte) and shares or
// copies it.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/crash_log.dart';
import 'glass.dart';
import 'style.dart';

/// Opens the sheet for [log] (the app's own log when null).
Future<void> showReportProblemSheet(BuildContext context, {CrashLog? log, Future<void> Function(String text)? share}) {
  final l = log ?? CrashLog.i ?? CrashLog();
  return showByteSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => ReportProblemSheet(log: l, share: share),
  );
}

class ReportProblemSheet extends StatefulWidget {
  final CrashLog log;

  /// How the report is shared (the system share sheet when null).
  final Future<void> Function(String text)? share;
  const ReportProblemSheet({super.key, required this.log, this.share});

  @override
  State<ReportProblemSheet> createState() => _ReportProblemSheetState();
}

class _ReportProblemSheetState extends State<ReportProblemSheet> {
  late String _text = widget.log.read();

  Future<void> _copy(String report, {String said = 'Copied'}) async {
    await Clipboard.setData(ClipboardData(text: report));
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(said)));
  }

  Future<void> _share() async {
    final report = widget.log.report();
    try {
      final s = widget.share;
      if (s != null) {
        await s(report);
      } else {
        await SharePlus.instance.share(ShareParams(text: report, subject: 'Byte problem report'));
      }
    } catch (_) {
      // no share sheet on this device: the text goes to the clipboard instead
      await _copy(report, said: 'Copied, paste it in a message');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final empty = _text.isEmpty;
    final n = RegExp(r'^\[\d{4}-', multiLine: true).allMatches(_text).length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Report a problem', style: BT.title3.copyWith(color: p.label)),
            const SizedBox(height: 6),
            Text(
              empty
                  ? 'Nothing has gone wrong so far. If Byte closes by itself, come back here and share the report.'
                  : '$n ${n == 1 ? 'thing' : 'things'} went wrong. Share this report so the cause can be fixed. It has no passwords, messages or songs you searched.',
              style: BT.sub.copyWith(color: p.secondary),
            ),
            const SizedBox(height: 12),
            if (!empty)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                child: Container(
                  decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.all(12),
                  child: SingleChildScrollView(
                    reverse: true, // newest at the bottom, shown first
                    child: SelectableText(
                      _text,
                      key: const ValueKey('crash-log-text'),
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.35, color: p.label),
                    ),
                  ),
                ),
              ),
            if (!empty) const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    key: const ValueKey('report-share'),
                    onPressed: _share,
                    icon: const Icon(Icons.ios_share_rounded, size: 18),
                    label: const Text('Share'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('report-copy'),
                    onPressed: () => _copy(widget.log.report()),
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    label: const Text('Copy'),
                  ),
                ),
              ],
            ),
            if (!empty)
              TextButton(
                key: const ValueKey('report-clear'),
                onPressed: () => setState(() {
                  widget.log.clear();
                  _text = widget.log.read();
                }),
                child: const Text('Clear the report'),
              ),
          ],
        ),
      ),
    );
  }
}
