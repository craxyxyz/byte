// Byte © 2026 Apurba Laskar.
//
// 1.4.3: the host's "share my sound" offer reaches a guest wherever he is in
// the app (home, player, lyrics, settings), not only on the party screen.

import 'package:flutter/material.dart';

import '../data/party_sound.dart';
import '../services.dart';
import 'party_sound_section.dart' show partySoundAsk;

class PartySoundBanner extends StatelessWidget {
  final Widget child;
  final PartySound? sound;
  const PartySoundBanner({super.key, required this.child, this.sound});

  @override
  Widget build(BuildContext context) {
    PartySound? ps = sound;
    if (ps == null) {
      try {
        ps = Services.i.partySound;
      } catch (_) {}
    }
    if (ps == null) return child;
    final s = ps;
    return Stack(
      children: [
        child,
        ListenableBuilder(
          listenable: s,
          builder: (context, _) {
            final o = s.offer;
            return Positioned(
              left: 12,
              right: 12,
              top: 0,
              child: SafeArea(
                bottom: false,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 260),
                  transitionBuilder: (c, a) => SlideTransition(position: Tween(begin: const Offset(0, -1.2), end: Offset.zero).animate(a), child: FadeTransition(opacity: a, child: c)),
                  child: o == null ? const SizedBox.shrink(key: ValueKey('none')) : _Offer(key: ValueKey('offer-${o.gen}'), offer: o, sound: s),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _Offer extends StatelessWidget {
  final SoundOffer offer;
  final PartySound sound;
  const _Offer({super.key, required this.offer, required this.sound});

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('party-sound-banner'),
      color: const Color(0xF21C1C1E),
      elevation: 8,
      shadowColor: Colors.black54,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [Color(0xFFFF375F), Color(0xFF8E3BD6)])),
                  child: const Icon(Icons.graphic_eq_rounded, color: Colors.white, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(partySoundAsk(offer), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
                      Text(offer.skippedLine(sound.caps().place) ?? 'Only while you\'re in the party. Your own sound comes back when you leave.', key: const ValueKey('party-sound-banner-note'), style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(key: const ValueKey('party-sound-banner-never'), onPressed: sound.declineForParty, child: const Text('Don\'t ask again', style: TextStyle(color: Color(0x99FFFFFF)))),
                const Spacer(),
                TextButton(key: const ValueKey('party-sound-banner-decline'), onPressed: sound.decline, child: const Text('Keep mine', style: TextStyle(color: Color(0xCCFFFFFF)))),
                const SizedBox(width: 4),
                FilledButton(key: const ValueKey('party-sound-banner-accept'), onPressed: sound.accept, child: const Text('Apply')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
