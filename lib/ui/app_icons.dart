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
    AppIconOption('samsung-glass', 'Samsung Glass', 'SamsungGlass', IconShape.squircle),
    AppIconOption('samsung-glass-dark', 'Samsung Glass Dark', 'SamsungGlassDark', IconShape.squircle),
    AppIconOption('samsung-neon-cyan', 'Samsung Neon Cyan', 'SamsungNeonCyan', IconShape.squircle),
    AppIconOption('pixel-glass', 'Pixel Glass', 'PixelGlass', IconShape.circle),
    AppIconOption('pixel-glass-dark', 'Pixel Glass Dark', 'PixelGlassDark', IconShape.circle),
    AppIconOption('pixel-neon-cyan', 'Pixel Neon Cyan', 'PixelNeonCyan', IconShape.circle),
  ];

  /// The rows of the picker, laid out like the icon sheet.
  static const groups = <(String, List<String>)>[
    ('Classic', ['default', 'monochrome']),
    ('Liquid Glass', ['liquid-glass', 'liquid-glass-dark', 'liquid-glass-clear', 'liquid-glass-clear-dark']),
    ('Neon', ['neon-silver', 'neon-cyan', 'neon-violet']),
    ('Samsung', ['samsung-glass', 'samsung-glass-dark', 'samsung-neon-cyan']),
    ('Pixel', ['pixel-glass', 'pixel-glass-dark', 'pixel-neon-cyan']),
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
