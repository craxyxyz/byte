
import 'package:flutter/material.dart';

import '../data/account.dart';
import '../services.dart';
import 'screens/login_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/sync_screen.dart' show SyncScreen, SyncStart;
import 'nav.dart';
import 'style.dart';
import 'widgets.dart';

/// Round avatar with the account's first letter (or a person icon).
class AccountAvatar extends StatelessWidget {
  final SavedAccount? account;
  final double size;
  const AccountAvatar({super.key, this.account, this.size = 40});
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final a = account;
    final photo = a?.photo;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: p.avatar, shape: BoxShape.circle),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: photo != null && photo.isNotEmpty
          ? Image(image: imageProviderFor(photo)!, width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, _, _) => _letter(a, size))
          : _letter(a, size),
    );
  }

  Widget _letter(SavedAccount? a, double size) => a == null
      ? Icon(Icons.person_rounded, color: Colors.white, size: size * 0.6)
      : Text(
          a.initial,
          style: TextStyle(color: Colors.white, fontSize: size * 0.45, fontWeight: FontWeight.w600),
        );
}

/// The avatar at the top right of every page; tap → Switch account.
class ProfileButton extends StatelessWidget {
  const ProfileButton({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Services.i.account,
      builder: (context, _) => Tooltip(
        message: 'Account',
        child: Pressable(
          onTap: () => showAccountSwitcher(context),
          child: AccountAvatar(key: const ValueKey('profile-avatar'), account: Services.i.account.active, size: 40),
        ),
      ),
    );
  }
}

Future<void> showAccountSwitcher(BuildContext context) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close',
    barrierColor: Colors.black.withValues(alpha: 0.18),
    transitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, _, _) => const _Switcher(),
    transitionBuilder: (ctx, a, _, child) {
      final c = CurvedAnimation(parent: a, curve: Curves.easeOutCubic);
      // 2.0: no live blur of the whole screen behind the switcher
      return FadeTransition(
        opacity: c,
        child: ScaleTransition(scale: Tween(begin: 0.94, end: 1.0).animate(c), alignment: Alignment.topRight, child: child),
      );
    },
  );
}

class _Switcher extends StatelessWidget {
  const _Switcher();
  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final top = MediaQuery.paddingOf(context).top;
    final acc = Services.i.account;
    void go(Widget page) {
      Navigator.of(context).pop();
      // Open inside the current tab so the bars stay, like any other page.
      final push = pushInCurrentTab;
      if (push != null) {
        push(page);
      } else {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
      }
    }

    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, top + 6, 14, 0),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Material(
            type: MaterialType.transparency,
            child: GlassBox(
              radius: BorderRadius.circular(28),
              tint: Theme.of(context).brightness == Brightness.dark ? const Color(0xE62A2A2D) : const Color(0xE6FBFBFC),
              child: ListenableBuilder(
                listenable: Listenable.merge([acc, Services.i.cloud]),
                builder: (context, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(0, 18, 0, 8),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Text(acc.signedIn ? 'Switch account' : 'Account', style: BT.title3.copyWith(color: p.label)),
                      ),
                      if (acc.email != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 2, 20, 0),
                          child: Text(
                            acc.email!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: BT.body.copyWith(color: p.secondary, fontSize: 15),
                          ),
                        ),
                      const SizedBox(height: 10),
                      for (final a in acc.accounts)
                        _row(
                          context,
                          leading: AccountAvatar(account: a, size: 42),
                          title: a.name,
                          sub: a.handle ?? (a.email ?? 'No channel'),
                          trailing: a.key == acc.activeKey ? Icon(Icons.check_rounded, color: p.label) : null,
                          onTap: () async {
                            Navigator.pop(context);
                            await acc.switchTo(a.key);
                            Services.i.feedVersion.value++;
                          },
                        ),
                      if (!acc.signedIn)
                        _row(context, leading: const AccountAvatar(size: 42), title: 'Not signed in', sub: 'Sign in to see your YouTube Music playlists'),
                      _row(
                        context,
                        icon: Icons.person_add_alt_1_outlined,
                        title: acc.signedIn ? 'Add account' : 'Sign in with Google',
                        sub: acc.signedIn ? null : 'Your YouTube Music playlists and likes',
                        onTap: () {
                          // Full screen: the bars must not cover Google's form.
                          final nav = Navigator.of(context, rootNavigator: true);
                          Navigator.of(context).pop();
                          nav.push(MaterialPageRoute(builder: (_) => const LoginScreen()));
                        },
                      ),
                      if (acc.accounts.isNotEmpty)
                        _row(context, icon: Icons.manage_accounts_outlined, title: 'Manage accounts', onTap: () => go(const ManageAccountsScreen())),
                      const Divider(height: 14, indent: 20, endIndent: 20),
                      // Byte's own account: same likes, playlists and settings everywhere
                      if (Services.i.cloud.signedIn)
                        _row(
                          context,
                          key: const ValueKey('acct-byte'),
                          icon: Icons.cloud_done_outlined,
                          title: 'Byte account',
                          sub: Services.i.cloud.email,
                          onTap: () => go(const SyncScreen()),
                        )
                      else ...[
                        _row(
                          context,
                          key: const ValueKey('acct-create'),
                          icon: Icons.person_add_rounded,
                          title: 'Create Byte account',
                          sub: 'Email + password · same Byte on every phone',
                          onTap: () => go(const SyncScreen(startWith: SyncStart.create)),
                        ),
                        _row(
                          context,
                          key: const ValueKey('acct-login'),
                          icon: Icons.login_rounded,
                          title: 'Log in to Byte',
                          onTap: () => go(const SyncScreen(startWith: SyncStart.login)),
                        ),
                      ],
                      _row(context, icon: Icons.settings_outlined, title: 'Settings', onTap: () => go(const SettingsScreen())),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, {Key? key, Widget? leading, IconData? icon, required String title, String? sub, Widget? trailing, VoidCallback? onTap}) {
    final p = BytePalette.of(context);
    return InkWell(
      key: key,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: 42,
              child: Center(child: leading ?? Icon(icon, size: 26, color: p.label)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BT.body.copyWith(color: p.label),
                  ),
                  if (sub != null)
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: BT.caption.copyWith(color: p.secondary),
                    ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
