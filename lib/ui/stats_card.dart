import 'package:flutter/material.dart';

import '../data/stats.dart';
import '../services.dart';
import 'nav.dart';
import 'screens/library_pages.dart';
import 'style.dart';

/// "Your listening experience": swipeable cards with this year's minutes,
/// top song, album and artist. Counted on this phone. Tap → Replay.
class StatsCarousel extends StatelessWidget {
  const StatsCarousel({super.key});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.stats.thisYear;
    final name = (Services.i.account.name ?? Services.i.settings.listenName).trim();
    final since = Services.i.settings.memberSince;
    final w = MediaQuery.sizeOf(context).width;
    final cardW = w >= 820 ? 380.0 : w - 16 - 54;
    final cards = <Widget>[
      _StatCard(big: '${st.minutes}', label: 'MINUTES LISTENED', name: name, detail: '${st.plays} ${st.plays == 1 ? 'play' : 'plays'} · ${st.year}', since: since),
      if (st.songs.isNotEmpty)
        _StatCard(
          big: st.songs.first.item.title,
          label: 'TOP SONG',
          name: name,
          detail: st.songs.first.item.artistLine,
          since: since,
          title: true,
        ),
      if (st.albums.isNotEmpty) _StatCard(big: st.albums.first.name, label: 'TOP ALBUM', name: name, detail: st.albums.first.detail ?? '', since: since, title: true),
      if (st.artists.isNotEmpty)
        _StatCard(
          big: st.artists.first.name,
          label: 'TOP ARTIST',
          name: name,
          detail: '${st.artists.first.minutes} min · ${st.artists.first.plays} ${st.artists.first.plays == 1 ? 'play' : 'plays'}',
          since: since,
          title: true,
          dark: true,
        ),
    ];
    return SizedBox(
      height: 236,
      child: ListView.separated(
        key: const ValueKey('stats-carousel'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
        physics: const PageScrollPhysics(),
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 14),
        itemBuilder: (c, i) => SizedBox(
          width: cardW,
          child: Pressable(onTap: () => pushPage(context, const ReplayScreen()), child: cards[i]),
        ),
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String big;
  final String label;
  final String name;
  final String detail;
  final DateTime since;
  final bool title;
  final bool dark;
  const _StatCard({
    required this.big,
    required this.label,
    required this.name,
    required this.detail,
    required this.since,
    this.title = false,
    this.dark = false,
  });

  @override
  Widget build(BuildContext context) {
    final colors = dark ? const [Color(0xFF0E0E10), Color(0xFF26262B), Color(0xFF3A3A40)] : const [Color(0xFF1B0A36), Color(0xFF45124F), Color(0xFF7A1D4D)];
    const white = Colors.white;
    final dim = Colors.white.withValues(alpha: 0.72);
    final mm = since.month.toString().padLeft(2, '0');
    final yy = (since.year % 100).toString().padLeft(2, '0');
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(colors: colors, begin: Alignment.topLeft, end: Alignment.bottomRight),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.22), blurRadius: 18, offset: const Offset(0, 8))],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          // soft glows for depth
          Positioned(
            right: -40,
            top: -50,
            child: _Glow(color: (dark ? const Color(0xFF6B6B78) : const Color(0xFFB0306E)).withValues(alpha: 0.45), size: 200),
          ),
          Positioned(left: -60, bottom: -70, child: _Glow(color: (dark ? const Color(0xFF2B2B33) : const Color(0xFF4B1C8C)).withValues(alpha: 0.5), size: 220)),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('YOUR LISTENING EXPERIENCE', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: dim, fontSize: 11.5, letterSpacing: 1.6, fontWeight: FontWeight.w600)),
                    ),
                    const _Wave(),
                  ],
                ),
                const Spacer(),
                Text(
                  big,
                  maxLines: title ? 2 : 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: white, fontSize: title ? 26 : 34, height: 1.1, fontWeight: FontWeight.w800, letterSpacing: -0.6),
                ),
                const SizedBox(height: 4),
                Text(label, style: TextStyle(color: dim, fontSize: 11.5, letterSpacing: 1.6, fontWeight: FontWeight.w600)),
                const Spacer(),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (name.isNotEmpty)
                            Text(name.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: white, fontSize: 14, letterSpacing: 1.4, fontWeight: FontWeight.w800)),
                          Text(detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: dim, fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('MEMBER SINCE', style: TextStyle(color: dim, fontSize: 9.5, letterSpacing: 1.2, fontWeight: FontWeight.w600)),
                        Text('$mm/$yy', style: const TextStyle(color: white, fontSize: 14, letterSpacing: 1.4, fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Glow extends StatelessWidget {
  final Color color;
  final double size;
  const _Glow({required this.color, required this.size});
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(shape: BoxShape.circle, gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)])),
  );
}

/// Small white sound-wave glyph (Byte's own) at the card's corner.
class _Wave extends StatelessWidget {
  const _Wave();
  @override
  Widget build(BuildContext context) => SizedBox(width: 26, height: 18, child: CustomPaint(painter: _WavePainter()));
}

class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.4;
    const hs = [0.35, 0.8, 1.0, 0.55, 0.75];
    final step = s.width / (hs.length - 1);
    for (var i = 0; i < hs.length; i++) {
      final x = i * step;
      final h = s.height * hs[i];
      canvas.drawLine(Offset(x, (s.height - h) / 2), Offset(x, (s.height + h) / 2), p);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Kept for the Replay page: what the numbers mean in one line.
String statsFootnote(YearStats st) => 'Counted on this phone since ${st.year}. A play counts after ${ListeningStats.playThreshold.inSeconds} seconds.';
