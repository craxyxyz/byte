// Byte © 2026 Apurba Laskar
// Golden screenshots for 1.4.5: Listen together → "Share my sound settings
// with guests": the guest's prompt (banner + party sheet) and the host switch.
// Run on its own: SHOTS_DIR=... flutter test test_shots/v145_party_sound_shots_test.dart
// ignore_for_file: invalid_use_of_visible_for_testing_member
import 'dart:io';
import 'dart:ui' as ui;

import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/data/party_sound.dart';
import 'package:byte/ui/party_sound_banner.dart';
import 'package:byte/ui/party_sound_section.dart';
import 'package:byte/ui/style.dart';
import 'package:byte/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/v142_party_sound_test.dart' show Bus, FakeLink;

const _fonts = '/home/user/sdk/flutter/bin/cache/artifacts/material_fonts';
final _out = Platform.environment['SHOTS_DIR'] ?? 'build/shots/like';

Future<void> _loadFonts() async {
  Future<ByteData> f(String p) async => ByteData.view(Uint8List.fromList(File(p).readAsBytesSync()).buffer);
  final roboto = FontLoader('Roboto');
  for (final w in ['Regular', 'Medium', 'Bold', 'Black']) {
    roboto.addFont(f('$_fonts/Roboto-$w.ttf'));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(f('$_fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

final _key = GlobalKey();

Future<void> _shot(WidgetTester tester, String name) async {
  await tester.runAsync(() async {
    final ro = _key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final img = await ro.toImage(pixelRatio: 1);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$_out/$name.png')
      ..createSync(recursive: true)
      ..writeAsBytesSync(png!.buffer.asUint8List());
  });
}

Map<String, Object?> _hostSound() => {'eqOn': true, 'preset': 'Bass Booster', 'nodes': nodesFromBands(eqPresets['Bass Booster']!).map((n) => n.toJson()).toList(), 'rvOn': false, 'ldOn': false};

/// The app's dark theme; the filled button's label gets the real font (on a
/// phone a label with no font is the system font; in a test it'd be boxes).
ThemeData _theme() {
  final t = ByteTheme.build(Brightness.dark, font: 'Roboto');
  return t.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: t.filledButtonTheme.style!.copyWith(textStyle: const WidgetStatePropertyAll(TextStyle(fontFamily: 'Roboto', fontWeight: FontWeight.w700, fontSize: 14))),
    ),
  );
}

/// The party sheet as the guest / host sees it, with the banner on top.
Widget _sheet(PartySound s, {bool banner = false}) => RepaintBoundary(
  key: _key,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    home: Builder(
      builder: (context) {
        final p = BytePalette.of(context);
        final body = Scaffold(
          backgroundColor: p.bg,
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 40),
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, banner ? 150 : 12, 20, 4),
                  child: Text('Listening together', style: BT.title2.copyWith(color: p.label)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text('Party code BD6CDN · ${s.link.people.length} listening', style: BT.sub.copyWith(color: p.secondary)),
                ),
                PartySoundSection(sound: s),
              ],
            ),
          ),
        );
        return banner ? PartySoundBanner(sound: s, child: body) : body;
      },
    ),
  ),
);

void main() {
  setUpAll(_loadFonts);

  Future<void> run(WidgetTester tester, Future<void> Function() body) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.padding = const FakeViewPadding(top: 44, bottom: 24);
    await body();
  }

  testWidgets('guest prompt (390)', (tester) => run(tester, () async {
    final bus = Bus();
    final hostLab = AudioLab()..openForTest(_hostSound());
    final host = FakeLink(bus, 'host', 'Apurba', isHost: true);
    final hostSound = PartySound(lab: hostLab, link: host);
    final g = FakeLink(bus, 'g1', 'Riya');
    final guest = PartySound(lab: AudioLab()..openForTest(), link: g, caps: () => SoundCaps.android);
    bus.changed();
    await tester.runAsync(() => hostSound.setSharing(true));
    await tester.pumpWidget(_sheet(guest, banner: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Apurba wants to share their sound settings (Bass Booster)'), findsNWidgets(2));
    expect(find.text('Apply'), findsNWidgets(2));
    expect(find.text('Keep mine'), findsNWidgets(2));
    await _shot(tester, 'party_sound_prompt_390');
  }));

  testWidgets('guest prompt on iPhone names what is skipped (390)', (tester) => run(tester, () async {
    final bus = Bus();
    final hostLab = AudioLab()..openForTest({..._hostSound(), 'rvOn': true, 'semis': -2.0});
    final host = FakeLink(bus, 'host', 'Apurba', isHost: true);
    final hostSound = PartySound(lab: hostLab, link: host);
    final g = FakeLink(bus, 'g1', 'Riya');
    final guest = PartySound(lab: AudioLab()..openForTest(), link: g, caps: () => SoundCaps.ios);
    bus.changed();
    await tester.runAsync(() => hostSound.setSharing(true));
    await tester.pumpWidget(_sheet(guest, banner: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining("Reverb and pitch can't play on iPhone"), findsNWidgets(2));
    await _shot(tester, 'party_sound_prompt_ios_390');
  }));

  testWidgets('host switch (390)', (tester) => run(tester, () async {
    final bus = Bus();
    final hostLab = AudioLab()..openForTest(_hostSound());
    final host = FakeLink(bus, 'host', 'Apurba', isHost: true);
    final hostSound = PartySound(lab: hostLab, link: host);
    final names = ['Riya', 'Kabir', 'Meera'];
    final guests = [for (var i = 0; i < 3; i++) PartySound(lab: AudioLab()..openForTest(), link: FakeLink(bus, 'g$i', names[i]), caps: () => SoundCaps.android)];
    bus.changed();
    await tester.runAsync(() async {
      await hostSound.setSharing(true);
      await guests[0].accept();
      await guests[1].accept();
      await guests[2].decline();
    });
    await tester.pumpWidget(_sheet(hostSound));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Share my sound settings with guests'), findsOneWidget);
    expect(find.text('Send now'), findsOneWidget);
    expect(find.text('Sharing with 2 of 3 guests'), findsOneWidget);
    await _shot(tester, 'party_sound_host_390');
  }));
}
