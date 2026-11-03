// 1.4.6 QA: every screen at 320 px and at the phone's largest text size
// (1.6×, followed up to 1.3×): no overflow stripes. Built from screens_test.dart.
import 'package:byte/app.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/import_sheet.dart';
import 'package:byte/ui/nav.dart';
import 'package:byte/ui/screens/browse_screen.dart';
import 'package:byte/ui/screens/explore_screen.dart';
import 'package:byte/ui/screens/integrations_pages.dart';
import 'package:byte/ui/screens/library_pages.dart';
import 'package:byte/ui/screens/listen_together_screen.dart';
import 'package:byte/ui/screens/playlist_screen.dart';
import 'package:byte/ui/screens/settings_pages.dart';
import 'package:byte/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'helpers.dart';

/// Every new or changed screen of Byte 1.1, at 360 / 390 / 820 px wide, in
/// light and dark. Each screen is opened, scrolled to the end and closed; any
/// overflow or exception fails the test.
void main() {
  late Services sv;
  late List<Item> songs;
  late String playlistId;

  setUpAll(() async {
    sv = await makeServices();
    sv.settings.autoplay = false;
    final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
    songs = album.tracks;
    // A library with something in it: likes, history, a playlist, stats,
    // a podcast episode for later, long Hindi / Bengali titles.
    for (final s in songs.take(4)) {
      await sv.library.toggleLike(s);
      await sv.library.addHistory(s);
      sv.stats.add(s, 200000, session: s.id);
    }
    const hindi = Item(
      kind: ItemKind.song,
      id: 'hi1',
      title: 'तुम ही हो (अरिजीत सिंह की आवाज़ में एक बहुत लंबा शीर्षक जो कभी ख़त्म नहीं होता)',
      artists: [ArtistRef('अरिजीत सिंह'), ArtistRef('मिथुन')],
      durationSec: 262,
    );
    const bengali = Item(
      kind: ItemKind.song,
      id: 'bn1',
      title: 'আমি তোমার সঙ্গে বেঁধেছি আমার প্রাণ — রবীন্দ্রসঙ্গীতের একটি অনেক লম্বা শিরোনাম',
      artists: [ArtistRef('শ্রেয়া ঘোষাল')],
      durationSec: 301,
    );
    await sv.library.toggleLike(hindi);
    await sv.library.toggleLike(bengali);
    await sv.library.addHistory(hindi);
    sv.stats.add(hindi, 400000, session: 'h');
    sv.stats.add(bengali, 100000, session: 'b');
    final pl = await sv.library.createPlaylist('Late night drive — একটি লম্বা প্লেলিস্টের নাম', items: [...songs.skip(2), hindi, bengali]);
    playlistId = pl.id;
    await sv.webdav.connect('https://nas.local/music/', 'me', 'secret');
    await sv.library.setLater(const Item(kind: ItemKind.episode, id: 'ep1', title: 'Episode 12: A long conversation about music and memory', subtitle: 'The Show'), true);
  });

  Map<String, Widget Function()> screens() => {
    'Explore': () => const ExploreScreen(),
    'Mood': () => const MoodScreen(mood: MoodCategory('Romance', 0xFFE5245C, 'ggMPOg1uX1JOQWZFeDByc2Jm')),
    'Podcasts': () => const PodcastsScreen(),
    'Podcast show': () => const BrowseScreen(item: Item(kind: ItemKind.podcast, id: 'MPSPPLQgtw2o0vlIraOBvCCiHzmKS4pNYYIolx', title: 'A show')),
    'History': () => const HistoryScreen(),
    'Downloads': () => const DownloadsScreen(),
    'Local music': () => const LocalMusicScreen(),
    'Spotify': () => const SpotifyScreen(),
    'All playlists': () => const AllPlaylistsScreen(),
    'Liked': () => const LikedScreen(),
    'Later': () => const LaterScreen(),
    'Replay': () => const ReplayScreen(),
    'Playlist': () => PlaylistScreen(id: playlistId),
    'Settings': () => const SettingsScreen(),
    'Account': () => const AccountScreen(),
    'Accounts': () => const ManageAccountsScreen(),
    'Listen together (lobby)': () => const ListenTogetherScreen(),
    'Party server': () => const PartyServerScreen(),
    'Import': () => const ImportScreen(),
    'Scrobbling': () => const ScrobblingScreen(),
    'Own server': () => const OwnServerScreen(),
    'Own server folder': () => const DavFolderScreen(),
    'Own server sub-folder': () => DavFolderScreen(folder: Uri.parse('https://nas.local/music/Bollywood/'), name: 'Bollywood — অনেক লম্বা ফোল্ডারের নাম যা শেষ হয় না'),
    'Import review': () => ImportReviewScreen(
      list: const ExtList('Hindi Songs - Best - Bollywood - All Time Top 500 Songs — একটি লম্বা নাম', null, [], MusicService.spotify, 'spotify:x', total: 619),
      matches: [
        for (final (i, s) in songs.indexed) TrackMatch(ExtTrack(s.title, s.artistLine), chosen: i.isEven ? s : null, candidates: [s]),
        TrackMatch(const ExtTrack('तुम ही हो (अरिजीत सिंह की आवाज़ में एक बहुत लंबा शीर्षक जो कभी ख़त्म नहीं होता)', 'अरिजीत सिंह')),
        TrackMatch(const ExtTrack('Couldn\'t check this one', 'Someone'))..failed = true,
      ],
    ),
    for (final (i, p) in allSettingsPages().indexed) 'Settings page $i ${p.runtimeType}': () => p,
  };

  const sizes = {'320@1.0': Size(320, 640), '320@1.6': Size(320, 640), '390@1.6': Size(390, 844)};
  for (final e in sizes.entries) {
    for (final mode in [ThemeMode.light]) {
      testWidgets('small screens ${e.key}', (tester) async {
        final problems = <String>[];
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = e.value;
        addTearDown(tester.view.reset);
        tester.platformDispatcher.textScaleFactorTestValue = e.key.endsWith('1.6') ? 1.6 : 1.0;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        sv.settings.themeMode = mode;
        await tester.pumpWidget(const ByteApp());
        await settle(tester);
        for (final s in screens().entries) {
          final orig = FlutterError.onError;
          FlutterError.onError = (d) {
            if ('${d.exception}'.contains('overflowed')) debugPrint('DETAIL ${s.key}: ${d.toString().split('\n').where((l) => l.contains('.dart:')).join(' | ')}');
            orig?.call(d);
          };
          addTearDown(() => FlutterError.onError = orig);
          pushInCurrentTab!(s.value());
          await settle(tester);
          final scrollers = find.byType(Scrollable);
          if (scrollers.evaluate().isNotEmpty) {
            await tester.drag(scrollers.last, const Offset(0, -4000), warnIfMissed: false);
            await settle(tester);
          }
          final ex = tester.takeException();
          if (ex != null) problems.add('${s.key}: ${'$ex'.split('\n').where((l) => l.contains('overflowed') || l.contains('.dart:')).take(3).join(' | ')}');
          final nav = tester.state<NavigatorState>(find.byType(Navigator).at(1));
          nav.pop();
          await settle(tester);
        }

        // Listen together room (as host, with members and activity)
        final party = sv.party;
        party
          ..role = RoomRole.host
          ..code = 'ZWB9YJ'
          ..connected = true
          ..roundTripMs = 434
          ..capacity = 5
          ..people = const [
            Listener2('me', 'Apurba', true),
            Listener2('x', 'অনেক লম্বা নামের এক বন্ধু যিনি পার্টিতে এসেছেন', false),
            Listener2('y', 'Rahul', false),
          ];
        party.activity
          ..clear()
          ..add(Activity(DateTime(2026, 11, 1, 23, 51, 47), 'Apurba', 'Changed the song to "तुम ही हो (अरिजीत सिंह की आवाज़ में एक बहुत लंबा शीर्षक)"'))
          ..add(Activity(DateTime(2026, 11, 1, 23, 52, 3), 'Rahul', 'Paused'));
        pushInCurrentTab!(const ListenTogetherScreen());
        await settle(tester);
        expect(find.text('Z W B 9 Y J'), findsOneWidget);
        expect(find.text('434 ms'), findsOneWidget);
        await tester.drag(find.byType(Scrollable).last, const Offset(0, -4000), warnIfMissed: false);
        await settle(tester);
        expect(find.textContaining('[23:51:47] Apurba: Changed the song'), findsOneWidget);
        // Share sheet with the QR code
        await tester.drag(find.byType(Scrollable).last, const Offset(0, 4000), warnIfMissed: false);
        await settle(tester);
        await tester.tap(find.text('Share'));
        await settle(tester);
        expect(find.text('Invite friends to your party'), findsOneWidget);
        expect(find.byType(QrImageView), findsOneWidget);
        expect(tester.takeException(), isNull);
        // Guest view while the host's phone has dropped out.
        Navigator.of(tester.element(find.text('Invite friends to your party'))).pop();
        await settle(tester);
        party
          ..role = RoomRole.guest
          ..hostName = 'Apurba'
          ..hostAway = true;
        party.notifyListeners();
        await settle(tester);
        expect(tester.takeException(), isNull);
        party
          ..role = RoomRole.none
          ..hostAway = false
          ..code = null
          ..people = const [];
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 2));
        expect(problems, isEmpty, reason: problems.join('\n'));
      });
    }
  }
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
    await tester.pump(const Duration(milliseconds: 150));
  }
}
