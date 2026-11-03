// Byte © 2026 Apurba Laskar.
// 1.4.6 feature audit (FEATURES.md): features that worked but had no test.
import 'package:byte/core/models.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/player_parts.dart' show showSongInfo;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const it = Item(kind: ItemKind.song, id: 'si1', title: 'Kesariya', artists: [ArtistRef('Arijit Singh')], album: 'Brahmastra', durationSec: 268);

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.stats.add(it, 180000, session: 's1');
    sv.stats.add(it, 180000, session: 's2');
    await sv.library.addHistory(it);
    await Future<void>.delayed(const Duration(seconds: 2)); // let the stats save
  });

  testWidgets('Song info (⋯ → Song info): album, length and your own plays', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (c) => Scaffold(body: Center(child: TextButton(onPressed: () => showSongInfo(c, it), child: const Text('info'))))),
      ),
    );
    await tester.tap(find.text('info'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('Kesariya'), findsOneWidget);
    expect(find.text('Brahmastra'), findsOneWidget);
    expect(find.text('4:28'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'two plays counted');
    expect(find.text('6 min'), findsOneWidget);
    expect(find.text('First played'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
