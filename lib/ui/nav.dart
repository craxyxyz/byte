import 'package:flutter/material.dart';

import '../core/models.dart';
import '../services.dart';
import 'screens/browse_screen.dart';
import 'screens/playlist_screen.dart';
import 'widgets.dart';

/// Push a page inside the current tab (so the floating bar stays visible).
void Function(Widget page)? pushInCurrentTab;

void pushPage(BuildContext context, Widget page) {
  final f = pushInCurrentTab;
  if (f != null) {
    f(page);
  } else {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }
}

void openLocalPlaylist(BuildContext context, String id) => pushPage(context, PlaylistScreen(id: id));

/// Tap on anything: songs play (with radio), collections open.
void openItem(BuildContext context, Item item, {String? heroTag}) {
  if (item.isPlayable) {
    Services.i.player.playSong(item);
    return;
  }
  pushPage(context, BrowseScreen(item: item, heroTag: heroTag));
}

Route<T> fadeRoute<T>(Widget page) => PageRouteBuilder<T>(
  transitionDuration: const Duration(milliseconds: 380),
  reverseTransitionDuration: const Duration(milliseconds: 300),
  pageBuilder: (_, _, _) => page,
  transitionsBuilder: (_, a, _, child) {
    final c = CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return FadeTransition(
      opacity: c,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.04), end: Offset.zero).animate(c),
        child: child,
      ),
    );
  },
);

Future<List<Item>> tracksOf(Item collection) async {
  final yt = Services.i.yt;
  switch (collection.kind) {
    case ItemKind.album:
      return (await yt.album(collection.id)).tracks;
    case ItemKind.playlist:
      return (await yt.playlist(collection.id)).tracks;
    case ItemKind.artist:
      final p = await yt.artist(collection.id);
      return p.shelves.where((s) => s.isSongList).expand((s) => s.items).toList();
    default:
      return [collection];
  }
}

Future<void> playCollection(BuildContext context, Item collection, {bool shuffle = false}) async {
  try {
    final t = await tracksOf(collection);
    if (t.isEmpty) {
      if (context.mounted) toast(context, 'Nothing to play here');
      return;
    }
    await Services.i.player.playItems(t, shuffle: shuffle);
  } catch (_) {
    if (context.mounted) toast(context, 'Couldn\'t load — check your internet');
  }
}

Future<void> saveCollection(BuildContext context, Item collection) async {
  try {
    final t = (await tracksOf(collection)).where((i) => i.isPlayable).toList();
    final lib = Services.i.library;
    final src = 'youtube:${collection.id}';
    final existing = lib.playlistBySource(src);
    if (existing != null) {
      existing.items
        ..clear()
        ..addAll(t);
      await lib.savePlaylist(existing);
    } else {
      await lib.createPlaylist(collection.title, items: t, source: src, cover: collection.thumb);
    }
    if (context.mounted) toast(context, 'Saved "${collection.title}" to your library');
  } catch (_) {
    if (context.mounted) toast(context, 'Couldn\'t save — check your internet');
  }
}
