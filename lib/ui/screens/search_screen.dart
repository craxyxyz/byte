import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../data/link_import.dart';
import '../../data/playlist_import.dart';
import '../../services.dart';
import '../account_ui.dart';
import '../import_sheet.dart';
import '../nav.dart';
import '../shelves.dart';
import '../style.dart';
import '../widgets.dart';
import 'sources_pages.dart' show openAddons;
import '../glass.dart';
import '../../core/platform_caps.dart';

/// Search: YouTube Music, your own library, or podcasts.
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => SearchScreenState();
}

class SearchScreenState extends State<SearchScreen> with AutomaticKeepAliveClientMixin {
  final ctrl = TextEditingController();
  final focus = FocusNode();
  Timer? _debounce;
  int scope = 0; // 0 YouTube, 1 Library, 2 Podcasts
  List<String> suggestions = [];
  String? submitted;
  SearchFilter filter = SearchFilter.all;
  List<Item>? results;
  List<Shelf>? shelves;
  bool loading = false;
  bool failed = false;
  int _req = 0;

  static const scopes = ['Online', 'Library', 'Addons'];
  static const hints = ['Artists, Songs, Lyrics and More', 'Songs, Artists and Albums', 'Search your addons'];

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    ctrl.dispose();
    focus.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void focusSearch() => focus.requestFocus();

  void _onChanged(String v) {
    setState(() {});
    if (scope == 1) {
      submitted = v.trim().isEmpty ? null : v.trim();
      return;
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () async {
      final q = v.trim();
      if (q.isEmpty || parseLink(q).kind != LinkKind.unknown || detectService(q) != null || scope != 0) {
        if (mounted) setState(() => suggestions = []);
        return;
      }
      try {
        final s = await Services.i.yt.suggestions(q);
        if (mounted && ctrl.text.trim() == q) setState(() => suggestions = s);
      } catch (_) {}
    });
  }

  Future<void> _submit(String q) async {
    q = q.trim();
    if (q.isEmpty) return;
    focus.unfocus();
    final link = parseLink(q);
    final svc = detectService(firstLink(q) ?? q);
    if (link.kind != LinkKind.unknown || (svc != null && svc != MusicService.web)) {
      showImportSheet(context, initial: q);
      return;
    }
    ctrl.text = q;
    if (scope != 1) Services.i.library.addSearch(q);
    setState(() {
      submitted = q;
      suggestions = [];
    });
    await _run();
  }

  void _setScope(int i) {
    setState(() {
      scope = i;
      results = null;
      shelves = null;
      failed = false;
      suggestions = [];
      submitted = ctrl.text.trim().isEmpty ? null : ctrl.text.trim();
    });
    if (submitted != null && scope != 1) _run();
  }

  Future<void> _run() async {
    final q = submitted;
    if (q == null || scope == 1) return;
    final id = ++_req;
    setState(() {
      loading = true;
      failed = false;
      results = null;
      shelves = null;
    });
    try {
      final yt = Services.i.yt;
      if (scope == 2) {
        // Every turned-on addon that can search, side by side.
        final ad = Services.i.addons;
        final rs = await Future.wait([for (final a in ad.enabled.where((a) => a.can('search'))) ad.search(a, q)]);
        if (id == _req && mounted) {
          setState(() => shelves = [for (final r in rs) if (r.items.isNotEmpty) Shelf(r.addon.name, r.items)]);
        }
      } else if (filter == SearchFilter.podcasts) {
        final r = await Future.wait([yt.search(q, SearchFilter.podcasts), yt.search(q, SearchFilter.episodes)]);
        if (id == _req && mounted) {
          setState(() => shelves = [if (r[0].isNotEmpty) Shelf('Shows', r[0]), if (r[1].isNotEmpty) Shelf('Episodes', r[1])]);
        }
      } else if (filter == SearchFilter.all) {
        final s = await yt.searchShelves(q);
        if (id == _req && mounted) setState(() => shelves = s);
      } else {
        final r = await yt.search(q, filter);
        if (id == _req && mounted) setState(() => results = r);
      }
    } catch (_) {
      if (id == _req && mounted) setState(() => failed = true);
    } finally {
      if (id == _req && mounted) setState(() => loading = false);
    }
  }

  void _open(Item it, {List<Item>? list, int index = 0}) {
    if (scope != 1) Services.i.library.addRecentItem(it);
    if (it.isPlayable && list != null && it.kind != ItemKind.song) {
      Services.i.player.playItems(list.where((i) => i.isPlayable).toList(), start: list.where((i) => i.isPlayable).toList().indexOf(it).clamp(0, 9999));
    } else {
      openItem(context, it);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final p = BytePalette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final typing = focus.hasFocus && ctrl.text.trim().isNotEmpty && suggestions.isNotEmpty && scope == 0;
    return Scaffold(
      backgroundColor: p.bg,
      body: Column(
        children: [
          SizedBox(height: top + 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 14, 0),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 44,
                    child: LiquidGlass(
                    key: const ValueKey('glass-search'),
                    radius: BorderRadius.circular(22),
                    tint: p.fill.withValues(alpha: 0.6),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Icon(Icons.search_rounded, color: p.secondary, size: 22),
                        const SizedBox(width: 6),
                        Expanded(
                          child: TextField(
                            controller: ctrl,
                            focusNode: focus,
                            onChanged: _onChanged,
                            onSubmitted: _submit,
                            textInputAction: TextInputAction.search,
                            style: BT.body.copyWith(color: p.label),
                            cursorColor: p.accent,
                            decoration: InputDecoration(
                              isCollapsed: true,
                              border: InputBorder.none,
                              hintText: hints[scope],
                              hintStyle: BT.body.copyWith(color: p.secondary),
                            ),
                          ),
                        ),
                        if (ctrl.text.isNotEmpty)
                          IconButton(
                            tooltip: 'Clear',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(Icons.cancel_rounded, color: p.tertiary, size: 20),
                            onPressed: () {
                              ctrl.clear();
                              setState(() {
                                suggestions = [];
                                submitted = null;
                                results = null;
                                shelves = null;
                              });
                              focus.requestFocus();
                            },
                          ),
                      ],
                    ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                const ProfileButton(),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SegmentedPill(labels: scopes, index: scope, onChanged: _setScope),
          ),
          Expanded(child: typing ? _suggestions(p) : _body(p)),
        ],
      ),
    );
  }

  Widget _suggestions(BytePalette p) => ListView(
    padding: EdgeInsets.only(bottom: bottomBarSpace(context)),
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    children: [
      for (final s in suggestions)
        ListTile(
          leading: Icon(Icons.search_rounded, color: p.secondary),
          title: Text(s, style: BT.body.copyWith(color: p.label)),
          trailing: IconButton(
            tooltip: 'Use',
            icon: Icon(Icons.north_west_rounded, color: p.tertiary),
            onPressed: () {
              ctrl.text = s;
              ctrl.selection = TextSelection.collapsed(offset: s.length);
              _onChanged(s);
            },
          ),
          onTap: () => _submit(s),
        ),
    ],
  );

  Widget _body(BytePalette p) {
    if (scope == 1) return _library(p);
    if (scope == 2 && Services.i.addons.enabled.where((a) => a.can('search')).isEmpty) {
      return ListView(
        padding: EdgeInsets.only(bottom: bottomBarSpace(context)),
        children: [
          _hint(p, 'No addons yet. Add your own server (a NAS or a music server you run) to search and play its music here.'),
          const SizedBox(height: 14),
          Center(child: FilledButton.icon(onPressed: () => openAddons(context), icon: const Icon(Icons.add_rounded), label: const Text('Add an addon'))),
        ],
      );
    }
    if (submitted == null) return scope == 0 ? _recents(p) : _hint(p, 'Searches every enabled addon at once.');
    if (failed) return ErrorRetry('Search needs the internet.', onRetry: _run);
    return ListView(
      padding: EdgeInsets.only(bottom: bottomBarSpace(context)),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (scope == 0)
          SizedBox(
            height: 50,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
              children: [
                for (final f in SearchFilter.values.where((f) => f != SearchFilter.episodes))
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _Chip(
                      label: switch (f) {
                        SearchFilter.all => 'All',
                        SearchFilter.songs => 'Songs',
                        SearchFilter.videos => 'Videos',
                        SearchFilter.albums => 'Albums',
                        SearchFilter.artists => 'Artists',
                        SearchFilter.playlists => 'Playlists',
                        SearchFilter.podcasts => 'Podcasts',
                        SearchFilter.episodes => 'Episodes',
                      },
                      selected: filter == f,
                      onTap: () {
                        setState(() => filter = f);
                        _run();
                      },
                    ),
                  ),
              ],
            ),
          ),
        if (loading) const LoadingList(rows: 8),
        if (shelves != null) ...[
          if (shelves!.isEmpty) _hint(p, 'No results for "$submitted"'),
          for (final s in shelves!)
            if (s.items.every((i) => i.isPlayable) || s.title == 'Top result' || s.title == 'Results' || s.items.length <= 3 || scope == 2 || filter == SearchFilter.podcasts) ...[
              SectionTitle(s.title),
              for (var i = 0; i < s.items.length; i++) _row(s.items[i], s.items, i),
            ] else
              ShelfView(shelf: s),
        ],
        if (results != null) ...[
          if (results!.isEmpty) _hint(p, 'No results for "$submitted"'),
          for (var i = 0; i < results!.length; i++) _row(results![i], results!, i),
        ],
      ],
    );
  }

  Widget _row(Item it, List<Item> list, int i) {
    // Lossless / Hi-Res / Dolby Atmos only when the addon says the file is one.
    final badge = it.isAddon ? Services.i.addons.formats[it.id]?.badge : null;
    if (it.isPlayable) {
      return SongTile(item: it, trailing: badge == null ? null : Badge2(badge.toUpperCase()), onTap: () => _open(it, list: list, index: i));
    }
    return ItemRow(item: it, onTap: () => _open(it));
  }

  Widget _hint(BytePalette p, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(32, 60, 32, 0),
    child: Text(text, textAlign: TextAlign.center, style: BT.body.copyWith(color: p.secondary)),
  );

  Widget _recents(BytePalette p) {
    return ListenableBuilder(
      listenable: Services.i.library,
      builder: (context, _) {
        final lib = Services.i.library;
        final items = lib.recentItems;
        final words = lib.searches;
        if (items.isEmpty && words.isEmpty) return _hint(p, 'Search for songs, artists, albums and playlists — or paste a playlist link from any music app.');
        return ListView(
          padding: EdgeInsets.only(bottom: bottomBarSpace(context)),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          children: [
            SectionTitle('Recent searches', action: 'Clear', onAction: lib.clearSearches, padding: const EdgeInsets.fromLTRB(16, 18, 16, 6)),
            for (final it in items)
              ItemRow(
                item: it,
                onTap: () => _open(it),
                trailing: IconButton(tooltip: 'Remove', icon: Icon(Icons.close_rounded, color: p.secondary), onPressed: () => lib.removeRecentItem(it.id)),
              ),
            for (final w in words)
              InkWell(
                onTap: () => _submit(w),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                  child: Row(
                    children: [
                      Container(
                        width: 54,
                        height: 54,
                        decoration: BoxDecoration(color: p.grouped, borderRadius: BorderRadius.circular(6)),
                        child: Icon(Icons.search_rounded, color: p.secondary),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: Text(w, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: p.label))),
                      IconButton(tooltip: 'Remove', icon: Icon(Icons.close_rounded, color: p.secondary), onPressed: () => lib.removeSearch(w)),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _library(BytePalette p) {
    final q = (submitted ?? '').toLowerCase();
    if (q.isEmpty) return _hint(p, onWeb ? 'Search the songs in your library.' : 'Search the songs in your library, downloads and Local Music folder.');
    final lib = Services.i.library;
    final seen = <String>{};
    final songs = <Item>[];
    bool hit(Item i) => i.title.toLowerCase().contains(q) || i.artistLine.toLowerCase().contains(q) || (i.album ?? '').toLowerCase().contains(q);
    for (final it in [
      ...lib.likes,
      ...lib.downloads.map((d) => d.item),
      ...lib.localTracks,
      ...lib.playlists.expand((p) => p.items),
      ...lib.history.map((h) => h.item),
    ]) {
      if (hit(it) && seen.add(it.id)) songs.add(it);
    }
    final lists = lib.playlists.where((l) => l.name.toLowerCase().contains(q)).toList();
    if (songs.isEmpty && lists.isEmpty) return _hint(p, 'Nothing in your library matches "$submitted".');
    return ListView(
      padding: EdgeInsets.only(bottom: bottomBarSpace(context)),
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: [
        if (lists.isNotEmpty) ...[
          const SectionTitle('Playlists'),
          for (final l in lists)
            ItemRow(
              item: Item(kind: ItemKind.playlist, id: 'local:${l.id}', title: l.name, thumb: l.artwork, subtitle: '${l.items.length} songs'),
              onTap: () => openLocalPlaylist(context, l.id),
            ),
        ],
        if (songs.isNotEmpty) ...[
          const SectionTitle('Songs'),
          for (var i = 0; i < songs.length && i < 200; i++) SongTile(item: songs[i], onTap: () => Services.i.player.playItems(songs, start: i)),
        ],
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(color: selected ? p.label : p.fill, borderRadius: BorderRadius.circular(18)),
        child: Text(label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: selected ? p.bg : p.label)),
      ),
    );
  }
}
