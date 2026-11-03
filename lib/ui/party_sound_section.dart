import 'package:flutter/material.dart';

import '../data/party_sound.dart';
import 'style.dart';

// Byte © 2026 Apurba Laskar.
//
// Listen together → the host's sound (1.4.2): the host's switch and who said
// yes; a guest's question (Accept / Decline) and "Using …'s sound · Turn off".

const partySoundNote = 'Your equalizer, bass, reverb, loudness, mono, balance, crossfeed and pitch. Not speed or slowed: they change the tempo, which would pull the party out of sync.';

class PartySoundSection extends StatelessWidget {
  final PartySound sound;
  const PartySoundSection({super.key, required this.sound});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sound,
      builder: (context, _) {
        final link = sound.link;
        if (!link.active) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: link.isHost ? _host(context) : _guest(context),
        );
      },
    );
  }

  List<Widget> _host(BuildContext context) {
    final p = BytePalette.of(context);
    return [
      const GroupLabel('Sound'),
      GroupCard(
        dividerIndent: 64,
        children: [
          GroupRow(
            icon: Icons.graphic_eq_rounded,
            title: 'Share my sound with guests',
            subtitle: sound.sharing ? sound.hostLine : 'Guests are asked first and can say no',
            trailing: ByteSwitch(value: sound.sharing, onChanged: (v) => sound.setSharing(v)),
          ),
          if (sound.sharing)
            for (final g in sound.guests)
              GroupRow(
                leading: _AnswerIcon(sound.answerOf(g.id)),
                title: g.name.isEmpty ? 'Listener' : g.name,
                value: switch (sound.answerOf(g.id)) {
                  GuestAnswer.accepted => 'Using your sound',
                  GuestAnswer.declined => 'Said no',
                  GuestAnswer.waiting => 'Asked',
                },
              ),
        ],
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 6, 32, 0),
        child: Text(partySoundNote, style: BT.sub.copyWith(color: p.secondary, fontSize: 13)),
      ),
    ];
  }

  List<Widget> _guest(BuildContext context) {
    final p = BytePalette.of(context);
    final o = sound.offer;
    if (o != null) {
      return [
        const GroupLabel('Sound'),
        GroupCard(
          children: [
            Padding(
              key: const ValueKey('party-sound-offer'),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.graphic_eq_rounded, color: p.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text('${o.hostName} wants to share their sound', style: BT.body.copyWith(color: p.label, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Your own sound comes back when you turn it off or leave the party. Speed stays yours.', style: BT.sub.copyWith(color: p.secondary)),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(onPressed: sound.decline, child: const Text('Decline')),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(onPressed: sound.accept, child: const Text('Accept')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ];
    }
    if (sound.usingHostSound) {
      return [
        const GroupLabel('Sound'),
        GroupCard(
          children: [
            GroupRow(
              icon: Icons.graphic_eq_rounded,
              title: "Using ${sound.usingHost ?? 'the host'}'s sound",
              value: 'Turn off',
              onTap: sound.turnOff,
            ),
          ],
        ),
      ];
    }
    return const [];
  }
}

class _AnswerIcon extends StatelessWidget {
  final GuestAnswer a;
  const _AnswerIcon(this.a);
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return switch (a) {
      GuestAnswer.accepted => const Icon(Icons.check_circle_rounded, color: Color(0xFF34C759), semanticLabel: 'Accepted'),
      GuestAnswer.declined => Icon(Icons.remove_circle_outline_rounded, color: p.secondary, semanticLabel: 'Declined'),
      GuestAnswer.waiting => Icon(Icons.schedule_rounded, color: p.tertiary, semanticLabel: 'Waiting'),
    };
  }
}
