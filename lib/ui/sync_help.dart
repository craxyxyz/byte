// Byte © 2026 Apurba Laskar.
//
// Settings → Account & integrations → a music app → "How sync works"
// (1.4.4, Apurba: "Sync wala option bhi instructions dena"). Plain steps,
// and exactly what the code does: when it syncs, what comes in, which way.

import 'package:flutter/material.dart';

import 'style.dart';

class SyncHelpStep {
  final String title;
  final String body;
  const SyncHelpStep(this.title, this.body);
}

/// The steps for [service]. [automatic] = the app syncs by itself (Spotify
/// account sync); otherwise Sync now re-reads the app's own page.
List<SyncHelpStep> syncHelpSteps(String service, {required bool automatic}) => automatic
    ? [
        SyncHelpStep('Log in', 'Log in to your $service account on this page. You only do this once.'),
        SyncHelpStep(
          'Your playlists on Home',
          'They show on Home under "From $service", Liked Songs first. Tap one to play it. If it isn\'t in Byte yet, Byte brings it in right then. Import on this page does the same.',
        ),
        const SyncHelpStep(
          'Keep in sync',
          'When it\'s on, Byte brings in your Liked Songs and all your playlists by itself: it checks when you open Byte and every 3 hours while it\'s open, and syncs if the last sync was more than 6 hours ago. Only new songs are looked up, so it\'s quick.',
        ),
        const SyncHelpStep('Sync now', 'Checks right away.'),
        SyncHelpStep(
          'If it says "Couldn\'t sync"',
          'Byte tries again by itself (after 2 min, 10 min, 30 min, then every hour), and Home keeps showing your last list. If it keeps failing: tap Log out of $service, log in again, then tap Sync now.',
        ),
      ]
    : [
        SyncHelpStep('Log in', 'Log in to $service on this page. Right after, Byte brings in your liked songs and playlists.'),
        SyncHelpStep('Your playlists on Home', 'They show on Home under "From $service". Tap one to play it.'),
        SyncHelpStep('Sync now', 'Opens $service\'s page again, reads your library and updates those playlists in Byte.'),
        SyncHelpStep('No automatic sync yet', 'For $service, Byte syncs only when you tap Sync now. Tap it after you change something there.'),
        const SyncHelpStep('If it says "Couldn\'t sync"', 'Log out, log in again, then tap Sync now.'),
      ];

String syncHelpWhat(String service) =>
    'What comes in: your liked songs and playlists, one way, from $service into Byte. Changing something in Byte never changes your $service account. Songs are matched to Byte\'s catalogue; a few may not be found.';

Future<void> showSyncHelp(BuildContext context, {required String service, required bool automatic}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useRootNavigator: true,
  useSafeArea: true,
  showDragHandle: true,
  backgroundColor: BytePalette.of(context).grouped,
  builder: (_) => SyncHelpSheet(service: service, automatic: automatic),
);

class SyncHelpSheet extends StatelessWidget {
  final String service;
  final bool automatic;
  const SyncHelpSheet({super.key, required this.service, required this.automatic});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final steps = syncHelpSteps(service, automatic: automatic);
    return SingleChildScrollView(
      key: const ValueKey('sync-help'),
      padding: EdgeInsets.fromLTRB(20, 0, 20, 24 + MediaQuery.paddingOf(context).bottom),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'How sync works',
            style: BT.title3.copyWith(color: p.label, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle),
                    child: Text(
                      '${i + 1}',
                      style: BT.caption.copyWith(color: Colors.white, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          steps[i].title,
                          style: BT.body.copyWith(color: p.label, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(steps[i].body, style: BT.sub.copyWith(color: p.secondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(12)),
            child: Text(syncHelpWhat(service), style: BT.sub.copyWith(color: p.secondary)),
          ),
        ],
      ),
    );
  }
}
