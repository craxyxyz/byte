import 'package:byte/app.dart';
import 'package:byte/data/cloud_sync.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'cloud_sync_test.dart' show MemServer, MemBackend;
import 'helpers.dart';
import 'screens_test.dart' show settle;

/// The account without a server: remembers what was asked.
class FakeCloud extends CloudAccount {
  FakeCloud() : super(CloudAccount.makeClient('https://example.supabase.co', 'k'), secure: MemSecureStorage());
  String? _email;
  final calls = <String>[];
  @override
  bool get signedIn => _email != null;
  @override
  String? get email => _email;
  @override
  String? get uid => _email == null ? null : 'user-1';
  @override
  Future<void> restore() async {}
  @override
  Future<void> withPassword(String email, String password, {bool create = false, String? name}) async {
    calls.add('${create ? 'create' : 'login'} $email${name == null || name.isEmpty ? '' : ' $name'}');
    _email = CloudAccount.clean(email);
    notifyListeners();
  }

  @override
  Future<void> sendCode(String email) async => calls.add('code $email');
  @override
  Future<void> verifyCode(String email, String code) async {
    calls.add('verify $email $code');
    _email = CloudAccount.clean(email);
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    _email = null;
    notifyListeners();
  }
}

void main() {
  late Services sv;
  late FakeCloud cloud;
  final server = MemServer();
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
    cloud = FakeCloud();
    sv.cloud = cloud;
    sv.sync = CloudSync(backendFor: () => MemBackend(server, 'user-1'), deviceId: 'phone', deviceName: () => 'Pixel', debounce: const Duration(milliseconds: 50));
  });

  testWidgets('Settings → Byte account & sync: Gmail sign-in (code or password), status, sign out', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(const ByteApp());
    await settle(t);
    pushInCurrentTab!(const SettingsScreen());
    await settle(t);
    expect(find.text('Create account or log in · same Byte on every device'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('settings-sync')));
    await settle(t);
    // a new person sees "Create account" first, with all three ways in
    expect(find.text('Create your Byte account'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-tab-login')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-tab-code')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('sync-email')), 'Apurba.Test@gmail.com');
    await t.pump();
    // email code
    await t.tap(find.byKey(const ValueKey('sync-tab-code')));
    await settle(t);
    await t.tap(find.byKey(const ValueKey('sync-send-code')));
    await settle(t);
    expect(cloud.calls.last, 'code Apurba.Test@gmail.com');
    expect(find.byKey(const ValueKey('sync-paste-link')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('sync-code')), '123456');
    await t.pump();
    // log in tab: forgot password goes to the code
    await t.tap(find.byKey(const ValueKey('sync-tab-login')));
    await settle(t);
    expect(find.text('Log in to Byte'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-forgot')), findsOneWidget);
    // or a new account: name, email, password twice
    await t.tap(find.byKey(const ValueKey('sync-tab-create')));
    await settle(t);
    await t.enterText(find.byKey(const ValueKey('sync-name')), 'Apurba');
    await t.enterText(find.byKey(const ValueKey('sync-password')), 'my byte pass 1');
    await t.enterText(find.byKey(const ValueKey('sync-password2')), 'my byte pass X');
    await t.pump();
    expect(find.byKey(const ValueKey('sync-pw-mismatch')), findsOneWidget);
    await t.enterText(find.byKey(const ValueKey('sync-password2')), 'my byte pass 1');
    await t.pump();
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('sync-create')));
      await t.pump();
      await sv.sync.start(cloud.uid!);
    });
    await settle(t);
    expect(cloud.calls.last, 'create Apurba.Test@gmail.com Apurba');
    expect(find.text('apurba.test@gmail.com'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-status')), findsOneWidget);
    expect(find.textContaining('Last synced'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-link-youtube')), findsOneWidget); // not signed in to YouTube Music yet
    expect(t.takeException(), isNull);
    // sign out (asks first)
    await t.ensureVisible(find.byKey(const ValueKey('sync-sign-out')));
    await t.tap(find.byKey(const ValueKey('sync-sign-out')));
    await settle(t);
    expect(find.byKey(const ValueKey('glass-dialog')), findsOneWidget);
    await t.tap(find.text('Sign out').last);
    await t.runAsync(() => sv.sync.stop());
    await settle(t);
    expect(find.text('Create your Byte account'), findsOneWidget);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  });

  testWidgets('a song playing on the other phone: "Continue … from Pixel?" → plays here from the same moment', (t) async {
    t.view.devicePixelRatio = 1;
    t.view.physicalSize = const Size(400, 900);
    addTearDown(t.view.reset);
    await t.pumpWidget(const ByteApp());
    await settle(t);
    final album = await t.runAsync(() => sv.yt.album('MPREb_E4GfUXfDfhy'));
    sv.sync.remoteNow.value = RemoteNow(album!.tracks, 1, const Duration(seconds: 42), 'Pixel', DateTime.now());
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const ValueKey('continue-from-device')), findsOneWidget);
    expect(find.textContaining('from Pixel'), findsOneWidget);
    await t.runAsync(() async {
      await t.tap(find.byKey(const ValueKey('glass-toast-action')));
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await t.pump();
    expect(sv.player.current.value!.id, album.tracks[1].id);
    expect(sv.player.position.inSeconds, inInclusiveRange(42, 44));
    await t.runAsync(() => sv.player.stop());
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  });
}
