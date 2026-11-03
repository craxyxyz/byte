// Byte © 2026 Apurba Laskar.
// 1.4.6 QA: "Add to queue" / "Download all" on an empty playlist used to say
// nothing (or "Added to queue"). Own file: it needs a fresh player.
import 'package:byte/services.dart';
import 'package:byte/ui/screens/playlist_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

    testWidgets('"Add to queue" on an empty playlist says it is empty and queues nothing', (tester) async {
      final pl = (await tester.runAsync(() => sv.library.createPlaylist('Empty one')))!;
      await tester.pumpWidget(MaterialApp(home: PlaylistScreen(id: pl.id)));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byType(PopupMenuButton<String>));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.text('Add to queue'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(emptyPlaylistMessage), findsOneWidget);
      expect(find.text('Added to queue'), findsNothing);
      expect(sv.player.queueModel.isEmpty, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    }, timeout: const Timeout(Duration(seconds: 60)));
  
}
