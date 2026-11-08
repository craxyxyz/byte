import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/cover_cache.dart';
import '../core/models.dart';
import '../data/addons.dart' show SourceFormat;
import '../data/audio_format.dart';
import '../data/downloads.dart';
import '../services.dart';
import 'nav.dart';
import 'style.dart';
import 'glass.dart';
import 'kit/current_is.dart';

/// How web images are loaded (swappable so screenshot tests can serve them).
ImageProvider Function(String url) networkImage = (u) => CoverCache.dir != null ? CachedCover(u) : NetworkImage(u);

ImageProvider? imageProviderFor(String? url) {
  if (url == null || url.isEmpty) return null;
  if (url.startsWith('file:')) return FileImage(File(Uri.parse(url).toFilePath()));
  if (url.startsWith('/')) return FileImage(File(url));
  return networkImage(url);
}

/// Album art / thumbnail with a soft placeholder and a quick fade-in.
class Artwork extends StatelessWidget {
  final String? url;
  final double size;
  final double radius;
  final bool circle;
  final IconData icon;
  final BoxFit fit;
  const Artwork(this.url, {super.key, this.size = 52, this.radius = 8, this.circle = false, this.icon = Icons.music_note_rounded, this.fit = BoxFit.cover});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2;
    final px = (size * dpr).clamp(60, 1200).round();
    final resolved = resizeThumb(url, px > 226 ? (px > 544 ? 1080 : 544) : 226);
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [cs.primaryContainer, cs.tertiaryContainer], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Icon(icon, size: size * 0.42, color: cs.onPrimaryContainer.withValues(alpha: 0.7)),
    );
    // 2.0: decoded at the size it is drawn (a 1080 px cover for a 52 px row
    // was decoded whole before: memory and decode time while scrolling)
    final decodePx = (size * dpr * (isLetterboxedThumb(resolved) ? 4 / 3 : 1)).round();
    ImageProvider? sized(ImageProvider? p) => p == null ? null : ResizeImage.resizeIfNeeded(decodePx, null, p);
    final provider = sized(imageProviderFor(resolved));
    // While the big picture loads, show the small one the lists and the mini
    // player already loaded (no music-note flash when the player opens).
    final small = resizeThumb(url, 226);
    final smallProvider = small != null && small != resolved ? sized(imageProviderFor(small)) : null;
    final Widget waiting = smallProvider == null
        ? placeholder
        : Image(
            image: smallProvider,
            width: size,
            height: size,
            fit: fit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => placeholder,
            frameBuilder: (context, child, frame, sync) => sync || frame != null ? child : placeholder,
          );
    // Some videos have no hq720 frame: fall back to the 4:3 file, zoomed past its black bars.
    final fallbackUrl = ytThumbVariant(resolved, 'hqdefault');
    final Widget onError = fallbackUrl != null && fallbackUrl != resolved
        ? _unbar(
            Image(
              image: sized(imageProviderFor(fallbackUrl))!,
              width: size,
              height: size,
              fit: fit,
              gaplessPlayback: true,
              filterQuality: FilterQuality.medium,
              errorBuilder: (_, _, _) => placeholder,
            ),
          )
        : placeholder;
    Widget img = provider == null
        ? placeholder
        : Image(
            image: provider,
            width: size,
            height: size,
            fit: fit,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            errorBuilder: (_, _, _) => onError,
            frameBuilder: (context, child, frame, sync) {
              if (sync) return child;
              return Stack(
                fit: StackFit.passthrough,
                children: [
                  waiting,
                  AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 280), curve: Curves.easeOut, child: child),
                ],
              );
            },
          );
    if (isLetterboxedThumb(resolved)) img = _unbar(img);
    return SizedBox(
      width: size,
      height: size,
      child: circle ? ClipOval(child: img) : ClipRRect(borderRadius: BorderRadius.circular(radius), child: img),
    );
  }

  /// A 4:3 YouTube frame has black bars above and below the 16:9 picture:
  /// zoom by 4/3 so the square shows only the picture's centre.
  static Widget _unbar(Widget child) => ClipRect(child: Transform.scale(scale: 4 / 3, child: child));
}

String fmtDuration(int? sec) {
  if (sec == null) return '';
  final h = sec ~/ 3600, m = (sec % 3600) ~/ 60, s = sec % 60;
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}' : '$m:${s.toString().padLeft(2, '0')}';
}

/// A row in any song list. Shows a live "playing" indicator for the current song.
class SongTile extends StatelessWidget {
  final Item item;
  final VoidCallback? onTap;
  final Widget? trailing;
  final int? index; // album track numbers instead of art
  final bool showArt;
  final bool dense;
  final bool showDuration;

  /// Swipe right to queue (off inside sideways-scrolling rows).
  final bool swipe;
  const SongTile({super.key, required this.item, this.onTap, this.trailing, this.index, this.showArt = true, this.dense = false, this.showDuration = false, this.swipe = true});

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final player = Services.i.player;
    final artSize = dense ? 50.0 : 54.0;
    // 2.0: a row rebuilds only when it starts or stops being the song
    // playing (every visible row rebuilt on every song change before)
    return CurrentIs(
      id: item.id,
      builder: (context, isCur) {
        final leading = index != null && !showArt
            ? SizedBox(
                width: 32,
                child: Center(
                  child: isCur
                      ? Icon(Icons.graphic_eq_rounded, color: p.accent)
                      : Text(
                          '${index! + 1}',
                          style: TextStyle(color: p.secondary, fontSize: 16, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                ),
              )
            : Stack(
                alignment: Alignment.center,
                children: [
                  Artwork(item.thumb, size: artSize, radius: 6),
                  if (isCur)
                    Container(
                      width: artSize,
                      height: artSize,
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.42), borderRadius: BorderRadius.circular(6)),
                      child: const Icon(Icons.graphic_eq_rounded, color: Colors.white),
                    ),
                ],
              );
        final sub = [item.line2, if (showDuration && item.durationSec != null) fmtDuration(item.durationSec)].where((s) => s.isNotEmpty).join(' • ');
        if (!item.isPlayable || !swipe) return _tile(context, p, leading, isCur, sub);
        // Swipe right: play next (or add to the end of the queue — Settings → Miscellaneous).
        final next = Services.i.settings.playNextOnSwipe;
        return Dismissible(
          key: UniqueKey(),
          direction: DismissDirection.startToEnd,
          dismissThresholds: const {DismissDirection.startToEnd: 0.28},
          confirmDismiss: (_) async {
            HapticFeedback.mediumImpact();
            if (next) {
              player.playNextItem(item);
            } else {
              player.addToQueue([item]);
            }
            toast(context, next ? 'Playing next' : 'Added to queue');
            return false;
          },
          background: Container(
            color: const Color(0xFF34C759),
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 22),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(next ? Icons.playlist_play_rounded : Icons.queue_music_rounded, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  next ? 'Play next' : 'Add to queue',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          child: _tile(context, p, leading, isCur, sub),
        );
      },
    );
  }

  Widget _tile(BuildContext context, BytePalette p, Widget leading, bool isCur, String sub) {
    {
      {
        return InkWell(mouseCursor: SystemMouseCursors.click, 
          onTap: onTap,
          onLongPress: () => showItemMenu(context, item),
          onSecondaryTap: () => showItemMenu(context, item),
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, dense ? 5 : 6, 4, dense ? 5 : 6),
            child: Row(
              children: [
                leading,
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: dense ? 16 : 17, letterSpacing: -0.2, color: isCur ? p.accent : p.label),
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          if (item.explicit)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(Icons.explicit_rounded, size: 15, color: p.secondary),
                            ),
                          if (Services.i.library.isDownloaded(item.id))
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(Icons.arrow_circle_down_rounded, size: 15, color: p.secondary),
                            ),
                          Expanded(
                            child: Text(
                              sub,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 14, color: p.secondary),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ?trailing,
                // songs from this phone: "Lossless · 24-bit/96 kHz" when the file really is
                if (trailing == null && item.isOnPhone) LosslessBadge(path: item.id.substring(6)),
                if (trailing == null)
                  IconButton(
                    icon: Icon(Icons.more_vert_rounded, color: p.secondary),
                    tooltip: 'More',
                    onPressed: () => showItemMenu(context, item),
                  ),
              ],
            ),
          ),
        );
      }
    }
  }
}

/// The real format of a file on the phone, read from the file itself:
/// shows only for lossless files (FLAC, ALAC, WAV, AIFF).
class LosslessBadge extends StatelessWidget {
  final String path;
  const LosslessBadge({super.key, required this.path});
  @override
  Widget build(BuildContext context) => FutureBuilder<SourceFormat?>(
    future: AudioFormats.of(path),
    initialData: AudioFormats.cached(path),
    builder: (context, f) {
      final l = f.data?.label;
      if (l == null) return const SizedBox.shrink();
      return Padding(padding: const EdgeInsets.only(left: 6), child: Badge2(l.toUpperCase(), key: const ValueKey('lossless-badge')));
    },
  );
}

/// Square (or round, for artists) card used in carousels.
class ItemCard extends StatelessWidget {
  final Item item;
  final double width;
  final VoidCallback? onTap;

  /// Where the card sits (e.g. its shelf), so the same album twice on one
  /// page still gets its own art animation.
  final String scope;
  const ItemCard({super.key, required this.item, this.width = 148, this.onTap, this.scope = ''});
  String get _tag => 'art-$scope-${item.kind.name}-${item.id}';

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final circle = item.kind == ItemKind.artist;
    final wide = item.kind == ItemKind.video;
    final w = wide ? width * 1.45 : width;
    return SizedBox(
      width: w,
      child: InkWell(mouseCursor: SystemMouseCursors.click, 
        borderRadius: BorderRadius.circular(12),
        onTap: onTap ?? () => openItem(context, item, heroTag: _tag),
        onLongPress: () => showItemMenu(context, item),
        onSecondaryTap: () => showItemMenu(context, item),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              Hero(
                tag: _tag,
                child: wide
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: SizedBox(
                          width: w - 8,
                          height: (w - 8) * 9 / 16,
                          child: Artwork(item.thumb, size: w - 8, radius: 0, fit: BoxFit.cover),
                        ),
                      )
                    : Artwork(item.thumb, size: w - 8, radius: 10, circle: circle, icon: circle ? Icons.person_rounded : Icons.album_rounded),
              ),
              const SizedBox(height: 8),
              Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: circle ? TextAlign.center : TextAlign.start,
                style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600, height: 1.2),
              ),
              const SizedBox(height: 2),
              Text(
                item.isPlayable ? item.artistLine : (item.subtitle ?? ''),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final VoidCallback? onMore;
  const SectionHeader(this.title, {super.key, this.subtitle, this.onMore});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (subtitle != null && subtitle!.isNotEmpty) Text(subtitle!, style: t.bodySmall?.copyWith(color: BytePalette.of(context).secondary)),
                Text(
                  title,
                  style: BT.section.copyWith(color: BytePalette.of(context).label),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              child: Text('Show all', style: BT.body.copyWith(color: BytePalette.of(context).secondary)),
            ),
        ],
      ),
    );
  }
}

/// Extra height a fixed-height row or shelf needs at the phone's text size:
/// [perUnit] × (scale − 1), so 0 at normal size (1.4.6).
double textGrow(BuildContext context, double perUnit) =>
    (MediaQuery.textScalerOf(context).scale(10) / 10 - 1).clamp(0.0, 1.0) * perUnit;

void toast(BuildContext context, String msg) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(
    SnackBar(
      content: GlassToast(msg),
      backgroundColor: Colors.transparent,
      elevation: 0,
      padding: EdgeInsets.zero,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ),
  );
}

String shareUrlFor(Item it) => switch (it.kind) {
  ItemKind.song || ItemKind.video || ItemKind.episode => 'https://music.youtube.com/watch?v=${it.id}',
  ItemKind.album || ItemKind.artist || ItemKind.podcast => 'https://music.youtube.com/browse/${it.id}',
  ItemKind.playlist => 'https://music.youtube.com/playlist?list=${it.id.startsWith('VL') ? it.id.substring(2) : it.id}',
};

Future<void> showItemMenu(BuildContext context, Item item) async {
  final s = Services.i;
  HapticFeedback.selectionClick();
  await showByteSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) {
      final liked = s.library.isLiked(item.id);
      final downloaded = s.library.isDownloaded(item.id);
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Artwork(item.thumb, size: 48, circle: item.kind == ItemKind.artist),
                title: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(item.line2, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Divider(height: 8),
              if (item.isPlayable) ...[
                _menu(ctx, Icons.playlist_play_rounded, 'Play next', () {
                  s.player.playNextItem(item);
                  toast(context, 'Playing next');
                }),
                _menu(ctx, Icons.queue_music_rounded, 'Add to queue', () {
                  s.player.addToQueue([item]);
                  toast(context, 'Added to queue');
                }),
                if (item.kind == ItemKind.episode)
                  s.library.isLater(item.id)
                      ? _menu(ctx, Icons.bookmark_remove_outlined, 'Remove from Episodes for Later', () => s.library.setLater(item, false))
                      : _menu(ctx, Icons.bookmark_add_outlined, 'Save for later', () {
                          s.library.setLater(item, true);
                          toast(context, 'Saved to Episodes for Later');
                        }),
                if (item.kind == ItemKind.episode && item.albumId != null)
                  _menu(
                    ctx,
                    Icons.podcasts_rounded,
                    'Go to podcast',
                    () => openItem(context, Item(kind: ItemKind.podcast, id: item.albumId!, title: item.album ?? '')),
                  ),
                if (!item.isLocal && item.kind != ItemKind.episode) _menu(ctx, Icons.radio_rounded, 'Start radio', () => s.player.playSong(item)),
                _menu(ctx, liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, liked ? 'Remove from liked' : 'Like', () async {
                  final now = await s.library.toggleLike(item);
                  if (context.mounted) toast(context, now ? 'Added to liked songs' : 'Removed from liked songs');
                }),
                _menu(ctx, Icons.playlist_add_rounded, 'Add to playlist', () => addToPlaylistSheet(context, [item])),
                if (s.downloads.supported && !item.isLocal)
                  downloaded
                      ? _menu(ctx, Icons.delete_outline_rounded, 'Remove download', () => s.downloads.delete(item.id))
                      : _menu(ctx, Icons.download_rounded, 'Download', () {
                          s.downloads.enqueue([item]);
                          toast(context, 'Downloading…');
                        }),
                if (item.albumId != null && item.kind != ItemKind.episode)
                  _menu(
                    ctx,
                    Icons.album_rounded,
                    'Go to album',
                    () => openItem(context, Item(kind: ItemKind.album, id: item.albumId!, title: item.album ?? '')),
                  ),
                for (final a in item.artists.where((a) => a.id != null).take(2))
                  _menu(ctx, Icons.person_rounded, 'Go to ${a.name}', () => openItem(context, Item(kind: ItemKind.artist, id: a.id!, title: a.name))),
              ] else ...[
                _menu(ctx, Icons.play_arrow_rounded, 'Play', () => playCollection(context, item)),
                _menu(ctx, Icons.shuffle_rounded, 'Shuffle', () => playCollection(context, item, shuffle: true)),
                if (item.kind == ItemKind.podcast)
                  s.library.isPodcastSaved(item.id)
                      ? _menu(ctx, Icons.bookmark_remove_outlined, 'Remove from library', () => s.library.setPodcastSaved(item, false))
                      : _menu(ctx, Icons.bookmark_add_outlined, 'Save to library', () {
                          s.library.setPodcastSaved(item, true);
                          toast(context, 'Podcast saved to Library');
                        })
                else if (item.kind != ItemKind.artist)
                  _menu(ctx, Icons.library_add_rounded, 'Save to library', () => saveCollection(context, item)),
              ],
              if (!item.isLocal)
                _menu(ctx, Icons.share_rounded, 'Share', () => SharePlus.instance.share(ShareParams(text: '${item.title}\n${shareUrlFor(item)}'))),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

Widget _menu(BuildContext ctx, IconData icon, String label, VoidCallback onTap) => ListTile(
  leading: Icon(icon),
  title: Text(label),
  onTap: () {
    Navigator.pop(ctx);
    onTap();
  },
);

Future<void> addToPlaylistSheet(BuildContext context, List<Item> items) async {
  final s = Services.i;
  await showByteSheet(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (ctx) {
      final lists = s.library.playlists;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: const CircleAvatar(child: Icon(Icons.add_rounded)),
                title: const Text('New playlist'),
                onTap: () async {
                  Navigator.pop(ctx);
                  final name = await promptText(context, title: 'New playlist', hint: 'Playlist name');
                  if (name == null) return;
                  await s.library.createPlaylist(name, items: items);
                  if (context.mounted) toast(context, 'Saved to "$name"');
                },
              ),
              for (final p in lists)
                ListTile(
                  leading: Artwork(p.artwork, size: 44, icon: Icons.queue_music_rounded),
                  title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(songCount(p.items.length)),
                  onTap: () async {
                    Navigator.pop(ctx);
                    final n = await s.library.addToPlaylist(p.id, items);
                    if (context.mounted) toast(context, n == 0 ? 'Already in "${p.name}"' : 'Added to "${p.name}"');
                  },
                ),
            ],
          ),
        ),
      );
    },
  );
}

Future<String?> promptText(BuildContext context, {required String title, String? hint, String? initial, String action = 'Save'}) async {
  final c = TextEditingController(text: initial);
  // 1.4.6: Save with an empty name used to close nothing and say nothing;
  // the dialog now stays open and says what's missing.
  String? problem;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        void done() {
          final v = c.text.trim();
          if (v.isEmpty) {
            setD(() => problem = emptyNameMessage(hint));
            return;
          }
          Navigator.pop(ctx, v);
        }

        return GlassDialog(
          title: Text(title),
          content: TextField(
            controller: c,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(hintText: hint, errorText: problem),
            onChanged: (_) {
              if (problem != null) setD(() => problem = null);
            },
            onSubmitted: (_) => done(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: done, child: Text(action)),
          ],
        );
      },
    ),
  );
}

/// "Type a playlist name first" (from the field's hint, "Playlist name").
String emptyNameMessage(String? hint) {
  final h = (hint ?? '').trim();
  return h.isEmpty ? 'Type a name first' : 'Type a ${h[0].toLowerCase()}${h.substring(1)} first';
}

/// Loading skeleton: rows shaped like the songs that are coming (cover,
/// title, artist), softly pulsing until the real rows land.
class LoadingList extends StatelessWidget {
  final int rows;
  final double cover;
  const LoadingList({super.key, this.rows = 8, this.cover = 50});
  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey('skeleton-list'),
      children: [
        for (var i = 0; i < rows; i++)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Skel(width: cover, height: cover, radius: 8),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Skel(height: 12, width: 120.0 + (i * 37) % 90, radius: 6),
                      const SizedBox(height: 8),
                      Skel(height: 10, width: 70.0 + (i * 23) % 60, radius: 6),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// "1 hr 12 min" / "45 min" for a list's total length.
String fmtTotal(int seconds) {
  if (seconds <= 0) return '';
  final m = (seconds / 60).round();
  if (m < 60) return '$m min';
  final h = m ~/ 60, r = m % 60;
  return r == 0 ? '$h hr' : '$h hr $r min';
}

/// "12 songs • 45 min" under a playlist or album title.
String listSummary(List<Item> items) {
  final songs = items.where((i) => i.isPlayable).toList();
  if (songs.isEmpty) return '';
  final total = songs.fold<int>(0, (a, i) => a + (i.durationSec ?? 0));
  final n = '${songs.length} ${songs.length == 1 ? 'song' : 'songs'}';
  return total <= 0 ? n : '$n • ${fmtTotal(total)}';
}

class ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ErrorRetry(this.message, {super.key, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_off_rounded, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

class DownloadBadge extends StatelessWidget {
  final String id;
  const DownloadBadge(this.id, {super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Services.i.downloads,
      builder: (context, _) {
        final t = Services.i.downloads.task(id);
        if (t == null || t.state == DlState.done) return const SizedBox.shrink();
        if (t.state == DlState.failed) return const Icon(Icons.error_outline_rounded, size: 18);
        return SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, value: t.progress == 0 ? null : t.progress));
      },
    );
  }
}

/// A list row for albums, artists, playlists and podcasts (round art for artists).
class ItemRow extends StatelessWidget {
  final Item item;
  final VoidCallback? onTap;
  final Widget? trailing;
  const ItemRow({super.key, required this.item, this.onTap, this.trailing});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final circle = item.kind == ItemKind.artist;
    final kind = switch (item.kind) {
      ItemKind.artist => 'Artist',
      ItemKind.album => 'Album',
      ItemKind.playlist => 'Playlist',
      ItemKind.podcast => 'Podcast',
      ItemKind.episode => 'Episode',
      ItemKind.video => 'Video',
      ItemKind.song => 'Song',
    };
    final sub = (item.subtitle ?? item.line2).trim();
    return InkWell(mouseCursor: SystemMouseCursors.click, 
      onTap: onTap ?? () => openItem(context, item),
      onLongPress: item.id.startsWith('local:') ? null : () => showItemMenu(context, item),
      onSecondaryTap: item.id.startsWith('local:') ? null : () => showItemMenu(context, item),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
        child: Row(
          children: [
            Artwork(item.thumb, size: 54, radius: 6, circle: circle, icon: circle ? Icons.person_rounded : Icons.album_rounded),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BT.body.copyWith(color: p.label),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub.isEmpty ? kind : (sub.toLowerCase().startsWith(kind.toLowerCase()) ? sub : '$kind • $sub'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BT.sub.copyWith(color: p.secondary),
                  ),
                ],
              ),
            ),
            trailing ??
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Icon(Icons.chevron_right_rounded, color: p.tertiary),
                ),
          ],
        ),
      ),
    );
  }
}
