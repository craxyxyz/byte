import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../brand.dart';
import '../developer_concepts.dart';
import '../../core/platform_caps.dart';
import '../../core/streams.dart';
import '../../data/genres.dart';
import '../../data/backup.dart';
import '../../lyrics/lyrics_service.dart';
import '../../lyrics/translate.dart';
import '../lyrics_view.dart' show LyricsPane;
import '../../player/equalizer.dart';
import '../../services.dart';
import '../app_icon_picker.dart';
import '../report_problem.dart';
import '../app_icons.dart';
import '../dj_card.dart';
import '../logo.dart';
import '../nav.dart';
import '../page.dart';
import '../style.dart';
import 'audio_lab_screen.dart';
import '../theme.dart';
import '../widgets.dart';
import 'integrations_pages.dart';
import 'library_pages.dart';
import 'lock_screen_settings.dart';
import 'settings_screen.dart';
import 'sources_pages.dart';
import '../glass.dart';

Widget _note(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
  child: Text(text, style: BT.sub.copyWith(color: BytePalette.of(context).secondary)),
);

/// A settings sub-page that rebuilds when settings change.
class _SettingsPage extends StatelessWidget {
  final String title;
  final List<Widget> Function(BuildContext) children;
  final Listenable? extra;
  const _SettingsPage({required this.title, required this.children, this.extra});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return ListenableBuilder(
      listenable: extra == null ? st : Listenable.merge([st, extra]),
      builder: (context, _) => SubPage(capWidth: true, 
        title: title,
        showProfile: false,
        rememberScroll: true,
        slivers: [SliverList.list(children: children(context))],
      ),
    );
  }
}

Widget _switchRow(IconData? icon, String title, String? sub, bool value, ValueChanged<bool>? onChanged) => GroupRow(
  icon: icon,
  leading: icon == null ? const SizedBox(width: 26) : null,
  title: title,
  subtitle: sub,
  enabled: onChanged != null,
  trailing: ByteSwitch(value: value, onChanged: onChanged),
  onTap: onChanged == null ? null : () => onChanged(!value),
);

// ── Sources ──────────────────────────────────────────────────────────────
class SourcesScreen extends StatelessWidget {
  const SourcesScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    final ad = Services.i.addons;
    return _SettingsPage(
      title: 'Sources',
      extra: ad,
      children: (context) {
        final p = BytePalette.of(context);
        Widget num(int n) => SizedBox(
          width: 18,
          child: Text('$n', style: BT.body.copyWith(color: p.secondary)),
        );
        var n = 0;
        Widget lead(IconData i) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            num(++n),
            const SizedBox(width: 8),
            Icon(i, color: p.label),
          ],
        );
        return [
          const GroupLabel('Sources, tried in this order'),
          GroupCard(
            dividerIndent: 70,
            children: [
              GroupRow(
                leading: lead(Icons.download_done_rounded),
                title: 'Downloads on this phone',
                subtitle: 'Songs you downloaded play from the phone, even offline',
                trailing: ByteSwitch(
                  value: st.preferDownloads,
                  onChanged: (v) async {
                    if (!v) {
                      final ok = await confirm(
                        context,
                        'Stream downloaded songs?',
                        'Byte will stream songs even when they are downloaded. The downloaded copy is still used when you are offline.',
                        action: 'Stream them',
                        destructive: false,
                      );
                      if (!ok) return;
                    }
                    st.preferDownloads = v;
                  },
                ),
              ),
              for (final a in ad.all)
                GroupRow(
                  leading: lead(Icons.extension_rounded),
                  title: a.name,
                  subtitle: a.description ?? 'Addon · ${a.resources.join(', ')}',
                  trailing: ByteSwitch(value: a.enabled, onChanged: (v) => ad.setEnabled(a.id, v)),
                ),
              GroupRow(leading: lead(Icons.smart_display_outlined), title: 'Online catalogue', subtitle: 'Lossy · Full catalogue · Radio', value: 'Always on'),
              GroupRow(
                leading: const SizedBox(
                  width: 50,
                  child: Align(alignment: Alignment.centerRight, child: Icon(Icons.add_rounded)),
                ),
                title: 'Add an addon',
                subtitle: 'Your own server that searches and streams music',
                chevron: true,
                onTap: () => pushPage(context, const AddonsScreen()),
              ),
            ],
          ),
          _note(
            context,
            'Byte looks for each song in this order and falls back to the next one. Songs from Local Music, WebDAV and SMB always play from there. '
            'No lossless source is built in: the online catalogue is lossy.',
          ),
          const GroupLabel('WebDAV'),
          GroupCard(
            children: [
              GroupRow(
                icon: Icons.dns_rounded,
                title: 'WebDAV',
                subtitle: Services.i.webdav.configured ? Services.i.webdav.url : 'Your NAS or cloud folder',
                chevron: true,
                onTap: () => pushPage(context, const OwnServerScreen()),
              ),
            ],
          ),
          _note(context, 'A home server, a NAS or any WebDAV folder.'),
          const GroupLabel('SMB'),
          GroupCard(
            children: [
              GroupRow(
                icon: Icons.lan_outlined,
                title: 'SMB',
                subtitle: Services.i.smb.configured ? Services.i.smb.host : 'Windows or NAS shared folders on your Wi-Fi',
                chevron: true,
                onTap: () => pushPage(context, const SmbScreen()),
              ),
            ],
          ),
          _note(context, 'Play straight from a shared folder; nothing is copied.'),
          const GroupLabel('Source matching'),
          GroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        SizedBox(width: 26, child: Icon(Icons.straighten_rounded, color: p.label)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text('Track length tolerance', style: BT.body.copyWith(color: p.label)),
                        ),
                        Text('±${st.trackLengthTolerance} s', style: BT.body.copyWith(color: p.secondary)),
                      ],
                    ),
                    Slider(
                      value: st.trackLengthTolerance.toDouble(),
                      min: 1,
                      max: 15,
                      divisions: 14,
                      label: '±${st.trackLengthTolerance} s',
                      onChanged: (v) => st.trackLengthTolerance = v.round(),
                    ),
                  ],
                ),
              ),
            ],
          ),
          _note(context, 'How much a song\'s length may differ between sources (and in playlist imports) and still count as the same song.'),
        ];
      },
    );
  }
}

// ── Quality picker ───────────────────────────────────────────────────────
class QualityScreen extends StatelessWidget {
  final bool mobile;
  final bool download;
  const QualityScreen({super.key, this.mobile = false, this.download = false});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    final title = download ? 'Download quality' : (mobile ? 'On mobile data' : 'On Wi-Fi');
    return _SettingsPage(
      title: title,
      children: (context) {
        final p = BytePalette.of(context);
        final cur = download ? st.downloadQuality : (mobile ? st.mobileQuality : st.wifiQuality);
        return [
          GroupCard(
            dividerIndent: 16,
            children: [
              for (final q in AudioQuality.values.reversed)
                GroupRow(
                  title: qualityLabel(q),
                  subtitle: qualityDetail(q),
                  trailing: q == cur ? Icon(Icons.check_rounded, color: p.accent) : const SizedBox(width: 24),
                  onTap: () {
                    HapticFeedback.selectionClick();
                    if (download) {
                      st.downloadQuality = q;
                    } else if (mobile) {
                      st.mobileQuality = q;
                    } else {
                      st.wifiQuality = q;
                    }
                  },
                ),
            ],
          ),
          _note(context, download ? 'For songs you download. Higher takes more space.' : (mobile ? 'While on mobile data.' : 'While on Wi-Fi.')),
        ];
      },
    );
  }
}

// ── Downloads ────────────────────────────────────────────────────────────
class DownloadSettingsScreen extends StatelessWidget {
  const DownloadSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final st = s.settings;
    return _SettingsPage(
      title: 'Downloads',
      extra: Listenable.merge([s.library, s.downloads]),
      children: (context) => [
        GroupCard(
          children: [
            GroupRow(
              icon: Icons.high_quality_outlined,
              title: 'Download quality',
              value: qualityLabel(st.downloadQuality),
              chevron: true,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QualityScreen(download: true))),
            ),
            _switchRow(
              Icons.wifi_rounded,
              'Download on Wi-Fi only',
              'Downloads wait until you are on Wi-Fi',
              st.downloadWifiOnly,
              (v) => st.downloadWifiOnly = v,
            ),
            _switchRow(
              Icons.ios_share_rounded,
              'Export compatible downloads',
              'Names new downloads "Artist - Title.m4a" with tags and cover, so other music apps show them properly',
              st.compatibleDownloads,
              (v) => st.compatibleDownloads = v,
            ),
            _switchRow(
              Icons.playlist_add_check_rounded,
              'Keep downloaded playlists updated',
              'New songs added to a downloaded playlist download by themselves',
              st.keepPlaylistsUpdated,
              (v) => st.keepPlaylistsUpdated = v,
            ),
            if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
              GroupRow(
                icon: Icons.folder_outlined,
                title: 'Save downloads in',
                subtitle: st.downloadDir == 'external' ? 'Phone storage (Android/data/…/Byte Downloads)' : 'Inside Byte (private)',
                chevron: true,
                onTap: () async {
                  final v = await showByteSheet<String>(
                    context: context,
                    builder: (ctx) => SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(title: const Text('Inside Byte (private)'), onTap: () => Navigator.pop(ctx, 'app')),
                          ListTile(title: const Text('Phone storage (Android/data)'), onTap: () => Navigator.pop(ctx, 'external')),
                        ],
                      ),
                    ),
                  );
                  if (v != null) st.downloadDir = v;
                },
              ),
          ],
        ),
        const SizedBox(height: 22),
        GroupCard(
          children: [
            GroupRow(
              icon: Icons.download_done_rounded,
              title: 'Downloaded songs',
              subtitle: '${s.library.downloads.length} songs · ${(s.downloads.totalBytes / 1048576).toStringAsFixed(1)} MB',
              chevron: true,
              onTap: () => pushPage(context, const DownloadsScreen()),
            ),
            GroupRow(
              icon: Icons.delete_outline_rounded,
              title: 'Delete all downloads',
              titleColor: const Color(0xFFFF3B30),
              enabled: s.library.downloads.isNotEmpty,
              onTap: () async {
                final ok = await confirm(context, 'Delete all downloads?', 'The songs stay in your library and stream again.', action: 'Delete');
                if (!ok) return;
                for (final d in s.library.downloads.toList()) {
                  await s.downloads.delete(d.item.id);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

// ── Playback ─────────────────────────────────────────────────────────────
// ── Automix ──────────────────────────────────────────────────────────────
class AutomixScreen extends StatefulWidget {
  const AutomixScreen({super.key});
  @override
  State<AutomixScreen> createState() => _AutomixScreenState();
}

class _AutomixScreenState extends State<AutomixScreen> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    final a = Services.i.automix;
    if (a == null || kIsWeb) return;
    final n = await a.cacheBytes();
    if (mounted) setState(() => _bytes = n);
  }

  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return _SettingsPage(
      title: 'Automix',
      children: (context) {
        final p = BytePalette.of(context);
        final on = st.automix;
        final sec = st.automixSeconds;
        return [
          const _AutomixBanner(),
          GroupCard(
            children: [
              _switchRow(
                Icons.auto_awesome_rounded,
                'Automix',
                'Same loudness, no dead air, then a short pause before the next song',
                on,
                (v) => st.automix = v,
              ),
            ],
          ),
          _note(context, 'Byte listens to the next song before it plays to find its beat, loudness and where the music really starts and ends.'),
          const GroupLabel('STYLE'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: IgnorePointer(
              ignoring: !on,
              child: Opacity(
                opacity: on ? 1 : 0.45,
                child: SegmentedPill(labels: const ['Smart', 'Simple'], index: st.automixSmart ? 0 : 1, onChanged: (i) => st.automixSmart = i == 0),
              ),
            ),
          ),
          _note(
            context,
            st.automixSmart
                ? 'Smart: lines up the beats, nudges the tempo a little, swaps the bass so it never gets muddy, and skips long silent endings.'
                : 'Simple: a smooth fade at the right moment, matched loudness, no tempo change.',
          ),
          const SizedBox(height: 22),
          GroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        SizedBox(width: 26, child: Icon(Icons.swap_horiz_rounded, color: on ? p.label : p.secondary)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text('Transition length', style: BT.body.copyWith(color: on ? p.label : p.secondary)),
                        ),
                        Text('${sec.round()} s', style: BT.body.copyWith(color: p.secondary)),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(inactiveTrackColor: p.separator),
                      child: Slider(value: sec, min: 4, max: 16, divisions: 12, label: '${sec.round()} s', onChanged: on ? (v) => st.automixSeconds = v : null),
                    ),
                  ],
                ),
              ),
              _switchRow(
                Icons.shuffle_rounded,
                'Smart shuffle',
                'When shuffle is on, picks the next song that blends best',
                st.automixSmartShuffle,
                on && st.automixSmart ? (v) => st.automixSmartShuffle = v : null,
              ),
            ],
          ),
          _note(
            context,
            'Short songs, songs without a steady beat and podcasts get a plain fade. If a song can\'t be read in time, Byte falls back to a normal crossfade.',
          ),
          const SizedBox(height: 22),
          GroupCard(
            children: [
              GroupRow(
                icon: Icons.sd_storage_outlined,
                title: 'Songs ready for mixing',
                value: _bytes == null ? '…' : '${(_bytes! / 1048576).toStringAsFixed(1)} MB',
              ),
              GroupRow(
                icon: Icons.cleaning_services_outlined,
                title: 'Clear Automix cache',
                onTap: () async {
                  await Services.i.automix?.clearCache();
                  await _measure();
                  if (context.mounted) toast(context, 'Automix cache cleared');
                },
              ),
            ],
          ),
          const SizedBox(height: 40),
        ];
      },
    );
  }
}

// ── Personal DJ ──────────────────────────────────────────────────────────
class DjSettingsScreen extends StatelessWidget {
  const DjSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return _SettingsPage(
      title: 'Personal DJ',
      children: (context) => [
        const GroupLabel('DJ language'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SegmentedPill(
            labels: const ['Hinglish', 'English'],
            index: st.djLanguage == 'english' ? 1 : 0,
            onChanged: (i) => st.djLanguage = i == 1 ? 'english' : 'hinglish',
          ),
        ),
        const SizedBox(height: 22),
        GroupCard(
          children: [
            GroupRow(
              icon: Icons.badge_outlined,
              title: 'What the DJ calls you',
              value: st.djName,
              chevron: true,
              onTap: () async {
                final v = await promptText(context, title: 'What should the DJ call you?', initial: st.djName);
                if (v != null) st.djName = v;
              },
            ),
          ],
        ),
        _note(
          context,
          'The DJ mixes without talking over your songs. Everything it picks comes from what you play and like on this phone.',
        ),
        const SizedBox(height: 40),
      ],
    );
  }
}

class PlaybackScreen extends StatelessWidget {
  const PlaybackScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final st = s.settings;
    return _SettingsPage(
      title: 'Playback',
      extra: s.route,
      children: (context) {
        final p = BytePalette.of(context);
        final cf = st.crossfadeSeconds;
        final info = s.route.info;
        final usb = info.outputType == 'usb';
        final rate = '${((info.sampleRate ?? 48000) / 1000).toStringAsFixed(1)} kHz';
        return [
          GroupCard(
            children: [
              GroupRow(
                icon: Icons.high_quality_rounded,
                title: 'Output precision',
                subtitle:
                    '${onWeb ? 'Browser audio' : defaultTargetPlatform == TargetPlatform.iOS ? 'iPhone audio' : 'Android audio'} · ${info.label} · $rate · ${st.bitPerfect && usb ? 'bit-perfect' : '16-bit'}',
                value: '16-bit PCM',
              ),
              if (!onWeb && defaultTargetPlatform != TargetPlatform.iOS)
                _switchRow(
                  Icons.usb_rounded,
                  'Prefer USB DAC',
                  'Plays at your USB DAC\'s own best sample rate (Android 14+)',
                  st.preferUsbDac,
                  (v) => st.preferUsbDac = v,
                ),
              if (!onWeb && defaultTargetPlatform != TargetPlatform.iOS)
                _switchRow(
                  Icons.verified_rounded,
                  'Bit-perfect output',
                  'USB DAC only, Android 14+. Sends the audio untouched: phone volume, equalizer and effects stop working while it\'s on.',
                  st.bitPerfect,
                  (v) => st.bitPerfect = v,
                ),
            ],
          ),
          _note(
            context,
            onWeb
                ? 'In a browser the sound goes out through the browser at its own rate. USB DAC and bit-perfect options are in the phone app.'
                : defaultTargetPlatform == TargetPlatform.iOS
                ? 'On iPhone the system sends audio to a USB DAC at its own rate by itself. 32-bit float output isn\'t offered.'
                : 'Byte\'s player hands Android 16-bit audio unless Audio Lab → Hi-res output (32-bit float) is on. Lossless sources play losslessly either way.',
          ),
          const SizedBox(height: 22),
          GroupCard(
            children: [
              _switchRow(
                Icons.graphic_eq_rounded,
                'Loudness normalization',
                'Evens out songs that are mastered very loud',
                st.normalizeVolume,
                (v) => st.normalizeVolume = v,
              ),
              _switchRow(
                Icons.speaker_phone_rounded,
                'Disable on Phone Speaker',
                'No normalization when playing through the phone\'s own speaker',
                st.normalizeOffOnSpeaker,
                st.normalizeVolume ? (v) => st.normalizeOffOnSpeaker = v : null,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  children: [
                    Row(
                      children: [
                        SizedBox(width: 26, child: Icon(Icons.swap_horiz_rounded, color: p.label)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Crossfade', style: BT.body.copyWith(color: st.automix ? p.secondary : p.label)),
                              Text(
                                st.automix ? 'Automix is on: a short pause between songs' : 'Blends one song into the next',
                                style: BT.sub.copyWith(color: p.secondary),
                              ),
                            ],
                          ),
                        ),
                        Text(cf == 0 ? 'Off' : '${cf.round()} s', style: BT.body.copyWith(color: p.secondary)),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(inactiveTrackColor: p.separator),
                      child: Slider(
                        value: cf,
                        min: 0,
                        max: 12,
                        divisions: 12,
                        label: cf == 0 ? 'Off' : '${cf.round()} s',
                        onChanged: st.automix ? null : (v) => st.crossfadeSeconds = v,
                      ),
                    ),
                  ],
                ),
              ),
              GroupRow(
                icon: Icons.auto_awesome_rounded,
                title: 'Automix',
                badge: const Badge2('BETA'),
                subtitle: 'Matched loudness, a short pause between songs',
                value: !st.automix ? 'Off' : (st.automixSmart ? 'Smart' : 'Simple'),
                chevron: true,
                onTap: () => pushPage(context, const AutomixScreen()),
              ),
              GroupRow(
                icon: Icons.memory_rounded,
                title: 'Automix performance',
                subtitle: const [
                  'Battery saver: only songs on your phone are analysed',
                  'Balanced: the next song is prepared',
                  'Best: the next two songs are prepared',
                ][st.automixPerformance],
                value: const ['Battery saver', 'Balanced', 'Best'][st.automixPerformance],
                chevron: true,
                enabled: st.automix,
                onTap: !st.automix
                    ? null
                    : () async {
                        final v = await showByteSheet<int>(
                          context: context,
                          builder: (ctx) => SafeArea(
                            child: Wrap(
                              children: [
                                for (final (i, n) in const ['Battery saver', 'Balanced', 'Best'].indexed)
                                  ListTile(
                                    title: Text(n),
                                    trailing: i == st.automixPerformance ? const Icon(Icons.check_rounded) : null,
                                    onTap: () => Navigator.pop(ctx, i),
                                  ),
                              ],
                            ),
                          ),
                        );
                        if (v != null) st.automixPerformance = v;
                      },
              ),
              _switchRow(Icons.content_cut_rounded, 'Skip silence', 'Trims long quiet gaps', st.skipSilence, (v) async {
                st.skipSilence = v;
                await s.player.applySkipSilence();
              }),
              _switchRow(
                Icons.surround_sound_rounded,
                'Spatial audio',
                info.spatialAvailable ? 'Uses your phone\'s spatial audio for stereo music' : 'This phone or output can\'t do spatial audio',
                info.spatialEnabled,
                info.spatialAvailable ? (_) => s.route.openSoundSettings() : null,
              ),
              GroupRow(
                icon: Icons.equalizer_rounded,
                title: 'Equalizer',
                subtitle: s.lab.eqOn ? (s.lab.preset ?? 'Custom') : (st.eqEnabled ? '${st.eqPreset} (classic)' : 'Off'),
                chevron: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LabEqualizerScreen())),
              ),
            ],
          ),
          const SizedBox(height: 22),
          GroupCard(
            children: [
              _switchRow(
                Icons.all_inclusive_rounded,
                'Autoplay similar songs',
                'Keeps the music going when the queue ends',
                st.autoplay,
                (v) => st.autoplay = v,
              ),
              GroupRow(
                icon: Icons.speed_rounded,
                title: 'Playback speed',
                value: '${st.speed.toStringAsFixed(st.speed == st.speed.roundToDouble() ? 1 : 2)}×',
                chevron: true,
                onTap: () async {
                  final v = await showByteSheet<double>(
                    context: context,
                    builder: (ctx) => SafeArea(
                      child: Wrap(
                        children: [
                          for (final x in const [0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0])
                            ListTile(title: Text('$x×'), trailing: x == st.speed ? const Icon(Icons.check_rounded) : null, onTap: () => Navigator.pop(ctx, x)),
                        ],
                      ),
                    ),
                  );
                  if (v != null) {
                    st.speed = v;
                    await s.player.setSpeed(v);
                  }
                },
              ),
              if (lockScreenSupported)
                GroupRow(
                  icon: Icons.lock_rounded,
                  title: 'Lock screen player',
                  value: lockScreenRowValue(),
                  chevron: true,
                  onTap: () => pushPage(context, const LockScreenSettingsScreen()),
                ),
              GroupRow(
                icon: Icons.record_voice_over_rounded,
                title: 'Personal DJ',
                subtitle: 'Voice, language, your name',
                chevron: true,
                onTap: () => pushPage(context, const DjSettingsScreen()),
              ),
            ],
          ),
        ];
      },
    );
  }
}

class EqualizerScreen extends StatelessWidget {
  const EqualizerScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final eq = Services.i.player.equalizer;
    final st = Services.i.settings;
    return _SettingsPage(
      title: 'Equalizer',
      extra: eq,
      children: (context) {
        final p = BytePalette.of(context);
        if (eq == null || !(ByteEqualizer.supported || eq.ios)) {
          return [EmptyNote('The equalizer works in the Android and iPhone apps.', icon: Icons.equalizer_rounded)];
        }
        final bands = eq.bands;
        final gains = eq.gains;
        return [
          GroupCard(
            children: [
              _switchRow(
                Icons.equalizer_rounded,
                'Equalizer',
                eq.ios ? 'Byte\'s own 10-band equalizer' : 'Shapes the sound with your phone\'s built-in equalizer',
                st.eqEnabled,
                eq.setEnabled,
              ),
            ],
          ),
          const GroupLabel('Presets'),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final name in [...eqPresets.keys, 'Manual'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(name),
                      selected: st.eqPreset == name,
                      onSelected: st.eqEnabled && name != 'Manual' ? (_) => eq.setPreset(name) : null,
                    ),
                  ),
              ],
            ),
          ),
          const GroupLabel('Bands'),
          if (bands.isEmpty)
            _note(context, 'Play a song once and the bands of your phone\'s equalizer appear here.')
          else
            GroupCard(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
                  child: SizedBox(
                    height: 230,
                    child: Row(
                      children: [
                        for (var i = 0; i < bands.length; i++)
                          Expanded(
                            child: Column(
                              children: [
                                Text('${gains[i] >= 0 ? '+' : ''}${gains[i].toStringAsFixed(0)}', style: BT.caption.copyWith(color: p.secondary)),
                                Expanded(
                                  child: RotatedBox(
                                    quarterTurns: 3,
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(inactiveTrackColor: p.separator),
                                      child: Slider(
                                        value: gains[i].clamp(bands[i].minDb, bands[i].maxDb),
                                        min: bands[i].minDb,
                                        max: bands[i].maxDb,
                                        onChanged: st.eqEnabled ? (v) => eq.setBand(i, v) : null,
                                      ),
                                    ),
                                  ),
                                ),
                                Text(bands[i].label, style: BT.caption.copyWith(color: p.secondary)),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          _note(context, 'Moving a band switches to Manual. Changes apply right away.'),
        ];
      },
    );
  }
}

// ── Appearance ───────────────────────────────────────────────────────────
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return _SettingsPage(
      title: 'Appearance',
      children: (context) {
        final p = BytePalette.of(context);
        final idx = switch (st.themeMode) {
          ThemeMode.system => 0,
          ThemeMode.light => 1,
          ThemeMode.dark => 2,
        };
        final icon = AppIcons.byId(AppIcons.normalize(st.appIcon));
        Future<T?> pick<T>(String title, Map<T, String> options, T current) => showByteSheet<T>(
          context: context,
          isScrollControlled: true,
          builder: (ctx) => SafeArea(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Text(title, style: Theme.of(ctx).textTheme.titleMedium),
                  ),
                  for (final e in options.entries)
                    ListTile(title: Text(e.value), trailing: e.key == current ? const Icon(Icons.check_rounded) : null, onTap: () => Navigator.pop(ctx, e.key)),
                ],
              ),
            ),
          ),
        );
        return [
          GroupCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        SizedBox(width: 26, child: Icon(Icons.contrast_rounded, color: p.label)),
                        const SizedBox(width: 14),
                        Text('Theme', style: BT.body.copyWith(color: p.label)),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SegmentedPill(
                      labels: const ['System', 'Light', 'Dark'],
                      index: idx,
                      onChanged: (i) => st.themeMode = [ThemeMode.system, ThemeMode.light, ThemeMode.dark][i],
                    ),
                  ],
                ),
              ),
              GroupRow(
                icon: Icons.font_download_outlined,
                title: 'Font',
                value: ByteTheme.fonts[st.font] ?? 'Default',
                chevron: true,
                onTap: () async {
                  final v = await pick('Font', ByteTheme.fonts, st.font);
                  if (v != null) st.font = v;
                },
              ),
              _switchRow(
                Icons.motion_photos_on_outlined,
                'Animated cover art',
                'The player\'s cover drifts and zooms slowly while you listen',
                st.animatedCover,
                (v) => st.animatedCover = v,
              ),
              _switchRow(
                Icons.animation_rounded,
                'Reduce animation',
                'Fewer moving parts: bars fold instantly, the player\'s colours stop drifting',
                st.reduceMotion,
                (v) => st.reduceMotion = v,
              ),
              _switchRow(
                Icons.blur_off_rounded,
                'Reduce dynamic blur',
                'Swaps frosted glass for solid fills across the app',
                !st.glassEffects,
                (v) => st.glassEffects = !v,
              ),
              _switchRow(
                Icons.water_drop_outlined,
                'Liquid glass',
                GlassPerf.light.value
                    ? 'Frosted glass on bars, player buttons, menus, sheets and pop-ups. Lighter on this phone so it stays smooth'
                    : 'Frosted glass on bars, player buttons, menus, sheets and pop-ups',
                st.liquidGlass,
                (v) => st.liquidGlass = v,
              ),
              _switchRow(
                Icons.gradient_rounded,
                'Progressive Blur',
                'Top bars fade into the page instead of ending in a hard edge',
                st.progressiveBlur,
                (v) => st.progressiveBlur = v,
              ),
              _switchRow(
                Icons.fullscreen_rounded,
                'Full-screen cover art',
                'Runs the cover to the edges of the player instead of a square',
                st.fullScreenCover,
                (v) => st.fullScreenCover = v,
              ),
              _switchRow(
                Icons.bubble_chart_outlined,
                'Legacy mesh gradient',
                'Drifting colour blobs behind the player',
                st.meshGradient,
                (v) => st.meshGradient = v,
              ),
              _switchRow(
                Icons.palette_outlined,
                'Player gradients',
                'Colours from the album art behind the player',
                st.dynamicColor,
                (v) => st.dynamicColor = v,
              ),
              _switchRow(Icons.dark_mode_outlined, 'Pure black', 'Black backgrounds in dark mode, for OLED screens', st.pureBlack, (v) => st.pureBlack = v),
            ],
          ),
          _note(context, 'Animated cover art, cover videos and artist signatures aren\'t here: the sources Byte can use legally don\'t provide them.'),
          const SizedBox(height: 22),
          GroupCard(
            children: [
              _switchRow(Icons.lyrics_outlined, 'Synced lyrics', 'Lines light up in time with the song', st.syncedLyrics, (v) => st.syncedLyrics = v),
              _switchRow(Icons.blur_on_rounded, 'Blur unfocused lyrics', 'Softens the lines that aren\'t being sung (uses more battery)', st.blurLyrics, (v) => st.blurLyrics = v),
              GroupRow(
                key: const ValueKey('lyrics-script'),
                icon: Icons.abc_rounded,
                title: 'Lyrics letters',
                subtitle: 'For the lyrics screen and the line under the cover',
                value: const {'hindi': 'हिंदी (Hindi letters)', 'latin': 'English letters', 'original': 'Song\'s own'}[st.lyricsScript],
                chevron: true,
                onTap: () async {
                  final v = await pick('Show lyrics in', const {'latin': 'English letters: Tujhe dekha to (a–z)', 'hindi': 'हिंदी — Hindi letters, same words', 'original': 'The song\'s own script'}, st.lyricsScript);
                  if (v != null) {
                    st.lyricsScript = v;
                    st.lyricsLook = null; // 1.4.4: the letters picked here win over an earlier pick on the lyrics screen
                    LyricsPane.reload.value++;
                  }
                },
              ),
              GroupRow(
                key: const ValueKey('lyrics-offset'),
                icon: Icons.av_timer_rounded,
                title: 'Lyrics timing',
                subtitle: 'If every song\'s lyrics run early or late on this phone',
                value: st.lyricsOffsetMs == 0 ? 'In time' : '${st.lyricsOffsetMs > 0 ? '+' : ''}${(st.lyricsOffsetMs / 1000).toStringAsFixed(1)} s',
                chevron: true,
                onTap: () async {
                  final opts = {for (var ms = -1500; ms <= 1500; ms += 250) '$ms': ms == 0 ? 'In time' : '${ms > 0 ? '+' : ''}${(ms / 1000).toStringAsFixed(2)} s ${ms > 0 ? '(earlier)' : '(later)'}'};
                  final v = await pick('Lyrics timing', opts, '${st.lyricsOffsetMs}');
                  if (v != null) st.lyricsOffsetMs = int.parse(v);
                },
              ),
              GroupRow(
                icon: Icons.format_list_numbered_rounded,
                title: 'Lyrics sources',
                subtitle: Services.i.lyrics.activeOrder.map((id) => LyricsProvider.byId(id).name).join(' · '),
                chevron: true,
                onTap: () => pushPage(context, const LyricsSourcesScreen()),
              ),
              GroupRow(
                icon: Icons.translate_rounded,
                title: 'Translation language',
                value: LyricsTranslator.languages[st.translationLanguage] ?? st.translationLanguage,
                chevron: true,
                onTap: () async {
                  final v = await pick('Translate lyrics to', LyricsTranslator.languages, st.translationLanguage);
                  if (v != null) st.translationLanguage = v;
                },
              ),
              _switchRow(
                Icons.fullscreen_rounded,
                'Full-screen lyrics',
                'After a few seconds without a touch the controls fold away; tap to bring them back',
                st.lyricsAutoFullScreen,
                (v) => st.lyricsAutoFullScreen = v,
              ),
              _switchRow(
                Icons.format_color_fill_rounded,
                'Word-by-word fill',
                'Fills each word as it is sung',
                st.lyricsWordFill,
                (v) => st.lyricsWordFill = v,
              ),
              GroupRow(
                icon: Icons.format_size_rounded,
                title: 'Lyrics size',
                value: const ['Small', 'Normal', 'Large'][st.lyricsSize],
                onTap: () => st.lyricsSize = (st.lyricsSize + 1) % 3,
              ),
            ],
          ),
          const SizedBox(height: 22),
          GroupCard(
            children: [
              GroupRow(
                leading: ClipRRect(borderRadius: BorderRadius.circular(7), child: Image.asset(icon.preview, width: 30, height: 30)),
                title: 'App icon',
                value: icon.label,
                chevron: true,
                onTap: () => pushPage(context, const AppIconScreen()),
              ),
            ],
          ),
        ];
      },
    );
  }
}

/// Lyrics sources: order (drag) and on/off, plus the Musixmatch key.
class LyricsSourcesScreen extends StatefulWidget {
  const LyricsSourcesScreen({super.key});
  @override
  State<LyricsSourcesScreen> createState() => _LyricsSourcesScreenState();
}

class _LyricsSourcesScreenState extends State<LyricsSourcesScreen> {
  late final key = TextEditingController(text: Services.i.settings.musixmatchKey);

  @override
  void dispose() {
    key.dispose();
    super.dispose();
  }

  List<String> _order() {
    final st = Services.i.settings;
    final o = [...st.lyricsOrder];
    for (final p in LyricsProvider.all) {
      if (!o.contains(p.id)) o.add(p.id);
    }
    return o;
  }

  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) {
        final order = _order();
        final off = st.lyricsOff;
        return SubPage(capWidth: true, 
          title: 'Lyrics sources',
          showProfile: false,
          slivers: [
            const SliverToBoxAdapter(child: GroupLabel('Tried in this order')),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverReorderableList(
                itemCount: order.length,
                onReorderItem: (a, b) {
                  final o = [...order];
                  final x = o.removeAt(a);
                  o.insert(b, x);
                  st.lyricsOrder = o;
                },
                itemBuilder: (c, i) {
                  final pr = LyricsProvider.byId(order[i]);
                  final on = !off.contains(pr.id);
                  final needsKey = pr.id == 'musixmatch' && st.musixmatchKey.isEmpty;
                  return Material(
                    key: ValueKey(pr.id),
                    color: p.grouped,
                    child: ListTile(
                      leading: ReorderableDragStartListener(
                        index: i,
                        child: Icon(Icons.drag_handle_rounded, color: p.secondary),
                      ),
                      title: Text('${i + 1}. ${pr.name}', style: BT.body.copyWith(color: p.label)),
                      subtitle: Text(needsKey ? 'Add your API key below to turn it on' : pr.about, style: BT.sub.copyWith(color: p.secondary)),
                      trailing: ByteSwitch(
                        value: on && !needsKey,
                        onChanged: needsKey
                            ? null
                            : (v) {
                                final s = {...off};
                                v ? s.remove(pr.id) : s.add(pr.id);
                                st.lyricsOff = s;
                              },
                      ),
                    ),
                  );
                },
              ),
            ),
            SliverList.list(
              children: [
                const GroupLabel('Lyrics service API key'),
                GroupCard(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: TextField(
                        controller: key,
                        autocorrect: false,
                        obscureText: true,
                        decoration: const InputDecoration(hintText: 'Your own key from the lyrics service', border: InputBorder.none),
                        onSubmitted: (v) => _saveKey(v),
                      ),
                    ),
                    GroupRow(icon: Icons.save_outlined, title: 'Save key', onTap: () => _saveKey(key.text)),
                  ],
                ),
                _note(
                  context,
                  'Byte doesn\'t come with a key for this lyrics service. With your own key, its lyrics are used under your own account and its terms.',
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _saveKey(String v) {
    final st = Services.i.settings;
    st.musixmatchKey = v;
    final s = {...st.lyricsOff};
    v.trim().isEmpty ? s.add('musixmatch') : s.remove('musixmatch');
    st.lyricsOff = s;
    FocusScope.of(context).unfocus();
    toast(context, v.trim().isEmpty ? 'Key removed' : 'Key saved');
  }
}

// ── Performance ──────────────────────────────────────────────────────────
class PerformanceScreen extends StatelessWidget {
  const PerformanceScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return _SettingsPage(
      title: 'Performance',
      children: (context) => [
        GroupCard(
          children: [
            _switchRow(
              Icons.bolt_rounded,
              'High performance mode',
              'Uses full animations and blur, and asks for the screen\'s highest refresh rate',
              st.highPerformance,
              (v) async {
                if (v) {
                  final ok = await confirm(
                    context,
                    'Use more battery?',
                    'High performance mode keeps every effect on and runs the screen at its fastest. Your battery runs down a little quicker.',
                    action: 'Turn on',
                    destructive: false,
                  );
                  if (!ok) return;
                  st.glassEffects = true;
                  st.reduceMotion = false;
                }
                st.highPerformance = v;
                await applyRefreshRate(v);
              },
            ),
            // 2.0: glass is drawn without a live blur unless this is on
            _switchRow(
              Icons.blur_on_rounded,
              'Real glass blur',
              'Bars blur what scrolls under them. Looks deeper but costs battery and can stutter on some phones. Off: the same frosted look, smoother',
              st.realBlur,
              (v) => st.realBlur = v,
            ),
            _switchRow(
              Icons.skip_next_rounded,
              'Load the next song early',
              'The next song is ready the moment this one ends',
              st.preloadNext,
              (v) => st.preloadNext = v,
            ),
          ],
        ),
      ],
    );
  }
}

const _display = MethodChannel('byte/display');

/// Asks Android for the highest refresh rate (or back to the default).
Future<void> applyRefreshRate(bool high) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _display.invokeMethod('setHighRefresh', high);
  } catch (_) {}
}

// ── Local music ──────────────────────────────────────────────────────────
class LocalMusicSettingsScreen extends StatelessWidget {
  const LocalMusicSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final st = s.settings;
    return _SettingsPage(
      title: 'Local Music',
      extra: s.library,
      children: (context) => [
        GroupCard(
          children: [
            GroupRow(
              icon: Icons.folder_outlined,
              title: 'Local music folder',
              subtitle: 'All audio folders · ${s.library.localTracks.length} songs found',
              chevron: true,
              onTap: () => pushPage(context, const LocalMusicScreen()),
            ),
            if (!kIsWeb)
              GroupRow(
                icon: Icons.create_new_folder_outlined,
                title: 'Add a folder',
                subtitle: 'Scan one more folder for songs',
                onTap: () async {
                  try {
                    await s.local.addFolder();
                  } catch (_) {}
                },
              ),
            _switchRow(
              Icons.filter_alt_outlined,
              'Filter non-music audio',
              'Hides clips under 30 seconds, WAV files, voice notes and recordings',
              st.filterShortAudio,
              (v) => st.filterShortAudio = v,
            ),
          ],
        ),
      ],
    );
  }
}

// ── Storage ──────────────────────────────────────────────────────────────
class StorageScreen extends StatefulWidget {
  const StorageScreen({super.key});
  @override
  State<StorageScreen> createState() => _StorageScreenState();
}

class _StorageScreenState extends State<StorageScreen> {
  int? cacheBytes;
  int? songBytes;
  String? songDir;
  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    if (kIsWeb) return;
    try {
      final d = await getTemporaryDirectory();
      var n = 0;
      await for (final f in d.list(recursive: true, followLinks: false)) {
        if (f is File) n += await f.length();
      }
      final am = Services.i.automix;
      final sb = am == null ? 0 : await am.cacheBytes();
      final sd = am == null ? null : (await am.cacheDir()).path;
      if (mounted) {
        setState(() {
          cacheBytes = n;
          songBytes = sb;
          songDir = sd;
        });
      }
    } catch (_) {}
  }

  String _mb(int b) => '${(b / 1048576).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    return _SettingsPage(
      title: 'Storage',
      extra: s.library,
      children: (context) => [
        GroupCard(
          children: [
            GroupRow(icon: Icons.download_done_rounded, title: 'Downloads', value: _mb(s.downloads.totalBytes)),
            GroupRow(icon: Icons.image_outlined, title: 'Temporary files', value: cacheBytes == null ? '…' : _mb(cacheBytes!)),
          ],
        ),
        const GroupLabel('Song cache'),
        GroupCard(
          children: [
            GroupRow(
              key: const ValueKey('song-cache-folder'),
              icon: Icons.folder_outlined,
              title: 'Cached songs folder',
              subtitle: songDir ?? 'Songs saved for smooth blends',
              value: songBytes == null ? '…' : _mb(songBytes!),
            ),
            GroupRow(
              key: const ValueKey('song-cache-limit'),
              icon: Icons.data_usage_rounded,
              title: 'Song cache limit',
              value: s.settings.songCacheMb >= 1000 ? '${s.settings.songCacheMb ~/ 1000} GB' : '${s.settings.songCacheMb} MB',
              chevron: true,
              onTap: () async {
                final v = await showByteSheet<int>(
                  context: context,
                  builder: (ctx) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final mb in const [100, 200, 500, 1000, 2000])
                          ListTile(
                            title: Text(mb >= 1000 ? '${mb ~/ 1000} GB' : '$mb MB'),
                            trailing: mb == s.settings.songCacheMb ? const Icon(Icons.check_rounded) : null,
                            onTap: () => Navigator.pop(ctx, mb),
                          ),
                      ],
                    ),
                  ),
                );
                if (v == null) return;
                s.settings.songCacheMb = v;
                s.automix?.maxBytes = v * 1048576;
                s.automix?.maxFiles = (v / 8).ceil();
                await s.automix?.trim(const {});
                await _measure();
              },
            ),
            GroupRow(
              key: const ValueKey('clear-song-cache'),
              icon: Icons.music_off_outlined,
              title: 'Clear song cache',
              onTap: () async {
                final freed = await s.automix?.clearCache() ?? 0;
                await _measure();
                if (context.mounted) toast(context, 'Freed ${_mb(freed)}');
              },
            ),
            GroupRow(
              key: const ValueKey('clear-image-cache'),
              icon: Icons.hide_image_outlined,
              title: 'Clear image cache',
              onTap: () {
                PaintingBinding.instance.imageCache.clear();
                PaintingBinding.instance.imageCache.clearLiveImages();
                toast(context, 'Image cache cleared');
              },
            ),
            GroupRow(
              icon: Icons.cleaning_services_outlined,
              title: 'Clear cache',
              subtitle: 'Pictures and lyrics saved for speed',
              onTap: () async {
                PaintingBinding.instance.imageCache.clear();
                PaintingBinding.instance.imageCache.clearLiveImages();
                try {
                  await Hive.box('lyrics').clear();
                } catch (_) {}
                try {
                  final d = await getTemporaryDirectory();
                  for (final f in d.listSync()) {
                    try {
                      f.deleteSync(recursive: true);
                    } catch (_) {}
                  }
                } catch (_) {}
                await _measure();
                if (context.mounted) toast(context, 'Cache cleared');
              },
            ),
          ],
        ),
      ],
    );
  }
}

// ── Your data ────────────────────────────────────────────────────────────
/// Top genres, worked out from the person's top artists' Last.fm tags.
class GenresScreen extends StatefulWidget {
  const GenresScreen({super.key});
  @override
  State<GenresScreen> createState() => _GenresScreenState();
}

class _GenresScreenState extends State<GenresScreen> {
  List<(String, double)>? genres;
  String? problem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = Services.i;
    final key = s.scrobbler.lfmKey;
    if (key.isEmpty) {
      setState(() => problem = 'Connect the classic listening log in Settings → Account & integrations → Scrobbling (it uses your own free key), then come back.');
      return;
    }
    final y = s.stats.year(DateTime.now().year);
    final artists = [for (final a in y.artists.take(15)) (a.name, a.minutes)];
    if (artists.isEmpty) {
      setState(() => problem = 'Play some music first: genres come from the artists you listen to.');
      return;
    }
    try {
      final g = await GenreGuesser(s.net).topGenres(artists, key);
      if (mounted) setState(() => genres = g);
    } catch (_) {
      if (mounted) setState(() => problem = 'Couldn\'t reach the listening log right now. Try again in a bit.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final g = genres;
    return _SettingsPage(
      title: 'Genres',
      children: (context) => [
        if (problem != null)
          Padding(padding: const EdgeInsets.all(20), child: Text(problem!, style: BT.sub.copyWith(color: p.secondary, height: 1.35)))
        else if (g == null)
          const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
        else if (g.isEmpty)
          Padding(padding: const EdgeInsets.all(20), child: Text('There are no genre tags for your artists yet.', style: BT.sub.copyWith(color: p.secondary)))
        else
          GroupCard(
            children: [
              for (final (name, share) in g)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(name, style: BT.body.copyWith(color: p.label, fontWeight: FontWeight.w600))),
                          Text('${(share * 100).round()}%', style: BT.sub.copyWith(color: p.secondary)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(value: share.clamp(0.02, 1.0), minHeight: 6, color: p.accent, backgroundColor: p.secondary.withValues(alpha: 0.15)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
          child: Text('From the tags listeners on the classic listening log give your top artists this year. Only artist names are sent.', style: BT.caption.copyWith(color: p.secondary)),
        ),
      ],
    );
  }
}

class YourDataScreen extends StatelessWidget {
  const YourDataScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final st = s.settings;
    return _SettingsPage(
      title: 'Your data',
      children: (context) => [
        GroupCard(
          children: [
            KeyedSubtree(
              key: const ValueKey('share-usage'),
              child: _switchRow(
                Icons.bar_chart_rounded,
                'Share usage with Byte\'s owner',
                'Phone model, Byte version, when you use it and the songs you play. Never passwords, messages, contacts or location.',
                st.shareUsage,
                (v) {
                  st.shareUsage = v;
                  st.changed();
                },
              ),
            ),
            GroupRow(
              icon: Icons.insights_rounded,
              title: 'Replay',
              subtitle: 'Your top songs, artists and albums',
              chevron: true,
              onTap: () => pushPage(context, const ReplayScreen()),
            ),
            GroupRow(
              icon: Icons.category_rounded,
              title: 'Work out genres',
              subtitle: s.scrobbler.lfmKey.isEmpty ? 'Add your Last.fm key under Scrobbling first' : 'Your top genres from the artists you play',
              chevron: true,
              onTap: () => pushPage(context, const GenresScreen()),
            ),
            GroupRow(
              icon: Icons.ios_share_rounded,
              title: 'Export data',
              subtitle: 'Settings, library and listening history, as one JSON file',
              onTap: () async {
                try {
                  final f = await exportBackup();
                  await SharePlus.instance.share(
                    ShareParams(
                      files: [XFile(f.path, mimeType: 'application/json')],
                      subject: 'Byte backup',
                    ),
                  );
                } catch (_) {
                  if (context.mounted) toast(context, 'Couldn\'t make the backup file');
                }
              },
            ),
            GroupRow(
              icon: Icons.file_download_outlined,
              title: 'Import data',
              subtitle: 'Replaces the settings and history on this phone',
              onTap: () async {
                final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['json']);
                if (r.isEmpty) return;
                final bytes = await r.first.readAsBytes();
                if (!context.mounted) return;
                final ok = await confirm(context, 'Import this backup?', 'Your current settings, playlists, likes and history are replaced.', action: 'Import');
                if (!ok) return;
                try {
                  final n = await importBackup(utf8.decode(bytes));
                  if (context.mounted) toast(context, 'Imported $n items');
                } catch (_) {
                  if (context.mounted) toast(context, 'That file isn\'t a Byte backup');
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 22),
        GroupCard(
          children: [
            _switchRow(Icons.history_rounded, 'Save listening history', 'Used for Recents and History', st.saveHistory, (v) => st.saveHistory = v),
            GroupRow(
              icon: Icons.delete_sweep_outlined,
              title: 'Clear search history',
              onTap: () async {
                await s.library.clearSearches();
                if (context.mounted) toast(context, 'Search history cleared');
              },
            ),
            GroupRow(
              icon: Icons.restart_alt_rounded,
              title: 'Reset listening stats',
              titleColor: const Color(0xFFFF3B30),
              onTap: () async {
                final ok = await confirm(context, 'Reset your stats?', 'Minutes, top songs and Replay start again from zero.', action: 'Reset');
                if (ok) await s.stats.reset();
              },
            ),
          ],
        ),
        _note(context, 'Everything Byte knows about your listening stays on this phone.'),
      ],
    );
  }
}

// ── Miscellaneous ────────────────────────────────────────────────────────
class MiscScreen extends StatelessWidget {
  const MiscScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return _SettingsPage(
      title: 'Miscellaneous',
      children: (context) => [
        GroupCard(
          children: [
            _switchRow(
              Icons.swipe_rounded,
              'Play next on swipe',
              'Swiping a song in a list plays it next. When off, it goes to the end of the queue',
              st.playNextOnSwipe,
              (v) => st.playNextOnSwipe = v,
            ),
            _switchRow(
              Icons.repeat_one_rounded,
              'Don\'t repeat songs in this session',
              'Autoplay won\'t suggest a song already played or suggested',
              st.noRepeatInSession,
              (v) => st.noRepeatInSession = v,
            ),
            _switchRow(
              Icons.close_rounded,
              'Stop music on close from recents',
              'Stops playback when Byte is swiped away from recent apps',
              st.stopOnClose,
              (v) => st.stopOnClose = v,
            ),
            _switchRow(Icons.volume_off_outlined, 'Hide volume bar', 'Hides the volume slider in the player', st.hideVolumeBar, (v) => st.hideVolumeBar = v),
            _switchRow(
              Icons.people_outline_rounded,
              'Show Listen together button',
              'A button on the player to start or join a party',
              st.showListenTogetherButton,
              (v) => st.showListenTogetherButton = v,
            ),
            _switchRow(
              Icons.fullscreen_exit_rounded,
              'Hide status bar in player',
              'More room for the cover and lyrics',
              st.hideStatusBarInPlayer,
              (v) => st.hideStatusBarInPlayer = v,
            ),
            _switchRow(
              Icons.history_toggle_off_rounded,
              'Show queue history',
              'Shows up to 25 played songs above Now playing in the queue',
              st.showQueueHistory,
              (v) => st.showQueueHistory = v,
            ),
            _switchRow(
              Icons.info_outline_rounded,
              'Hide song status',
              'Hides the "Playing from" line in the player',
              st.hideSongStatus,
              (v) => st.hideSongStatus = v,
            ),
          ],
        ),
      ],
    );
  }
}

// ── Language ─────────────────────────────────────────────────────────────
const _langs = {
  'en': 'English',
  'hi': 'हिन्दी (Hindi)',
  'bn': 'বাংলা (Bengali)',
  'ta': 'தமிழ் (Tamil)',
  'te': 'తెలుగు (Telugu)',
  'mr': 'मराठी (Marathi)',
  'pa': 'ਪੰਜਾਬੀ (Punjabi)',
};
const _regions = {
  'IN': 'India',
  'BD': 'Bangladesh',
  'US': 'United States',
  'GB': 'United Kingdom',
  'AE': 'United Arab Emirates',
  'CA': 'Canada',
  'AU': 'Australia',
  'NP': 'Nepal',
};

class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final st = s.settings;
    Future<void> pick(String title, Map<String, String> opts, String cur, ValueChanged<String> set) async {
      final v = await showByteSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(title, style: BT.title3),
              ),
              for (final e in opts.entries)
                ListTile(title: Text(e.value), trailing: e.key == cur ? const Icon(Icons.check_rounded) : null, onTap: () => Navigator.pop(ctx, e.key)),
            ],
          ),
        ),
      );
      if (v != null && v != cur) {
        set(v);
        s.yt
          ..hl = st.language
          ..gl = st.contentRegion;
        s.feedVersion.value++;
      }
    }

    return _SettingsPage(
      title: 'Language',
      children: (context) => [
        GroupCard(
          children: [
            const GroupRow(icon: Icons.language_rounded, title: 'App language', value: 'English'),
            GroupRow(
              icon: Icons.translate_rounded,
              title: 'Content language',
              subtitle: 'Titles and sections from the online catalogue',
              value: _langs[st.language] ?? st.language,
              chevron: true,
              onTap: () => pick('Content language', _langs, st.language, (v) => st.language = v),
            ),
            GroupRow(
              icon: Icons.public_rounded,
              title: 'Content country',
              subtitle: 'Charts, new releases and moods',
              value: _regions[st.contentRegion] ?? st.contentRegion,
              chevron: true,
              onTap: () => pick('Content country', _regions, st.contentRegion, (v) => st.contentRegion = v),
            ),
          ],
        ),
      ],
    );
  }
}

/// Top of the Automix page: two songs (two strokes) flowing into each other
/// on the brand gradient.
class _AutomixBanner extends StatelessWidget {
  const _AutomixBanner();
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 104),
      child: DjSurface(
        radius: 24,
        waves: false,
        child: Stack(
          children: [
            Positioned(right: 0, top: 0, bottom: 0, width: 150, child: CustomPaint(painter: _BlendPainter())),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 124, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Automix',
                    style: TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900, letterSpacing: -0.6, height: 1),
                  ),
                  SizedBox(height: 6),
                  Text('Every song at the same loudness, with a short pause in between.', maxLines: 3, style: TextStyle(color: Colors.white, fontSize: 14, height: 1.25)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _BlendPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    // two thick round strokes crossing like a crossfade
    final a = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s.height * 0.12
      ..color = Colors.white.withValues(alpha: 0.9);
    final b = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s.height * 0.12
      ..color = Colors.white.withValues(alpha: 0.38);
    final h = s.height;
    final p1 = Path()
      ..moveTo(s.width * 0.12, h * 0.30)
      ..cubicTo(s.width * 0.45, h * 0.30, s.width * 0.55, h * 0.70, s.width * 0.86, h * 0.70);
    final p2 = Path()
      ..moveTo(s.width * 0.12, h * 0.70)
      ..cubicTo(s.width * 0.45, h * 0.70, s.width * 0.55, h * 0.30, s.width * 0.86, h * 0.30);
    canvas.drawPath(p2, b);
    canvas.drawPath(p1, a);
  }

  @override
  bool shouldRepaint(covariant _BlendPainter old) => false;
}

// ── Advanced ─────────────────────────────────────────────────────────────
class AdvancedScreen extends StatelessWidget {
  const AdvancedScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final st = Services.i.settings;
    return _SettingsPage(
      title: 'Advanced & experimental options',
      children: (context) {
        return [
          GroupCard(
            children: [
              _switchRow(
                Icons.bar_chart_rounded,
                'Show stats for nerds',
                'Codec, bitrate and stream details on the player',
                st.statsForNerds,
                (v) => st.statsForNerds = v,
              ),
              _switchRow(
                Icons.verified_outlined,
                'Check streams before playing',
                'Makes sure the server sends the whole song (same as turning Direct stream off)',
                st.verifyStreams,
                (v) => st.verifyStreams = v,
              ),
            ],
          ),
        ];
      },
    );
  }
}

// ── About ────────────────────────────────────────────────────────────────
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return SubPage(
      capWidth: true,
      solidBar: true,
      title: 'About ${Brand.appName}',
      showProfile: false,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 26),
            child: Column(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(25),
                    boxShadow: [BoxShadow(color: ByteColors.red.withValues(alpha: 0.22), blurRadius: 28, spreadRadius: -6, offset: const Offset(0, 10))],
                  ),
                  child: const ByteLogo(size: 112),
                ),
                const SizedBox(height: 18),
                Text(Brand.appName, style: BT.largeTitle.copyWith(color: p.label)),
                const SizedBox(height: 4),
                Text(Brand.tagline, style: BT.body.copyWith(color: p.secondary)),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                  decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
                  child: Text(
                    'Version ${Brand.version}',
                    style: BT.caption.copyWith(color: p.accent, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 1.4.3: who made Byte (his signature card, picked by him), with his own links
        const SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 18), child: DeveloperConceptC(key: ValueKey('developer-card'))),
        ),
        SliverToBoxAdapter(
          child: GroupCard(
            children: [
              const GroupRow(icon: Icons.music_note_rounded, title: Brand.appName, value: 'Version ${Brand.version}'),
              const GroupRow(icon: Icons.copyright_rounded, title: Brand.copyright),
              GroupRow(
                icon: Icons.description_outlined,
                title: 'Licenses',
                chevron: true,
                onTap: () =>
                    showLicensePage(context: context, applicationName: Brand.appName, applicationVersion: Brand.version, applicationLegalese: Brand.copyright),
              ),
              // 1.4.5: what went wrong when Byte closed by itself, to share
              GroupRow(
                key: const ValueKey('report-problem'),
                icon: Icons.bug_report_outlined,
                title: 'Report a problem',
                subtitle: 'If Byte closed by itself, share what went wrong',
                chevron: true,
                onTap: () => showReportProblemSheet(context),
              ),
            ],
          ),
        ),
        SliverToBoxAdapter(
          child: _note(context, '${Brand.appName} plays music from an online catalogue. Your account, library and listening stats stay on this phone.'),
        ),
        // 1.4.3: the last paragraph scrolls clear of the floating nav
        SliverToBoxAdapter(
          child: SizedBox(height: 56, child: ColoredBox(color: p.bg)),
        ),
      ],
    );
  }
}

/// Exported for tests: every settings page.
List<Widget> allSettingsPages() => [
  const SourcesScreen(),
  const ScrobblingScreen(),
  const OwnServerScreen(),
  const SpotifyAccountScreen(),
  const QualityScreen(),
  const QualityScreen(mobile: true),
  const QualityScreen(download: true),
  const DownloadSettingsScreen(),
  const PlaybackScreen(),
  const AutomixScreen(),
  const DjSettingsScreen(),
  const EqualizerScreen(),
  const AudioLabScreen(),
  const LabEqualizerScreen(),
  const LabEffectsScreen(),
  const LabQualityScreen(),
  const LabTransitionScreen(),
  const LabAudioPassScreen(),
  const AppearanceScreen(),
  const PerformanceScreen(),
  const LocalMusicSettingsScreen(),
  const StorageScreen(),
  const YourDataScreen(),
  const MiscScreen(),
  const LanguageScreen(),
  const AdvancedScreen(),
  const AboutScreen(),
];
