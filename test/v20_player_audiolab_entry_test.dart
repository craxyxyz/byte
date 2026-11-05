import 'package:byte/app.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/now_playing.dart' show SeekBar;
import 'package:byte/ui/player_parts.dart';
import 'package:byte/ui/screens/audio_lab_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'screens_test.dart' show settle;

/// 2.0.0+2003: the player's ⋯ sheet has an "Audio Lab" entry right after
/// "Playback speed"; one tap closes the sheet and opens the Audio Lab page,
/// and back returns to the player.
void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    sv.settings.verifyStreams = false;
  });

  testWidgets('player ⋯ → Audio Lab opens the page; back returns to the player', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
      await sv.player.playItems(album.tracks);
    });
    await tester.pumpWidget(const ByteApp());
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('mini')));
    await settle(tester);
    final ctx = tester.element(find.byType(SeekBar).first);
    showPlayerMore(ctx, sv.player.current.value!);
    await settle(tester);

    // the entry is there, with its subtitle, right after "Playback speed"
    final entry = find.widgetWithText(ListTile, 'Audio Lab');
    for (var i = 0; i < 40 && !(entry.evaluate().isNotEmpty && tester.getRect(entry).bottom <= 820); i++) {
      await tester.drag(find.byKey(const ValueKey('song-menu-list')), const Offset(0, -150));
      await tester.pump();
    }
    expect(entry, findsOneWidget);
    expect(find.text('Equalizer, headphones, effects'), findsOneWidget);
    final titles = tester.widgetList<ListTile>(find.byType(ListTile)).map((l) => (l.title as Text).data).toList();
    expect(titles[titles.indexOf('Playback speed') + 1], 'Audio Lab');
    expect(find.byType(AudioLabScreen), findsNothing);

    // tap: the sheet closes and the Audio Lab page opens
    await tester.ensureVisible(entry);
    await tester.tap(entry);
    await settle(tester);
    expect(find.byType(AudioLabScreen), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);

    // back: the player is still there
    Navigator.of(tester.element(find.byType(AudioLabScreen)), rootNavigator: true).pop();
    await settle(tester);
    expect(find.byType(AudioLabScreen), findsNothing);
    expect(find.byType(SeekBar), findsWidgets);

    await tester.runAsync(() => sv.player.stop());
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
