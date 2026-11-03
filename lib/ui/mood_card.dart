import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services.dart';
import 'style.dart';
import 'widgets.dart';

/// Remembers one picture per mood/genre (the first playlist's cover), so the
/// Explore grid fills in with art the way the reference does.
class MoodArt {
  static final Map<String, String?> _mem = {};
  static final Map<String, Future<String?>> _pending = {};
  static int _running = 0;
  static final List<Completer<void>> _queue = [];

  static String? cached(String params) {
    if (_mem.containsKey(params)) return _mem[params];
    try {
      final v = Services.i.library.get('moodimg:$params');
      if (v is Map && (DateTime.now().millisecondsSinceEpoch - ((v['t'] as num?) ?? 0)) < const Duration(days: 7).inMilliseconds) {
        return _mem[params] = v['u'] as String?;
      }
    } catch (_) {}
    return null;
  }

  static Future<String?> load(String params) {
    final c = cached(params);
    if (c != null) return Future.value(c);
    return _pending[params] ??= _fetch(params).whenComplete(() => _pending.remove(params));
  }

  static Future<String?> _fetch(String params) async {
    if (_running >= 3) {
      final w = Completer<void>();
      _queue.add(w);
      await w.future;
    }
    _running++;
    try {
      final yt = Services.i.yt;
      // Byte's own cards (New releases / Charts / Podcasts) borrow the cover
      // of their real page.
      final shelves = await switch (params) {
        '_new' => yt.newReleases(),
        '_charts' => yt.charts(),
        '_podcasts' => yt.podcasts(),
        _ => yt.moodPage(params),
      }.timeout(const Duration(seconds: 25));
      final url = shelves.expand((s) => s.items).map((i) => i.thumb).whereType<String>().firstOrNull;
      _mem[params] = url;
      await Services.i.library.put('moodimg:$params', {'u': url, 't': DateTime.now().millisecondsSinceEpoch});
      return url;
    } catch (_) {
      return null;
    } finally {
      _running--;
      if (_queue.isNotEmpty) _queue.removeAt(0).complete();
    }
  }
}

/// Explore card: a solid colour strip on the left blending into the
/// category's cover art, tinted with the same colour.
class MoodCard extends StatefulWidget {
  final MoodCategory mood;
  final VoidCallback onTap;
  const MoodCard({super.key, required this.mood, required this.onTap});
  @override
  State<MoodCard> createState() => _MoodCardState();
}

class _MoodCardState extends State<MoodCard> {
  String? url;
  @override
  void initState() {
    super.initState();
    url = MoodArt.cached(widget.mood.params);
    if (url == null) {
      MoodArt.load(widget.mood.params).then((u) {
        if (mounted && u != null) setState(() => url = u);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final base = Color(widget.mood.color);
    final hsl = HSLColor.fromColor(base);
    final deep = hsl.withLightness((hsl.lightness * 0.62).clamp(0.12, 0.5)).toColor();
    final strip = hsl.withLightness(hsl.lightness.clamp(0.32, 0.6)).withSaturation((hsl.saturation * 1.05).clamp(0.0, 1.0)).toColor();
    final provider = imageProviderFor(resizeThumb(url, 226));
    return Pressable(
      onTap: widget.onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: LayoutBuilder(
          builder: (context, c) {
            final stripW = c.maxWidth * 0.28;
            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: deep),
                if (provider != null)
                  Positioned(
                    left: stripW * 0.6,
                    top: 0,
                    bottom: 0,
                    right: 0,
                    child: AnimatedOpacity(
                      opacity: 1,
                      duration: const Duration(milliseconds: 300),
                      child: ColorFiltered(
                        colorFilter: ColorFilter.mode(base.withValues(alpha: 0.55), BlendMode.color),
                        child: Image(image: provider, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, _, _) => const SizedBox.shrink()),
                      ),
                    ),
                  ),
                // tint over the art
                Positioned.fill(left: stripW * 0.6, child: ColoredBox(color: deep.withValues(alpha: 0.35))),
                // the strip, fading into the art
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: stripW * 1.5,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [strip, strip, strip.withValues(alpha: 0)], stops: const [0, 0.62, 1]),
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  top: 12,
                  right: 10,
                  child: Text(
                    widget.mood.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 17, letterSpacing: -0.2, height: 1.15, shadows: [Shadow(color: Color(0x40000000), blurRadius: 6)]),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class MoodSkeleton extends StatelessWidget {
  const MoodSkeleton({super.key});
  @override
  Widget build(BuildContext context) => const Skel(height: 112, radius: 14);
}
