import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/device_online_stub.dart' if (dart.library.js_interop) '../core/device_online_web.dart' as device;
import '../core/net_proxy.dart';
import '../data/listen_together.dart' show Backend;

/// The web build's link to the Byte web server (supabase/functions/byte-proxy).
class WebProxy {
  /// Build-time override: --dart-define=BYTE_PROXY=https://…/byte-proxy
  static const _override = String.fromEnvironment('BYTE_PROXY');
  static Uri get endpoint => Uri.parse(_override.isNotEmpty ? _override : '${Backend.url}/functions/v1/byte-proxy');

  static WebProxyNet? _net;
  static WebProxyNet get net => _net ??= WebProxyNet(endpoint, deviceOnline: device.deviceOnline);

  /// Up / down, for the banner.
  static ValueNotifier<WebProxyState> get state => net.state;

  /// Where the browser plays [videoId] from (Safari needs MP4 audio).
  static Uri playUrl(String videoId, {bool low = false}) {
    final apple = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;
    return net.playUrl(videoId, low: low, mp4: apple);
  }

  /// Why [videoId] didn't play in the browser, when it's the server's block (1.4.6).
  static Future<String?> playProblem(String videoId) {
    final apple = defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.macOS;
    return net.playProblem(videoId, mp4: apple);
  }
}

/// Wraps the app on the web: one honest line while the web server is off.
class WebShell extends StatefulWidget {
  final Widget child;
  const WebShell({super.key, required this.child});
  @override
  State<WebShell> createState() => _WebShellState();
}

class _WebShellState extends State<WebShell> {
  bool _hidden = false;
  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ValueListenableBuilder<WebProxyState>(
        valueListenable: WebProxy.state,
        builder: (context, s, _) {
          final show = s == WebProxyState.offline && !_hidden;
          return Column(
            children: [
              if (show) WebServerBanner(onClose: () => setState(() => _hidden = true)),
              Expanded(child: widget.child),
            ],
          );
        },
      ),
    );
  }
}

class WebServerBanner extends StatelessWidget {
  final VoidCallback onClose;
  const WebServerBanner({super.key, required this.onClose});
  static const text = 'Online search can\'t be reached right now. Your library and settings still work.';
  @override
  Widget build(BuildContext context) {
    final top = MediaQueryData.fromView(View.of(context)).padding.top;
    return Material(
      color: const Color(0xFF1C1C1E),
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 8 + top, 4, 8),
        child: Row(
          children: [
            const Icon(Icons.cloud_off_rounded, size: 18, color: Color(0xFFFFB547)),
            const SizedBox(width: 10),
            const Expanded(
              child: Text(text, style: TextStyle(color: Colors.white, fontSize: 13, height: 1.3, decoration: TextDecoration.none)),
            ),
            IconButton(
              tooltip: 'Hide',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 18, color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}
