import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/listen_together.dart';
import '../../services.dart';
import '../account_ui.dart';
import '../page.dart';
import '../style.dart';
import '../widgets.dart';
import '../glass.dart';
import '../party_sound_section.dart';

String partyLink(String code) => 'byte://listen/$code';

/// Settings → Listen together: start or join a party, then the room page.
class ListenTogetherScreen extends StatefulWidget {
  /// Opened from a byte://listen/CODE link: join this code.
  final String? joinCode;
  const ListenTogetherScreen({super.key, this.joinCode});
  @override
  State<ListenTogetherScreen> createState() => _ListenTogetherScreenState();
}

class _ListenTogetherScreenState extends State<ListenTogetherScreen> {
  @override
  void initState() {
    super.initState();
    final c = widget.joinCode;
    if (c != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final party = Services.i.party;
        if (party.code == ListenTogether.normaliseCode(c)) return;
        if (party.active) {
          final ok = await _ask(context, 'Join party $c?', 'You will leave the party you are in now.');
          if (!ok) return;
        }
        await party.join(c);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    final party = s.party;
    return ListenableBuilder(
      listenable: Listenable.merge([party, s.player.current, s.settings]),
      builder: (context, _) {
        final p = BytePalette.of(context);
        final rtt = party.roundTripMs;
        return SubPage(capWidth: true, 
          title: 'Listen together',
          showProfile: false,
          largeTitle: party.active,
          actions: [
            if (party.active)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(16)),
                child: Text(
                  rtt == null ? (party.connected ? '— ms' : 'Offline') : '$rtt ms',
                  style: BT.sub.copyWith(color: p.secondary, fontWeight: FontWeight.w600),
                ),
              ),
          ],
          slivers: [SliverList.list(children: party.active ? _room(context, party, p) : _lobby(context, party, p))],
        );
      },
    );
  }

  // ── Not in a party ──────────────────────────────────────────────────────
  List<Widget> _lobby(BuildContext context, ListenTogether party, BytePalette p) => [
    const SizedBox(height: 18),
    Center(
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [BoxShadow(color: p.accent.withValues(alpha: 0.25), blurRadius: 40, spreadRadius: 4)],
        ),
        child: AccountAvatar(account: Services.i.account.active, size: 112),
      ),
    ),
    const SizedBox(height: 22),
    Text('Start a party', textAlign: TextAlign.center, style: BT.largeTitle.copyWith(color: p.label, fontSize: 30)),
    Padding(
      padding: const EdgeInsets.fromLTRB(32, 10, 32, 26),
      child: Text(
        'Music is better together. Invite friends and everyone hears the same song at the same moment, wherever they are.',
        textAlign: TextAlign.center,
        style: BT.body.copyWith(color: p.secondary),
      ),
    ),
    if (party.error != null)
      Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 16),
        child: Text(party.error!, textAlign: TextAlign.center, style: BT.sub.copyWith(color: const Color(0xFFFF3B30))),
      ),
    if (party.saved != null) PartyResumeCard(party: party), // 1.4.3
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: _BigButton(
        label: party.connecting ? 'Connecting…' : 'Create a party',
        onTap: party.connecting ? null : () => _createSheet(context),
      ),
    ),
    const SizedBox(height: 6),
    Center(
      child: TextButton(
        onPressed: party.connecting ? null : () => _joinSheet(context),
        child: Text('Join existing', style: BT.body.copyWith(color: p.secondary, fontWeight: FontWeight.w600)),
      ),
    ),
    const GroupLabel('Use your own server'),
    _serverCard(context, enabled: true),
    _foot(context, 'Leave this empty to use Byte\'s server. If you run your own, everyone in the party has to use the same one.'),
  ];

  Widget _serverCard(BuildContext context, {required bool enabled}) {
    final st = Services.i.settings;
    return GroupCard(
      children: [
        GroupRow(
          icon: Icons.dns_outlined,
          title: 'Use your own server',
          subtitle: st.ltServerUrl.isEmpty ? 'Using the default server' : st.ltServerUrl,
          chevron: true,
          enabled: enabled,
          onTap: enabled ? () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PartyServerScreen())) : null,
        ),
      ],
    );
  }

  Future<void> _createSheet(BuildContext context) async {
    final st = Services.i.settings;
    final name = TextEditingController(text: st.listenName.isNotEmpty ? st.listenName : (Services.i.account.name ?? ''));
    var size = 5;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true, // above the mini player + tab bar (1.4.2)
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) {
          final p = BytePalette.of(ctx);
          return _Sheet(
            children: [
              Text('Create a party', textAlign: TextAlign.center, style: BT.title2.copyWith(color: p.label)),
              const SizedBox(height: 6),
              Text('Pick how you\'ll show up, and how many can join.', textAlign: TextAlign.center, style: BT.sub.copyWith(color: p.secondary, fontSize: 15)),
              const SizedBox(height: 20),
              Row(
                children: [
                  AccountAvatar(account: Services.i.account.active, size: 44),
                  const SizedBox(width: 12),
                  Expanded(child: _Field(controller: name, hint: 'Your name')),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Party size', style: BT.body.copyWith(color: p.label)),
                        Text('Choose 2–10 listeners', style: BT.sub.copyWith(color: p.secondary)),
                      ],
                    ),
                  ),
                  Stepper2(value: size, min: 2, max: 10, onChanged: (v) => setS(() => size = v)),
                ],
              ),
              const SizedBox(height: 22),
              _BigButton(label: 'Create', onTap: () => Navigator.pop(ctx, true)),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    st.listenName = name.text.trim();
    await Services.i.party.host(capacity: size);
  }

  Future<void> _joinSheet(BuildContext context) async {
    final st = Services.i.settings;
    final code = TextEditingController();
    final name = TextEditingController(text: st.listenName.isNotEmpty ? st.listenName : (Services.i.account.name ?? ''));
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true, // above the mini player + tab bar (1.4.2)
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final p = BytePalette.of(ctx);
        return _Sheet(
          children: [
            Text('Join a party', textAlign: TextAlign.center, style: BT.title2.copyWith(color: p.label)),
            const SizedBox(height: 6),
            Text('Type the 6-character code the host shared.', textAlign: TextAlign.center, style: BT.sub.copyWith(color: p.secondary, fontSize: 15)),
            const SizedBox(height: 20),
            _Field(
              controller: code,
              hint: 'Party code',
              big: true,
              autofocus: true,
              caps: true,
              onSubmitted: (_) => Navigator.pop(ctx, true),
            ),
            const SizedBox(height: 12),
            _Field(controller: name, hint: 'Your name'),
            const SizedBox(height: 22),
            _BigButton(label: 'Join', onTap: () => Navigator.pop(ctx, true)),
          ],
        );
      },
    );
    if (ok != true || code.text.trim().isEmpty) return;
    st.listenName = name.text.trim();
    await Services.i.party.join(code.text);
  }

  // ── In a party ──────────────────────────────────────────────────────────
  List<Widget> _room(BuildContext context, ListenTogether party, BytePalette p) {
    final code = party.code ?? '';
    final s = Services.i;
    final it = party.last?.item ?? s.player.current.value;
    final pos = s.player.position;
    String mmss(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    final syncLine = !party.connected
        ? 'Reconnecting…'
        : party.hostAway
        ? '${party.hostName ?? 'The host'} is away · the party carries on'
        : (party.roundTripMs == null ? 'In sync' : 'In sync · ${party.roundTripMs} ms round trip');
    final me = s.settings.deviceId;
    return [
      const GroupLabel('Party code'),
      GroupCard(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                code.split('').join(' '),
                style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700, letterSpacing: 4, color: p.label, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
          ),
          GroupRow(
            icon: Icons.copy_rounded,
            title: 'Copy code',
            chevron: true,
            onTap: () {
              Clipboard.setData(ClipboardData(text: code));
              toast(context, 'Code copied');
            },
          ),
          GroupRow(icon: Icons.ios_share_rounded, title: 'Share', chevron: true, onTap: () => _shareSheet(context, code)),
        ],
      ),
      _foot(context, 'Read it out or send it. Codes never use the letters O or I, so an "oh" is always a zero.'),
      const GroupLabel('Now playing'),
      GroupCard(
        children: [
          GroupRow(
            icon: Icons.music_note_rounded,
            title: it?.title ?? 'Nothing playing yet',
            subtitle: it == null ? syncLine : '${it.artistLine} · ${mmss(pos)}${it.durationSec != null ? ' / ${mmss(Duration(seconds: it.durationSec!))}' : ''}',
          ),
          if (it != null)
            GroupRow(
              leading: Icon(party.connected && !party.hostAway ? Icons.check_circle_rounded : Icons.sync_problem_rounded, color: party.connected && !party.hostAway ? const Color(0xFF34C759) : const Color(0xFFFF9500)),
              title: syncLine,
              value: 'Re-sync',
              onTap: party.resync,
            ),
        ],
      ),
      GroupLabel('Listening · ${party.people.length} of ${party.capacity}'),
      GroupCard(
        dividerIndent: 64,
        children: [
          if (party.isHost) ...[
            GroupRow(
              icon: Icons.groups_rounded,
              title: 'Party size',
              subtitle: 'Only you can change capacity or remove listeners',
              trailing: Stepper2(value: party.capacity, min: 2, max: 10, onChanged: party.setCapacity),
            ),
            GroupRow(
              icon: Icons.lock_outline_rounded,
              title: 'Only I control the music',
              subtitle: 'Everyone else listens along and can pause on their own phone',
              trailing: ByteSwitch(value: party.hostOnly, onChanged: party.setHostOnly),
            ),
          ] else if (party.hostOnly)
            const GroupRow(icon: Icons.lock_outline_rounded, title: 'The host controls the music', subtitle: 'You can still pause on your own phone'),
          for (final m in party.people)
            GroupRow(
              leading: _Initial(m.name),
              title: m.name.isEmpty ? 'Listener' : m.name,
              badge: m.id == me ? const Badge2('YOU') : null,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (m.host) const Badge2('HOST'),
                  if (party.isHost && !m.host && m.id != me)
                    IconButton(
                      tooltip: 'Remove from party',
                      icon: Icon(Icons.person_remove_outlined, color: p.secondary),
                      onPressed: () async {
                        final ok = await _ask(context, 'Remove ${m.name}?', 'They leave the party. They can join again with the code.');
                        if (ok) await party.remove(m.id);
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
      _foot(context, party.hostOnly ? 'A party holds ${party.capacity} phones. Only the host can change the music.' : 'A party holds ${party.capacity} phones. Anyone in it can control the music.'),
      PartySoundSection(sound: s.partySound), // 1.4.2: the host's sound
      const SizedBox(height: 18),
      PartyEndCard(party: party), // 1.4.3: only the host's "End party" ends it
      const GroupLabel('Recent activity'),
      GroupCard(
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 140),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: party.activity.isEmpty
                  ? Text('Nothing yet', style: BT.sub.copyWith(color: p.secondary))
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final a in party.activity.take(100))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(a.line, style: TextStyle(fontSize: 13.5, height: 1.3, color: p.label, fontFeatures: const [FontFeature.tabularFigures()])),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
      _foot(context, 'This session only · latest first · up to 100 actions'),
      const GroupLabel('Use your own server'),
      _serverCard(context, enabled: false),
      _foot(context, 'Leave the party to change the server.'),
    ];
  }

  Future<void> _shareSheet(BuildContext context, String code) async {
    final link = partyLink(code);
    final text = 'Listen with me on Byte! Open Byte → Settings → Listen together → Join existing, and type $code\n$link';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      useRootNavigator: true, // above the mini player + tab bar (1.4.2)
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final p = BytePalette.of(ctx);
        return _Sheet(
          children: [
            Text('Invite friends to your party', textAlign: TextAlign.center, style: BT.title2.copyWith(color: p.label)),
            const SizedBox(height: 6),
            Text('They scan this with their camera, or open the link on a phone with Byte.', textAlign: TextAlign.center, style: BT.sub.copyWith(color: p.secondary, fontSize: 15)),
            const SizedBox(height: 18),
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)),
                child: QrImageView(data: link, size: 200, backgroundColor: Colors.white, eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Colors.black), dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Colors.black)),
              ),
            ),
            const SizedBox(height: 10),
            Text(code.split('').join(' '), textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, letterSpacing: 3, color: p.label)),
            const SizedBox(height: 18),
            _BigButton(
              label: 'Share link',
              icon: Icons.link_rounded,
              onTap: () {
                final box = ctx.findRenderObject() as RenderBox?;
                SharePlus.instance.share(ShareParams(text: text, subject: 'Byte party $code', sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size));
              },
            ),
          ],
        );
      },
    );
  }
}

Widget _foot(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
  child: Text(text, style: BT.sub.copyWith(color: BytePalette.of(context).secondary)),
);

Future<bool> _ask(BuildContext context, String title, String body, {String ok = 'OK'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok)),
        ],
      ),
    ) ==
    true;

class _Initial extends StatelessWidget {
  final String name;
  const _Initial(this.name);
  @override
  Widget build(BuildContext context) {
    final letter = name.trim().isEmpty ? '?' : name.trim().characters.first.toUpperCase();
    final hue = (name.hashCode % 360).abs().toDouble();
    return CircleAvatar(
      radius: 18,
      backgroundColor: HSLColor.fromAHSL(1, hue, 0.35, 0.55).toColor(),
      child: Text(letter, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
    );
  }
}

class _Sheet extends StatelessWidget {
  final List<Widget> children;
  const _Sheet({required this.children});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(color: p.bg, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
        padding: const EdgeInsets.fromLTRB(22, 10, 22, 22),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(width: 36, height: 5, decoration: BoxDecoration(color: p.separator, borderRadius: BorderRadius.circular(3))),
                ),
                const SizedBox(height: 18),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool big;
  final bool autofocus;
  final bool caps;
  final ValueChanged<String>? onSubmitted;
  const _Field({required this.controller, required this.hint, this.big = false, this.autofocus = false, this.caps = false, this.onSubmitted});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return TextField(
      controller: controller,
      autofocus: autofocus,
      textAlign: big ? TextAlign.center : TextAlign.start,
      textCapitalization: caps ? TextCapitalization.characters : TextCapitalization.words,
      maxLength: big ? 6 : 40,
      onSubmitted: onSubmitted,
      style: big ? TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: 6, color: p.label) : BT.body.copyWith(color: p.label),
      decoration: InputDecoration(
        counterText: '',
        hintText: hint,
        hintStyle: (big ? const TextStyle(fontSize: 22, letterSpacing: 1) : BT.body).copyWith(color: p.secondary),
        filled: true,
        fillColor: p.fill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  const _BigButton({required this.label, this.icon, this.onTap});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final on = onTap != null;
    return Pressable(
      onTap: onTap,
      child: Container(
        height: 56,
        decoration: BoxDecoration(color: on ? p.label : p.fill, borderRadius: BorderRadius.circular(28)),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[Icon(icon, color: on ? p.bg : p.secondary, size: 20), const SizedBox(width: 8)],
            Text(label, style: BT.bodyStrong.copyWith(color: on ? p.bg : p.secondary)),
          ],
        ),
      ),
    );
  }
}

/// − n + stepper.
class Stepper2 extends StatelessWidget {
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;
  const Stepper2({super.key, required this.value, required this.min, required this.max, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    Widget b(IconData i, bool on, int to) => IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(i, color: on ? p.label : p.tertiary),
      onPressed: on
          ? () {
              HapticFeedback.selectionClick();
              onChanged(to);
            }
          : null,
    );
    return Container(
      decoration: BoxDecoration(color: p.fill, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          b(Icons.remove_rounded, value > min, value - 1),
          SizedBox(width: 22, child: Text('$value', textAlign: TextAlign.center, style: BT.bodyStrong.copyWith(color: p.label))),
          b(Icons.add_rounded, value < max, value + 1),
        ],
      ),
    );
  }
}

/// Use your own Supabase project for Listen together.
class PartyServerScreen extends StatefulWidget {
  const PartyServerScreen({super.key});
  @override
  State<PartyServerScreen> createState() => _PartyServerScreenState();
}

class _PartyServerScreenState extends State<PartyServerScreen> {
  late final url = TextEditingController(text: Services.i.settings.ltServerUrl);
  late final key = TextEditingController(text: Services.i.settings.ltServerKey);
  String? err;

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    return SubPage(capWidth: true, 
      title: 'Your own server',
      showProfile: false,
      slivers: [
        SliverList.list(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Field(controller: url, hint: 'https://your-project.supabase.co'),
                  const SizedBox(height: 10),
                  _Field(controller: key, hint: 'Publishable (anon) key'),
                  if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: BT.sub.copyWith(color: const Color(0xFFFF3B30)))),
                  const SizedBox(height: 16),
                  _BigButton(
                    label: 'Save',
                    onTap: () {
                      final u = url.text.trim();
                      final k = key.text.trim();
                      if (u.isNotEmpty && (!u.startsWith('https://') && !u.startsWith('http://') || k.isEmpty)) {
                        setState(() => err = 'Enter the project URL (https://…) and its publishable key, or leave both empty.');
                        return;
                      }
                      Services.i.settings
                        ..ltServerUrl = u
                        ..ltServerKey = k;
                      Services.i.party.resetClient();
                      Navigator.pop(context);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () {
                      url.clear();
                      key.clear();
                      Services.i.settings
                        ..ltServerUrl = ''
                        ..ltServerKey = '';
                      Services.i.party.resetClient();
                      Navigator.pop(context);
                    },
                    child: Text('Use the default server', style: BT.body.copyWith(color: p.secondary)),
                  ),
                ],
              ),
            ),
            _foot(context, 'Run Byte\'s server setup file once in your server\'s SQL editor first. Everyone in a party must use the same server.'),
          ],
        ),
      ],
    );
  }
}

/// 1.4.3: the way out of a party. A guest leaves on his own; only the host
/// ends it for everyone (after "End the party for everyone?").
class PartyEndCard extends StatelessWidget {
  final ListenTogether party;
  const PartyEndCard({super.key, required this.party});
  @override
  Widget build(BuildContext context) {
    final host = party.isHost;
    return GroupCard(
      children: [
        if (!host)
          GroupRow(
            icon: Icons.logout_rounded,
            title: 'Leave party',
            subtitle: 'Only you leave. The party carries on for everyone else',
            chevron: true,
            onTap: () async {
              final ok = await _ask(context, 'Leave the party?', 'Only you leave. The others keep listening, and your music keeps playing on your own.', ok: 'Leave');
              if (ok) await party.leave();
            },
          ),
        if (party.canEndForAll)
          GroupRow(
            icon: Icons.stop_circle_outlined,
            title: 'End party',
            subtitle: 'Ends it for everyone',
            chevron: true,
            onTap: () async {
              final ok = await _ask(context, 'End the party for everyone?', 'Everyone is taken out of the party. Their music keeps playing on their own.', ok: 'End party');
              if (ok) await party.endParty();
            },
          ),
      ],
    );
  }
}

/// 1.4.3: the app was closed or killed while in a party: go back into it.
class PartyResumeCard extends StatelessWidget {
  final ListenTogether party;
  const PartyResumeCard({super.key, required this.party});
  @override
  Widget build(BuildContext context) {
    final s = party.saved;
    if (s == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: GroupCard(
        children: [
          GroupRow(
            icon: Icons.play_circle_outline_rounded,
            title: s.host ? 'Resume your party' : 'Rejoin party ${s.code}',
            subtitle: s.host ? 'Code ${s.code} · you\'re the host. It kept going while you were away' : (s.hostName == null || s.hostName!.isEmpty ? 'Go back in where the music is' : '${s.hostName}\'s party · go back in where the music is'),
            chevron: true,
            enabled: !party.connecting,
            onTap: party.connecting ? null : party.resume,
          ),
          GroupRow(
            icon: Icons.close_rounded,
            title: s.host ? 'End it instead' : 'Forget it',
            chevron: false,
            enabled: !party.connecting,
            onTap: party.connecting
                ? null
                : () async {
                    if (!s.host) return party.forgetSaved();
                    final ok = await _ask(context, 'End the party for everyone?', 'Everyone still in it is taken out.', ok: 'End party');
                    if (!ok) return;
                    if (await party.resume()) await party.endParty();
                    party.forgetSaved();
                  },
          ),
        ],
      ),
    );
  }
}
