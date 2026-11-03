import 'package:byte/services.dart';
import 'package:byte/ui/lyrics_view.dart';
import 'package:byte/ui/now_playing.dart' show SeekBar;
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';
import 'v13_player_lyrics_test.dart' show openPlayer, closeAll;

// Byte 1.4: lyrics full screen after a few quiet seconds (Apurba's reference video).
void main() {
  late Services sv;
  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
  });

  testWidgets('1.4 lyrics go full screen after a few quiet seconds; a tap brings the controls back', (tester) async {
    addTearDown(tester.view.reset);
    sv.settings.lyricsAutoFullScreen = true;
    await openPlayer(tester, sv);
    await tester.tap(find.byTooltip('Lyrics'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SeekBar), findsOneWidget);
    expect(LyricsPane.idle.value, isFalse);
    // 5 quiet seconds
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(LyricsPane.idle.value, isTrue);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SeekBar), findsNothing, reason: 'controls folded: lyrics fill the screen');
    // a touch anywhere: controls come back
    await tester.tapAt(const Offset(200, 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(LyricsPane.idle.value, isFalse);
    expect(find.byType(SeekBar), findsOneWidget);
    // turned off in Settings: stays put
    sv.settings.lyricsAutoFullScreen = false;
    await tester.tapAt(const Offset(200, 400));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(LyricsPane.idle.value, isFalse);
    expect(find.byType(SeekBar), findsOneWidget);
    sv.settings.lyricsAutoFullScreen = true;
    await closeAll(tester, sv);
  });
}
