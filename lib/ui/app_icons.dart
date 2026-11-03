import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The outline an icon is drawn in (the picker shows each in its own shape).
enum IconShape { rounded, squircle, circle }

class AppIconOption {
  final String id; // stored in settings
  final String label;
  final String native; // Android alias suffix (Logo<native>) / iOS AppIcon-<native>
  final IconShape shape;
  const AppIconOption(this.id, this.label, this.native, [this.shape = IconShape.rounded]);
  String get preview => 'assets/icons/$id.png';
}

/// Byte's icon pack: the "b)" mark in fifteen styles.
class AppIcons {
  static const _ch = MethodChannel('byte/icons');
  static const all = [
    AppIconOption('default', 'Default', 'Default'),
    AppIconOption('monochrome', 'Monochrome', 'Monochrome'),
    AppIconOption('liquid-glass', 'Liquid Glass', 'LiquidGlass'),
    AppIconOption('liquid-glass-dark', 'Liquid Glass Dark', 'LiquidGlassDark'),
    AppIconOption('liquid-glass-clear', 'Liquid Glass Clear', 'LiquidGlassClear'),
    AppIconOption('liquid-glass-clear-dark', 'Liquid Glass Clear Dark', 'LiquidGlassClearDark'),
    AppIconOption('neon-silver', 'Neon Silver', 'NeonSilver'),
    AppIconOption('neon-cyan', 'Neon Cyan', 'NeonCyan'),
    AppIconOption('neon-violet', 'Neon Violet', 'NeonViolet'),
    AppIconOption('soft-glass', 'Soft Glass', 'SoftGlass', IconShape.squircle),
    AppIconOption('soft-glass-dark', 'Soft Glass Dark', 'SoftGlassDark', IconShape.squircle),
    AppIconOption('soft-neon-cyan', 'Soft Neon Cyan', 'SoftNeonCyan', IconShape.squircle),
    AppIconOption('round-glass', 'Round Glass', 'RoundGlass', IconShape.circle),
    AppIconOption('round-glass-dark', 'Round Glass Dark', 'RoundGlassDark', IconShape.circle),
    AppIconOption('round-neon-cyan', 'Round Neon Cyan', 'RoundNeonCyan', IconShape.circle),
  ];

  /// The rows of the picker, laid out like the icon sheet.
  static const groups = <(String, List<String>)>[
    ('Classic', ['default', 'monochrome']),
    ('Liquid Glass', ['liquid-glass', 'liquid-glass-dark', 'liquid-glass-clear', 'liquid-glass-clear-dark']),
    ('Neon', ['neon-silver', 'neon-cyan', 'neon-violet']),
    ('Soft', ['soft-glass', 'soft-glass-dark', 'soft-neon-cyan']),
    ('Round', ['round-glass', 'round-glass-dark', 'round-neon-cyan']),
  ];

  static AppIconOption byId(String id) => all.firstWhere((e) => e.id == id, orElse: () => all.first);

  /// A saved id from an older version (e.g. "midnight") falls back to Default.
  static String normalize(String id) => all.any((e) => e.id == id) ? id : 'default';

  static bool get supported => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  static Future<bool> set(String id) async {
    final o = all.where((e) => e.id == id).firstOrNull;
    if (o == null || !supported) return false;
    try {
      return await _ch.invokeMethod<bool>('set', o.native) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// The icon the phone shows now (null when it can't be read).
  static Future<String?> current() async {
    if (!supported) return null;
    try {
      final n = await _ch.invokeMethod<String>('get');
      return all.where((e) => e.native == n).firstOrNull?.id;
    } catch (_) {
      return null;
    }
  }
}
