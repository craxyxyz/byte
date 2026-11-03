import 'package:flutter/material.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// The web build has no in-app browser (sign-in pages for Google, Spotify,
/// Last.fm, ListenBrainz need the Byte app). This stand-in lets those screens
/// open without crashing and says so plainly where the page would be.
class NoWebViewPlatform extends WebViewPlatform {
  static void install() => WebViewPlatform.instance = NoWebViewPlatform();

  static const message = 'This sign-in opens inside the Byte app on your phone or tablet. '
      'On the web, use a Byte account (email) — your likes and playlists sync from the app.';

  @override
  PlatformWebViewController createPlatformWebViewController(PlatformWebViewControllerCreationParams params) => _Controller(params);
  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(PlatformNavigationDelegateCreationParams params) => _Nav(params);
  @override
  PlatformWebViewWidget createPlatformWebViewWidget(PlatformWebViewWidgetCreationParams params) => _Widget(params);
  @override
  PlatformWebViewCookieManager createPlatformCookieManager(PlatformWebViewCookieManagerCreationParams params) => _Cookies(params);
}

class _Controller extends PlatformWebViewController {
  _Controller(super.params) : super.implementation();
  String? _url;
  _Nav? _nav;
  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _url = params.uri.toString();
    // "Loaded" at once, so screens drop their spinner and show the notice.
    final n = _nav, u = _url!;
    Future<void>.delayed(const Duration(milliseconds: 50), () {
      n?._progress?.call(100);
      n?._finished?.call(u);
    });
  }
  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}
  @override
  Future<void> loadFile(String absoluteFilePath) async {}
  @override
  Future<void> loadFlutterAsset(String key) async {}
  @override
  Future<String?> currentUrl() async => _url;
  @override
  Future<bool> canGoBack() async => false;
  @override
  Future<bool> canGoForward() async => false;
  @override
  Future<void> goBack() async {}
  @override
  Future<void> goForward() async {}
  @override
  Future<void> reload() async {}
  @override
  Future<void> clearCache() async {}
  @override
  Future<void> clearLocalStorage() async {}
  @override
  Future<void> setPlatformNavigationDelegate(PlatformNavigationDelegate handler) async => _nav = handler is _Nav ? handler : null;
  @override
  Future<void> runJavaScript(String javaScript) async {}
  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => '';
  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams javaScriptChannelParams) async {}
  @override
  Future<void> removeJavaScriptChannel(String javaScriptChannelName) async {}
  @override
  Future<String?> getTitle() async => null;
  @override
  Future<void> scrollTo(int x, int y) async {}
  @override
  Future<void> scrollBy(int x, int y) async {}
  @override
  Future<Offset> getScrollPosition() async => Offset.zero;
  @override
  Future<void> enableZoom(bool enabled) async {}
  @override
  Future<void> setBackgroundColor(Color color) async {}
  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}
  @override
  Future<void> setUserAgent(String? userAgent) async {}
  @override
  Future<String?> getUserAgent() async => null;
  @override
  Future<void> setVerticalScrollBarEnabled(bool enabled) async {}
  @override
  Future<void> setHorizontalScrollBarEnabled(bool enabled) async {}
  @override
  Future<void> setOnPlatformPermissionRequest(void Function(PlatformWebViewPermissionRequest request) onPermissionRequest) async {}
  @override
  Future<void> setOnConsoleMessage(void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage) async {}
  @override
  Future<void> setOnScrollPositionChange(void Function(ScrollPositionChange scrollPositionChange)? onScrollPositionChange) async {}
  @override
  Future<void> setOnJavaScriptAlertDialog(Future<void> Function(JavaScriptAlertDialogRequest request) onJavaScriptAlertDialog) async {}
  @override
  Future<void> setOnJavaScriptConfirmDialog(Future<bool> Function(JavaScriptConfirmDialogRequest request) onJavaScriptConfirmDialog) async {}
  @override
  Future<void> setOnJavaScriptTextInputDialog(Future<String> Function(JavaScriptTextInputDialogRequest request) onJavaScriptTextInputDialog) async {}
}

class _Nav extends PlatformNavigationDelegate {
  _Nav(super.params) : super.implementation();
  PageEventCallback? _finished;
  ProgressCallback? _progress;
  @override
  Future<void> setOnNavigationRequest(NavigationRequestCallback onNavigationRequest) async {}
  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}
  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async => _finished = onPageFinished;
  @override
  Future<void> setOnHttpError(HttpResponseErrorCallback onHttpError) async {}
  @override
  Future<void> setOnProgress(ProgressCallback onProgress) async => _progress = onProgress;
  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback onWebResourceError) async {}
  @override
  Future<void> setOnUrlChange(UrlChangeCallback onUrlChange) async {}
  @override
  Future<void> setOnHttpAuthRequest(HttpAuthRequestCallback onHttpAuthRequest) async {}
  @override
  Future<void> setOnSSlAuthError(SslAuthErrorCallback onSslAuthError) async {}
}

class _Cookies extends PlatformWebViewCookieManager {
  _Cookies(super.params) : super.implementation();
  @override
  Future<bool> clearCookies() async => false;
  @override
  Future<void> setCookie(WebViewCookie cookie) async {}
}

class _Widget extends PlatformWebViewWidget {
  _Widget(super.params) : super.implementation();
  @override
  Widget build(BuildContext context) => const NoWebViewNotice();
}

class NoWebViewNotice extends StatelessWidget {
  const NoWebViewNotice({super.key});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return ColoredBox(
      color: t.colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.phone_android_rounded, size: 48, color: t.colorScheme.primary),
                const SizedBox(height: 16),
                Text(NoWebViewPlatform.message, textAlign: TextAlign.center, style: t.textTheme.bodyLarge),
                const SizedBox(height: 20),
                FilledButton.tonal(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Back')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
