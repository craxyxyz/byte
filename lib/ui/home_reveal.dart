import 'dart:async';

import 'package:flutter/material.dart';

import '../services.dart';

/// Home-page entrance, read from the reference recording: sections come in one
/// after another from the top of the page in bursts about 0.3 s apart (the first
/// at about 0.37 s), each rising a short way while it fades up. The rise and the
/// stagger are read off the stills, not measured to the pixel.
///
/// Byte's version: each section starts [kHomeRevealStep] after the one above
/// it (capped at [kHomeRevealMaxSteps] steps, so the whole page is in by about 1.9 s), runs
/// for [kHomeRevealDuration] and then removes its own wrapper, so a settled
/// section costs nothing per frame. It plays once per section, on its first
/// build. Reduce-motion, or the system's disable-animations flag, shows the
/// page at once.
const Duration kHomeRevealStep = Duration(milliseconds: 280);
const Duration kHomeRevealDuration = Duration(milliseconds: 480);
const int kHomeRevealMaxSteps = 5;
const double kHomeRevealRise = 22;

/// Start delay for a section at [index] (its place in the page, top first).
Duration homeRevealDelay(int index) => kHomeRevealStep * index.clamp(0, kHomeRevealMaxSteps);

/// The app's own Reduce motion switch (Settings → Performance). Read defensively
/// so a screen built without the services running still shows its sections.
bool _appReduceMotion() {
  try {
    return Services.i.settings.reduceMotion;
  } catch (_) {
    return false;
  }
}

/// Wraps one section of the home page in its entrance. Cheap by construction:
/// the controller only moves a translate and an opacity, the child is passed
/// through the builder unchanged (no per-frame rebuild of the section), and
/// once the entrance has finished the wrapper is gone.
class HomeReveal extends StatefulWidget {
  final int index;
  final Widget child;
  const HomeReveal({super.key, required this.index, required this.child});

  @override
  State<HomeReveal> createState() => _HomeRevealState();
}

class _HomeRevealState extends State<HomeReveal> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  Timer? _start;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final system = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (system || _appReduceMotion()) return;
    final c = AnimationController(vsync: this, duration: kHomeRevealDuration);
    _c = c;
    final delay = homeRevealDelay(widget.index);
    if (delay == Duration.zero) {
      c.forward();
    } else {
      _start = Timer(delay, () {
        if (mounted) c.forward();
      });
    }
  }

  @override
  void dispose() {
    _start?.cancel();
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The same widget tree in every state, so the section's own state (a
    // scroll position, a loaded image) is never remounted when the entrance
    // ends. Once settled the opacity is 1 and the offset is zero, which paint
    // the child as it is: no layer is kept for it.
    final c = _c;
    return AnimatedBuilder(
      animation: c ?? kAlwaysCompleteAnimation,
      child: widget.child,
      builder: (context, child) {
        final t = c == null ? 1.0 : Curves.easeOutCubic.transform(c.value);
        return Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * kHomeRevealRise), child: child),
        );
      },
    );
  }
}
