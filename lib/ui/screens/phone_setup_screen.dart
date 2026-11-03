import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../lock/lock_bridge.dart';
import '../page.dart';
import '../style.dart';
import '../widgets.dart';
import 'lock_screen_settings.dart' show oemNote;

/// What Android tells Byte about the phone (Settings › Phone setup).
@immutable
class PhoneInfo {
  final String manufacturer;
  final String brand;
  final String model;
  final int sdk;
  final String release;
  final bool lowRam;
  final int totalMemMb;
  final List<String> abis;
  final bool miui;
  final bool ignoringBattery;
  const PhoneInfo({
    this.manufacturer = '',
    this.brand = '',
    this.model = '',
    this.sdk = 0,
    this.release = '',
    this.lowRam = false,
    this.totalMemMb = 0,
    this.abis = const [],
    this.miui = false,
    this.ignoringBattery = false,
  });

  factory PhoneInfo.fromMap(Map<String, Object?> m) => PhoneInfo(
    manufacturer: (m['manufacturer'] as String? ?? '').toLowerCase(),
    brand: (m['brand'] as String? ?? '').toLowerCase(),
    model: m['model'] as String? ?? '',
    sdk: (m['sdk'] as num?)?.toInt() ?? 0,
    release: m['release'] as String? ?? '',
    lowRam: m['lowRam'] == true,
    totalMemMb: (m['totalMemMb'] as num?)?.toInt() ?? 0,
    abis: [for (final a in (m['abis'] as List? ?? const [])) '$a'],
    miui: m['miui'] == true,
    ignoringBattery: m['ignoringBattery'] == true,
  );

  bool _is(List<String> n) => n.any((x) => manufacturer.contains(x) || brand.contains(x));

  /// The phone family that decides where the settings live.
  PhoneFamily get family {
    if (miui || _is(['xiaomi', 'redmi', 'poco'])) return PhoneFamily.xiaomi;
    if (_is(['vivo', 'iqoo'])) return PhoneFamily.vivo;
    if (_is(['oppo', 'realme', 'oneplus'])) return PhoneFamily.oppo;
    if (_is(['samsung'])) return PhoneFamily.samsung;
    if (_is(['huawei', 'honor'])) return PhoneFamily.huawei;
    if (_is(['motorola', 'moto', 'nokia', 'hmd', 'google', 'pixel', 'nothing', 'lenovo', 'asus', 'sony'])) return PhoneFamily.stock;
    return PhoneFamily.other;
  }

  String get makerName {
    final raw = brand.isNotEmpty ? brand : manufacturer;
    if (raw.isEmpty) return 'Your phone';
    const names = {'iqoo': 'iQOO', 'oneplus': 'OnePlus', 'poco': 'POCO', 'hmd global': 'Nokia', 'realme': 'realme', 'vivo': 'vivo'};
    return names[raw] ?? raw[0].toUpperCase() + raw.substring(1);
  }

  /// The lock-screen helper's view of the same phone (for its brand notes).
  LockScreenStatus get lockStatus => LockScreenStatus(sdk: sdk, manufacturer: manufacturer, brand: brand, miui: miui);
}

enum PhoneFamily { xiaomi, vivo, oppo, samsung, huawei, stock, other }

/// One step on the Phone setup page: a title, what to switch on and which
/// settings page the "Open" button goes to (`byte/device` › open(kind)).
@immutable
class SetupStep {
  final String kind; // battery-request, battery, autostart, lockscreen, popup, notifications, overlay
  final IconData icon;
  final String title;
  final String how;
  final bool done;
  const SetupStep(this.kind, this.icon, this.title, this.how, {this.done = false});
}

/// The steps for this phone, most important first. Every phone gets the
/// battery step (so music keeps playing with the screen off); makers that
/// hide autostart / lock-screen / pop-up switches get those too.
List<SetupStep> phoneSetupSteps(PhoneInfo p) {
  final out = <SetupStep>[
    SetupStep(
      'battery-request',
      Icons.battery_charging_full_rounded,
      'Keep playing with the screen off',
      'Allow Byte to ignore battery optimisation',
      done: p.ignoringBattery,
    ),
  ];
  switch (p.family) {
    case PhoneFamily.xiaomi:
      out.addAll(const [
        SetupStep('autostart', Icons.rocket_launch_rounded, 'Autostart', 'Security › Autostart › turn on Byte'),
        SetupStep('lockscreen', Icons.lock_open_rounded, 'Show on Lock screen + pop-ups', 'Other permissions › “Show on Lock screen” and “Display pop-up windows while running in the background”'),
        SetupStep('battery', Icons.battery_saver_rounded, 'Battery saver: No restrictions', 'Battery saver › Byte › “No restrictions”'),
      ]);
    case PhoneFamily.vivo:
      out.addAll(const [
        SetupStep('autostart', Icons.rocket_launch_rounded, 'Background start / Autostart', 'Turn on Byte'),
        SetupStep('lockscreen', Icons.lock_open_rounded, 'Display on lock screen + pop-ups', 'Allow “Display on lock screen” and “Pop-up windows in background”'),
        SetupStep('battery', Icons.battery_saver_rounded, 'Background power consumption', 'Allow high background power use for Byte'),
      ]);
    case PhoneFamily.oppo:
      out.addAll(const [
        SetupStep('autostart', Icons.rocket_launch_rounded, 'Auto launch', 'App management › Auto launch › turn on Byte'),
        SetupStep('lockscreen', Icons.lock_open_rounded, 'Floating windows / lock screen', 'Allow “Display over other apps” and “Lock screen display”'),
        SetupStep('battery', Icons.battery_saver_rounded, 'Allow background activity', 'Battery › Byte › “Allow background activity”'),
      ]);
    case PhoneFamily.samsung:
      out.addAll(const [
        SetupStep('battery', Icons.battery_saver_rounded, 'Battery: Unrestricted', 'Apps › Byte › Battery › “Unrestricted” (and not in “Sleeping apps”)'),
        SetupStep('notifications', Icons.notifications_rounded, 'Notifications on', 'Media controls and the lock screen player need them'),
      ]);
    case PhoneFamily.huawei:
      out.addAll(const [
        SetupStep('autostart', Icons.rocket_launch_rounded, 'App launch: Manage manually', 'Turn on Auto-launch, Secondary launch and Run in background'),
        SetupStep('battery', Icons.battery_saver_rounded, 'Battery', 'Byte › don\'t optimise'),
      ]);
    case PhoneFamily.stock:
    case PhoneFamily.other:
      out.addAll(const [
        SetupStep('notifications', Icons.notifications_rounded, 'Notifications on', 'Media controls and the lock screen player need them'),
        SetupStep('overlay', Icons.layers_rounded, 'Display over other apps (optional)', 'Helps the lock screen player open faster'),
      ]);
  }
  if (p.sdk >= 34) {
    out.add(const SetupStep('fullscreen', Icons.fullscreen_rounded, 'Open over the lock screen', 'Android 14+: allow full-screen notifications for Byte'));
  }
  return out;
}

typedef DeviceInvoker = Future<Object?> Function(String method, [Object? args]);

/// Settings › Phone setup: finds the phone maker and opens the right pages.
class PhoneSetupScreen extends StatefulWidget {
  /// Tests pass the phone and a fake channel.
  final PhoneInfo? info;
  final DeviceInvoker? invoke;
  const PhoneSetupScreen({super.key, this.info, this.invoke});

  static const channel = MethodChannel('byte/device');
  static Future<Object?> _defaultInvoke(String m, [Object? a]) => channel.invokeMethod<Object?>(m, a);

  @override
  State<PhoneSetupScreen> createState() => _PhoneSetupScreenState();
}

class _PhoneSetupScreenState extends State<PhoneSetupScreen> with WidgetsBindingObserver {
  PhoneInfo? info;
  bool unsupported = false;
  DeviceInvoker get _invoke => widget.invoke ?? PhoneSetupScreen._defaultInvoke;

  @override
  void initState() {
    super.initState();
    info = widget.info;
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final m = await _invoke('info');
      if (m is Map && mounted) setState(() => info = PhoneInfo.fromMap(m.cast<String, Object?>()));
    } on MissingPluginException {
      if (mounted && info == null) setState(() => unsupported = true);
    } catch (_) {
      if (mounted && info == null) setState(() => unsupported = true);
    }
  }

  Future<void> _open(SetupStep s) async {
    try {
      if (s.kind == 'battery-request') {
        await _invoke('requestIgnoreBattery');
        return;
      }
      if (s.kind == 'fullscreen') {
        await LockScreenBridge.openFullScreenSettings();
        return;
      }
      final r = await _invoke('open', s.kind);
      if (!mounted) return;
      if (r == 'app') {
        toast(context, 'Opened Byte\'s app page: look for “${s.title}”');
      } else if (r == '' || r == null) {
        toast(context, 'Couldn\'t open that page on this phone');
      }
    } catch (_) {
      if (mounted) toast(context, 'Couldn\'t open that page on this phone');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = BytePalette.of(context);
    final i = info;
    Widget note(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
      child: Text(t, style: BT.sub.copyWith(color: p.secondary)),
    );
    return SubPage(capWidth: true, 
      title: 'Phone setup',
      showProfile: false,
      slivers: [
        SliverList.list(
          children: [
            if (unsupported && i == null)
              note('Nothing to set up here: this works the same on every phone of this kind.')
            else if (i == null)
              const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()))
            else ...[
              GroupCard(
                children: [
                  GroupRow(
                    key: const ValueKey('phone-maker'),
                    icon: Icons.phone_android_rounded,
                    title: '${i.makerName}${i.model.isEmpty ? '' : ' ${i.model}'}',
                    subtitle: [
                      if (i.release.isNotEmpty) 'Android ${i.release}',
                      if (i.totalMemMb > 0) '${(i.totalMemMb / 1024).toStringAsFixed(i.totalMemMb < 4096 ? 1 : 0)} GB RAM',
                      if (i.lowRam) 'light mode on',
                    ].join(' · '),
                  ),
                ],
              ),
              note('Every phone maker hides these switches somewhere else. Tap a step: Byte opens the right page on your ${i.makerName}. Turn the switch on there and come back.'),
              const SizedBox(height: 22),
              GroupCard(
                children: [
                  for (final s in phoneSetupSteps(i))
                    GroupRow(
                      key: ValueKey('setup-${s.kind}'),
                      icon: s.done ? Icons.check_circle_rounded : s.icon,
                      title: s.title,
                      subtitle: s.done ? 'Done' : s.how,
                      chevron: !s.done,
                      onTap: s.done ? null : () => _open(s),
                    ),
                ],
              ),
              note(oemNote(i.lockStatus)),
              const SizedBox(height: 22),
              GroupCard(
                children: [
                  GroupRow(
                    key: const ValueKey('setup-app'),
                    icon: Icons.settings_applications_rounded,
                    title: 'Byte\'s app page',
                    subtitle: 'Permissions, battery, notifications',
                    chevron: true,
                    onTap: () => _invoke('open', 'app'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ],
    );
  }
}
