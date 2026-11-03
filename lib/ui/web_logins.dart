import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../data/scrobble.dart';
import '../data/spotify_web.dart';
import '../services.dart';
import 'style.dart';
import 'widgets.dart';

// Byte © 2026 Apurba Laskar.
//
// Signing in to other music services on THEIR OWN web pages, inside Byte, the
// way the reference app does it: no developer setup for the person. Byte never
// sees the password; it only keeps what the page hands back.

const _mobileUa = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
const _webviewCh = MethodChannel('byte/webview');

/// A web view that runs [spotifyTokenHook] before the page's own script
/// (Android) and again after each page load (a fallback that still catches
/// the page's later requests).
Future<WebViewController> spotifyWebView({required void Function(String) onMessage, NavigationDelegate? nav}) async {
  final c = WebViewController();
  await c.setJavaScriptMode(JavaScriptMode.unrestricted);
  await c.setUserAgent(_mobileUa);
  await c.addJavaScriptChannel('ByteSpot', onMessageReceived: (m) => onMessage(m.message));
  final pc = c.platform;
  if (pc is AndroidWebViewController) {
    try {
      await _webviewCh.invokeMethod<bool>('docStart', {
        'id': pc.webViewIdentifier,
        'script': spotifyTokenHook,
        'origins': ['https://open.spotify.com'],
      });
    } catch (_) {}
    await pc.setMediaPlaybackRequiresUserGesture(true);
  }
  await c.setNavigationDelegate(
    NavigationDelegate(
      onPageFinished: (url) {
        if (url.startsWith('https://open.spotify.com')) unawaited(c.runJavaScript(spotifyTokenHook).catchError((_) {}));
        nav?.onPageFinished?.call(url);
      },
      onPageStarted: nav?.onPageStarted,
      onProgress: nav?.onProgress,
      onNavigationRequest: nav?.onNavigationRequest,
    ),
  );
  return c;
}

/// Gets a fresh sign-in quietly: opens the web player in the background
/// with the cookies the person's sign-in left, and listens. Null when the
/// person is signed out on the service.
Future<({String token, int expMs})?> refreshSpotifyQuietly({Duration wait = const Duration(seconds: 30)}) async {
  if (kIsWeb) return null;
  final done = Completer<({String token, int expMs})?>();
  final tried = <String>{};
  late WebViewController c;
  c = await spotifyWebView(
    onMessage: (msg) async {
      final m = parseHookMessage(msg);
      if (m == null || m.anonymous || done.isCompleted || !tried.add(m.token)) return;
      if (await spotifySignedIn(m.token)) {
        if (!done.isCompleted) done.complete((token: m.token, expMs: m.expMs));
      }
    },
  );
  await c.loadRequest(Uri.parse('https://open.spotify.com/collection/tracks'));
  final r = await done.future.timeout(wait, onTimeout: () => null);
  unawaited(c.loadRequest(Uri.parse('about:blank')).catchError((_) {}));
  return r;
}

/// Whether [token] belongs to a signed-in person (not the page's guest pass).
Future<bool> spotifySignedIn(String token) async {
  try {
    final api = SpotifyWebApi(Services.i.net, () async => token);
    return (await api.me()) != null;
  } catch (_) {
    return false;
  }
}

/// "Tap to connect": the service's own sign-in page ("Welcome back",
/// email / phone / Google) inside Byte. When the page has signed the person
/// in, Byte reads their own library and keeps it synced.
class SpotifyWebLoginPage extends StatefulWidget {
  const SpotifyWebLoginPage({super.key});
  static const loginUrl = 'https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com%2F';
  @override
  State<SpotifyWebLoginPage> createState() => _SpotifyWebLoginPageState();
}

class _SpotifyWebLoginPageState extends State<SpotifyWebLoginPage> {
  WebViewController? web;
  double progress = 0;
  bool finishing = false;
  bool done = false;
  String url = '';
  final tried = <String>{};

  @override
  void initState() {
    super.initState();
    _make();
  }

  Future<void> _make() async {
    final c = await spotifyWebView(
      onMessage: _onMessage,
      nav: NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => progress = p / 100);
        },
        onPageStarted: (u) => url = u,
        onPageFinished: (u) {
          url = u;
          if (mounted) setState(() {});
        },
      ),
    );
    await c.loadRequest(Uri.parse(SpotifyWebLoginPage.loginUrl));
    if (mounted) setState(() => web = c);
  }

  Future<void> _onMessage(String msg) async {
    final m = parseHookMessage(msg);
    if (m == null || m.anonymous || done || !tried.add(m.token)) return;
    if (mounted) setState(() => finishing = true);
    final name = await Services.i.spotify.finishWeb(m.token, m.expMs);
    if (name == null) {
      // The page's guest pass (not signed in yet): keep waiting.
      if (mounted) setState(() => finishing = false);
      return;
    }
    if (done || !mounted) return;
    done = true;
    HapticFeedback.mediumImpact();
    toast(context, 'Connected as $name. Bringing your Liked Songs and playlists…');
    unawaited(Services.i.spotifySync.syncNow());
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context, false)),
        title: const Text('Sign in with Spotify'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: AnimatedOpacity(
            opacity: progress < 1 || finishing ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: LinearProgressIndicator(value: finishing ? null : progress, minHeight: 2, color: p.accent, backgroundColor: Colors.transparent),
          ),
        ),
      ),
      body: Stack(
        children: [
          if (web != null) WebViewWidget(controller: web!),
          if (web == null) const Center(child: CircularProgressIndicator()),
          if (finishing)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Material(
                color: const Color(0xEE1C1C1E),
                borderRadius: BorderRadius.circular(14),
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Row(
                    children: [
                      SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                      SizedBox(width: 12),
                      Expanded(child: Text('Signed in. Opening your library…', style: TextStyle(color: Colors.white))),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Last.fm's own sign-in page inside Byte. Needs an API account (Byte's
/// built-in one, or the person's own key + secret).
class LastFmWebLoginPage extends StatefulWidget {
  final String apiKey;
  final String secret;
  const LastFmWebLoginPage({super.key, required this.apiKey, required this.secret});
  static const callback = 'byte://lastfm-callback';
  @override
  State<LastFmWebLoginPage> createState() => _LastFmWebLoginPageState();
}

class _LastFmWebLoginPageState extends State<LastFmWebLoginPage> {
  late final WebViewController web;
  bool done = false;
  double progress = 0;

  @override
  void initState() {
    super.initState();
    web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_mobileUa)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => progress = p / 100);
          },
          onNavigationRequest: (r) {
            if (r.url.startsWith(LastFmWebLoginPage.callback)) {
              _finish(Uri.parse(r.url).queryParameters['token']);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.https('www.last.fm', '/api/auth/', {'api_key': widget.apiKey, 'cb': LastFmWebLoginPage.callback}));
  }

  Future<void> _finish(String? token) async {
    if (done) return;
    done = true;
    try {
      if (token == null) throw const ScrobbleProblem('Last.fm didn\'t finish the sign-in');
      final user = await Services.i.scrobbler.connectLastFmToken(apiKey: widget.apiKey, secret: widget.secret, token: token);
      if (!mounted) return;
      toast(context, 'Scrobbling to Last.fm as $user');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      toast(context, e is ScrobbleProblem ? e.message : 'No internet connection. Try again.');
      Navigator.pop(context, false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Sign in to Last.fm'),
      bottom: progress < 1 ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: progress, minHeight: 2)) : null,
    ),
    body: WebViewWidget(controller: web),
  );
}

/// ListenBrainz: sign in on its own site inside Byte; Byte reads the user
/// token from the settings page the person is shown after signing in.
class ListenBrainzWebLoginPage extends StatefulWidget {
  const ListenBrainzWebLoginPage({super.key});
  @override
  State<ListenBrainzWebLoginPage> createState() => _ListenBrainzWebLoginPageState();
}

class _ListenBrainzWebLoginPageState extends State<ListenBrainzWebLoginPage> {
  late final WebViewController web;
  bool done = false;
  double progress = 0;

  @override
  void initState() {
    super.initState();
    web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_mobileUa)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => progress = p / 100);
          },
          onPageFinished: (u) => _look(u),
        ),
      )
      ..loadRequest(Uri.parse('https://listenbrainz.org/settings/'));
  }

  Future<void> _look(String url) async {
    if (done || !url.contains('listenbrainz.org')) return;
    try {
      final html = await web.runJavaScriptReturningResult('document.documentElement.outerHTML');
      final token = Scrobbler.listenBrainzTokenIn('$html'.replaceAll(r'\"', '"'));
      if (token == null) return;
      done = true;
      final user = await Services.i.scrobbler.connectListenBrainz(token);
      if (!mounted) return;
      toast(context, 'Scrobbling to ListenBrainz as $user');
      Navigator.pop(context, true);
    } catch (_) {
      done = false;
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Sign in to ListenBrainz'),
      bottom: progress < 1 ? PreferredSize(preferredSize: const Size.fromHeight(2), child: LinearProgressIndicator(value: progress, minHeight: 2)) : null,
    ),
    body: WebViewWidget(controller: web),
  );
}

/// The reference app's "use sp_dc token": paste the sign-in cookie from a
/// computer's browser; Byte puts it in its web view and signs in with it.
Future<bool> connectSpotifyWithCookie(BuildContext context, String value) async {
  final v = value.trim().replaceFirst(RegExp(r'^sp_dc='), '');
  if (v.length < 40) {
    toast(context, 'That doesn\'t look like a sign-in cookie');
    return false;
  }
  await WebViewCookieManager().setCookie(WebViewCookie(name: 'sp_dc', value: v, domain: '.spotify.com', path: '/'));
  final fresh = await refreshSpotifyQuietly();
  if (fresh == null) {
    if (context.mounted) toast(context, 'Spotify didn\'t accept that cookie');
    return false;
  }
  final name = await Services.i.spotify.finishWeb(fresh.token, fresh.expMs);
  if (name == null) return false;
  unawaited(Services.i.spotifySync.syncNow());
  if (context.mounted) toast(context, 'Connected as $name');
  return true;
}

/// Log out of the service's page too (so the next person on this tablet can
/// sign in with their own account).
Future<void> forgetSpotifyWebSignIn() async {
  for (final h in const ['spotify.com', 'accounts.spotify.com', 'open.spotify.com']) {
    try {
      await _webviewCh.invokeMethod('clearCookies', {'host': h});
    } catch (_) {}
  }
}

enum ServiceMarkKind { spotify, discord, listenbrainz, lastfm }

/// A plain coloured badge for a service row (no copied logos).
class ServiceMark extends StatelessWidget {
  final ServiceMarkKind kind;
  const ServiceMark(this.kind, {super.key});
  @override
  Widget build(BuildContext context) {
    final (Color bg, Widget fg) = switch (kind) {
      ServiceMarkKind.spotify => (const Color(0xFF1DB954), const Icon(Icons.graphic_eq_rounded, color: Colors.black, size: 20)),
      ServiceMarkKind.discord => (const Color(0xFF5865F2), const Icon(Icons.sports_esports_rounded, color: Colors.white, size: 19)),
      ServiceMarkKind.listenbrainz => (const Color(0xFFEB743B), const Text('LB', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12))),
      ServiceMarkKind.lastfm => (const Color(0xFFD51007), const Text('fm', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13))),
    };
    return Container(width: 30, height: 30, alignment: Alignment.center, decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)), child: fg);
  }
}
