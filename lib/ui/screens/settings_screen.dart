import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../brand.dart';
import '../../core/platform_caps.dart';
import '../../core/streams.dart';
import '../../services.dart';
import '../account_ui.dart';
import 'sync_screen.dart';
import 'admin_screen.dart';
import '../../data/usage.dart' show AdminApi;
import '../import_sheet.dart';
import '../music_apps.dart';
import '../../data/service_library.dart';

import '../web_logins.dart';
import '../../data/scrobble.dart';
import '../nav.dart';
import '../page.dart';
import '../style.dart';
import '../widgets.dart';
import 'listen_together_screen.dart';
import 'login_screen.dart';
import 'integrations_pages.dart';
import 'settings_pages.dart';
import 'audio_lab_screen.dart';
import 'phone_setup_screen.dart';
import '../glass.dart';

String qualityLabel(AudioQuality q) => switch (q) {
  AudioQuality.low => 'Data saver',
  AudioQuality.normal => 'Normal',
  AudioQuality.high => 'Best',
};

String qualityDetail(AudioQuality q) => switch (q) {
  AudioQuality.low => 'About 50–70 kbps · about 30 MB an hour',
  AudioQuality.normal => 'About 128 kbps · about 58 MB an hour',
  AudioQuality.high => 'Default. The highest the song has: Opus about 160 kbps (AAC 128 on iPhone) · about 70 MB an hour',
};

/// One searchable settings row: where it lives and how to open it.
class SettingEntry {
  final String title;
  final String sub;
  final String page;
  final Widget Function() open;
  const SettingEntry(this.title, this.sub, this.page, this.open);
}

List<SettingEntry> settingsIndex() => _allSettings().where((e) => !onWeb || !_notOnWeb.contains(e.title)).toList();

/// Pages a browser can't use.
const _notOnWeb = {'Downloads', 'Local Music', 'Phone setup'};

List<SettingEntry> _allSettings() => [
  SettingEntry(
    'Account & integrations',
    'Google account, YouTube Music, switch account, sign out, import playlists from Spotify, Apple Music, JioSaavn, Gaana, Amazon Music, SoundCloud, Deezer',
    'Settings',
    () => const AccountScreen(),
  ),
  SettingEntry('Byte account & sync', 'Email sign-in, same likes, playlists, history and settings on every device, sync now, sign out', 'Settings', () => const SyncScreen()),
  SettingEntry('Listen together', 'Party code, play the same music in time', 'Settings', () => const ListenTogetherScreen()),
  SettingEntry('Sources', 'Where audio comes from and the order used', 'Audio quality', () => const SourcesScreen()),
  SettingEntry('Music apps', 'Log in to Amazon Music, Apple Music, JioSaavn, Gaana, YouTube Music, SoundCloud, Deezer; liked songs and playlists', 'Account & integrations', () => const MusicAppsScreen()),
  SettingEntry('Spotify account', 'Log in with Spotify, private playlists, Liked Songs', 'Account & integrations', () => const SpotifyAccountScreen()),
  SettingEntry('Scrobbling', 'ListenBrainz, Last.fm, scrobble, now playing', 'Account & integrations', () => const ScrobblingScreen()),
  SettingEntry('Your own server', 'WebDAV, NAS, home server, play music from your server', 'Account & integrations', () => const OwnServerScreen()),
  SettingEntry('On Wi-Fi', 'Streaming quality on Wi-Fi', 'Audio quality', () => const QualityScreen(mobile: false)),
  SettingEntry('On mobile data', 'Streaming quality on mobile data', 'Audio quality', () => const QualityScreen(mobile: true)),
  SettingEntry('Downloads', 'Download quality, Wi-Fi only, keep playlists updated, delete all', 'Settings', () => const DownloadSettingsScreen()),
  SettingEntry('Playback', 'Automix, DJ, crossfade, loudness normalization, skip silence, speed, equalizer', 'Settings', () => const PlaybackScreen()),
  SettingEntry('Equalizer', 'Graph, bands and presets', 'Audio Lab', () => const LabEqualizerScreen()),
  SettingEntry('Reverb', 'Room, studio, plate', 'Audio Lab', () => const LabEffectsScreen()),
  SettingEntry('Crossfade', 'Off, auto or manual; gapless albums', 'Audio Lab', () => const LabTransitionScreen()),
  SettingEntry('Classic equalizer', 'The phone\'s own bands', 'Playback', () => const EqualizerScreen()),
  SettingEntry('Automix', 'DJ-style transitions, beat matching, transition length, smart shuffle', 'Playback', () => const AutomixScreen()),
  SettingEntry('Personal DJ', 'Hinglish or English, your name', 'Playback', () => const DjSettingsScreen()),
  SettingEntry('Appearance', 'App icon, theme, dark mode, blur, full-screen cover art, lyrics', 'Settings', () => const AppearanceScreen()),
  SettingEntry('Performance', 'High performance mode', 'Settings', () => const PerformanceScreen()),
  SettingEntry('Phone setup', 'Background play, autostart, battery, lock screen: Xiaomi, Redmi, POCO, vivo, iQOO, OPPO, realme, OnePlus, Samsung, Huawei, Honor, Motorola', 'Settings', () => const PhoneSetupScreen()),
  SettingEntry('Local Music', 'Music folder, filter non-music audio', 'Settings', () => const LocalMusicSettingsScreen()),
  SettingEntry('Storage', 'Cache, downloads space, clear', 'Settings', () => const StorageScreen()),
  SettingEntry('Your data', 'Replay, export and import, history', 'Settings', () => const YourDataScreen()),
  SettingEntry('Miscellaneous', 'Swipe, autoplay, queue history, status bar', 'Settings', () => const MiscScreen()),
  SettingEntry('Language', 'App language, content language and region', 'Settings', () => const LanguageScreen()),
  SettingEntry('Advanced & experimental options', 'Stats for nerds, stream check', 'Settings', () => const AdvancedScreen()),
  SettingEntry('About Byte', 'Version, licenses', 'Settings', () => const AboutScreen()),
];

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final q = TextEditingController();
  ConnectivityResult? net;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      Connectivity()
          .checkConnectivity()
          .then((r) {
            if (mounted) {
              setState(
                () => net = r.contains(ConnectivityResult.wifi)
                    ? ConnectivityResult.wifi
                    : (r.contains(ConnectivityResult.mobile) ? ConnectivityResult.mobile : null),
              );
            }
          })
          .catchError((_) {});
    }
  }

  @override
  void dispose() {
    q.dispose();
    super.dispose();
  }

  void open(Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final st = s.settings;
    final p = BytePalette.of(context);
    final query = q.text.trim().toLowerCase();
    return ListenableBuilder(
      listenable: Listenable.merge([st, s.account, s.party, s.cloud, s.sync]),
      builder: (context, _) => SubPage(capWidth: true, 
        title: 'Settings',
        showProfile: false,
        rememberScroll: true,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
              child: Container(
                height: 46,
                decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    const SizedBox(width: 10),
                    Icon(Icons.search_rounded, color: p.secondary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: TextField(
                        controller: q,
                        onChanged: (_) => setState(() {}),
                        style: BT.body.copyWith(color: p.label),
                        decoration: InputDecoration(
                          isCollapsed: true,
                          border: InputBorder.none,
                          hintText: 'Search settings',
                          hintStyle: BT.body.copyWith(color: p.secondary),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (query.isNotEmpty)
            SliverToBoxAdapter(child: _searchResults(query))
          else ...[
            SliverToBoxAdapter(
              child: GroupCard(
                children: [
                  GroupRow(
                    key: const ValueKey('settings-sync'),
                    icon: Icons.cloud_sync_outlined,
                    title: 'Byte account & sync',
                    subtitle: s.cloud.email == null ? 'Create account or log in · same Byte on every device' : '${s.cloud.email} · ${syncStatusLine(s.sync).$2}',
                    chevron: true,
                    onTap: () => open(const SyncScreen()),
                  ),
                  if (AdminApi.isOwner(s.cloud.email))
                    GroupRow(
                      key: const ValueKey('settings-admin'),
                      icon: Icons.admin_panel_settings_outlined,
                      title: 'Admin',
                      subtitle: 'Who uses Byte, top songs, daily active phones',
                      chevron: true,
                      onTap: () => open(const AdminScreen()),
                    ),
                  GroupRow(
                    icon: Icons.person_outline_rounded,
                    title: 'Account & integrations',
                    subtitle: s.account.email != null ? 'Google: ${s.account.email}' : 'Sign in with Google · Spotify · Last.fm · your own server',
                    chevron: true,
                    onTap: () => open(const AccountScreen()),
                  ),
                  GroupRow(
                    icon: Icons.people_outline_rounded,
                    title: 'Listen together',
                    subtitle: s.party.active ? 'In a party · ${s.party.code}' : 'Share a code and play the same music, in time',
                    chevron: true,
                    onTap: () => open(const ListenTogetherScreen()),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 22),
                child: GroupCard(
                  children: [
                    GroupRow(
                      key: const ValueKey('settings-audio-lab'),
                      icon: Icons.graphic_eq_rounded,
                      title: 'Audio Lab',
                      subtitle: 'Equalizer, effects, transitions, audio pass',
                      chevron: true,
                      onTap: () => open(const AudioLabScreen()),
                    ),
                  ],
                ),
              ),
            ),
            const SliverToBoxAdapter(child: GroupLabel('Audio quality')),
            SliverToBoxAdapter(
              child: GroupCard(
                children: [
                  GroupRow(
                    icon: Icons.input_rounded,
                    title: 'Sources',
                    subtitle: 'Where audio comes from and the order used',
                    chevron: true,
                    onTap: () => open(const SourcesScreen()),
                  ),
                  GroupRow(
                    leading: const SizedBox(width: 26),
                    title: 'Direct Source Stream',
                    subtitle: 'Start songs without checking the stream first. Faster, but a song can stop early on some networks',
                    trailing: ByteSwitch(value: !st.verifyStreams, onChanged: (v) => st.verifyStreams = !v),
                  ),
                  GroupRow(
                    icon: Icons.wifi_rounded,
                    title: 'On Wi-Fi',
                    badge: net == ConnectivityResult.wifi ? const Badge2('IN USE') : null,
                    value: qualityLabel(st.wifiQuality),
                    chevron: true,
                    onTap: () => open(const QualityScreen(mobile: false)),
                  ),
                  GroupRow(
                    icon: Icons.signal_cellular_alt_rounded,
                    title: 'On mobile data',
                    badge: net == ConnectivityResult.mobile ? const Badge2('IN USE') : null,
                    value: qualityLabel(st.mobileQuality),
                    chevron: true,
                    onTap: () => open(const QualityScreen(mobile: true)),
                  ),
                  ListenableBuilder(
                    listenable: s.route,
                    builder: (context, _) {
                      final can = s.route.info.atmos;
                      return GroupRow(
                        icon: Icons.surround_sound_outlined,
                        title: 'Spatial surround',
                        subtitle: can ? 'Plays the spatial surround version when one of your sources has it' : 'This phone or output can\'t play spatial surround',
                        enabled: can,
                        trailing: ByteSwitch(value: can && st.dolbyAtmos, onChanged: can ? (v) => st.dolbyAtmos = v : null),
                      );
                    },
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
                child: Text(
                  'Online streams are lossy (AAC / Opus). Lossless, Hi-Res and spatial surround only appear for songs from your own files, server or addons that really have them.',
                  style: BT.sub.copyWith(color: p.secondary),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 22)),
            SliverToBoxAdapter(
              child: GroupCard(
                children: [
                  if (!onWeb) GroupRow(icon: Icons.arrow_circle_down_outlined, title: 'Downloads', chevron: true, onTap: () => open(const DownloadSettingsScreen())),
                  GroupRow(icon: Icons.play_circle_outline_rounded, title: 'Playback', chevron: true, onTap: () => open(const PlaybackScreen())),
                  GroupRow(icon: Icons.brush_outlined, title: 'Appearance', chevron: true, onTap: () => open(const AppearanceScreen())),
                  GroupRow(icon: Icons.speed_outlined, title: 'Performance', chevron: true, onTap: () => open(const PerformanceScreen())),
                  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
                    GroupRow(
                      key: const ValueKey('settings-phone-setup'),
                      icon: Icons.phonelink_setup_rounded,
                      title: 'Phone setup',
                      subtitle: 'So Byte plays in the background on any phone brand',
                      chevron: true,
                      onTap: () => open(const PhoneSetupScreen()),
                    ),
                  if (!onWeb) GroupRow(icon: Icons.other_houses_outlined, title: 'Local Music', chevron: true, onTap: () => open(const LocalMusicSettingsScreen())),
                  GroupRow(icon: Icons.dns_outlined, title: 'Storage', chevron: true, onTap: () => open(const StorageScreen())),
                  GroupRow(icon: Icons.inventory_2_outlined, title: 'Your data', chevron: true, onTap: () => open(const YourDataScreen())),
                  GroupRow(icon: Icons.pending_outlined, title: 'Miscellaneous', chevron: true, onTap: () => open(const MiscScreen())),
                  GroupRow(icon: Icons.language_rounded, title: 'Language', chevron: true, onTap: () => open(const LanguageScreen())),
                  if (!onWeb)
                  GroupRow(
                    key: const ValueKey('settings-wear'),
                    icon: Icons.watch_outlined,
                    title: 'Wear OS',
                    subtitle: 'Control Byte from your watch',
                    chevron: true,
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => GlassDialog(
                        title: const Text('Wear OS'),
                        content: const Text(
                          'Your watch\'s media controls already work with Byte: play, pause, skip and volume show up on the watch while music plays. A separate watch app for browsing and offline songs isn\'t built yet.',
                        ),
                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                      ),
                    ),
                  ),
                  GroupRow(icon: Icons.handyman_outlined, title: 'Advanced & experimental options', chevron: true, onTap: () => open(const AdvancedScreen())),
                ],
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 22)),
            SliverToBoxAdapter(
              child: GroupCard(
                children: [
                  GroupRow(
                    icon: Icons.info_outline_rounded,
                    title: 'About ${Brand.appName}',
                    value: Brand.version,
                    chevron: true,
                    onTap: () => open(const AboutScreen()),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 0),
                child: Text(
                  '${Brand.appName} ${Brand.version.replaceFirst(RegExp(r'\.0$'), '')} · ${Brand.copyright}',
                  textAlign: TextAlign.center,
                  style: BT.caption.copyWith(color: p.secondary),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _searchResults(String query) {
    final hits = settingsIndex().where((e) => '${e.title} ${e.sub}'.toLowerCase().contains(query)).toList();
    if (hits.isEmpty) return EmptyNote('No settings match "${q.text.trim()}".');
    return GroupCard(
      children: [for (final h in hits) GroupRow(title: h.title, subtitle: '${h.page} · ${h.sub}', chevron: true, onTap: () => open(h.open()))],
    );
  }
}

// ── Account & integrations ─────────────────────────────────────────────
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final acc = Services.i.account;
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: acc,
      builder: (context, _) {
        final a = acc.active;
        return SubPage(capWidth: true, 
          title: 'Account & integrations',
          showProfile: false,
          slivers: [
            SliverToBoxAdapter(
              child: GroupCard(
                dividerIndent: 16,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: Row(
                      children: [
                        AccountAvatar(account: a, size: 56),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                a?.name ?? 'Not signed in',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: BT.title3.copyWith(color: p.label, fontWeight: FontWeight.w600),
                              ),
                              Text(
                                a?.email ?? (a == null ? 'Sign in to bring your YouTube Music playlists' : 'YouTube Music'),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: BT.sub.copyWith(color: p.secondary, fontSize: 15),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (a != null) ...[
                    GroupRow(
                      icon: Icons.account_circle_outlined,
                      title: 'Listen as',
                      subtitle: a.name,
                      chevron: true,
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManageAccountsScreen())),
                    ),
                    GroupRow(
                      icon: Icons.sync_rounded,
                      title: acc.syncing ? 'Syncing…' : 'Sync playlists now',
                      subtitle:
                          acc.syncMessage ?? (acc.lastSync == null ? 'Your playlists appear in Library automatically' : 'Last synced ${_ago(acc.lastSync!)}'),
                      enabled: !acc.syncing,
                      onTap: acc.sync,
                    ),
                    InkWell(
                      onTap: () => _signOut(context),
                      child: SizedBox(
                        height: 52,
                        child: Center(
                          child: Text('Sign out', style: BT.body.copyWith(color: p.label)),
                        ),
                      ),
                    ),
                  ] else
                    InkWell(
                      onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
                      child: SizedBox(
                        height: 52,
                        child: Center(
                          child: Text('Sign in with Google', style: BT.bodyStrong.copyWith(color: p.accent)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
                child: Text(
                  'One account can have a personal profile and brand profiles; each has its own library. Your sign-in stays on this phone and is only sent to the music service.',
                  style: BT.sub.copyWith(color: p.secondary),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: GroupLabel('Spotify')),
            SliverToBoxAdapter(
              child: ListenableBuilder(
                listenable: Listenable.merge([Services.i.spotify, Services.i.spotifySync]),
                builder: (context, _) {
                  final sp = Services.i.spotify;
                  final sy = Services.i.spotifySync;
                  final sub = !sp.connected
                      ? 'Tap to connect'
                      : sy.running
                      ? (sy.status ?? 'Syncing…')
                      : sy.lastError ?? (sy.lastSync == null ? 'Connected · ${sp.userName}' : '${sp.userName} · ${sy.likedCount} liked songs, ${sy.playlistCount} playlists · synced ${_ago(sy.lastSync!)}');
                  return GroupCard(
                    children: [
                      GroupRow(
                        key: const ValueKey('spotify-row'),
                        leading: const ServiceMark(ServiceMarkKind.spotify),
                        title: 'Spotify',
                        subtitle: sub,
                        chevron: true,
                        onTap: () async {
                          if (sp.connected) {
                            pushPage(context, const SpotifyAccountScreen());
                          } else {
                            await Navigator.of(context, rootNavigator: true).push<bool>(MaterialPageRoute(builder: (_) => const SpotifyWebLoginPage()));
                          }
                        },
                      ),
                    ],
                  );
                },
              ),
            ),
            SliverToBoxAdapter(child: _Caption('Sign in to load your Liked Songs and playlists; they stay synced. Songs play through Byte\'s usual sources.')),
            const SliverToBoxAdapter(child: GroupLabel('Other music apps')),
            SliverToBoxAdapter(
              child: ListenableBuilder(
                listenable: Listenable.merge([Services.i.libSync, Services.i.account]),
                builder: (context, _) => GroupCard(
                  children: [
                    for (final spec in libServices(region: Services.i.settings.contentRegion).where((x) => x.service != LibService.spotify))
                      GroupRow(
                        key: ValueKey('account-music-app-${spec.service.name}'),
                        leading: MusicAppBadge(spec.service),
                        title: spec.name,
                        subtitle: musicAppStatus(spec.service),
                        chevron: true,
                        onTap: () => pushPage(context, MusicAppAccountScreen(service: spec.service)),
                      ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(child: _Caption('Log in on the app\'s own page; your liked songs and playlists come into Byte.')),
            const SliverToBoxAdapter(child: GroupLabel('Rich presence')),
            SliverToBoxAdapter(
              child: GroupCard(
                children: [
                  GroupRow(
                    key: const ValueKey('discord-row'),
                    leading: const ServiceMark(ServiceMarkKind.discord),
                    title: 'Discord',
                    subtitle: 'Not available on phones yet',
                    chevron: true,
                    onTap: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Discord'),
                        content: const Text(
                          'Discord only lets apps show "listening to" from its computer app, or through its own closed kit for game makers. A phone app would have to log in with your Discord password in a way Discord bans accounts for, so Byte doesn\'t do that.',
                        ),
                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SliverToBoxAdapter(child: _Caption('Show what you are playing on your profile there.')),
            const SliverToBoxAdapter(child: GroupLabel('Scrobbling')),
            SliverToBoxAdapter(
              child: ListenableBuilder(
                listenable: Services.i.scrobbler,
                builder: (context, _) {
                  final sc = Services.i.scrobbler;
                  return GroupCard(
                    children: [
                      GroupRow(
                        key: const ValueKey('listenbrainz-row'),
                        leading: const ServiceMark(ServiceMarkKind.listenbrainz),
                        title: 'ListenBrainz',
                        subtitle: sc.lbOn ? 'Connected · ${sc.lbUser}' : 'Enter a token to enable',
                        trailing: ByteSwitch(
                          value: sc.lbOn,
                          onChanged: (v) => v ? pushPage(context, const ScrobblingScreen()) : sc.disconnectListenBrainz(),
                        ),
                        onTap: () => pushPage(context, const ScrobblingScreen()),
                      ),
                      GroupRow(
                        key: const ValueKey('lastfm-row'),
                        leading: const ServiceMark(ServiceMarkKind.lastfm),
                        title: 'Last.fm',
                        subtitle: sc.lfmOn ? 'Connected · ${sc.lfmUser}' : 'Tap to sign in',
                        trailing: ByteSwitch(
                          value: sc.lfmOn,
                          onChanged: (v) => v ? _lastFmSignIn(context) : sc.disconnectLastFm(),
                        ),
                        onTap: () => _lastFmSignIn(context),
                      ),
                    ],
                  );
                },
              ),
            ),
            SliverToBoxAdapter(child: _Caption('Scrobble your listens to Last.fm and ListenBrainz.')),
            const SliverToBoxAdapter(child: GroupLabel('More')),
            SliverToBoxAdapter(
              child: GroupCard(
                children: [
                  GroupRow(
                    icon: Icons.playlist_add_rounded,
                    title: 'Import a playlist',
                    subtitle: 'From a playlist link, a song list or a CSV file',
                    chevron: true,
                    onTap: () => showImportSheet(context),
                  ),
                  GroupRow(
                    icon: Icons.dns_rounded,
                    title: 'Your own server',
                    subtitle: Services.i.webdav.configured ? Services.i.webdav.url : 'Play music from your NAS or cloud (WebDAV)',
                    chevron: true,
                    onTap: () => pushPage(context, const OwnServerScreen()),
                  ),
                ],
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        );
      },
    );
  }

  Future<void> _lastFmSignIn(BuildContext context) async {
    final sc = Services.i.scrobbler;
    if (Scrobbler.hasBuiltInLfm || sc.lfmKey.isNotEmpty) {
      final key = Scrobbler.hasBuiltInLfm ? Scrobbler.builtInLfmKey : sc.lfmKey;
      final secret = Scrobbler.hasBuiltInLfm ? Scrobbler.builtInLfmSecret : sc.lfmSecret;
      await Navigator.of(context, rootNavigator: true).push<bool>(MaterialPageRoute(builder: (_) => LastFmWebLoginPage(apiKey: key, secret: secret)));
    } else {
      pushPage(context, const ScrobblingScreen());
    }
  }

  Future<void> _signOut(BuildContext context) async {
    final acc = Services.i.account;
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: const Text('Sign out?'),
        content: const Text('Your liked songs, downloads and Byte playlists stay. Remove the playlists that came from this account too?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep playlists')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove them', style: TextStyle(color: Color(0xFFFF3B30))),
          ),
        ],
      ),
    );
    if (remove == null) return;
    await acc.signOut(removePlaylists: remove);
    Services.i.feedVersion.value++;
    if (context.mounted) toast(context, 'Signed out');
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return '${d.inDays} days ago';
}

/// Every account saved on this phone: switch ("Listen as"), add, remove.
class ManageAccountsScreen extends StatelessWidget {
  const ManageAccountsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final acc = Services.i.account;
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: acc,
      builder: (context, _) => SubPage(capWidth: true, 
        title: 'Accounts',
        showProfile: false,
        slivers: [
          SliverToBoxAdapter(
            child: GroupCard(
              dividerIndent: 72,
              children: [
                for (final a in acc.accounts)
                  GroupRow(
                    leading: AccountAvatar(account: a, size: 42),
                    title: a.name,
                    subtitle: a.email ?? a.handle ?? 'Music account',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (a.key == acc.activeKey) Icon(Icons.check_rounded, color: p.label),
                        IconButton(
                          tooltip: 'Remove from this phone',
                          icon: Icon(Icons.remove_circle_outline_rounded, color: p.secondary),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => GlassDialog(
                                title: Text('Remove ${a.name}?'),
                                content: const Text('Byte forgets this sign-in. You can add it again any time.'),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Remove', style: TextStyle(color: Color(0xFFFF3B30))),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await acc.remove(a.key);
                              Services.i.feedVersion.value++;
                            }
                          },
                        ),
                      ],
                    ),
                    onTap: () async {
                      await acc.switchTo(a.key);
                      Services.i.feedVersion.value++;
                    },
                  ),
                GroupRow(
                  icon: Icons.person_add_alt_1_outlined,
                  title: 'Add account',
                  onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
                ),
              ],
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
              child: Text(
                'Tap an account to listen as it. Its playlists replace the ones from the previous account in Library.',
                style: BT.sub.copyWith(color: p.secondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens a settings page from anywhere (kept for older callers).
void openSettings(BuildContext context) => pushPage(context, const SettingsScreen());


/// Small grey note under a group (the reference's captions).
class _Caption extends StatelessWidget {
  final String text;
  const _Caption(this.text);
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
    child: Text(text, style: BT.sub.copyWith(color: BytePalette.of(context).secondary)),
  );
}
