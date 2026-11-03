import 'package:flutter/material.dart';

import '../../services.dart';
import '../style.dart';
import 'login_screen.dart';
import 'sync_screen.dart';

// Byte © 2026 Apurba Laskar. First launch: your name, then connect or skip.

class OnboardingScreen extends StatefulWidget {
  final VoidCallback onDone;
  const OnboardingScreen({super.key, required this.onDone});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final name = TextEditingController();
  int step = 0;

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  void _finish() {
    Services.i.settings.onboarded = true;
    widget.onDone();
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    _finish();
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 380),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: SlideTransition(position: Tween(begin: const Offset(0.06, 0), end: Offset.zero).animate(a), child: c),
          ),
          child: step == 0 ? _nameStep(p) : _connectStep(p),
        ),
      ),
    );
  }

  Widget _nameStep(BytePalette p) => Padding(
    key: const ValueKey('ob-name'),
    padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Welcome to Byte', style: BT.largeTitle.copyWith(color: p.label)),
        const SizedBox(height: 8),
        Text('What should we call you?', style: BT.body.copyWith(color: p.secondary)),
        const SizedBox(height: 24),
        TextField(
          key: const ValueKey('ob-name-field'),
          controller: name,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'Your name'),
          onSubmitted: (_) => _next(),
        ),
        const Spacer(),
        SizedBox(
          width: double.infinity,
          child: FilledButton(key: const ValueKey('ob-continue'), onPressed: _next, child: const Text('Continue')),
        ),
      ],
    ),
  );

  void _next() {
    final n = name.text.trim();
    if (n.isNotEmpty) Services.i.settings.listenName = n;
    setState(() => step = 1);
  }

  Widget _connectStep(BytePalette p) {
    final n = Services.i.settings.listenName;
    return Padding(
      key: const ValueKey('ob-connect'),
      padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(n.isEmpty ? 'Bring your music' : 'Hi $n', style: BT.largeTitle.copyWith(color: p.label)),
          const SizedBox(height: 8),
          Text('Connect to bring your playlists, likes and mixes. You can do this later in Settings.', style: BT.body.copyWith(color: p.secondary)),
          const Spacer(),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: const ValueKey('ob-youtube'),
              onPressed: () => _open(const LoginScreen()),
              icon: const Icon(Icons.play_circle_fill_rounded),
              label: const Text('Connect YouTube Music'),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              key: const ValueKey('ob-byte'),
              onPressed: () => _open(const SyncScreen()),
              icon: const Icon(Icons.account_circle_outlined),
              label: const Text('Sign in to Byte'),
            ),
          ),
          const SizedBox(height: 6),
          Center(child: TextButton(key: const ValueKey('ob-skip'), onPressed: _finish, child: const Text('Skip'))),
        ],
      ),
    );
  }
}
