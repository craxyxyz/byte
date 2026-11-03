import 'package:flutter/material.dart';
import '../style.dart' show bottomBarSpace;

import '../../services.dart';
import '../widgets.dart';
import '../glass.dart';

/// A playlist saved in Byte: play, shuffle, rename, reorder, remove, download.
class PlaylistScreen extends StatelessWidget {
  final String id;
  const PlaylistScreen({super.key, required this.id});

  @override
  Widget build(BuildContext context) {
    final lib = Services.i.library;
    final t = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final p = lib.playlist(id);
        if (p == null) return const Scaffold(body: Center(child: Text('Playlist deleted')));
        final items = p.items;
        final total = items.fold<int>(0, (a, i) => a + (i.durationSec ?? 0));
        return Scaffold(
          appBar: AppBar(
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'rename':
                      final n = await promptText(context, title: 'Rename playlist', initial: p.name);
                      if (n != null) await lib.renamePlaylist(id, n);
                    case 'download':
                      await Services.i.downloads.downloadPlaylist(id, items);
                      if (context.mounted) toast(context, 'Downloading ${items.length} songs');
                    case 'pin':
                      final on = !lib.isPinned(id);
                      await lib.setPinned(id, on);
                      if (context.mounted) toast(context, on ? 'Pinned to the top of your Library' : 'Unpinned');
                    case 'queue':
                      Services.i.player.addToQueue(items);
                      if (context.mounted) toast(context, 'Added to queue');
                    case 'delete':
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (c) => GlassDialog(
                          title: Text('Delete "${p.name}"?'),
                          content: const Text('The songs stay in your likes and downloads.'),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                            FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        await lib.deletePlaylist(id);
                        if (context.mounted) Navigator.pop(context);
                      }
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  PopupMenuItem(value: 'pin', child: Text(lib.isPinned(id) ? 'Unpin' : 'Pin to top')),
                  const PopupMenuItem(value: 'queue', child: Text('Add to queue')),
                  if (Services.i.downloads.supported) const PopupMenuItem(value: 'download', child: Text('Download all')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete playlist')),
                ],
              ),
            ],
          ),
          body: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Row(
                    children: [
                      Material(
                        elevation: 10,
                        borderRadius: BorderRadius.circular(12),
                        clipBehavior: Clip.antiAlias,
                        child: Artwork(p.artwork, size: 120, radius: 12, icon: Icons.queue_music_rounded),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(p.name, style: t.headlineSmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                            const SizedBox(height: 4),
                            Text(total > 0 ? '${items.length} songs • ${fmtTotal(total)}' : '${items.length} songs', key: const ValueKey('list-total'), style: t.bodyMedium),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: items.isEmpty ? null : () => Services.i.player.playItems(items, from: p.name),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Play'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: items.isEmpty ? null : () => Services.i.player.playItems(items, shuffle: true, from: p.name),
                          icon: const Icon(Icons.shuffle_rounded),
                          label: const Text('Shuffle'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (items.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: Text('Add songs from their ⋮ menu → "Add to playlist".')),
                  ),
                ),
              SliverReorderableList(
                itemCount: items.length,
                onReorderItem: (a, b) => lib.reorderPlaylistItem(id, a, b),
                itemBuilder: (c, i) => Dismissible(
                  key: ValueKey('${items[i].id}-$i'),
                  // Right: play next / add to queue. Left: remove from this playlist.
                  direction: DismissDirection.horizontal,
                  confirmDismiss: (d) async {
                    if (d == DismissDirection.endToStart) return true;
                    final next = Services.i.settings.playNextOnSwipe;
                    if (next) {
                      Services.i.player.playNextItem(items[i]);
                    } else {
                      Services.i.player.addToQueue([items[i]]);
                    }
                    toast(context, next ? 'Playing next' : 'Added to queue');
                    return false;
                  },
                  background: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(left: 24),
                    color: const Color(0xFF34C759),
                    child: const Icon(Icons.playlist_play_rounded, color: Colors.white),
                  ),
                  secondaryBackground: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: const Icon(Icons.delete_outline_rounded),
                  ),
                  onDismissed: (_) => lib.removeFromPlaylist(id, i),
                  child: Material(
                    type: MaterialType.transparency,
                    child: SongTile(
                      swipe: false,
                      item: items[i],
                      onTap: () => Services.i.player.playItems(items, start: i, from: p.name),
                      trailing: ReorderableDragStartListener(
                        index: i,
                        child: const Padding(padding: EdgeInsets.all(8), child: Icon(Icons.drag_handle_rounded)),
                      ),
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(child: SizedBox(height: bottomBarSpace(context))),
            ],
          ),
        );
      },
    );
  }
}
