import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase/supabase.dart' show AuthException;

import '../../data/cloud_sync.dart';
import '../../services.dart';
import '../page.dart';
import 'login_screen.dart';
import '../glass.dart';
import '../style.dart';
import '../widgets.dart';

/// Settings → Byte account & sync: sign in with the Gmail address, and
/// everything made in Byte is the same on every device signed in to it.
class SyncScreen extends StatefulWidget {
  /// Which way in shows first: a new account (the default), log in, or a code.
  final SyncStart startWith;
  const SyncScreen({super.key, this.startWith = SyncStart.create});
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

enum _Mode { create, password, code }

/// The first tab of the sign-in screen.
enum SyncStart { create, login, code }

class _SyncScreenState extends State<SyncScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _pw = TextEditingController();
  final _pw2 = TextEditingController();
  final _name = TextEditingController();
  late _Mode _mode = switch (widget.startWith) {
    SyncStart.create => _Mode.create,
    SyncStart.login => _Mode.password,
    SyncStart.code => _Mode.code,
  };
  bool _codeSent = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // the Google account already used for YouTube Music
    final g = Services.i.account.active?.email;
    if (g != null && g.contains('@')) _email.text = g;
    final n = Services.i.account.active?.name;
    if (n != null && n.trim().isNotEmpty && !n.contains('@')) _name.text = n;
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    _pw.dispose();
    _pw2.dispose();
    _name.dispose();
    super.dispose();
  }

  bool get _emailOk => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(_email.text.trim());

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await f();
    } on AuthException catch (e) {
      _error = friendlyAuthError(e.message);
    } on FormatException {
      _error = "That doesn't look like the sign-in link from the email.";
    } catch (e) {
      _error = 'No connection to the sync server. Check the internet and try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _sendCode() => _run(() async {
    await Services.i.cloud.sendCode(_email.text);
    _codeSent = true;
  });

  Future<void> _pasteLink() => _run(() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    await Services.i.cloud.verifyLink(d?.text ?? '');
  });

  @override
  Widget build(BuildContext context) {
    final s = Services.i;
    return ListenableBuilder(
      listenable: Listenable.merge([s.cloud, s.sync, s.sync.remoteNow, s.account]),
      builder: (context, _) => SubPage(capWidth: true, 
        title: 'Byte account & sync',
        showProfile: false,
        slivers: [SliverToBoxAdapter(child: s.cloud.signedIn ? _signedIn(context) : _signIn(context))],
      ),
    );
  }

  Widget _field(TextEditingController c, String hint, {Key? key, bool obscure = false, TextInputType? type, bool big = false}) {
    final p = BytePalette.of(context);
    return TextField(
      key: key,
      controller: c,
      obscureText: obscure,
      keyboardType: type,
      autocorrect: false,
      textAlign: big ? TextAlign.center : TextAlign.start,
      onChanged: (_) => setState(() {}),
      style: big ? TextStyle(fontSize: 26, fontWeight: FontWeight.w700, letterSpacing: 6, color: p.label) : BT.body.copyWith(color: p.label),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: BT.body.copyWith(color: p.secondary),
        filled: true,
        fillColor: p.fill,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }

  Widget _button(String label, VoidCallback? onTap, {Key? key, bool primary = true}) {
    final p = BytePalette.of(context);
    final on = !_busy && onTap != null;
    final bg = primary ? p.accent : p.fill;
    return Opacity(
      opacity: on || (_busy && primary) ? 1 : 0.45,
      child: Material(
        key: key,
        color: bg,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: on ? onTap : null,
          child: SizedBox(
            height: 50,
            child: Center(
              child: _busy && primary
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                  : Text(label, style: BT.bodyStrong.copyWith(color: primary ? Colors.white : p.label)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _signIn(BuildContext context) {
    final p = BytePalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.cloud_sync_rounded, size: 52, color: p.accent),
          const SizedBox(height: 10),
          Text(
            switch (_mode) {
              _Mode.create => 'Create your Byte account',
              _Mode.password => 'Log in to Byte',
              _Mode.code => 'Sign in with an email code',
            },
            key: const ValueKey('sync-title'),
            textAlign: TextAlign.center,
            style: BT.title2.copyWith(color: p.label, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Your likes, playlists, history, stats and settings stay the same on every phone, tablet and iPhone you sign in on.',
            textAlign: TextAlign.center,
            style: BT.sub.copyWith(color: p.secondary, fontSize: 15),
          ),
          const SizedBox(height: 14),
          SegmentedButton<_Mode>(
            key: const ValueKey('sync-mode'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(value: _Mode.create, label: Text('New account', key: const ValueKey('sync-tab-create'), style: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w600))),
              ButtonSegment(value: _Mode.password, label: Text('Log in', key: const ValueKey('sync-tab-login'), style: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w600))),
              ButtonSegment(value: _Mode.code, label: Text('Email code', key: const ValueKey('sync-tab-code'), style: BT.sub.copyWith(color: p.label, fontWeight: FontWeight.w600))),
            ],
            selected: {_mode},
            onSelectionChanged: (v) => setState(() {
              _mode = v.first;
              _error = null;
            }),
          ),
          const SizedBox(height: 14),
          if (_mode == _Mode.create) ...[
            _field(_name, 'Your name', key: const ValueKey('sync-name')),
            const SizedBox(height: 10),
          ],
          _field(_email, 'Your email address (Gmail works)', key: const ValueKey('sync-email'), type: TextInputType.emailAddress),
          const SizedBox(height: 10),
          if (_mode == _Mode.code) ...[
            if (!_codeSent)
              _button('Send code', _emailOk ? _sendCode : null, key: const ValueKey('sync-send-code'))
            else ...[
              Text(
                'Check ${_email.text.trim()} for an email from Byte.',
                textAlign: TextAlign.center,
                style: BT.sub.copyWith(color: p.secondary),
              ),
              const SizedBox(height: 10),
              _field(_code, '6-digit code', key: const ValueKey('sync-code'), type: TextInputType.number, big: true),
              const SizedBox(height: 10),
              _button('Sign in', _code.text.trim().length >= 6 ? () => _run(() => Services.i.cloud.verifyCode(_email.text, _code.text)) : null, key: const ValueKey('sync-verify')),
              const SizedBox(height: 8),
              Text(
                'Email has a link and no code? Long-press the link, tap Copy link, come back and tap Paste link.',
                textAlign: TextAlign.center,
                style: BT.sub.copyWith(color: p.secondary, fontSize: 13),
              ),
              const SizedBox(height: 8),
              _button('Paste link', _pasteLink, key: const ValueKey('sync-paste-link'), primary: false),
              TextButton(onPressed: _busy ? null : _sendCode, child: Text('Send again', style: BT.sub.copyWith(color: p.accent, fontWeight: FontWeight.w600))),
            ],
          ] else if (_mode == _Mode.password) ...[
            _field(_pw, 'Byte password', key: const ValueKey('sync-password'), obscure: true),
            const SizedBox(height: 10),
            _button('Log in', _emailOk && _pw.text.length >= 6 ? () => _run(() => Services.i.cloud.withPassword(_email.text, _pw.text)) : null, key: const ValueKey('sync-login')),
            TextButton(
              key: const ValueKey('sync-forgot'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _mode = _Mode.code;
                      _error = null;
                    }),
              child: Text('Forgot password? Sign in with an email code', style: BT.sub.copyWith(color: p.accent, fontWeight: FontWeight.w600)),
            ),
          ] else ...[
            _field(_pw, 'Choose a password (8+ characters)', key: const ValueKey('sync-password'), obscure: true),
            const SizedBox(height: 10),
            _field(_pw2, 'Type the password again', key: const ValueKey('sync-password2'), obscure: true),
            if (_pw2.text.isNotEmpty && _pw2.text != _pw.text) ...[
              const SizedBox(height: 6),
              Text('The two passwords are different', key: const ValueKey('sync-pw-mismatch'), style: BT.sub.copyWith(color: const Color(0xFFFF453A))),
            ],
            const SizedBox(height: 10),
            _button(
              'Create account',
              _emailOk && _pw.text.length >= 8 && _pw.text == _pw2.text
                  ? () => _run(() => Services.i.cloud.withPassword(_email.text, _pw.text, create: true, name: _name.text))
                  : null,
              key: const ValueKey('sync-create'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _mode = _Mode.password;
                      _error = null;
                    }),
              child: Text('Already have a Byte account? Log in', style: BT.sub.copyWith(color: p.accent, fontWeight: FontWeight.w600)),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const ValueKey('sync-error'),
              textAlign: TextAlign.center,
              style: BT.sub.copyWith(color: const Color(0xFFFF453A)),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Same email on every device = same Byte. Data goes only to your own Byte server and only your account can read it. Downloads stay on each phone; their list syncs so you can download them again.',
            textAlign: TextAlign.center,
            style: BT.sub.copyWith(color: p.secondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _signedIn(BuildContext context) {
    final s = Services.i;
    final sync = s.sync;
    final p = BytePalette.of(context);
    final (icon, line) = syncStatusLine(sync);
    final now = sync.remoteNow.value;
    final others = sync.otherDownloads.values.where((i) => !s.library.isDownloaded(i.id)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupCard(
          dividerIndent: 16,
          children: [
            GroupRow(icon: Icons.account_circle_rounded, title: s.cloud.email ?? 'Signed in', subtitle: 'Byte account', key: const ValueKey('sync-account')),
            GroupRow(icon: icon, title: line, subtitle: sync.message, key: const ValueKey('sync-status')),
            GroupRow(icon: Icons.sync_rounded, title: 'Sync now', enabled: sync.state != SyncState.syncing, key: const ValueKey('sync-now'), onTap: () => sync.syncNow()),
          ],
        ),
        if (now?.item != null) ...[
          const GroupLabel('Continue listening'),
          GroupCard(
            children: [
              GroupRow(
                key: const ValueKey('sync-continue'),
                icon: Icons.play_circle_fill_rounded,
                title: now!.item!.title,
                subtitle: 'From ${now.deviceName} · at ${fmtDuration(now.position.inSeconds)}',
                chevron: true,
                onTap: () async {
                  sync.clearRemoteNow();
                  await s.player.playItems(now.items, start: now.index);
                  await s.player.seek(now.position);
                },
              ),
            ],
          ),
        ],
        if (others.isNotEmpty) ...[
          const GroupLabel('Downloads on your other devices'),
          GroupCard(
            children: [
              GroupRow(
                key: const ValueKey('sync-other-downloads'),
                icon: Icons.download_rounded,
                title: 'Download ${others.length} song${others.length == 1 ? '' : 's'} here too',
                subtitle: others.take(3).map((i) => i.title).join(', '),
                enabled: s.downloads.supported,
                onTap: () {
                  s.downloads.enqueue(others);
                  toast(context, 'Downloading ${others.length} songs');
                },
              ),
            ],
          ),
        ],
        if (s.account.active == null) ...[
          const GroupLabel('YouTube Music'),
          GroupCard(
            children: [
              GroupRow(
                key: const ValueKey('sync-link-youtube'),
                icon: Icons.link_rounded,
                title: 'Use this Google account for YouTube Music too',
                subtitle: 'Brings your YouTube Music playlists and likes',
                chevron: true,
                onTap: () => Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(builder: (_) => const LoginScreen())),
              ),
            ],
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 10, 32, 0),
          child: Text(
            'Syncs: liked songs, playlists (order and pins), saved podcasts, history, searches, listening stats, the DJ\'s taste, all settings and what is playing. Changes made offline go up when you are back online.',
            style: BT.sub.copyWith(color: p.secondary, fontSize: 13),
          ),
        ),
        const SizedBox(height: 14),
        GroupCard(
          children: [
            InkWell(
              key: const ValueKey('sync-sign-out'),
              onTap: () async {
                final ok = await showGlassConfirm(context, 'Sign out of sync?', 'Everything stays on this phone. It stops syncing until you sign in again.', 'Sign out');
                if (ok) await s.cloud.signOut();
              },
              child: SizedBox(
                height: 52,
                child: Center(
                  child: Text('Sign out', style: BT.body.copyWith(color: const Color(0xFFFF453A))),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
      ],
    );
  }
}

/// Status for the sync row ("Synced · just now", "Offline · 3 waiting"…).
(IconData, String) syncStatusLine(CloudSync s) => switch (s.state) {
  SyncState.syncing => (Icons.sync_rounded, 'Syncing…'),
  SyncState.synced => (Icons.cloud_done_rounded, s.lastSynced == null ? 'Synced' : 'Last synced ${_ago(s.lastSynced!)}'),
  SyncState.offline => (Icons.cloud_off_rounded, 'Offline · ${s.pending} waiting'),
  SyncState.notReady => (Icons.cloud_off_rounded, 'Sync is not set up on the server yet'),
  SyncState.error => (Icons.error_outline_rounded, 'Sign in again'),
  SyncState.signedOut => (Icons.cloud_outlined, 'Not signed in'),
};

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inSeconds < 45) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} hr ago';
  return '${t.day}/${t.month}';
}

/// Server words → plain words.
String friendlyAuthError(String m) {
  final l = m.toLowerCase();
  if (l.contains('invalid login') || l.contains('invalid credentials')) return 'Wrong email or password.';
  if (l.contains('already registered') || l.contains('already exists')) return 'This email already has a Byte account. Tap Log in.';
  if (l.contains('expired') || l.contains('invalid') && l.contains('otp') || l.contains('token')) return 'That code has expired or is wrong. Tap Send again.';
  if (l.contains('rate') || l.contains('seconds') || l.contains('too many')) return 'Too many emails just now. Wait a minute and try again.';
  if (l.contains('password') && l.contains('characters')) return 'The password needs at least 8 characters.';
  if (l.contains('signups not allowed') || l.contains('disabled')) return 'New accounts are switched off on the server.';
  return m;
}
