import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/net.dart';
import '../data/playlist_import.dart';
import '../data/service_library.dart';
import 'music_apps.dart';
import '../services.dart';
import 'nav.dart';
import 'page.dart';
import 'screens/playlist_screen.dart';
import 'style.dart';
import 'widgets.dart';

/// Opens the importer (a link from any music app, a pasted song list, or a
/// CSV / TXT file). Kept under its 1.0 name for every caller.
Future<void> showImportSheet(BuildContext context, {String? initial}) async {
  pushPage(context, ImportScreen(initial: initial));
}


const importServices = ['Spotify', 'Apple Music', 'YouTube Music', 'JioSaavn', 'Gaana', 'Amazon Music', 'SoundCloud', 'Deezer'];

class ImportScreen extends StatefulWidget {
  final String? initial;
  /// A list that is already read (e.g. from a linked music app login): match it straight away.
  final Future<ExtList> Function(void Function(String) onStatus)? preset;
  const ImportScreen({super.key, this.initial, this.preset});
  @override
  State<ImportScreen> createState() => _ImportScreenState();
}

class _ImportScreenState extends State<ImportScreen> {
  late final ctrl = TextEditingController(text: widget.initial);
  bool busy = false;
  bool cancelled = false;
  String? status;
  String? error;
  String? _errorDetail;
  LibService loginPick = LibService.spotify;
  LibService? _loginFor;
  String? _loginLink;
  double? progress;

  @override
  void initState() {
    super.initState();
    if (widget.preset != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fromPreset());
    } else if (widget.initial == null) {
      Clipboard.getData('text/plain').then((d) {
        final t = d?.text?.trim();
        final link = t == null ? null : firstLink(t);
        if (link != null && detectService(link) != null && ctrl.text.isEmpty && mounted) setState(() => ctrl.text = link);
      }).catchError((_) {});
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fromLink());
    }
  }

  @override
  void dispose() {
    cancelled = true;
    ctrl.dispose();
    super.dispose();
  }

  void _set(String? s, [double? p]) {
    if (mounted) {
      setState(() {
        status = s;
        progress = p;
      });
    }
  }

  Future<void> _fromLink() async {
    final text = ctrl.text.trim();
    if (text.isEmpty) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      busy = true;
      cancelled = false;
      error = null;
      _loginFor = null;
    });
    try {
      final s = Services.i;
      final list = await PlaylistReader(s.net, s.yt).read(text, onStatus: (m) => _set(m));
      await _match(list);
    } on ImportProblem catch (e) {
      _errorDetail = '$text\n${e.message}';
      _loginFor = e.loginService == 'amazon' ? LibService.amazon : null;
      _loginLink = e.link;
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      final why = e is NetException ? 'the app\'s server answered ${e.status ?? 'nothing'}' : (e is TimeoutException ? 'it took too long' : e.runtimeType.toString());
      if (mounted) setState(() => error = 'Couldn\'t read that link ($why). Check your internet, and that the playlist is public.');
      _errorDetail = '$text\n$e';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _fromPreset() async {
    setState(() {
      busy = true;
      cancelled = false;
      error = null;
    });
    try {
      final list = await widget.preset!((m) => _set(m));
      if (list.tracks.isEmpty && (list.ready?.isEmpty ?? true)) throw const ImportProblem('That playlist is empty');
      await _match(list);
    } on ImportProblem catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) setState(() => error = '$e'.replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _fromTracks(List<ExtTrack> tracks, String name, MusicService service) async {
    if (tracks.isEmpty) {
      setState(() => error = 'No songs found in that ${service == MusicService.file ? 'file' : 'list'}.');
      return;
    }
    setState(() {
      busy = true;
      cancelled = false;
      error = null;
    });
    try {
      await _match(ExtList(name, null, tracks, service, '${service.name}:${DateTime.now().millisecondsSinceEpoch}'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _match(ExtList list) async {
    List<TrackMatch> matches;
    if (list.ready != null) {
      matches = [for (final i in list.ready!) TrackMatch(ExtTrack(i.title, i.artistLine, durationMs: i.durationSec == null ? null : i.durationSec! * 1000), chosen: i, candidates: [i], score: 9, searched: true)];
    } else {
      _set('Finding ${list.tracks.length} songs…', 0);
      matches = await PlaylistMatcher(Services.i.yt).matchAll(
        list.tracks,
        onProgress: (d, t) => _set('Finding songs… $d of $t', d / t),
        cancelled: () => cancelled,
      );
      if (cancelled) return;
    }
    if (!mounted) return;
    _set(null);
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => ImportReviewScreen(list: list, matches: matches)));
  }

  Future<void> _pasteList() async {
    final text = await Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => const _PasteListScreen()));
    if (text == null || text.trim().isEmpty) return;
    await _fromTracks(parseTextList(text), 'My imported songs', MusicService.text);
  }

  Future<void> _pickFile() async {
    try {
      final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: const ['csv', 'txt', 'tsv', 'm3u', 'm3u8']);
      if (r.isEmpty) return;
      final f = r.first;
      final text = utf8.decode(await f.readAsBytes(), allowMalformed: true).replaceFirst('\uFEFF', '');
      final lower = f.name.toLowerCase();
      final tracks = lower.endsWith('.m3u') || lower.endsWith('.m3u8') ? parseM3u(text) : parseCsvList(text);
      final name = f.name.replaceAll(RegExp(r'\.(csv|txt|tsv|m3u8?)$', caseSensitive: false), '').replaceAll('_', ' ');
      await _fromTracks(tracks, name.isEmpty ? 'Imported playlist' : name, MusicService.file);
    } catch (_) {
      if (mounted) setState(() => error = 'Couldn\'t read that file');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return SubPage(
      title: 'Import playlist',
      showProfile: false,
      slivers: [
        SliverList.list(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Text('Bring a playlist from any music app. Byte finds every song and saves it here.', style: BT.body.copyWith(color: p.secondary)),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(14)),
                padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                child: Row(
                  children: [
                    Icon(Icons.link_rounded, color: p.secondary),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: ctrl,
                        enabled: !busy,
                        minLines: 1,
                        maxLines: 3,
                        keyboardType: TextInputType.url,
                        textInputAction: TextInputAction.go,
                        onSubmitted: (_) => _fromLink(),
                        style: BT.body.copyWith(color: p.label),
                        decoration: InputDecoration(border: InputBorder.none, hintText: 'Paste a playlist or album link', hintStyle: BT.body.copyWith(color: p.secondary)),
                      ),
                    ),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              final d = await Clipboard.getData('text/plain');
                              final t = d?.text?.trim();
                              if (t != null && mounted) setState(() => ctrl.text = firstLink(t) ?? t);
                            },
                      child: Text('Paste', style: BT.bodyStrong.copyWith(color: p.accent)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Pressable(
                onTap: busy ? null : _fromLink,
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: busy ? p.fill : p.label, borderRadius: BorderRadius.circular(26)),
                  child: Text(busy ? 'Working…' : 'Import', style: BT.bodyStrong.copyWith(color: busy ? p.secondary : p.bg)),
                ),
              ),
            ),
            if (busy && status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 18, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(status!, style: BT.sub.copyWith(color: p.secondary)),
                    const SizedBox(height: 8),
                    ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: progress, minHeight: 5)),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => setState(() {
                          cancelled = true;
                          busy = false;
                          status = null;
                        }),
                        child: const Text('Cancel'),
                      ),
                    ),
                  ],
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Text(error!, style: BT.sub.copyWith(color: const Color(0xFFFF3B30))),
              ),
            if (error != null && _loginFor != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: FilledButton.icon(
                  key: const ValueKey('import-login-for-link'),
                  onPressed: () => Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute(builder: (_) => MusicAppLoginPage(service: _loginFor!, playlistUrl: _loginLink)),
                  ),
                  icon: const Icon(Icons.login_rounded),
                  label: Text('Log in to ${libSpec(_loginFor!, region: Services.i.settings.contentRegion).name}'),
                ),
              ),
            if (error != null && _errorDetail != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: const Key('import-copy-details'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: 'Byte import problem\n$_errorDetail'));
                    toast(context, 'Copied. Send it to the developer.');
                  },
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy details'),
                ),
              ),
            const GroupLabel('Works with'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in importServices)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(16)),
                      child: Text(s, style: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
            const GroupLabel('Log in to your music app'),
            GroupCard(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
                  child: Row(
                    children: [
                      MusicAppBadge(loginPick),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonHideUnderline(
                          child: DropdownButton<LibService>(
                            key: const ValueKey('import-login-picker'),
                            value: loginPick,
                            isExpanded: true,
                            items: [
                              for (final sp in libServices(region: Services.i.settings.contentRegion))
                                DropdownMenuItem(value: sp.service, child: Text(sp.name, style: BT.body.copyWith(color: p.label))),
                            ],
                            onChanged: busy ? null : (v) => setState(() => loginPick = v ?? loginPick),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: const ValueKey('import-login-button'),
                        onPressed: busy ? null : () => openMusicAppLogin(context, loginPick),
                        child: Text(musicAppConnected(loginPick) ? 'Sync' : 'Log in'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
              child: Text(
                libSpec(loginPick, region: Services.i.settings.contentRegion).note,
                key: const ValueKey('import-honest-note'),
                style: BT.sub.copyWith(color: p.secondary),
              ),
            ),
            const GroupLabel('No link?'),
            GroupCard(
              children: [
                GroupRow(icon: Icons.notes_rounded, title: 'Paste a list of songs', subtitle: 'One song per line, like "Tum Hi Ho - Arijit Singh"', chevron: true, enabled: !busy, onTap: busy ? null : _pasteList),
                GroupRow(icon: Icons.upload_file_rounded, title: 'Import a CSV or TXT file', subtitle: 'From any app or website that exports playlists', chevron: true, enabled: !busy, onTap: busy ? null : _pickFile),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
              child: Text(
                'Only the song names are read from the other app — no sign-in, and no music is taken from it. If an app has shut down, paste the same playlist from another app or use a CSV export.',
                style: BT.sub.copyWith(color: p.secondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// M3U playlists: "#EXTINF:123,Artist - Title" lines, or file names.
List<ExtTrack> parseM3u(String text) {
  final out = <ExtTrack>[];
  String? info;
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.startsWith('#EXTINF')) {
      info = line.substring(line.indexOf(',') + 1).trim();
    } else if (line.isNotEmpty && !line.startsWith('#')) {
      final name = info ?? line.split(RegExp(r'[\\/]')).last.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');
      out.addAll(parseTextList(name));
      info = null;
    }
  }
  return out;
}

class _PasteListScreen extends StatefulWidget {
  const _PasteListScreen();
  @override
  State<_PasteListScreen> createState() => _PasteListScreenState();
}

class _PasteListScreenState extends State<_PasteListScreen> {
  final ctrl = TextEditingController();
  bool _nudge = false;

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    final t = d?.text?.trim();
    if (t == null || t.isEmpty || !mounted) return;
    ctrl.text = ctrl.text.trim().isEmpty ? t : '${ctrl.text.trimRight()}\n$t';
    ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
    setState(() => _nudge = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final n = parseTextList(ctrl.text).length;
    return SubPage(
      title: 'Paste songs',
      showProfile: false,
      largeTitle: false,
      slivers: [
        SliverList.list(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: ctrl,
                autofocus: true,
                minLines: 10,
                maxLines: 18,
                onChanged: (_) => setState(() => _nudge = false),
                style: BT.body.copyWith(color: p.label),
                decoration: InputDecoration(
                  // Reads as an example, not as text already typed in.
                  hintText: 'Type or paste your songs here, one per line.\n\nFor example:\nTum Hi Ho - Arijit Singh\nKesariya - Pritam',
                  hintStyle: BT.body.copyWith(color: p.tertiary, fontStyle: FontStyle.italic),
                  filled: true,
                  fillColor: p.fill,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
              child: Row(
                children: [
                  TextButton.icon(onPressed: _paste, icon: const Icon(Icons.content_paste_rounded, size: 18), label: const Text('Paste')),
                  const Spacer(),
                  if (n > 0) Text(n == 1 ? '1 song' : '$n songs', style: BT.sub.copyWith(color: p.secondary)),
                ],
              ),
            ),
            if (_nudge)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 2, 24, 6),
                child: Text('Type at least one song first, like "Tum Hi Ho - Arijit Singh".', style: BT.sub.copyWith(color: p.accent)),
              ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Pressable(
                onTap: n == 0 ? () => setState(() => _nudge = true) : () => Navigator.pop(context, ctrl.text),
                child: Container(
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: n == 0 ? p.fill : p.label, borderRadius: BorderRadius.circular(26)),
                  child: Text(n == 0 ? 'Find songs' : 'Find $n songs', style: BT.bodyStrong.copyWith(color: n == 0 ? p.secondary : p.bg)),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Check what was found, fix the misses, then save.
class ImportReviewScreen extends StatefulWidget {
  final ExtList list;
  final List<TrackMatch> matches;
  const ImportReviewScreen({super.key, required this.list, required this.matches});
  @override
  State<ImportReviewScreen> createState() => _ImportReviewScreenState();
}

class _ImportReviewScreenState extends State<ImportReviewScreen> {
  late final name = TextEditingController(text: widget.list.name);
  int filter = 0; // 0 all, 1 found, 2 not found
  bool saving = false;

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final all = widget.matches;
    final found = all.where((m) => m.matched).length;
    final shown = switch (filter) {
      1 => all.where((m) => m.matched).toList(),
      2 => all.where((m) => !m.matched).toList(),
      _ => all,
    };
    final l = widget.list;
    return SubPage(
      title: 'Review import',
      showProfile: false,
      largeTitle: false,
      actions: [
        Pressable(
          onTap: found == 0 || saving ? null : _save,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(color: found == 0 ? p.fill : p.label, borderRadius: BorderRadius.circular(18)),
            child: Text(saving ? 'Saving…' : 'Save', style: BT.bodyStrong.copyWith(color: found == 0 ? p.secondary : p.bg)),
          ),
        ),
      ],
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 84,
                    height: 84,
                    child: l.cover != null ? Artwork(l.cover, size: 84, radius: 10) : ColoredBox(color: p.fill, child: Icon(Icons.queue_music_rounded, color: p.secondary, size: 38)),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: name,
                        style: BT.title3.copyWith(color: p.label, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(isDense: true, border: InputBorder.none, hintText: 'Playlist name'),
                      ),
                      Text('$found of ${all.length} found', style: BT.sub.copyWith(color: p.secondary)),
                      Text('From ${serviceName(l.service)}', style: BT.caption.copyWith(color: p.tertiary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (l.partial)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'The app showed ${l.tracks.length} of its ${l.total} songs. For the rest, export the playlist as a CSV and import the file.',
                style: BT.sub.copyWith(color: const Color(0xFFFF9500)),
              ),
            ),
          ),
        if (all.any((m) => m.failed))
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${all.where((m) => m.failed).length} songs couldn\'t be checked (connection problem).',
                      style: BT.sub.copyWith(color: const Color(0xFFFF9500)),
                    ),
                  ),
                  TextButton(onPressed: retrying ? null : _retryFailed, child: Text(retrying ? 'Trying…' : 'Try again')),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: SegmentedPill(labels: ['All ${all.length}', 'Found $found', 'Not found ${all.length - found}'], index: filter, onChanged: (i) => setState(() => filter = i)),
          ),
        ),
        if (shown.isEmpty) SliverToBoxAdapter(child: EmptyNote(filter == 2 ? 'Every song was found.' : 'Nothing here.')),
        SliverList.builder(
          itemCount: shown.length,
          itemBuilder: (c, i) => _MatchRow(
            m: shown[i],
            onTap: () async {
              await showRepickSheet(context, shown[i]);
              if (mounted) setState(() {});
            },
          ),
        ),
      ],
    );
  }

  bool retrying = false;
  Future<void> _retryFailed() async {
    setState(() => retrying = true);
    final m = PlaylistMatcher(Services.i.yt);
    for (final t in widget.matches.where((x) => x.failed).toList()) {
      await m.matchOne(t);
      if (!mounted) return;
      setState(() {});
    }
    if (mounted) setState(() => retrying = false);
  }

  Future<void> _save() async {
    setState(() => saving = true);
    final items = <Item>[];
    final seen = <String>{};
    for (final m in widget.matches) {
      final c = m.chosen;
      if (c != null && seen.add(c.id)) items.add(c);
    }
    final pl = await Services.i.library.createPlaylist(name.text.trim().isEmpty ? widget.list.name : name.text.trim(), items: items, source: widget.list.sourceKey, cover: widget.list.cover);
    if (!mounted) return;
    toast(context, 'Saved ${items.length} songs to "${pl.name}"');
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => PlaylistScreen(id: pl.id)));
  }
}

class _MatchRow extends StatelessWidget {
  final TrackMatch m;
  final VoidCallback onTap;
  const _MatchRow({required this.m, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final c = m.chosen;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 10, 6),
        child: Row(
          children: [
            c == null
                ? Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(6)),
                    child: Icon(Icons.help_outline_rounded, color: p.secondary),
                  )
                : Artwork(c.thumb, size: 50, radius: 6),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c?.title ?? m.source.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: BT.body.copyWith(color: c == null ? p.secondary : p.label)),
                  Text(
                    c == null ? 'Not found · ${m.source.artists}' : '${c.artistLine} · from "${m.source.title}"',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BT.sub.copyWith(color: p.secondary),
                  ),
                ],
              ),
            ),
            Icon(c == null ? Icons.search_rounded : Icons.check_circle_rounded, color: c == null ? const Color(0xFFFF9500) : const Color(0xFF34C759), size: 22),
          ],
        ),
      ),
    );
  }
}

/// Pick the right YouTube Music song for one imported song (or skip it).
Future<void> showRepickSheet(BuildContext context, TrackMatch m) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  useRootNavigator: true, // above the mini player + tab bar (1.4.2)
  builder: (ctx) => _Repick(m: m),
);

class _Repick extends StatefulWidget {
  final TrackMatch m;
  const _Repick({required this.m});
  @override
  State<_Repick> createState() => _RepickState();
}

class _RepickState extends State<_Repick> {
  late final q = TextEditingController(text: widget.m.source.query);
  bool loading = false;

  Future<void> _search() async {
    setState(() => loading = true);
    try {
      final r = await Services.i.yt.search(q.text.trim(), SearchFilter.songs);
      widget.m.candidates = r.where((i) => i.isPlayable).take(12).toList();
    } catch (_) {}
    if (mounted) setState(() => loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final m = widget.m;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.95,
        builder: (context, sc) => ListView(
          controller: sc,
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.source.title, style: BT.title3.copyWith(color: p.label, fontWeight: FontWeight.w700)),
                  if (m.source.artists.isNotEmpty) Text(m.source.artists, style: BT.sub.copyWith(color: p.secondary)),
                  if (m.source.album != null) Text(m.source.album!, style: BT.caption.copyWith(color: p.tertiary)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: q,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded),
                      hintText: 'Search songs',
                      filled: true,
                      fillColor: p.fill,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                    ),
                  ),
                ],
              ),
            ),
            if (loading) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
            for (final c in m.candidates)
              ListTile(
                leading: Artwork(c.thumb, size: 46, radius: 6),
                title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${c.artistLine}${c.durationSec != null ? ' · ${fmtDuration(c.durationSec!)}' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: c.id == m.chosen?.id ? Icon(Icons.check_rounded, color: p.accent) : IconButton(tooltip: 'Preview', icon: const Icon(Icons.play_arrow_rounded), onPressed: () => Services.i.player.playItems([c])),
                onTap: () {
                  m.chosen = c;
                  Navigator.pop(context);
                },
              ),
            if (!loading && m.candidates.isEmpty) const EmptyNote('No results. Try different words.'),
            ListTile(
              leading: const Icon(Icons.remove_circle_outline_rounded, color: Color(0xFFFF3B30)),
              title: const Text('Don\'t add this song'),
              onTap: () {
                m.chosen = null;
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}
