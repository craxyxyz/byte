import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/crash_log.dart';
import '../core/models.dart';
import '../core/streams.dart';
import '../data/cache_ops.dart';
import '../player/byte_handler.dart' show SleepMode;
import '../services.dart';
import 'glass.dart';
import 'now_playing.dart' show NowPlayingScreen, openItemFromRoot, showSleepSheet, showSpeedSheet;
import 'player_parts.dart' show openAudioLabFromPlayer, openDjFromPlayer, openListenTogether, showSongInfo;
import 'widgets.dart';

// Byte 2.0 © 2026 Apurba Laskar.
//
// The player's song menu (⋯): one dark glass sheet, entries in groups with
// thin dividers, line icons, subtitles where a name helps (album, artists,
// the quality playing). Everything Byte had stays; Share, Upgrade quality,
// Start radio, Play next, Add to queue, Remove from cache,
// Open album / artist, Lyrics offset and Copy log join it.

/// The text "Copy log" puts on the clipboard: the app's own error log under a
/// short header (version, device, the song and stream that were playing).
String diagnosticLog(Services s) {
  final it = s.player.current.value;
  final st = s.player.currentStream.value;
  final head = StringBuffer()
    ..write('Byte 2.0.0')
    ..write(' · ${kIsWeb ? 'web' : defaultTargetPlatform.name}');
  if (it != null) head.write('\nPlaying: ${it.title} (${it.id})${st == null ? '' : ' · ${streamLabel(st)} · ${st.client}'}');
  final err = s.player.error.value;
  if (err != null) head.write('\nPlayer error: $err');
  final log = CrashLog.i?.read() ?? '';
  return '$head\n${log.isEmpty ? 'No errors recorded.' : log}';
}

/// Per-song lyrics offset, in ms (+ = lyrics earlier). Saved per song.
class LyricsOffsetSheet extends StatefulWidget {
  final Item song;
  const LyricsOffsetSheet({super.key, required this.song});
  @override
  State<LyricsOffsetSheet> createState() => _LyricsOffsetSheetState();
}

class _LyricsOffsetSheetState extends State<LyricsOffsetSheet> {
  static const range = 5000;
  int get ms => Services.i.settings.lyricsOffsetFor(widget.song.id);
  void _set(int v) => setState(() => Services.i.settings.setLyricsOffsetFor(widget.song.id, v.clamp(-range, range)));

  static String describe(int ms) => ms == 0
      ? 'In time'
      : '${ms > 0 ? '+' : '−'}${ms.abs()} ms · lyrics ${ms > 0 ? 'earlier' : 'later'}';

  @override
  Widget build(BuildContext context) {
    final v = ms;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Lyrics offset', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
            const Text('Only for this song. Moves the lyrics against the music.', style: TextStyle(color: Colors.white60)),
            const SizedBox(height: 14),
            Center(child: Text(describe(v), key: const ValueKey('lyrics-offset-value'), style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w700))),
            Row(
              children: [
                IconButton(key: const ValueKey('offset-minus'), tooltip: 'Lyrics later', color: Colors.white, onPressed: () => _set(ms - 50), icon: const Icon(Icons.remove_circle_outline_rounded)),
                Expanded(
                  child: Slider(
                    key: const ValueKey('offset-slider'),
                    value: v.clamp(-range, range).toDouble(),
                    min: -range.toDouble(),
                    max: range.toDouble(),
                    divisions: range * 2 ~/ 50,
                    onChanged: (x) => _set(x.round()),
                  ),
                ),
                IconButton(key: const ValueKey('offset-plus'), tooltip: 'Lyrics earlier', color: Colors.white, onPressed: () => _set(ms + 50), icon: const Icon(Icons.add_circle_outline_rounded)),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(key: const ValueKey('offset-reset'), onPressed: v == 0 ? null : () => _set(0), child: const Text('Reset')),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showLyricsOffsetSheet(BuildContext context, Item song) => showByteSheet<void>(
  context: context,
  isScrollControlled: true,
  backgroundColor: const Color(0xFF1C1C1E),
  builder: (_) => LyricsOffsetSheet(song: song),
);

/// After the player closes, open [target] in the current tab.
void _openFromPlayer(BuildContext context, Item target) {
  if (!context.mounted) return;
  if (context.findAncestorWidgetOfExactType<NowPlayingScreen>() != null) Navigator.pop(context);
  openItemFromRoot(context, target);
}

Future<void> _pickArtist(BuildContext context, Item it) async {
  final artists = it.artists.where((a) => a.id != null).toList();
  if (artists.isEmpty) {
    toast(context, 'No artist page for this song');
    return;
  }
  if (artists.length == 1) {
    _openFromPlayer(context, Item(kind: ItemKind.artist, id: artists.first.id!, title: artists.first.name));
    return;
  }
  final picked = await showByteSheet<ArtistRef>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1C1C1E),
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 6),
            child: Text('Open artist', style: TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
          ),
          for (final a in artists)
            ListTile(
              key: ValueKey('artist-${a.id}'),
              leading: const Icon(Icons.person_outline_rounded, color: Colors.white),
              title: Text(a.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              onTap: () => Navigator.pop(c, a),
            ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
  if (picked != null && context.mounted) _openFromPlayer(context, Item(kind: ItemKind.artist, id: picked.id!, title: picked.name));
}

Future<void> _upgradeQuality(BuildContext context) async {
  toast(context, 'Finding the best quality…');
  final r = await Services.i.player.upgradeCurrentQuality();
  if (context.mounted) toast(context, r.message);
}

Future<void> _startRadio(BuildContext context, Item it) async {
  final p = Services.i.player;
  toast(context, 'Starting radio…');
  await p.startRadio(it);
  if (!context.mounted) return;
  toast(context, p.upcomingCount > 0 ? 'Radio on · ${p.upcomingCount} songs up next' : 'Radio started');
}

Future<void> _removeFromCache(BuildContext context, Item it) async {
  final r = await removeSongCache(Services.i, it);
  if (context.mounted) toast(context, r.message);
}

Future<void> _copyLog(BuildContext context) async {
  await Clipboard.setData(ClipboardData(text: diagnosticLog(Services.i)));
  if (context.mounted) toast(context, 'Log copied');
}

/// The player's ⋯ menu.
Future<void> showSongMenu(BuildContext context, Item it) {
  final s = Services.i;
  return showByteSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF1C1C1E), // white text: dark glass from wherever it is opened
    builder: (c) {
      Widget row(IconData i, String t, VoidCallback onTap, {String? sub, Key? key}) => ListTile(
        key: key,
        leading: Icon(i, color: Colors.white),
        title: Text(t, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        subtitle: sub == null || sub.isEmpty ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60)),
        onTap: () {
          Navigator.pop(c);
          onTap();
        },
      );
      const divider = Divider(color: Colors.white12, height: 1, indent: 16, endIndent: 16);
      final (sleepMode, _) = s.player.sleep.value;
      final catalogue = !it.isLocal;
      final stream = s.player.currentStream.value;
      final albumName = it.album;
      final artistsWithPage = it.artists.where((a) => a.id != null).toList();
      final liked = s.library.isLiked(it.id);
      final downloaded = s.library.isDownloaded(it.id);

      final groups = <List<Widget>>[
        // Share: the big one at the top
        if (catalogue)
          [
            InkWell(
              key: const ValueKey('menu-share'),
              onTap: () {
                Navigator.pop(c);
                SharePlus.instance.share(ShareParams(text: '${it.title} — ${it.artistLine}\n${shareUrlFor(it)}'));
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.ios_share_rounded, color: Colors.white, size: 30),
                    SizedBox(height: 6),
                    Text('Share', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
            ),
          ],
        if (catalogue)
          [
            row(Icons.high_quality_outlined, 'Upgrade quality', () => unawaited(_upgradeQuality(context)),
                sub: stream == null ? 'Play the best audio quality' : 'Now ${streamLabel(stream)}', key: const ValueKey('menu-upgrade')),
          ],
        [
          row(
            liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
            liked ? 'Remove from Liked' : 'Like',
            () => s.library.setLiked(it, !liked),
          ),
          if (catalogue) row(Icons.sensors_rounded, 'Start radio', () => unawaited(_startRadio(context, it)), sub: 'Songs like this one', key: const ValueKey('menu-radio')),
          if (!s.dj.active)
            row(Icons.graphic_eq_rounded, 'Start DJ', () {
              s.dj.start();
              toast(context, 'DJ is starting…');
            }, sub: 'Non-stop mix from what you play')
          else
            row(Icons.graphic_eq_rounded, 'DJ', () => openDjFromPlayer(context), sub: 'Talk to your DJ, switch it up, stop'),
          row(Icons.playlist_play_rounded, 'Play next', () {
            s.player.playNextItem(it);
            toast(context, 'Playing next');
          }, key: const ValueKey('menu-play-next')),
          row(Icons.queue_music_rounded, 'Add to queue', () {
            s.player.addToQueue([it]);
            toast(context, 'Added to queue');
          }, key: const ValueKey('menu-add-queue')),
          row(Icons.playlist_add_rounded, 'Add to playlist', () => addToPlaylistSheet(context, [it])),
          if (catalogue && s.downloads.supported && !downloaded)
            row(Icons.download_rounded, 'Download', () {
              s.downloads.enqueue([it]);
              toast(context, 'Downloading…');
            }, key: const ValueKey('menu-download')),
          if (catalogue && s.downloads.supported && downloaded)
            row(Icons.download_done_rounded, 'Downloaded', () => toast(context, 'Already saved on this phone'), sub: 'Saved on this phone', key: const ValueKey('menu-download')),
          if (catalogue && !kIsWeb)
            row(Icons.delete_outline_rounded, 'Remove from cache', () => unawaited(_removeFromCache(context, it)),
                sub: 'Delete the saved audio of this song', key: const ValueKey('menu-remove-cache')),
        ],
        [
          if (catalogue && it.albumId != null && it.kind != ItemKind.episode)
            row(Icons.album_outlined, 'Open album', () => _openFromPlayer(context, Item(kind: ItemKind.album, id: it.albumId!, title: albumName ?? '')),
                sub: albumName, key: const ValueKey('menu-album')),
          if (catalogue && artistsWithPage.isNotEmpty)
            row(Icons.person_outline_rounded, 'Open artist', () => unawaited(_pickArtist(context, it)), sub: it.artistLine, key: const ValueKey('menu-artist')),
          row(Icons.info_outline_rounded, 'Song info', () => showSongInfo(context, it), sub: 'Release year, your plays and listening time'),
        ],
        [
          row(
            sleepMode == SleepMode.off ? Icons.bedtime_outlined : Icons.bedtime_rounded,
            'Sleep timer',
            () => showSleepSheet(context),
            sub: sleepMode == SleepMode.off ? null : 'On',
          ),
          row(Icons.speed_rounded, 'Playback speed', () => showSpeedSheet(context), sub: '${s.settings.speed}×'),
          row(Icons.equalizer_rounded, 'Audio Lab', () => openAudioLabFromPlayer(context), sub: 'Equalizer, headphones, effects'),
          row(Icons.lyrics_outlined, 'Lyrics offset', () => unawaited(showLyricsOffsetSheet(context, it)),
              sub: () {
                final v = s.settings.lyricsOffsetFor(it.id);
                return v == 0 ? 'Fix lyrics that run early or late' : _LyricsOffsetSheetState.describe(v);
              }(),
              key: const ValueKey('menu-lyrics-offset')),
          row(
            s.party.active ? Icons.people_rounded : Icons.people_outline_rounded,
            'Listen together',
            () => openListenTogether(context),
            sub: s.party.active ? 'In a party' : 'Play the same song with friends',
          ),
          row(Icons.copy_rounded, 'Copy log', () => unawaited(_copyLog(context)), sub: 'Copies Byte\'s error log', key: const ValueKey('menu-copy-log')),
        ],
        [row(Icons.more_horiz_rounded, 'More options', () => showItemMenu(context, it))],
      ].where((g) => g.isNotEmpty).toList();

      // header, then each group with a thin divider between (lazy list)
      final rows = <Widget>[
        ListTile(
          leading: Artwork(it.thumb, size: 44, radius: 6),
          title: Text(it.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
          subtitle: Text(it.artistLine, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white60)),
        ),
        const Divider(color: Colors.white12, height: 1),
        for (var g = 0; g < groups.length; g++) ...[
          if (g > 0) divider,
          ...groups[g],
        ],
        const SizedBox(height: 8),
      ];
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.9),
          child: ListView.builder(
            key: const ValueKey('song-menu-list'),
            shrinkWrap: true,
            itemCount: rows.length,
            itemBuilder: (_, i) => rows[i],
          ),
        ),
      );
    },
  );
}
