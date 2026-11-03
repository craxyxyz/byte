// Byte © 2026 Apurba Laskar
import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/developer_card.dart';
import 'package:byte/ui/developer_concepts.dart';
import 'package:byte/ui/party_sound_banner.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;
import 'v142_party_sound_test.dart' show Party;

// Byte 1.4.3 (Apurba, Nov 3): Developer card in About; the host's sound offer
// shows anywhere in the app.
void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  testWidgets('About: Developer card with his name, Instagram and Facebook links that open outside', (t) async {
    final opened = <Uri>[];
    t.view.physicalSize = const Size(390, 1400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DeveloperCard(open: (u) async {
      opened.add(u);
      return true;
    })))));
    expect(find.text('Apurba Laskar'), findsOneWidget);
    expect(find.text('DEVELOPER'), findsOneWidget);
    expect(find.text('Instagram'), findsOneWidget);
    expect(find.text('@apurbaaa_'), findsOneWidget);
    expect(find.text('Facebook'), findsOneWidget);
    await t.pump(DeveloperCard.entrance);
    await t.tap(find.byKey(const ValueKey('developer-instagram')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const ValueKey('developer-facebook')));
    await t.pump(const Duration(milliseconds: 300));
    expect(opened.map((u) => u.toString()), ['https://www.instagram.com/apurbaaa_', 'https://www.facebook.com/share/19dyN68CzU/']);
    expect(opened.first.query, isEmpty, reason: 'no tracking query');
  });

  Opacity cardOpacity(WidgetTester t) => t.widget<Opacity>(find.ancestor(of: find.byKey(const ValueKey('developer-card')), matching: find.byType(Opacity)).first);

  testWidgets('Developer card animates in (card, rows, shimmer) and its ring keeps turning', (t) async {
    await t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DeveloperCard(open: (u) async => true)))));
    expect(cardOpacity(t).opacity, 0);
    await t.pump(const Duration(milliseconds: 400));
    expect(cardOpacity(t).opacity, inExclusiveRange(0, 1));
    await t.pump(DeveloperCard.entrance);
    expect(cardOpacity(t).opacity, 1);
    expect(t.binding.hasScheduledFrame, isTrue, reason: 'the ring turns');
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('reduce motion: the card is at rest at once and nothing animates', (t) async {
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: DeveloperCard(open: (u) async => true)))),
    ));
    await t.pump();
    expect(cardOpacity(t).opacity, 1);
    expect(t.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('signature card: links open his profiles; reduce motion draws it at rest with no ticker', (t) async {
    final opened = <Uri>[];
    t.view.physicalSize = const Size(390, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: DeveloperConceptC(open: (u) async {
      opened.add(u);
      return true;
    })))));
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('©  2026 Apurba Laskar'), findsNothing);
    expect(find.textContaining('©'), findsNothing, reason: 'the © lives under the card on About, not inside it');
    await t.tap(find.bySemanticsLabel(RegExp('^Instagram|^@apurbaaa_')).first);
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.bySemanticsLabel(RegExp('^Facebook')).first);
    await t.pump(const Duration(milliseconds: 300));
    expect(opened, [DeveloperLinks.instagram, DeveloperLinks.facebook]);
    await t.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: MaterialApp(home: Scaffold(body: Center(child: DeveloperConceptC(open: (u) async => true)))),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(t.binding.transientCallbackCount, 0);
  });

  testWidgets('the About screen carries the Developer card', (t) async {
    t.view.physicalSize = const Size(390, 1600);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: AboutScreen()));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('developer-card')), findsOneWidget);
    expect(find.byType(DeveloperConceptC), findsOneWidget, reason: 'his pick: the signature card');
    expect(find.bySemanticsLabel(RegExp('Apurba Laskar')), findsWidgets);
    await t.pump(DeveloperConceptC.entrance);
    expect(find.text('© 2026 Apurba Laskar'), findsOneWidget, reason: 'the copyright stays on About (its own row under the card)');
  });

  testWidgets('host shares → the offer banner shows over any screen; Accept uses his sound, Decline changes nothing', (t) async {
    final p = Party(2);
    await t.pumpWidget(MaterialApp(
      builder: (c, child) => PartySoundBanner(sound: p.guestSounds[0], child: child!),
      home: const Scaffold(body: Center(child: Text('Home page'))),
    ));
    expect(find.byKey(const ValueKey('party-sound-banner')), findsNothing);
    await t.runAsync(() => p.hostSound.setSharing(true));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Apurba wants to share their sound'), findsOneWidget);
    expect(find.byKey(const ValueKey('party-sound-banner-accept')).hitTestable(), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('party-sound-banner-accept')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(p.guestLabs[0].borrowing, isTrue);
    expect(find.byKey(const ValueKey('party-sound-banner')), findsNothing);

    // the other guest declines from the banner: nothing changes
    await t.pumpWidget(MaterialApp(
      builder: (c, child) => PartySoundBanner(sound: p.guestSounds[1], child: child!),
      home: const Scaffold(body: Center(child: Text('Player'))),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.text('Apurba wants to share their sound'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('party-sound-banner-decline')));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(p.guestLabs[1].borrowing, isFalse);
    expect(find.byKey(const ValueKey('party-sound-banner')), findsNothing);
  });

  testWidgets('the app wraps every screen with the banner', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(const ByteApp());
    await settle(t);
    expect(find.byType(PartySoundBanner), findsOneWidget);
    expect(sv.partySound.offer, isNull);
    expect(find.byKey(const ValueKey('party-sound-banner')), findsNothing);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 2));
  });
}
