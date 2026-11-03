import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:byte/app.dart';
import 'package:byte/core/models.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/import_sheet.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/now_playing.dart';
import 'package:byte/ui/screens/integrations_pages.dart';
import 'package:byte/ui/shell.dart';
import 'package:byte/ui/theme.dart';
import 'package:byte/ui/widgets.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

final kTransparentPng = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==');

double _lum(Color c) {
  double ch(double v) => v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (max(la, lb) + 0.05) / (min(la, lb) + 0.05);
}

/// Every piece of text inside the open bottom sheet must be readable on the
/// sheet's own background (the bug: white text on a white sheet).
void expectSheetReadable(WidgetTester tester, String what) {
  final sheet = find.byType(BottomSheet);
  expect(sheet, findsOneWidget, reason: '$what: no sheet');
  final mat = tester.widget<Material>(find.descendant(of: sheet, matching: find.byType(Material)).first);
  final themeBg = Theme.of(tester.element(sheet)).bottomSheetTheme.backgroundColor!;
  var bg = mat.color ?? themeBg;
  // 1.3: sheets are liquid glass; the text sits on the glass tint over a
  // page of the same brightness
  final glass = find.descendant(of: sheet, matching: find.byKey(const ValueKey('glass-sheet')));
  if (glass.evaluate().isNotEmpty) {
    final tint = tester
        .widgetList<DecoratedBox>(find.descendant(of: glass, matching: find.byType(DecoratedBox)))
        .map((d) => d.decoration)
        .whereType<BoxDecoration>()
        .firstWhere((d) => d.color != null)
        .color!;
    bg = Color.alphaBlend(tint, themeBg);
  }
  final paras = tester.renderObjectList<RenderParagraph>(find.descendant(of: sheet, matching: find.byType(RichText)));
  var n = 0;
  for (final r in paras) {
    final c = r.text.style?.color;
    final txt = r.text.toPlainText().trim();
    if (c == null || txt.isEmpty || txt.codeUnits.every((u) => u > 0xE000)) continue; // icon glyphs
    n++;
    expect(contrast(c, bg), greaterThanOrEqualTo(3.0), reason: '$what: "$txt" is ${c.toARGB32().toRadixString(16)} on ${bg.toARGB32().toRadixString(16)}');
  }
  expect(n, greaterThan(0), reason: '$what: no text in the sheet');
}

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  group('bugs from the v1.2.1 phone video', () {
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      testWidgets('player sheets are readable (sleep, speed, add to playlist, more) — ${mode.name}', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          sv.settings.themeMode = mode;
          final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
          await sv.player.playItems(album.tracks);
        });
        await tester.pumpWidget(const ByteApp());
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('mini')));
        await settle(tester);
        final ctx = tester.element(find.byType(SeekBar).first);
        final it = sv.player.current.value!;
        final sheets = <String, void Function()>{
          'sleep timer': () => showSleepSheet(ctx),
          'speed': () => showSpeedSheet(ctx),
          'add to playlist': () => addToPlaylistSheet(ctx, [it]),
          'song menu': () => showItemMenu(ctx, it),
        };
        for (final e in sheets.entries) {
          e.value();
          await settle(tester);
          expectSheetReadable(tester, e.key);
          Navigator.of(tester.element(find.byType(BottomSheet))).pop();
          await settle(tester);
        }
        // the speed chips have readable labels
        showSpeedSheet(ctx);
        await settle(tester);
        expect(find.text('1.0×'), findsOneWidget);
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
        await settle(tester);
        await tester.runAsync(() => sv.player.stop());
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
      });
    }

    test('pages slide in (no fade-through that showed two pages at once)', () {
      for (final b in [Brightness.light, Brightness.dark]) {
        final t = ByteTheme.build(b);
        expect(t.pageTransitionsTheme.builders[TargetPlatform.android], isA<CupertinoPageTransitionsBuilder>());
      }
      expect(ByteTheme.player(ByteTheme.build(Brightness.light)).bottomSheetTheme.backgroundColor, const Color(0xFF1C1C1E));
    });

    testWidgets('big cover shows the small already-loaded picture while it loads (no music-note flash)', (tester) async {
      final asked = <String>[];
      final old = networkImage;
      networkImage = (u) {
        asked.add(u);
        return MemoryImage(kTransparentPng);
      };
      addTearDown(() => networkImage = old);
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(child: Artwork('https://lh3.googleusercontent.com/abc=w60-h60-l90-rj', size: 360)),
        ),
      );
      expect(asked.any((u) => u.contains('=w1080-h1080')), isTrue);
      expect(asked.any((u) => u.contains('=w226-h226')), isTrue, reason: 'the small picture is used while the big one loads');
    });

    testWidgets('paste a list: the example is a hint, an empty tap explains, typed songs go to matching', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
      pushInCurrentTab!(const ImportScreen());
      await settle(tester);
      for (var i = 0; i < 6 && find.text('Paste a list of songs').hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -300));
        await settle(tester);
      }
      await tester.tap(find.text('Paste a list of songs'));
      await settle(tester);
      final field = tester.widget<TextField>(find.byType(TextField).last);
      expect(field.controller!.text, isEmpty);
      expect(field.decoration!.hintText, contains('For example'));
      // keyboard up: the floating bar steps out of the way
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await settle(tester);
      expect(find.byType(FloatingBar), findsNothing);
      tester.view.resetViewInsets();
      await settle(tester);
      await tester.tap(find.text('Find songs'));
      await settle(tester);
      expect(find.textContaining('Type at least one song'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'Tum Hi Ho - Arijit Singh\nKesariya - Pritam');
      await settle(tester);
      expect(find.text('Find 2 songs'), findsOneWidget);
      await tester.tap(find.text('Find 2 songs'));
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
        await settle(tester);
      }
      // matching ran and the review page shows what was found
      expect(find.byType(ImportReviewScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('Spotify: link import first, guided steps, login button only with a real Client ID', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const ByteApp());
      await settle(tester);
      pushInCurrentTab!(const SpotifyAccountScreen());
      await settle(tester);
      expect(find.text('Import a playlist by link'), findsOneWidget);
      // 1.4: one-tap sign-in comes first; the Client-ID route is folded away.
      expect(find.text('Sign in with Spotify'), findsOneWidget);
      await tester.ensureVisible(find.text('Use your own Spotify developer app'));
      await settle(tester);
      await tester.tap(find.text('Use your own Spotify developer app'), warnIfMissed: true);
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Open Spotify for Developers'), findsOneWidget);
      FilledButton login() => tester.widget<FilledButton>(find.ancestor(of: find.text('Log in with Spotify'), matching: find.byType(FilledButton)));
      expect(login().onPressed, isNull);
      await tester.enterText(find.byType(TextField).last, 'abc');
      await settle(tester);
      expect(find.textContaining('doesn\'t look like a Client ID'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '0123456789abcdef0123456789abcdef');
      await settle(tester);
      expect(login().onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
    });
  });

  test('Item kinds: addon and SMB songs are not YouTube songs', () {
    const a = Item(kind: ItemKind.song, id: 'addon:home:42', title: 'x');
    const s = Item(kind: ItemKind.song, id: 'smb:/music/a.flac', title: 'y');
    expect(a.isLocal && a.isAddon && !a.isOnPhone, isTrue);
    expect(s.isLocal && s.isSmb && !s.isOnPhone, isTrue);
    expect(File('lib/ui/now_playing.dart').readAsStringSync().contains('ByteTheme.player('), isTrue);
  });
}
