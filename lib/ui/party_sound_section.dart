import 'package:flutter/material.dart';

import '../data/party_sound.dart';
import 'style.dart';

// Byte © 2026 Apurba Laskar.
//
// Listen together → the host's sound (1.4.2, 1.4.5): the host's switch,
// "Send now" and who said yes; a guest's question (Apply / Keep mine),
// "Use my own sound" and "Auto-accept host sound settings".

const partySoundNote = 'Your equalizer, bass, reverb, loudness, mono, balance, crossfeed and pitch. Not speed or slowed: they change the tempo, which would pull the party out of sync.';

/// "Apurba wants to share their sound settings (Bass Booster)".
String partySoundAsk(SoundOffer o) => '${o.hostName} wants to share their sound settings${o.name.isEmpty ? '' : ' (${o.name})'}';

class PartySoundSection extends StatelessWidget {
  final PartySound sound;
  const PartySoundSection({super.key, required this.sound});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([sound, sound.lab]),
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
            key: const ValueKey('party-sound-share'),
            icon: Icons.graphic_eq_rounded,
            title: 'Share my sound settings with guests',
            subtitle: sound.sharing ? sound.hostLine : 'Guests are asked first and can say no',
            trailing: ByteSwitch(value: sound.sharing, onChanged: (v) => sound.setSharing(v)),
          ),
          GroupRow(
            key: const ValueKey('party-sound-send-now'),
            icon: Icons.send_rounded,
            title: 'Send now',
            subtitle: 'Your sound now: ${PartySound.soundName(sound.lab.partySound())}',
            onTap: sound.sendNow,
          ),
          if (sound.sharing)
            for (final g in sound.guests)
              GroupRow(
                leading: _AnswerIcon(sound.answerOf(g.id)),
                title: g.name.isEmpty ? 'Listener' : g.name,
                value: switch (sound.answerOf(g.id)) {
                  GuestAnswer.accepted => 'Using your sound',
                  GuestAnswer.declined => 'Kept theirs',
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

  Widget _auto() => GroupRow(
    key: const ValueKey('party-sound-auto'),
    icon: Icons.bolt_rounded,
    title: 'Auto-accept host sound settings',
    subtitle: 'Use the host\'s sound without being asked',
    trailing: ByteSwitch(value: sound.lab.autoAcceptPartySound, onChanged: (v) => sound.lab.autoAcceptPartySound = v),
  );

  List<Widget> _guest(BuildContext context) {
    final p = BytePalette.of(context);
    final o = sound.offer;
    final place = sound.caps().place;
    if (o != null) {
      final skipped = o.skippedLine(place);
      return [
        const GroupLabel('Sound'),
        GroupCard(
          children: [
            Padding(
              key: const ValueKey('party-sound-offer'),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.graphic_eq_rounded, color: p.accent),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(partySoundAsk(o), style: BT.body.copyWith(color: p.label, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text('Your own sound comes back when you want or when you leave the party. Speed stays in sync.', style: BT.sub.copyWith(color: p.secondary)),
                  if (skipped != null) ...[
                    const SizedBox(height: 4),
                    Text(skipped, key: const ValueKey('party-sound-skipped'), style: BT.sub.copyWith(color: p.secondary)),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(key: const ValueKey('party-sound-keep'), onPressed: sound.decline, child: const Text('Keep mine')),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(key: const ValueKey('party-sound-apply'), onPressed: sound.accept, child: const Text('Apply')),
                      ),
                    ],
                  ),
                  Center(
                    child: TextButton(
                      key: const ValueKey('party-sound-no-more'),
                      onPressed: sound.declineForParty,
                      child: Text('Don\'t ask again this party', style: TextStyle(color: p.secondary)),
                    ),
                  ),
                ],
              ),
            ),
            _auto(),
          ],
        ),
      ];
    }
    if (sound.usingHostSound) {
      final skipped = sound.skippedNow;
      return [
        const GroupLabel('Sound'),
        GroupCard(
          children: [
            GroupRow(
              key: const ValueKey('party-sound-using'),
              icon: Icons.graphic_eq_rounded,
              title: "Using ${sound.usingHost ?? 'the host'}'s sound",
              subtitle: [?sound.hostSoundName, if (skipped.isNotEmpty) 'not here: ${skipped.join(', ')}'].join(' · '),
            ),
            GroupRow(
              key: const ValueKey('party-sound-own'),
              icon: Icons.person_rounded,
              title: 'Use my own sound',
              onTap: sound.turnOff,
            ),
            _auto(),
          ],
        ),
      ];
    }
    return [
      const GroupLabel('Sound'),
      GroupCard(children: [_auto()]),
    ];
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
