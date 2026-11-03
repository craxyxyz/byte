import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../data/listen_together.dart';

/// byte://listen/CODE links (Listen together invites, QR codes).
class ByteLinks {
  static const _ch = MethodChannel('byte/links');

  /// The party code inside a link, if it is one.
  static String? partyCode(String link) {
    final u = Uri.tryParse(link.trim());
    if (u == null || u.scheme != 'byte' || u.host != 'listen') return null;
    final seg = u.pathSegments.where((s) => s.isNotEmpty).firstOrNull;
    return seg == null ? null : ListenTogether.normaliseCode(seg);
  }

  /// Calls [onCode] for the link that opened the app and for later ones.
  static Future<void> listen(void Function(String code) onCode) async {
    if (kIsWeb) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'link') {
        final c = partyCode('${call.arguments}');
        if (c != null) onCode(c);
      }
    });
    try {
      final first = await _ch.invokeMethod<String>('initial');
      final c = first == null ? null : partyCode(first);
      if (c != null) onCode(c);
    } catch (_) {}
  }
}
