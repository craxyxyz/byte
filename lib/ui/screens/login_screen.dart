import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services.dart';
import '../import_sheet.dart';
import '../widgets.dart';

const _loginUrl =
    'https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F';
const _mobileChrome = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

/// Reads the web view's cookies natively (including the sign-in ones that
/// page scripts can't see). Implemented in MainActivity.kt / AppDelegate.swift.
const cookieChannel = MethodChannel('byte/cookies');

Future<String?> readCookies(String url) async {
  try {
    return await cookieChannel.invokeMethod<String>('get', {'url': url});
  } catch (_) {
    return null;
  }
}

/// Google sign-in page. Once YouTube Music opens signed in, Byte keeps the
/// session cookies (on this phone only) and copies your playlists.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  WebViewController? web;
  double progress = 0;
  bool done = false;

  /// Google's page has drawn at least once (until then a clear loading view shows,
  /// not a blank white page that looked like the button did nothing).
  bool shown = false;
  String? problem;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await WebViewCookieManager().clearCookies();
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_mobileChrome)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => progress = p / 100);
          },
          onPageFinished: (u) {
            if (mounted && !shown) setState(() => shown = true);
            _check(u);
          },
          onUrlChange: (ch) => _check(ch.url),
          onWebResourceError: (e) {
            if (e.isForMainFrame == false || !mounted || shown) return;
            setState(() => problem = 'Couldn\'t open the sign-in page. Check your internet and try again.');
          },
        ),
      )
      ..loadRequest(Uri.parse(_loginUrl));
    if (mounted) setState(() => web = c);
  }

  Future<void> _retry() async {
    setState(() {
      problem = null;
      shown = false;
      progress = 0;
    });
    await web?.loadRequest(Uri.parse(_loginUrl));
  }

  Future<void> _check(String? url) async {
    if (url != null && (url.contains('/signin/rejected') || url.contains('disallowed_useragent'))) {
      if (mounted) {
        setState(
          () =>
              problem = 'Signing in inside the app wasn\'t allowed on this phone. You can still bring your playlists in with a link, or try again later.',
        );
      }
      return;
    }
    if (done || url == null || Uri.tryParse(url)?.host != 'music.youtube.com') return;
    final header = await readCookies('https://music.youtube.com');
    if (header == null || !header.contains('SAPISID')) return;
    done = true;
    final ok = await Services.i.account.signInWithCookies(header);
    if (!mounted) return;
    Navigator.pop(context);
    toast(context, ok ? 'Signed in — your playlists are syncing to Library' : 'Sign-in didn\'t finish. Please try again.');
    if (ok) Services.i.feedVersion.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
        bottom: progress < 1
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: progress, minHeight: 2),
              )
            : null,
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              showImportSheet(context);
            },
            child: const Text('Use a link'),
          ),
        ],
      ),
      body: Stack(
        children: [
          if (web != null) Positioned.fill(child: WebViewWidget(controller: web!)),
          if (problem != null)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(28),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded, size: 48),
                        const SizedBox(height: 12),
                        Text(problem!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _retry, child: const Text('Try again')),
                        TextButton(
                          onPressed: () {
                            Navigator.pop(context);
                            showImportSheet(context);
                          },
                          child: const Text('Import a playlist by link instead'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            )
          else if (!shown)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text('Opening Google sign-in…', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text('${(progress * 100).round()}%', style: Theme.of(context).textTheme.bodySmall),
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
