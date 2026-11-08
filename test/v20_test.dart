import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/audiolab/headphone_eq.dart';
import 'package:byte/brand.dart';
import 'package:byte/core/models.dart';
import 'package:byte/core/search_rank.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/app_icons.dart';
import 'package:byte/ui/glass.dart';
import 'package:byte/ui/kit/fill_text.dart';
import 'package:byte/ui/kit/glass_policy.dart';
import 'package:byte/ui/kit/line_fill.dart';
import 'package:byte/ui/screens/headphone_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:io';

import 'helpers.dart';
import 'screens_test.dart' show settle;

// Byte 2.0 © 2026 Apurba Laskar: tests for what is new in 2.0.

const _profile = """Preamp: -6.0 dB
Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
Filter 2: ON PK Fc 180 Hz Gain -3.3 dB Q 0.57
Filter 3: OFF PK Fc 9140 Hz Gain 5.6 dB Q 3.46
Filter 4: ON HSC Fc 10000 Hz Gain -1.1 dB Q 0.70
Filter 5: ON XX Fc 300 Hz Gain 1 dB Q 1
""";

Item _song(String id, String title) => Item(kind: ItemKind.song, id: id, title: title, artists: const [ArtistRef('A', null)]);

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  group('identity', () {
    test('version 2.0.0, his name, separate app id', () {
      expect(Brand.version, '2.0.0');
      expect(Brand.copyright, '© 2026 Apurba Laskar');
      final gradle = File('android/app/build.gradle.kts').readAsStringSync();
      expect(gradle, contains('val byteApplicationId = "com.apurbalaskar.byte2"'));
      final pbx = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
      expect(pbx, contains('PRODUCT_BUNDLE_IDENTIFIER = com.apurbalaskar.byte2;'));
      expect(pbx, isNot(contains('PRODUCT_BUNDLE_IDENTIFIER = com.apurbalaskar.byte;')));
      expect(File('pubspec.yaml').readAsStringSync(), contains('version: 2.0.0+2008'));
    });

    test('app icon names carry no phone brand', () {
      final bad = RegExp(r'samsung|pixel|galaxy|google|apple|iphone|xiaomi|oneplus', caseSensitive: false);
      for (final o in AppIcons.all) {
        expect(bad.hasMatch(o.label), isFalse, reason: o.label);
        expect(bad.hasMatch(o.native), isFalse, reason: o.native);
        expect(bad.hasMatch(o.id), isFalse, reason: o.id);
        expect(File(o.preview).existsSync(), isTrue, reason: o.preview);
      }
      for (final g in AppIcons.groups) {
        expect(bad.hasMatch(g.$1), isFalse, reason: g.$1);
      }
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(RegExp(r'Logo(Samsung|Pixel)').hasMatch(manifest), isFalse);
    });

    test('no trace of other app names anywhere in the code', () {
      // the other app's name, spelled so this file is not a trace itself
      final other = String.fromCharCodes([98, 105, 116, 99, 104, 111, 114, 100]);
      for (final dir in ['lib', 'android/app/src', 'ios/Runner', 'web', 'test', 'assets']) {
        for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
          if (!RegExp(r'\.(dart|kt|java|swift|m|xml|plist|json|html|js|yaml|txt|tsv)$').hasMatch(f.path)) continue;
          expect(f.readAsStringSync().toLowerCase().contains(other), isFalse, reason: f.path);
        }
      }
    });
  });

  group('headphone correction', () {
    test('a profile is read into filters (OFF and unknown kinds skipped)', () {
      final p = HeadphoneProfile.parse(_profile)!;
      expect(p.preamp, -6.0);
      expect(p.nodes.length, 3);
      expect(p.nodes[0].type, EqNodeType.lowShelf);
      expect(p.nodes[0].f, 105);
      expect(p.nodes[1].g, -3.3);
      expect(p.nodes[2].type, EqNodeType.highShelf);
      expect(HeadphoneProfile.parse('nothing here'), isNull);
    });

    test('the bundled list loads and search finds by brand and model', () async {
      final all = HeadphoneIndex.parseIndex(File('assets/audiolab/headphones.tsv').readAsStringSync());
      expect(all.length, greaterThan(5000));
      final hits = HeadphoneIndex.search(all, 'sony wh-1000xm4');
      expect(hits, isNotEmpty);
      expect(hits.first.name.toLowerCase(), contains('wh-1000xm4'));
      expect(HeadphoneIndex.search(all, ''), isEmpty);
      expect(HeadphoneIndex.search(all, 'zzzz-not-a-headphone'), isEmpty);
      final e = hits.first;
      expect(e.url.toString(), startsWith('https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/'));
      expect(e.url.toString(), endsWith('ParametricEQ.txt'));
      expect(e.source, contains('measured by'));
    });

    test('correction plays under your own curve; both reach the sound processor', () {
      final lab = AudioLab()..openForTest();
      expect(lab.anyEq, isFalse);
      final p = HeadphoneProfile.parse(_profile)!;
      lab.setHeadphone('Test Phones', 'In-ear · measured by X', p.preamp, p.nodes);
      expect(lab.hpOn, isTrue);
      expect(lab.anyEq, isTrue);
      var c = lab.nativeConfig();
      expect(c['eqOn'], isTrue);
      final gains = (c['gains'] as List).cast<double>();
      expect(gains.any((g) => g.abs() > 1), isTrue, reason: 'the correction shapes the bands');
      // own curve on top: the bands are the sum
      lab.eqOn = true;
      lab.applyPreset('Bass Booster');
      c = lab.nativeConfig();
      expect(lab.activeNodes.length, p.nodes.length + lab.nodes.length);
      final low = EqMath.curveDb(lab.activeNodes, 40);
      expect(low, closeTo(EqMath.curveDb(p.nodes, 40) + EqMath.curveDb(lab.nodes, 40), 0.01));
      // auto preamp keeps the combined boost from clipping
      expect(lab.effectivePreamp, lessThanOrEqualTo(-EqMath.curveDb(lab.activeNodes, 40) + 0.2));
      lab.hpOn = false;
      expect(lab.activeNodes.length, lab.nodes.length);
      lab.clearHeadphone();
      expect(lab.hpName, isNull);
      expect(lab.hpNodes, isEmpty);
      lab.hpOn = true; // nothing to turn on
      expect(lab.hpOn, isFalse);
    });

    test('a party never shares the host\'s headphone correction', () {
      final lab = AudioLab()..openForTest();
      final p = HeadphoneProfile.parse(_profile)!;
      lab.setHeadphone('Host Phones', 's', p.preamp, p.nodes);
      final shared = lab.partySound();
      expect(shared.keys.where((k) => k.startsWith('hp')), isEmpty);
    });

    testWidgets('Headphones screen: search, pick, graph', (tester) async {
      HeadphoneIndex.debugAll = const [HeadphoneEntry('Test Phones X1', 'Tester/in-ear/Test Phones X1'), HeadphoneEntry('Other Cans', 'Tester/over-ear/Other Cans')];
      await tester.pumpWidget(const MaterialApp(home: LabHeadphoneScreen()));
      await settle(tester);
      expect(find.byKey(const ValueKey('hp-graph')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('hp-search')), 'x1');
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Test Phones X1'), findsOneWidget);
      expect(find.text('Other Cans'), findsNothing);
      HeadphoneIndex.debugAll = null;
    });
  });

  group('smoothness building blocks', () {
    test('glass has no live blur by default; Real glass blur brings it back', () {
      expect(sv.settings.realBlur, isFalse);
      expect(liveBlur(), isFalse);
      expect(frostedAlpha(0.5), greaterThanOrEqualTo(0.9));
      sv.settings.realBlur = true;
      expect(liveBlur(), isTrue);
      expect(frostedAlpha(0.5), 0.5);
      sv.settings.realBlur = false;
      expect(LiquidGlass.baseTint(dark: false, strong: false, level: 2).a, greaterThanOrEqualTo(0.9));
    });

    test('far-line lyric blur is off by default', () => expect(sv.settings.blurLyrics, isFalse));

    testWidgets('a lyric line lights word by word without rebuilding', (tester) async {
      final clock = ValueNotifier(0);
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              child: Builder(
                builder: (context) {
                  builds++;
                  return FillText(
                    text: 'one two three',
                    words: const ['one', 'two', 'three'],
                    style: const TextStyle(fontSize: 20, color: Colors.white),
                    dim: Colors.white30,
                    clock: clock,
                    fills: (ms) => [(ms / 100).clamp(0.0, 1.0), ((ms - 100) / 100).clamp(0.0, 1.0), ((ms - 200) / 100).clamp(0.0, 1.0)],
                  );
                },
              ),
            ),
          ),
        ),
      );
      expect(find.text('one two three', findRichText: true), findsOneWidget);
      final clipsBefore = FillClipper.clips;
      for (var ms = 0; ms <= 300; ms += 30) {
        clock.value = ms;
        await tester.pump();
      }
      expect(builds, 1, reason: 'ticks repaint only');
      expect(FillClipper.clips - clipsBefore, greaterThanOrEqualTo(8), reason: 'the lit part follows the clock');
      final clip = tester.renderObject<RenderClipPath>(find.byType(ClipPath));
      expect(clip, isNotNull);
    });

    testWidgets('the mini lyric line follows the clock without rebuilding', (tester) async {
      final clock = ValueNotifier(0);
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                builds++;
                return LineFill(text: 'hello world', style: const TextStyle(color: Colors.white), clock: clock, fraction: (ms) => ms / 1000);
              },
            ),
          ),
        ),
      );
      for (var ms = 0; ms <= 1000; ms += 100) {
        clock.value = ms;
        await tester.pump();
      }
      expect(builds, 1);
      expect(find.text('hello world'), findsOneWidget);
    });
  });

  group('search', () {
    test('remixes, dance / club / DJ mixes go under the original', () {
      final items = [
        _song('a', 'Tum Hi Ho (Dance Mix)'),
        _song('b', 'Tum Hi Ho (DJ Remix)'),
        _song('c', 'Tum Hi Ho - Club Mix'),
        _song('d', 'Tum Hi Ho (Female Version)'),
        _song('e', 'Tum Hi Ho'),
      ];
      final r = rankSearchItems('tum hi ho', items);
      expect(r.first.id, 'e');
      expect(r[1].id, 'd', reason: 'a soft variant before the strong edits');
      // asking for it finds it first
      expect(rankSearchItems('tum hi ho remix', items).first.id, 'b');
      expect(rankSearchItems('tum hi ho dance mix', items).first.id, 'a');
    });
  });
}
