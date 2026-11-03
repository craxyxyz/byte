import 'package:flutter/material.dart';

import '../services.dart';
import 'app_icons.dart';
import 'page.dart';
import 'style.dart';
import 'widgets.dart';

/// Settings → Appearance → App icon: all fifteen icons on a grey card, in
/// rows with their names underneath (like the icon sheet).
class AppIconScreen extends StatefulWidget {
  const AppIconScreen({super.key});
  @override
  State<AppIconScreen> createState() => _AppIconScreenState();
}

class _AppIconScreenState extends State<AppIconScreen> {
  String? _busy;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  /// Show what the phone really has (e.g. after a reinstall).
  Future<void> _sync() async {
    final now = await AppIcons.current();
    final st = Services.i.settings;
    if (now != null && now != st.appIcon && mounted) st.appIcon = now;
  }

  Future<void> _pick(AppIconOption o) async {
    final st = Services.i.settings;
    if (_busy != null || AppIcons.normalize(st.appIcon) == o.id) return;
    setState(() => _busy = o.id);
    final ok = await AppIcons.set(o.id);
    if (ok) st.appIcon = o.id;
    if (!mounted) return;
    setState(() => _busy = null);
    toast(context, ok ? '${o.label} icon chosen. It shows on your home screen after you leave Byte.' : 'Couldn\'t change the icon');
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Services.i.settings,
      builder: (context, _) {
        final p = BytePalette.of(context);
        final current = AppIcons.normalize(Services.i.settings.appIcon);
        return SubPage(
          title: 'App icon',
          showProfile: false,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Container(
                  decoration: BoxDecoration(color: p.grouped, borderRadius: BorderRadius.circular(24)),
                  padding: const EdgeInsets.fromLTRB(8, 18, 8, 10),
                  child: AppIconGrid(current: current, busy: _busy, onPick: AppIcons.supported ? _pick : null),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 12, 32, 0),
                child: Text(
                  AppIcons.supported
                      ? 'The icon changes on your home screen; the app stays the same. On Android the launcher shapes it to match your phone; on iPhone, iOS asks you to confirm.'
                      : 'Changing the icon works in the phone app.',
                  style: BT.sub.copyWith(color: p.secondary),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 24)),
          ],
        );
      },
    );
  }
}

/// The icon sheet itself (also used by tests).
class AppIconGrid extends StatelessWidget {
  final String current;
  final String? busy;
  final void Function(AppIconOption)? onPick;
  const AppIconGrid({super.key, required this.current, this.busy, this.onPick});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 640 ? 5 : (c.maxWidth >= 420 ? 4 : 3);
        final tileW = c.maxWidth / cols;
        final icon = (tileW - 26).clamp(56.0, 92.0);
        final tiles = [
          for (final g in AppIcons.groups)
            for (final id in g.$2) AppIcons.byId(id),
        ];
        return Wrap(
          runSpacing: 16,
          children: [
            for (final o in tiles)
              SizedBox(
                width: tileW,
                child: _IconTile(option: o, size: icon, selected: o.id == current, busy: busy == o.id, onTap: onPick == null ? null : () => onPick!(o)),
              ),
          ],
        );
      },
    );
  }
}

class _IconTile extends StatelessWidget {
  final AppIconOption option;
  final double size;
  final bool selected;
  final bool busy;
  final VoidCallback? onTap;
  const _IconTile({required this.option, required this.size, required this.selected, required this.busy, this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '${option.label} icon',
      excludeSemantics: true,
      child: Pressable(
        onTap: onTap,
        child: Column(
          children: [
            SizedBox(
              width: size + 12,
              height: size + 12,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // selection ring in the icon's own shape
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: size + 12,
                    height: size + 12,
                    decoration: BoxDecoration(
                      shape: option.shape == IconShape.circle ? BoxShape.circle : BoxShape.rectangle,
                      borderRadius: option.shape == IconShape.circle ? null : BorderRadius.circular((size + 12) * (option.shape == IconShape.squircle ? 0.36 : 0.27)),
                      border: Border.all(color: selected ? p.accent : Colors.transparent, width: 3),
                    ),
                  ),
                  Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 8, offset: const Offset(0, 3))],
                      shape: option.shape == IconShape.circle ? BoxShape.circle : BoxShape.rectangle,
                      borderRadius: option.shape == IconShape.circle ? null : BorderRadius.circular(size * (option.shape == IconShape.squircle ? 0.36 : 0.225)),
                    ),
                    child: Image.asset(option.preview, width: size, height: size, filterQuality: FilterQuality.medium),
                  ),
                  if (busy) SizedBox(width: size * 0.4, height: size * 0.4, child: const CircularProgressIndicator(strokeWidth: 3, color: Colors.white)),
                  if (selected)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(color: p.accent, shape: BoxShape.circle, border: Border.all(color: p.grouped, width: 2.5)),
                        child: const Icon(Icons.check_rounded, size: 15, color: Colors.white),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                option.label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: BT.caption.copyWith(color: selected ? p.label : p.secondary, fontWeight: selected ? FontWeight.w700 : FontWeight.w500, height: 1.2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
