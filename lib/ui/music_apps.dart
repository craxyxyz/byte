import 'dart:async';
import 'sync_help.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../brand.dart';
import '../data/playlist_import.dart';
import '../data/service_library.dart';
import '../services.dart';
import 'import_sheet.dart';
import 'nav.dart';
import 'page.dart';
import 'screens/integrations_pages.dart' show SpotifyAccountScreen;
import 'screens/login_screen.dart';
import 'style.dart';
import 'web_logins.dart';
import 'widgets.dart';

// Byte © 2026 Apurba Laskar.
//
// Account & integrations → Music apps: pick a music app, tap Log in, and that
// app's OWN web sign-in page opens inside Byte. Once signed in, Byte reads the
// person's own liked songs and playlists (titles and artists) and imports them.

const _phoneUa = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36';
const _webviewCh = MethodChannel('byte/webview');

String _region() {
  try {
    return Services.i.settings.contentRegion;
  } catch (_) {
    return 'IN';
  }
}

/// A plain coloured letter badge per music app (no copied logos).
class MusicAppBadge extends StatelessWidget {
  final LibService service;
  final double size;
  const MusicAppBadge(this.service, {super.key, this.size = 30});
  @override
  Widget build(BuildContext context) {
    final (Color bg, String t, Color fg) = switch (service) {
      LibService.spotify => (const Color(0xFF1DB954), 'S', Colors.black),
      LibService.youtubeMusic => (const Color(0xFFFF0033), 'YT', Colors.white),
      LibService.amazon => (const Color(0xFF25D1DA), 'a', Colors.black),
      LibService.apple => (const Color(0xFFFA2D48), '♪', Colors.white),
      LibService.jiosaavn => (const Color(0xFF2BC5B4), 'J', Colors.white),
      LibService.gaana => (const Color(0xFFE72C30), 'G', Colors.white),
      LibService.soundcloud => (const Color(0xFFFF5500), 'SC', Colors.white),
      LibService.deezer => (const Color(0xFFA238FF), 'D', Colors.white),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.27)),
      child: Text(
        t,
        style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: size * (t.length > 1 ? 0.36 : 0.5)),
      ),
    );
  }
}

/// One line about where a music app stands ("Tap to log in", "Rahul · 120 liked, 8 playlists").
String musicAppStatus(LibService s) {
  final sv = Services.i;
  switch (s) {
    case LibService.spotify:
      final sp = sv.spotify;
      final sy = sv.spotifySync;
      if (!sp.connected) return 'Tap to log in';
      if (sy.running) return sy.status ?? 'Syncing…';
      return '${sp.userName} · ${sy.likedCount} liked, ${sy.playlistCount} playlists';
    case LibService.youtubeMusic:
      final a = sv.account.active;
      return a == null ? 'Tap to log in' : '${a.name}${sv.account.syncMessage != null ? ' · ${sv.account.syncMessage}' : ''}';
    default:
      final l = sv.libSync;
      if (l.runningFor == s) return l.status ?? 'Syncing…';
      if (!l.connected(s)) return l.lastError(s) ?? 'Tap to log in';
      return '${l.user(s) ?? 'Logged in'} · ${l.likedCount(s)} liked, ${l.playlistCount(s)} playlists';
  }
}

bool musicAppConnected(LibService s) => switch (s) {
  LibService.spotify => Services.i.spotify.connected,
  LibService.youtubeMusic => Services.i.account.signedIn,
  _ => Services.i.libSync.connected(s),
};

/// Log in (or, when already in, open the account page) for [s].
Future<void> openMusicAppLogin(BuildContext context, LibService s, {bool syncOnly = false}) async {
  final nav = Navigator.of(context, rootNavigator: true);
  switch (s) {
    case LibService.spotify:
      if (Services.i.spotify.connected && syncOnly) {
        unawaited(Services.i.spotifySync.syncNow());
      } else {
        await nav.push<bool>(MaterialPageRoute(builder: (_) => const SpotifyWebLoginPage()));
      }
    case LibService.youtubeMusic:
      if (Services.i.account.signedIn && syncOnly) {
        unawaited(Services.i.account.sync());
      } else {
        await nav.push(MaterialPageRoute(builder: (_) => const LoginScreen()));
        if (Services.i.account.signedIn) unawaited(Services.i.account.sync());
      }
    default:
      await nav.push<bool>(
        MaterialPageRoute(
          builder: (_) => MusicAppLoginPage(service: s, syncOnly: syncOnly),
        ),
      );
  }
}

Future<void> logOutMusicApp(LibService s) async {
  final spec = libSpec(s, region: _region());
  switch (s) {
    case LibService.spotify:
      await Services.i.spotify.disconnect();
      await Services.i.spotifySync.forget();
      await forgetSpotifyWebSignIn();
      return;
    case LibService.youtubeMusic:
      if (Services.i.account.signedIn) await Services.i.account.signOut();
      return;
    default:
      await Services.i.libSync.forget(s);
      if (kIsWeb) return;
      for (final h in spec.cookieHosts) {
        try {
          await _webviewCh.invokeMethod('clearCookies', {'host': h});
        } catch (_) {}
      }
  }
}

// ── The picker ────────────────────────────────────────────────────────────

class MusicAppsScreen extends StatelessWidget {
  const MusicAppsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([Services.i.libSync, Services.i.spotify, Services.i.spotifySync, Services.i.account]),
      builder: (context, _) => SubPage(
        capWidth: true,
        title: 'Music apps',
        showProfile: false,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 4, 32, 8),
              child: Text(
                'Pick your music app and log in on its own page. Byte brings your liked songs and playlists and keeps them in sync. Your password goes only to that app.',
                style: BT.sub.copyWith(color: p.secondary),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: GroupCard(
              children: [
                for (final spec in libServices(region: _region()))
                  GroupRow(
                    key: ValueKey('music-app-${spec.service.name}'),
                    leading: MusicAppBadge(spec.service),
                    title: spec.name,
                    subtitle: musicAppStatus(spec.service),
                    chevron: true,
                    onTap: () => spec.service == LibService.spotify && Services.i.spotify.connected
                        ? pushPage(context, const SpotifyAccountScreen())
                        : pushPage(context, MusicAppAccountScreen(service: spec.service)),
                  ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 24),
              child: Text('Only want one playlist? Paste its link in Library → From a playlist link.', style: BT.sub.copyWith(color: p.secondary)),
            ),
          ),
        ],
      ),
    );
  }
}

class MusicAppAccountScreen extends StatelessWidget {
  final LibService service;
  const MusicAppAccountScreen({super.key, required this.service});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final spec = libSpec(service, region: _region());
    return ListenableBuilder(
      listenable: Listenable.merge([Services.i.libSync, Services.i.spotify, Services.i.spotifySync, Services.i.account]),
      builder: (context, _) {
        final on = musicAppConnected(service);
        final busy = Services.i.libSync.runningFor == service;
        return SubPage(
          capWidth: true,
          title: spec.name,
          showProfile: false,
          slivers: [
            SliverToBoxAdapter(
              child: GroupCard(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(
                      children: [
                        MusicAppBadge(service, size: 52),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                spec.name,
                                style: BT.title3.copyWith(color: p.label, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                musicAppStatus(service),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: BT.sub.copyWith(color: p.secondary),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (busy && Services.i.libSync.progress != null) LinearProgressIndicator(value: Services.i.libSync.progress, minHeight: 2),
                  if (!busy && Services.i.libSync.lastError(service) != null)
                    GroupRow(
                      key: const ValueKey('music-app-error'),
                      icon: Icons.error_outline_rounded,
                      title: 'Last problem',
                      subtitle: Services.i.libSync.lastError(service),
                      trailing: TextButton(
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: 'Byte ${Brand.version} · ${spec.name}\n${Services.i.libSync.lastError(service)}'));
                          toast(context, 'Details copied');
                        },
                        child: const Text('Copy details'),
                      ),
                    ),
                  if (!on)
                    GroupRow(
                      key: const ValueKey('music-app-login'),
                      icon: Icons.login_rounded,
                      title: 'Log in',
                      subtitle: 'Opens ${spec.name}\'s own login page',
                      titleColor: p.accent,
                      onTap: () => openMusicAppLogin(context, service),
                    )
                  else ...[
                    GroupRow(
                      key: const ValueKey('music-app-sync'),
                      icon: Icons.sync_rounded,
                      title: busy ? 'Syncing…' : 'Sync now',
                      subtitle: _lastLine(service),
                      enabled: !busy,
                      onTap: () => openMusicAppLogin(context, service, syncOnly: true),
                    ),
                    if (service != LibService.youtubeMusic)
                      GroupRow(
                        key: const ValueKey('music-app-sync-help'),
                        icon: Icons.info_outline_rounded,
                        title: 'How sync works',
                        chevron: true,
                        onTap: () => showSyncHelp(context, service: spec.name, automatic: service == LibService.spotify && Services.i.spotify.connected),
                      ),
                    GroupRow(
                      key: const ValueKey('music-app-logout'),
                      icon: Icons.logout_rounded,
                      title: 'Log out',
                      subtitle: 'Your imported songs and playlists stay in Byte',
                      onTap: () async {
                        await logOutMusicApp(service);
                        if (context.mounted) toast(context, 'Logged out of ${spec.name}');
                      },
                    ),
                  ],
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
                child: Text(spec.note, style: BT.sub.copyWith(color: p.secondary)),
              ),
            ),
            const SliverToBoxAdapter(child: GroupLabel('Or')),
            SliverToBoxAdapter(
              child: GroupCard(
                children: [GroupRow(icon: Icons.link_rounded, title: 'Import one playlist by link', chevron: true, onTap: () => showImportSheet(context))],
              ),
            ),
          ],
        );
      },
    );
  }

  String? _lastLine(LibService s) {
    if (s == LibService.spotify || s == LibService.youtubeMusic) return null;
    final l = Services.i.libSync.lastSync(s);
    if (l == null) return null;
    final m = DateTime.now().difference(l).inMinutes;
    return m < 1 ? 'Synced just now' : (m < 60 ? 'Synced $m min ago' : 'Synced ${m ~/ 60} h ago');
  }
}

// ── The sign-in page + reading the library in it ──────────────────────────

class MusicAppLoginPage extends StatefulWidget {
  final LibService service;

  /// Already logged in: open the library page straight away and read it.
  final bool syncOnly;

  /// A playlist link the person pasted that only opens when logged in: after
  /// sign-in Byte reads this one first.
  final String? playlistUrl;
  const MusicAppLoginPage({super.key, required this.service, this.syncOnly = false, this.playlistUrl});
  @override
  State<MusicAppLoginPage> createState() => _MusicAppLoginPageState();
}

class _MusicAppLoginPageState extends State<MusicAppLoginPage> {
  late final LibServiceSpec spec = libSpec(widget.service, region: _region());
  WebViewController? web;
  double progress = 0;
  String url = '';
  bool reading = false;
  bool done = false;
  String? note;

  /// Shown with "Copy details" when reading failed.
  String? _details;
  int _retries = 0;
  Timer? _poll;
  int _rid = 0;
  final _pending = <int, Completer<String?>>{};
  Completer<String>? _reader;
  Completer<void>? _loaded;

  @override
  void initState() {
    super.initState();
    _make();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  bool _onService(String u) {
    final h = Uri.tryParse(u)?.host ?? '';
    return spec.hosts.any((x) => h == x || h.endsWith('.$x'));
  }

  Future<void> _make() async {
    final c = WebViewController();
    // The app's sign-in sets cookies its web player uses from other hosts.
    if (c.platform is AndroidWebViewController) {
      try {
        await AndroidWebViewCookieManager(const PlatformWebViewCookieManagerCreationParams()).setAcceptThirdPartyCookies(c.platform as AndroidWebViewController, true);
      } catch (_) {}
    }
    await c.setJavaScriptMode(JavaScriptMode.unrestricted);
    await c.setUserAgent(_phoneUa);
    await c.addJavaScriptChannel('ByteLib', onMessageReceived: (m) => _onMessage(m.message));
    await c.setNavigationDelegate(
      NavigationDelegate(
        onProgress: (p) {
          if (mounted) setState(() => progress = p / 100);
        },
        onPageStarted: (u) {
          url = u;
          // The page moved on while Byte was reading it: its reader is gone.
          // Stop waiting now (not after minutes) and read again once it loads.
          if (reading && _reader != null && !_reader!.isCompleted) {
            _reader!.complete(jsonEncode({'ok': false, 'retry': true, 'error': 'The page changed while Byte was reading it.'}));
          }
        },
        onPageFinished: (u) {
          url = u;
          if (_loaded != null && !_loaded!.isCompleted) _loaded!.complete();
          if (mounted) setState(() {});
          unawaited(_maybeRead());
        },
      ),
    );
    await c.loadRequest(Uri.parse(widget.syncOnly ? spec.readUrl : spec.loginUrl));
    if (mounted) setState(() => web = c);
    // Some sign-ins finish inside the page without loading a new one.
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => unawaited(_maybeRead()));
  }

  void _onMessage(String msg) {
    Map? j;
    try {
      j = jsonDecode(msg) as Map?;
    } catch (_) {
      return;
    }
    if (j == null) return;
    final rid = j['rid'];
    if (rid is int) {
      _pending.remove(rid)?.complete(j['v'] as String?);
      return;
    }
    if (_reader != null && !_reader!.isCompleted) _reader!.complete(msg);
  }

  /// Runs [expr] (may be a promise) in the page and hands back its value as text.
  Future<String?> _eval(String expr, {Duration timeout = const Duration(seconds: 60)}) async {
    final c = web;
    if (c == null) return null;
    final id = ++_rid;
    final done = Completer<String?>();
    _pending[id] = done;
    await c
        .runJavaScript(
          '(async()=>{let v=null;try{v=await ($expr);}catch(e){v=null;}'
          'ByteLib.postMessage(JSON.stringify({rid:$id,v:(v===null||v===undefined)?null:(typeof v==="string"?v:JSON.stringify(v))}));})();',
        )
        .catchError((_) {});
    return done.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        return null;
      },
    );
  }

  Future<void> _load(String u) async {
    _loaded = Completer<void>();
    await web?.loadRequest(Uri.parse(u));
    await _loaded!.future.timeout(const Duration(seconds: 40), onTimeout: () {});
    await Future<void>.delayed(const Duration(seconds: 4)); // the app draws its page after loading
  }

  bool _checking = false;
  /// After a failed read, Byte waits for "I'm logged in" / "Try again"
  /// instead of reading the pages over and over.
  bool _paused = false;

  /// The page's own address right now (a web app changes it without loading a page).
  Future<String> _here() async {
    final h = await _eval('location.href', timeout: const Duration(seconds: 5));
    if (h != null && h.startsWith('http')) url = h;
    return url;
  }

  /// Signed in, judged by the app's own session cookie (read on the phone,
  /// including the ones a page can't see). Null when Byte can't tell.
  Future<bool?> _sessionCookie() async {
    final want = sessionCookieUrl(widget.service, region: _region());
    if (want == null || kIsWeb) return null;
    try {
      final c = await cookieChannel.invokeMethod<String>('get', {'url': want});
      return hasSessionCookie(widget.service, c);
    } catch (_) {
      return null;
    }
  }

  Future<void> _maybeRead({bool force = false}) async {
    if (reading || done || web == null || _checking) return;
    if (force) _paused = false;
    if (_paused) return;
    _checking = true;
    try {
      final cookie = await _sessionCookie();
      var here = await _here();
      var step = nextLoginStep(onService: _onService(here), cookie: cookie, force: force);
      if (step == LoginNext.openLibrary) {
        // Signed in on the app's account page (e.g. amazon.in) but not sent
        // back to the music app: go to the library ourselves.
        if (mounted) setState(() => note = 'Logged in. Opening your ${spec.name} library…');
        await _load(spec.readUrl);
        here = await _here();
        step = nextLoginStep(onService: _onService(here), cookie: cookie, force: force, afterOpening: true);
      }
      if (step == LoginNext.stillSigningIn) {
        if (mounted) {
          setState(() {
            note = '${spec.name} is still on its sign-in page. Finish logging in there, then tap "I\'m logged in".';
            _details = _detailsFor('not back on ${spec.name} after sign-in', 'cookie=$cookie');
          });
        }
        return;
      }
      if (!_onService(here)) return;
      if (step == LoginNext.wait) {
        final probe = signedInProbe(widget.service);
        if (probe == null) {
          step = LoginNext.read; // no check for this app: try reading
        } else {
          final v = await _eval(probe, timeout: const Duration(seconds: 15));
          step = nextLoginStep(onService: true, cookie: cookie, probe: v == 'true', force: force);
        }
      }
      if (step != LoginNext.read || reading || done) return;
      await _read(force: force, cookie: cookie);
    } finally {
      _checking = false;
    }
  }

  Future<void> _read({bool force = false, bool? cookie}) async {
    setState(() {
      reading = true;
      _details = null;
      note = 'Logged in. Reading your library…';
    });
    try {
      final LibSnapshot snap;
      if (spec.mode == LibReadMode.pages) {
        snap = await _readAmazonPages();
      } else {
        _reader = Completer<String>();
        await web!.runJavaScript(libraryReaderScript(widget.service));
        final msg = await _reader!.future.timeout(const Duration(minutes: 6));
        snap = parseLibraryMessage(widget.service, jsonDecode(msg) as Map);
      }
      if (!mounted) return;
      setState(() => note = 'Found ${snap.liked.length} liked songs and ${snap.playlists.length} playlists. Finding them…');
      final r = await Services.i.libSync.importSnapshot(widget.service, snap);
      done = true;
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      // A result, never a silent close.
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          key: const Key('music-app-result'),
          title: Text('${spec.name} is in Byte'),
          content: Text(
            '${r.liked} liked songs and ${r.playlists} playlists imported.'
            '${r.notFound > 0 ? '\n${r.notFound} songs couldn\'t be found.' : ''}'
            '${r.emptyPlaylists.isNotEmpty ? '\nNo songs found for: ${r.emptyPlaylists.take(3).join(', ')}.' : ''}'
            '\n\nThey\'re at the top of Home.',
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Done'))],
        ),
      );
      if (mounted) Navigator.pop(context, true);
    } on LibProblem catch (e) {
      if (!mounted) return;
      if (e.retry && _retries < 3) {
        _retries++;
        setState(() {
          reading = false;
          note = 'The page changed. Reading again…';
        });
        return; // the next page load (or the 4 s check) reads again
      }
      // Signed out on the page: quiet while the person is still typing their
      // password, but after "I'm logged in" (or with a session cookie) say so.
      final loud = !e.needLogin || force || cookie == true;
      if (loud) _paused = true;
      setState(() {
        reading = false;
        note = !loud
            ? null
            : (e.needLogin ? '${spec.name} didn\'t open your library yet. Finish logging in on the page (it may ask for an OTP), then tap "I\'m logged in".' : e.message);
        _details = loud ? _detailsFor(e.message, '${e.details ?? ''} cookie=$cookie') : null;
      });
      if (e.needLogin && widget.syncOnly && !url.startsWith(spec.loginUrl)) {
        await web?.loadRequest(Uri.parse(spec.loginUrl)); // signed out on the app: log in again
      }
      if (!e.needLogin) await Services.i.libSync.setError(widget.service, e.message);
    } catch (e) {
      if (!mounted) return;
      final msg = e is TimeoutException ? '${spec.name} took too long to answer. Try Sync now again.' : 'Couldn\'t read your ${spec.name} library ($e).';
      _paused = true;
      setState(() {
        reading = false;
        note = msg;
        _details = _detailsFor(msg, '${e.runtimeType}: $e');
      });
      await Services.i.libSync.setError(widget.service, msg);
    }
  }

  String _detailsFor(String msg, String? more) => [
    'Byte ${Brand.version} · ${spec.name} log-in import',
    'Problem: $msg',
    'Page: ${Uri.tryParse(url)?.replace(query: '').toString() ?? url}',
    'Mode: ${spec.mode.name}${widget.syncOnly ? ' · sync' : ''}${widget.playlistUrl != null ? ' · shared link' : ''}',
    if (more != null && more.isNotEmpty) 'Seen: $more',
  ].join('\n');

  /// Amazon Music: its pages are read row by row (it has no public data calls).
  Future<LibSnapshot> _readAmazonPages() async {
    final base = 'https://${spec.hosts.first}';
    bool atLibrary(String u) => Uri.tryParse(u)?.path.startsWith('/my/') ?? false;
    if (!(Uri.tryParse(await _here())?.path.startsWith('/my/playlists') ?? false)) await _load('$base/my/playlists');
    if (!atLibrary(await _here())) {
      // Just signed in: the web player can take a moment to pick the session
      // up and first sends you to its home page. Open it, then the library again.
      if (mounted) setState(() => note = 'Logged in. Opening your Amazon Music library…');
      await _load('$base/');
      await Future<void>.delayed(const Duration(seconds: 3));
      await _load('$base/my/playlists');
    }
    final here = await _here();
    if (!atLibrary(here)) {
      final signedIn = await _sessionCookie();
      throw LibProblem(
        signedIn == true
            ? 'You\'re logged in to Amazon, but Amazon Music didn\'t open your library (it sent Byte to ${Uri.tryParse(here)?.path ?? here}). Make sure this Amazon account has Amazon Music, open Library on the page, then tap "I\'m logged in". Or import a playlist by its link.'
            : 'Log in to Amazon Music first',
        needLogin: signedIn != true,
        details: 'landed=$here cookie=$signedIn',
      );
    }
    final raw = await _eval(amazonListsJs, timeout: const Duration(seconds: 90));
    final lists = raw == null ? <Map>[] : (jsonDecode(raw) as List).whereType<Map>().toList();
    final wanted = widget.playlistUrl == null ? null : Uri.tryParse(widget.playlistUrl!);
    if (wanted != null) {
      final id = wanted.pathSegments.isEmpty ? '' : wanted.pathSegments.last;
      lists.removeWhere((m) => '${m['href']}'.contains(id));
      lists.insert(0, {'href': wanted.replace(query: '').toString().replaceAll('?', ''), 'name': 'Shared playlist'});
    }
    final liked = <ExtTrack>[];
    final playlists = <LibPlaylist>[];
    for (var i = 0; i < lists.length; i++) {
      final href = '${lists[i]['href']}';
      final listed = unescapeHtml('${lists[i]['name']}');
      if (mounted) setState(() => note = 'Reading your Amazon Music library… "$listed" (${i + 1} of ${lists.length}) · ${liked.length + playlists.fold<int>(0, (a, p) => a + p.tracks.length)} songs so far');
      await _load(href.startsWith('http') ? href : '$base$href');
      final html = await _eval(amazonRowsJs, timeout: const Duration(minutes: 3));
      final parsed = html == null ? null : parseAmazonMusic(html, 'amazon');
      final tracks = parsed?.tracks ?? const <ExtTrack>[];
      final name = parsed != null && parsed.name != 'Imported playlist' ? parsed.name : listed;
      final isLikes = RegExp(r'liked|favou?rite|my likes', caseSensitive: false).hasMatch(name);
      if (isLikes) liked.addAll(tracks);
      // the playlist the person pasted always becomes a Byte playlist too
      if (!isLikes || (i == 0 && wanted != null)) {
        playlists.add(LibPlaylist(RegExp(r'/([A-Za-z0-9]+)(?:\?|$)').firstMatch(href)?.group(1) ?? href, name, tracks));
      }
    }
    if (lists.isEmpty) {
      throw LibProblem(
        'Amazon Music showed no playlists for this account. If you have some, open Library → Playlists on the page and tap "I\'m logged in" again, or import one by its link.',
        details: 'page=${await _here()} lists=0',
      );
    }
    return LibSnapshot('Amazon Music', liked, playlists);
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(tooltip: 'Close', icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context, false)),
        title: Text('Log in to ${spec.name}'),
        actions: [if (!reading) TextButton(key: const Key('music-app-import-now'), onPressed: () => unawaited(_maybeRead(force: true)), child: const Text('I\'m logged in'))],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(2),
          child: AnimatedOpacity(
            opacity: progress < 1 || reading ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: LinearProgressIndicator(value: reading ? Services.i.libSync.progress : progress, minHeight: 2, color: p.accent, backgroundColor: Colors.transparent),
          ),
        ),
      ),
      body: Stack(
        children: [
          if (web != null) WebViewWidget(controller: web!) else const Center(child: CircularProgressIndicator()),
          if (note != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: ListenableBuilder(
                listenable: Services.i.libSync,
                builder: (context, _) => Material(
                  color: const Color(0xEE1C1C1E),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            if (reading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                            if (reading) const SizedBox(width: 12),
                            Expanded(
                              child: Text(Services.i.libSync.runningFor == widget.service ? (Services.i.libSync.status ?? note!) : note!, style: const TextStyle(color: Colors.white)),
                            ),
                          ],
                        ),
                        if (!reading && _details != null)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextButton(
                                key: const Key('music-app-copy-details'),
                                onPressed: () {
                                  Clipboard.setData(ClipboardData(text: _details!));
                                  toast(context, 'Details copied');
                                },
                                child: const Text('Copy details'),
                              ),
                              TextButton(
                                key: const Key('music-app-try-again'),
                                onPressed: () {
                                  setState(() {
                                    _details = null;
                                    note = null;
                                    _retries = 0;
                                  });
                                  unawaited(_maybeRead(force: true));
                                },
                                child: const Text('Try again'),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
