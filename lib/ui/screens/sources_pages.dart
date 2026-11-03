import 'package:flutter/material.dart';

import '../../data/addons.dart';
import '../../data/smb_source.dart';
import '../../services.dart';
import '../nav.dart';
import '../page.dart';
import '../style.dart';
import '../widgets.dart';
import 'library_pages.dart' show confirm;

Widget _note(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
  child: Text(text, style: BT.sub.copyWith(color: BytePalette.of(context).secondary)),
);

Widget _field(BuildContext context, TextEditingController c, String hint, {bool secret = false, TextInputType? type}) {
  final p = BytePalette.of(context);
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    child: TextField(
      controller: c,
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

// ── Addons ───────────────────────────────────────────────────────────────

/// Your addons: servers you run or trust that search, stream and serve lyrics.
class AddonsScreen extends StatefulWidget {
  const AddonsScreen({super.key});
  @override
  State<AddonsScreen> createState() => _AddonsScreenState();
}

class _AddonsScreenState extends State<AddonsScreen> {
  final link = TextEditingController();
  final key = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void dispose() {
    link.dispose();
    key.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final l = link.text.trim();
    if (l.isEmpty) {
      setState(() => error = 'Paste the addon\'s link first');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final a = await Services.i.addons.add(l, token: key.text.trim().isEmpty ? null : key.text.trim());
      link.clear();
      key.clear();
      if (mounted) toast(context, '${a.name} added');
    } on AddonProblem catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Couldn\'t reach that addon. Check the link.';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final ad = Services.i.addons;
    final p = BytePalette.of(context);
    return ListenableBuilder(
      listenable: ad,
      builder: (context, _) => SubPage(capWidth: true, 
        title: 'Addons',
        showProfile: false,
        slivers: [
          SliverList.list(
            children: [
              if (ad.all.isNotEmpty) ...[
                const GroupLabel('Your addons'),
                GroupCard(
                  children: [
                    for (final a in ad.all)
                      GroupRow(
                        icon: Icons.extension_rounded,
                        title: a.name,
                        subtitle: [a.base.host, ...a.resources].join(' · '),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ByteSwitch(value: a.enabled, onChanged: (v) => ad.setEnabled(a.id, v)),
                            IconButton(
                              tooltip: 'Remove ${a.name}',
                              icon: Icon(Icons.delete_outline_rounded, color: p.secondary),
                              onPressed: () async {
                                final ok = await confirm(context, 'Remove ${a.name}?', 'Songs from it in your library will stop playing.', action: 'Remove');
                                if (ok) await ad.remove(a.id);
                              },
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              const GroupLabel('Add an addon'),
              GroupCard(
                children: [
                  _field(context, link, 'Addon link (https://…/manifest.json)', type: TextInputType.url),
                  _field(context, key, 'Key (only if the addon needs one)', secret: true),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Text(error!, style: BT.sub.copyWith(color: p.accent)),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: FilledButton(
                        onPressed: busy ? null : _add,
                        child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add addon'),
                      ),
                    ),
                  ),
                ],
              ),
              _note(
                context,
                'Byte comes with no addons. An addon is a server you run or trust (for example on your NAS) that searches your music, '
                'streams it and can serve lyrics. Its songs show up under Search → Addons. Lossless and spatial surround badges appear only when the addon says a file really is one.',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── SMB ─────────────────────────────────────────────────────────────────

/// A Windows / NAS shared folder on your Wi-Fi: connect, browse, play.
class SmbScreen extends StatefulWidget {
  const SmbScreen({super.key});
  @override
  State<SmbScreen> createState() => _SmbScreenState();
}

class _SmbScreenState extends State<SmbScreen> {
  final smb = Services.i.smb;
  late final host = TextEditingController(text: smb.host);
  late final user = TextEditingController(text: smb.user);
  final pass = TextEditingController();
  late final domain = TextEditingController(text: smb.domain);
  bool busy = false;
  String? error;
  String path = '';
  List<SmbEntry>? entries;

  @override
  void initState() {
    super.initState();
    if (smb.configured) _open('');
  }

  @override
  void dispose() {
    for (final c in [host, user, pass, domain]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    if (host.text.trim().isEmpty) {
      setState(() => error = 'Type the computer or NAS name, like 192.168.1.10');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final shares = await smb.connect(host.text.trim(), user.text.trim(), pass.text, domain: domain.text.trim());
      pass.clear();
      if (!mounted) return;
      setState(() {
        path = '';
        entries = shares;
      });
    } on SmbProblem catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Couldn\'t connect. Check the name, user and password.';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _open(String p) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final e = p.isEmpty ? await smb.shares() : await smb.list(p);
      if (!mounted) return;
      setState(() {
        path = p;
        entries = e;
      });
    } on SmbProblem catch (e) {
      error = e.message;
    } catch (_) {
      error = 'Couldn\'t open that folder';
    }
    if (mounted) setState(() => busy = false);
  }

  String get _up {
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length <= 1) return '';
    return '/${segs.sublist(0, segs.length - 1).join('/')}';
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final es = entries;
    final songs = (es ?? const <SmbEntry>[]).where((e) => e.isAudio).map(SmbSource.itemFor).toList();
    return SubPage(capWidth: true, 
      title: 'SMB',
      showProfile: false,
      slivers: [
        SliverList.list(
          children: [
            if (!smb.configured || es == null) ...[
              const GroupLabel('Shared folder'),
              GroupCard(
                children: [
                  _field(context, host, 'Computer or NAS (name or IP)', type: TextInputType.url),
                  _field(context, user, 'User name (empty for guest)'),
                  _field(context, pass, 'Password', secret: true),
                  _field(context, domain, 'Workgroup / domain (optional)'),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: FilledButton(
                        onPressed: busy ? null : _connect,
                        child: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Connect'),
                      ),
                    ),
                  ),
                ],
              ),
            ] else ...[
              GroupCard(
                children: [
                  GroupRow(icon: Icons.dns_rounded, title: smb.host, subtitle: path.isEmpty ? 'Shares' : path),
                  if (path.isNotEmpty) GroupRow(icon: Icons.arrow_upward_rounded, title: 'Up', onTap: () => _open(_up)),
                  if (songs.isNotEmpty)
                    GroupRow(
                      icon: Icons.play_arrow_rounded,
                      title: 'Play ${songs.length} songs in this folder',
                      onTap: () => Services.i.player.playItems(songs, from: path.split('/').last),
                    ),
                  GroupRow(
                    icon: Icons.logout_rounded,
                    title: 'Forget this server',
                    titleColor: const Color(0xFFFF3B30),
                    onTap: () async {
                      await smb.forget();
                      if (mounted) setState(() => entries = null);
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (busy) const LoadingList(rows: 4),
              if (!busy)
                GroupCard(
                  children: [
                    if (es.isEmpty) GroupRow(title: 'Nothing here', subtitle: 'No folders or music files'),
                    for (final e in es.where((e) => e.folder || e.isAudio))
                      e.folder
                          ? GroupRow(icon: Icons.folder_rounded, title: e.name, chevron: true, onTap: () => _open(e.path))
                          : GroupRow(
                              icon: Icons.music_note_rounded,
                              title: SmbSource.itemFor(e).title,
                              subtitle: [SmbSource.itemFor(e).artistLine, e.name.split('.').last.toUpperCase()].where((x) => x.isNotEmpty).join(' · '),
                              onTap: () => Services.i.player.playItems(
                                songs,
                                start: songs.indexWhere((s) => s.id.endsWith(e.path)).clamp(0, songs.length),
                                from: path.split('/').last,
                              ),
                            ),
                  ],
                ),
            ],
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
                child: Text(error!, style: BT.sub.copyWith(color: p.accent)),
              ),
            _note(
              context,
              'Plays music straight from a shared folder on your Wi-Fi (Windows, Mac, NAS). Nothing is copied to the phone. The password stays on this phone only.',
            ),
          ],
        ),
      ],
    );
  }
}

/// Opens the addons page (used by Search → Addons when there are none yet).
void openAddons(BuildContext context) => pushPage(context, const AddonsScreen());
