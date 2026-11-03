import 'package:flutter/material.dart';

import '../../data/usage.dart';
import '../../services.dart';
import '../page.dart';
import '../style.dart';
import '../nav.dart';
import 'sync_screen.dart';

/// Settings → Admin: who uses Byte and how. Only Byte's owner sees the row,
/// and the server answers only his account (signed in with an email code).
class AdminScreen extends StatefulWidget {
  /// For tests: where the numbers come from.
  final Future<AdminOverview> Function()? load;
  const AdminScreen({super.key, this.load});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  late Future<AdminOverview> _f = _load();
  int days = 30;

  Future<AdminOverview> _load() => widget.load?.call() ?? Services.i.admin.overview(days: days);

  String _ago(DateTime? t) {
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 2) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 30) return '${d.inDays} d ago';
    return '${t.day}/${t.month}/${t.year}';
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return SubPage(capWidth: true, 
      title: 'Admin',
      showProfile: false,
      slivers: [
        SliverToBoxAdapter(
          child: FutureBuilder<AdminOverview>(
            future: _f,
            builder: (context, s) {
              if (s.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()));
              }
              if (s.hasError) {
                final msg = s.error is AdminProblem ? (s.error as AdminProblem).message : 'Couldn\'t load the numbers. Try again.';
                return Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Text(msg, key: const ValueKey('admin-error'), textAlign: TextAlign.center, style: BT.body.copyWith(color: p.secondary)),
                      const SizedBox(height: 14),
                      if (msg.contains('email code'))
                        FilledButton(
                          onPressed: () => pushPage(context, const SyncScreen(startWith: SyncStart.code)),
                          child: const Text('Sign in with an email code'),
                        ),
                      TextButton(onPressed: () => setState(() => _f = _load()), child: const Text('Try again')),
                    ],
                  ),
                );
              }
              final o = s.data!;
              final maxDay = o.daily.fold<int>(1, (a, d) => d.$2 > a ? d.$2 : a);
              Widget stat(String label, int v, {Key? key}) => Expanded(
                child: Container(
                  key: key,
                  margin: const EdgeInsets.all(4),
                  padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                  decoration: BoxDecoration(color: p.grouped, borderRadius: BorderRadius.circular(14)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$v', style: BT.title2.copyWith(color: p.label, fontWeight: FontWeight.w800)),
                      Text(label, style: BT.caption.copyWith(color: p.secondary)),
                    ],
                  ),
                ),
              );
              return Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 120),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(children: [stat('Phones', o.devices, key: const ValueKey('admin-devices')), stat('Byte accounts', o.accounts), stat('Active today', o.activeToday)]),
                    Row(children: [stat('Active 7 days', o.active7d), stat('Plays 7 days', o.plays7d), stat('Plays total', o.playsTotal)]),
                    const SizedBox(height: 10),
                    const GroupLabel('Daily active phones'),
                    SizedBox(
                      height: 90,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final d in o.daily)
                            Expanded(
                              child: Tooltip(
                                message: '${d.$1}: ${d.$2}',
                                child: Container(
                                  margin: const EdgeInsets.symmetric(horizontal: 1),
                                  height: 4 + 82 * d.$2 / maxDay,
                                  decoration: BoxDecoration(color: p.accent, borderRadius: BorderRadius.circular(3)),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const GroupLabel('Top songs (30 days)'),
                    GroupCard(
                      children: [
                        if (o.topSongs.isEmpty) const GroupRow(title: 'No plays yet'),
                        for (final (i, t) in o.topSongs.take(15).indexed)
                          GroupRow(title: '${i + 1}. ${t.$1}', subtitle: t.$2, value: '${t.$3}'),
                      ],
                    ),
                    const GroupLabel('Top artists (30 days)'),
                    GroupCard(
                      children: [
                        if (o.topArtists.isEmpty) const GroupRow(title: 'No plays yet'),
                        for (final (i, t) in o.topArtists.take(10).indexed) GroupRow(title: '${i + 1}. ${t.$1}', value: '${t.$2}'),
                      ],
                    ),
                    GroupLabel('People (${o.users.length})'),
                    GroupCard(
                      children: [
                        for (final u in o.users)
                          GroupRow(
                            key: ValueKey('admin-user-${u.email}${u.device}'),
                            icon: u.email.isEmpty ? Icons.smartphone_rounded : Icons.person_rounded,
                            title: u.name.isNotEmpty ? u.name : (u.email.isNotEmpty ? u.email : (u.device.isEmpty ? 'A phone' : u.device)),
                            subtitle: [
                              if (u.email.isNotEmpty && u.name.isNotEmpty) u.email,
                              [u.device, u.platform].where((x) => x.isNotEmpty).join(' · '),
                              if (u.appVersion.isNotEmpty) 'Byte ${u.appVersion}',
                              '${u.plays} plays · ${u.minutes} min',
                            ].where((x) => x.isNotEmpty).join('\n'),
                            value: _ago(u.lastActive),
                          ),
                      ],
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                      child: Text(
                        'Phones that turned off "Share usage" don\'t appear. No passwords or locations are ever collected.',
                        style: BT.caption.copyWith(color: p.secondary),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
