import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/models.dart';
import '../../data/scrobble.dart';
import '../../data/spotify_account.dart';
import '../web_logins.dart';
import '../../data/webdav.dart';
import '../../services.dart';
import '../nav.dart';
import '../page.dart';
import '../style.dart';
import '../import_sheet.dart';
import '../service_rows.dart' show openSpotifyPlaylist;
import '../sync_help.dart';
import '../widgets.dart';

Widget _foot(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(32, 8, 32, 4),
  child: Text(text, style: BT.sub.copyWith(color: BytePalette.of(context).secondary)),
);

class _Input extends StatelessWidget {
  final TextEditingController c;
  final String hint;
  final bool secret;
  final TextInputType? type;
  final ValueChanged<String>? onChanged;
  const _Input(this.c, this.hint, {this.secret = false, this.type, this.onChanged});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: TextField(
        controller: c,
        onChanged: onChanged,
        obscureText: secret,
        autocorrect: false,
        enableSuggestions: !secret,
        keyboardType: type,
        style: BT.body.copyWith(color: p.label),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: BT.body.copyWith(color: p.secondary),
          filled: true,
          fillColor: p.fill,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
        ),
      ),
    );
  }
}

class _Button extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  final bool busy;
  const _Button(this.label, this.onTap, {this.busy = false});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: p.label,
            foregroundColor: p.bg,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(23)),
          ),
          onPressed: busy ? null : onTap,
          child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }
}

// ── Scrobbling (ListenBrainz / Last.fm) ──────────────────────────────────
class ScrobblingScreen extends StatefulWidget {
  const ScrobblingScreen({super.key});
  @override
  State<ScrobblingScreen> createState() => _ScrobblingScreenState();
}

class _ScrobblingScreenState extends State<ScrobblingScreen> {
  final lbToken = TextEditingController();
  final lfmKey = TextEditingController(), lfmSecret = TextEditingController(), lfmUser = TextEditingController(), lfmPass = TextEditingController();
  bool busyLb = false, busyLfm = false;

  @override
  void dispose() {
    for (final c in [lbToken, lfmKey, lfmSecret, lfmUser, lfmPass]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _run(void Function(bool) busy, Future<String> Function() f, String done) async {
    setState(() => busy(true));
    try {
      final who = await f();
      if (mounted) toast(context, '$done${who.isEmpty ? '' : ' as $who'}');
    } on ScrobbleProblem catch (e) {
      if (mounted) toast(context, e.message);
    } catch (_) {
      if (mounted) toast(context, 'No internet connection. Try again.');
    } finally {
      if (mounted) setState(() => busy(false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sc = Services.i.scrobbler;
    return ListenableBuilder(
      listenable: sc,
      builder: (context, _) => SubPage(capWidth: true, 
        title: 'Scrobbling',
        showProfile: false,
        slivers: [
          SliverList.list(
            children: [
              GroupCard(
                children: [
                  GroupRow(
                    icon: Icons.history_edu_rounded,
                    title: 'Send what I listen to',
                    subtitle: sc.queue.isEmpty ? 'A song counts after half of it (or 4 minutes)' : '${sc.queue.length} listens waiting to be sent',
                    trailing: ByteSwitch(value: sc.enabled, onChanged: (v) => sc.enabled = v),
                    onTap: () => sc.enabled = !sc.enabled,
                  ),
                  GroupRow(
                    icon: Icons.graphic_eq_rounded,
                    title: 'Show "now playing"',
                    trailing: ByteSwitch(value: sc.nowPlaying, onChanged: (v) => sc.nowPlaying = v),
                    onTap: () => sc.nowPlaying = !sc.nowPlaying,
                  ),
                  if (sc.queue.isNotEmpty && (sc.lbOn || sc.lfmOn)) GroupRow(icon: Icons.send_rounded, title: 'Send waiting listens now', chevron: true, onTap: sc.flush),
                ],
              ),
              if (sc.lastError != null) _foot(context, sc.lastError!),
              const GroupLabel('ListenBrainz'),
              GroupCard(
                children: sc.lbOn
                    ? [
                        GroupRow(icon: Icons.check_circle_rounded, title: 'Connected', subtitle: sc.lbUser.isEmpty ? null : sc.lbUser),
                        GroupRow(icon: Icons.logout_rounded, title: 'Disconnect', titleColor: const Color(0xFFFF3B30), onTap: sc.disconnectListenBrainz),
                      ]
                    : [
                        GroupRow(
                          key: const ValueKey('lb-web-signin'),
                          icon: Icons.login_rounded,
                          title: 'Sign in on ListenBrainz',
                          subtitle: 'Its own page opens here; Byte picks up your token after you sign in',
                          chevron: true,
                          onTap: () => Navigator.of(context, rootNavigator: true).push<bool>(MaterialPageRoute(builder: (_) => const ListenBrainzWebLoginPage())),
                        ),
                        GroupRow(
                          icon: Icons.open_in_new_rounded,
                          title: 'Open listenbrainz.org',
                          chevron: true,
                          onTap: () => launchUrl(Uri.parse('https://listenbrainz.org/settings/'), mode: LaunchMode.externalApplication),
                        ),
                        _Input(lbToken, 'Your user token'),
                        _Button('Connect', () => _run((b) => busyLb = b, () => sc.connectListenBrainz(lbToken.text), 'Connected to ListenBrainz'), busy: busyLb),
                      ],
              ),
              _foot(context, 'Free and open. Sign in at listenbrainz.org, open Settings, and copy your user token here.'),
              const GroupLabel('Last.fm'),
              GroupCard(
                children: sc.lfmOn
                    ? [
                        GroupRow(icon: Icons.check_circle_rounded, title: 'Connected', subtitle: sc.lfmUser),
                        GroupRow(icon: Icons.logout_rounded, title: 'Disconnect', titleColor: const Color(0xFFFF3B30), onTap: sc.disconnectLastFm),
                      ]
                    : [
                        if (Scrobbler.hasBuiltInLfm || (lfmKey.text.trim().length == 32 && lfmSecret.text.trim().length == 32))
                          GroupRow(
                            key: const ValueKey('lfm-web-signin'),
                            icon: Icons.login_rounded,
                            title: 'Sign in on Last.fm',
                            subtitle: 'Last.fm\'s own page opens here. No password typed into Byte.',
                            chevron: true,
                            onTap: () => Navigator.of(context, rootNavigator: true).push<bool>(
                              MaterialPageRoute(
                                builder: (_) => LastFmWebLoginPage(
                                  apiKey: Scrobbler.hasBuiltInLfm ? Scrobbler.builtInLfmKey : lfmKey.text.trim(),
                                  secret: Scrobbler.hasBuiltInLfm ? Scrobbler.builtInLfmSecret : lfmSecret.text.trim(),
                                ),
                              ),
                            ),
                          ),
                        GroupRow(
                          icon: Icons.open_in_new_rounded,
                          title: 'Open Last.fm API page',
                          chevron: true,
                          onTap: () => launchUrl(Uri.parse('https://www.last.fm/api/account/create'), mode: LaunchMode.externalApplication),
                        ),
                        _Input(lfmKey, 'API key'),
                        _Input(lfmSecret, 'Shared secret', secret: true),
                        _Input(lfmUser, 'Last.fm user name'),
                        _Input(lfmPass, 'Last.fm password', secret: true),
                        _Button(
                          'Connect',
                          () => _run((b) => busyLfm = b, () => sc.connectLastFm(apiKey: lfmKey.text, secret: lfmSecret.text, user: lfmUser.text, password: lfmPass.text), 'Connected to Last.fm'),
                          busy: busyLfm,
                        ),
                      ],
              ),
              _foot(context, 'Create a free API account at last.fm/api/account/create (any name), then paste its API key and shared secret. Your password is used once to sign in and is not kept.'),
              const SizedBox(height: 120),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Your own server (WebDAV) ─────────────────────────────────────────────
class OwnServerScreen extends StatefulWidget {
  const OwnServerScreen({super.key});
  @override
  State<OwnServerScreen> createState() => _OwnServerScreenState();
}

class _OwnServerScreenState extends State<OwnServerScreen> {
  final url = TextEditingController(), user = TextEditingController(), pass = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    final d = Services.i.webdav;
    url.text = d.url;
    user.text = d.user;
  }

  @override
  void dispose() {
    url.dispose();
    user.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Services.i.webdav.connect(url.text, user.text, pass.text);
      if (mounted) {
        toast(context, 'Connected');
        pushPage(context, const DavFolderScreen());
      }
    } on DavProblem catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Couldn\'t reach the server. Check the address.';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = Services.i.webdav;
    return ListenableBuilder(
      listenable: d,
      builder: (context, _) => SubPage(capWidth: true, 
        title: 'Your own server',
        showProfile: false,
        slivers: [
          SliverList.list(
            children: [
              if (d.configured) ...[
                GroupCard(
                  children: [
                    GroupRow(icon: Icons.folder_open_rounded, title: 'Browse my music', subtitle: d.url, chevron: true, onTap: () => pushPage(context, const DavFolderScreen())),
                    GroupRow(icon: Icons.link_off_rounded, title: 'Forget this server', titleColor: const Color(0xFFFF3B30), onTap: d.forget),
                  ],
                ),
                const GroupLabel('Change server'),
              ] else
                const GroupLabel('WebDAV server'),
              GroupCard(
                children: [
                  _Input(url, 'Address, e.g. https://cloud.example.com/remote.php/dav/files/me/Music/', type: TextInputType.url),
                  _Input(user, 'User name (optional)'),
                  _Input(pass, 'Password or app password (optional)', secret: true),
                  _Button('Connect', _connect, busy: busy),
                ],
              ),
              if (error != null) _foot(context, error!),
              _foot(context, 'Play the music on your own server: a home server, a NAS, or any WebDAV share. Songs stream straight from your server to this phone; your login stays on this phone.'),
              const SizedBox(height: 120),
            ],
          ),
        ],
      ),
    );
  }
}

class DavFolderScreen extends StatefulWidget {
  final Uri? folder;
  final String? name;
  const DavFolderScreen({super.key, this.folder, this.name});
  @override
  State<DavFolderScreen> createState() => _DavFolderScreenState();
}

class _DavFolderScreenState extends State<DavFolderScreen> {
  late Future<List<DavEntry>> _f;
  @override
  void initState() {
    super.initState();
    _f = Services.i.webdav.list(widget.folder);
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.name ?? 'Your server';
    return SubPage(capWidth: true, 
      title: title,
      largeTitle: false,
      showProfile: false,
      slivers: [
        SliverToBoxAdapter(
          child: FutureBuilder<List<DavEntry>>(
            future: _f,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) return const LoadingList();
              if (snap.hasError) {
                return ErrorRetry(
                  snap.error is DavProblem ? (snap.error as DavProblem).message : 'Couldn\'t open this folder',
                  onRetry: () => setState(() => _f = Services.i.webdav.list(widget.folder)),
                );
              }
              final all = snap.data!;
              final folders = all.where((e) => e.folder).toList();
              final songs = [for (final e in all.where((e) => e.isAudio)) WebDav.itemFor(e, folderName: widget.name)];
              if (folders.isEmpty && songs.isEmpty) return const EmptyNote('No folders or music files here');
              return Column(
                children: [
                  if (songs.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: PillButton(icon: Icons.play_arrow_rounded, label: 'Play', filled: true, onTap: () => Services.i.player.playItems(songs)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: PillButton(icon: Icons.shuffle_rounded, label: 'Shuffle', onTap: () => Services.i.player.playItems(songs, shuffle: true)),
                          ),
                        ],
                      ),
                    ),
                  for (final f in folders)
                    PlainRow(
                      icon: Icon(Icons.folder_rounded, color: BytePalette.of(context).label),
                      title: f.name,
                      onTap: () => pushPage(context, DavFolderScreen(folder: f.url, name: f.name)),
                    ),
                  for (final (i, it) in songs.indexed)
                    SongTile(
                      item: it,
                      onTap: () => Services.i.player.playItems(songs, start: i),
                    ),
                  const SizedBox(height: 140),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

// ── Spotify login (your own developer app) ──────────────────────────────
class SpotifyAccountScreen extends StatefulWidget {
  const SpotifyAccountScreen({super.key});
  @override
  State<SpotifyAccountScreen> createState() => _SpotifyAccountScreenState();
}

class _SpotifyAccountScreenState extends State<SpotifyAccountScreen> {
  final client = TextEditingController();
  Future<List<SpotifyPlaylistInfo>>? _lists;

  @override
  void initState() {
    super.initState();
    final sp = Services.i.spotify;
    client.text = sp.clientId.isNotEmpty ? sp.clientId : (SpotifyAccount.hasBuiltIn ? SpotifyAccount.builtInClientId : '');
    if (sp.connected) _lists = Services.i.spotifySync.refreshLists();
  }

  @override
  void dispose() {
    client.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final id = client.text.trim();
    if (!RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(id)) {
      toast(context, 'The Client ID is 32 letters and numbers. Copy it from your Spotify developer app.');
      return;
    }
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => SpotifyLoginPage(clientId: id)));
    if (ok == true && mounted) setState(() => _lists = Services.i.spotifySync.refreshLists());
  }

  void _import(SpotifyPlaylistInfo p) => pushPage(context, ImportScreen(preset: (onStatus) => Services.i.spotify.read(p, onStatus: onStatus)));

  @override
  Widget build(BuildContext context) {
    final sp = Services.i.spotify;
    final pal = BytePalette.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([sp, Services.i.spotifySync]),
      builder: (context, _) => SubPage(capWidth: true, 
        title: 'Spotify',
        showProfile: false,
        slivers: [
          SliverList.list(
            children: sp.connected
                ? [
                    GroupCard(
                      children: [
                        GroupRow(icon: Icons.check_circle_rounded, title: 'Logged in', subtitle: sp.userName),
                        GroupRow(
                          key: const ValueKey('spotify-sync-now'),
                          icon: Icons.sync_rounded,
                          title: Services.i.spotifySync.running ? (Services.i.spotifySync.status ?? 'Syncing…') : 'Sync now',
                          subtitle: Services.i.spotifySync.lastError ??
                              (Services.i.spotifySync.lastSync == null
                                  ? 'Liked Songs and playlists come into Byte'
                                  : '${Services.i.spotifySync.likedCount} liked songs · ${Services.i.spotifySync.playlistCount} playlists'),
                          enabled: !Services.i.spotifySync.running,
                          onTap: () => Services.i.spotifySync.syncNow(),
                        ),
                        GroupRow(
                          icon: Icons.autorenew_rounded,
                          title: 'Keep in sync',
                          subtitle: 'New likes and playlist changes come in by themselves',
                          trailing: ByteSwitch(value: Services.i.spotifySync.auto, onChanged: Services.i.spotifySync.setAuto),
                        ),
                        GroupRow(
                          key: const ValueKey('spotify-sync-help'),
                          icon: Icons.info_outline_rounded,
                          title: 'How sync works',
                          chevron: true,
                          onTap: () => showSyncHelp(context, service: 'Spotify', automatic: true),
                        ),
                        GroupRow(
                          icon: Icons.logout_rounded,
                          title: 'Log out of Spotify',
                          subtitle: 'So someone else can sign in on this device. Songs already in Byte stay.',
                          titleColor: const Color(0xFFFF3B30),
                          onTap: () async {
                            await sp.disconnect();
                            await Services.i.spotifySync.forget();
                            await forgetSpotifyWebSignIn();
                            if (mounted) setState(() => _lists = null);
                          },
                        ),
                      ],
                    ),
                    const GroupLabel('Your playlists'),
                    FutureBuilder<List<SpotifyPlaylistInfo>>(
                      future: _lists,
                      builder: (context, snap) {
                        if (snap.connectionState != ConnectionState.done) return const LoadingList(rows: 5);
                        final ls = snap.hasError ? Services.i.spotifySync.lists : snap.data!;
                        if (ls.isEmpty) {
                          return ErrorRetry(
                            snap.error is SpotifyProblem ? (snap.error as SpotifyProblem).message : 'Couldn\'t load your Spotify playlists',
                            onRetry: () => setState(() => _lists = Services.i.spotifySync.refreshLists()),
                          );
                        }
                        return GroupCard(
                          children: [
                            for (final p in ls)
                              GroupRow(
                                leading: p.id == 'liked'
                                    ? Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(6),
                                          gradient: const LinearGradient(colors: [Color(0xFF4A2BD6), Color(0xFF8FB5E8)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                                        ),
                                        child: const Icon(Icons.favorite_rounded, color: Colors.white, size: 20),
                                      )
                                    : Artwork(p.cover, size: 40, radius: 6),
                                title: p.name,
                                subtitle: [if (Services.i.spotifySync.countOf(p) >= 0) songCount(Services.i.spotifySync.countOf(p)), if (p.owner.isNotEmpty) p.owner].join(' · '),
                                value: (p.id == 'liked' ? Services.i.spotifySync.likedImported : Services.i.spotifySync.imported(p) != null) ? 'Open' : 'Import',
                                onTap: () => (p.id == 'liked' ? Services.i.spotifySync.likedImported : Services.i.spotifySync.imported(p) != null) ? openSpotifyPlaylist(context, p) : _import(p),
                              ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 120),
                  ]
                : [
                    // No setup needed for public playlists: this comes first.
                    const GroupLabel('Public playlists'),
                    GroupCard(
                      children: [
                        GroupRow(
                          icon: Icons.link_rounded,
                          title: 'Import a playlist by link',
                          subtitle: 'Paste any Spotify playlist link. No login needed.',
                          chevron: true,
                          onTap: () => showImportSheet(context),
                        ),
                      ],
                    ),
                    const GroupLabel('Your Liked Songs and playlists'),
                    GroupCard(
                      children: [
                        KeyedSubtree(
                          key: const ValueKey('spotify-web-signin'),
                          child: _Button('Sign in with Spotify', () async {
                            final ok = await Navigator.of(context, rootNavigator: true).push<bool>(MaterialPageRoute(builder: (_) => const SpotifyWebLoginPage()));
                            if (ok == true && mounted) setState(() => _lists = Services.i.spotifySync.refreshLists());
                          }),
                        ),
                      ],
                    ),
                    _foot(context, 'Spotify\'s own sign-in page opens here (email, phone or Google). Whoever signs in, their Liked Songs and playlists come into Byte and stay synced. Your password goes only to Spotify.'),
                    const GroupLabel('Other ways to connect'),
                    GroupCard(
                      children: [
                        GroupRow(
                          key: const ValueKey('spotify-cookie'),
                          icon: Icons.cookie_outlined,
                          title: 'Use a sign-in cookie',
                          subtitle: 'Paste the sp_dc cookie from a computer where you are signed in',
                          chevron: true,
                          onTap: () async {
                            final v = await promptText(context, title: 'sp_dc cookie', hint: 'Paste the value', action: 'Connect');
                            if (v == null || !context.mounted) return;
                            final ok = await connectSpotifyWithCookie(context, v);
                            if (ok && mounted) setState(() => _lists = Services.i.spotifySync.refreshLists());
                          },
                        ),
                      ],
                    ),
                    if (SpotifyAccount.hasBuiltIn) ...[
                      GroupCard(
                        children: [
                          KeyedSubtree(
                            key: const ValueKey('spotify-one-tap'),
                            child: _Button('Log in with Spotify', () {
                              client.text = SpotifyAccount.builtInClientId;
                              _login();
                            }),
                          ),
                        ],
                      ),
                      _foot(context, 'Brings your Liked Songs and every playlist, private ones too. Your Spotify password goes only to Spotify.'),
                    ],
                    Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        key: const ValueKey('spotify-own-app'),
                        initiallyExpanded: false,
                        title: Text('Use your own Spotify developer app', style: BT.body.copyWith(color: pal.label)),
                        children: [
                          GroupCard(
                            children: [
                              GroupRow(
                                leading: const _Step(1),
                                title: 'Open Spotify for Developers',
                                subtitle: 'Log in with your Spotify account, tap "Create app", give it any name',
                                chevron: true,
                                onTap: () => launchUrl(Uri.parse('https://developer.spotify.com/dashboard/create'), mode: LaunchMode.externalApplication),
                              ),
                              GroupRow(
                                leading: const _Step(2),
                                title: 'Copy this Redirect URI into the app',
                                subtitle: SpotifyAccount.redirectUri,
                                value: 'Copy',
                                onTap: () {
                                  Clipboard.setData(const ClipboardData(text: SpotifyAccount.redirectUri));
                                  toast(context, 'Copied. Paste it in "Redirect URIs", tick "Web API", then Save.');
                                },
                              ),
                              GroupRow(
                                leading: const _Step(3),
                                title: 'Paste the app\'s Client ID below',
                                subtitle: 'It\'s on the app\'s page, 32 letters and numbers',
                                value: 'Paste',
                                onTap: () async {
                                  final d = await Clipboard.getData(Clipboard.kTextPlain);
                                  final t = d?.text?.trim() ?? '';
                                  if (t.isNotEmpty && mounted) setState(() => client.text = t);
                                },
                              ),
                              _Input(client, 'Client ID', onChanged: (_) => setState(() {})),
                              if (client.text.trim().isNotEmpty && !_validId(client.text))
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                  child: Text('That doesn\'t look like a Client ID yet (32 letters and numbers).', style: BT.sub.copyWith(color: pal.accent)),
                                ),
                              _Button('Log in with Spotify', _validId(client.text) ? _login : null),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _foot(context, 'This is a free, one-time step Spotify asks of every app that reads private playlists. Your Spotify password goes only to Spotify.'),
                    const SizedBox(height: 120),
                  ],
          ),
        ],
      ),
    );
  }

  static bool _validId(String s) => RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(s.trim());
}

class _Step extends StatelessWidget {
  final int n;
  const _Step(this.n);
  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 28,
    alignment: Alignment.center,
    decoration: const BoxDecoration(color: ByteColors.brand, shape: BoxShape.circle),
    child: Text(
      '$n',
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
    ),
  );
}

/// Spotify's own sign-in page; Byte only catches the redirect at the end.
class SpotifyLoginPage extends StatefulWidget {
  final String clientId;
  const SpotifyLoginPage({super.key, required this.clientId});
  @override
  State<SpotifyLoginPage> createState() => _SpotifyLoginPageState();
}

class _SpotifyLoginPageState extends State<SpotifyLoginPage> {
  WebViewController? web;
  double progress = 0;
  bool done = false;

  @override
  void initState() {
    super.initState();
    final url = Services.i.spotify.authorizeUrl(widget.clientId);
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => progress = p / 100);
          },
          onNavigationRequest: (r) {
            if (r.url.startsWith(SpotifyAccount.redirectUri)) {
              _finish(Uri.parse(r.url));
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(url);
    web = c;
  }

  Future<void> _finish(Uri u) async {
    if (done) return;
    done = true;
    try {
      await Services.i.spotify.finish(u);
      if (!mounted) return;
      toast(context, 'Logged in to Spotify');
      Navigator.pop(context, true);
    } on SpotifyProblem catch (e) {
      if (!mounted) return;
      toast(context, e.message);
      Navigator.pop(context, false);
    } catch (_) {
      if (!mounted) return;
      toast(context, 'No internet connection. Try again.');
      Navigator.pop(context, false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Spotify'),
      bottom: progress < 1
          ? PreferredSize(
              preferredSize: const Size.fromHeight(2),
              child: LinearProgressIndicator(value: progress, minHeight: 2),
            )
          : null,
    ),
    body: WebViewWidget(controller: web!),
  );
}

/// For tests: a server song as the player sees it.
Item davSong(String url, String name) => WebDav.itemFor(DavEntry(name, Uri.parse(url), false));
