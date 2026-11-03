import 'dart:async';

import 'package:byte/core/innertube.dart';
import 'package:byte/core/innertube_parse.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/backup.dart';
import 'package:byte/data/listen_together.dart';
import 'package:byte/data/stats.dart';
import 'package:byte/player/equalizer.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/links.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

/// Byte 1.1: moods, podcasts, stats, backup, party codes, equalizer, links.
void main() {
  late Services sv;
  setUpAll(() async => sv = await makeServices());

  group('YouTube Music parsing', () {
    test('moods & genres buttons have a title, colour and params', () async {
      final moods = await InnerTube(FakeNet(catalogue)).moods();
      expect(moods.length, greaterThan(10));
      for (final m in moods) {
        expect(m.title, isNotEmpty);
        expect(m.params, isNotEmpty);
        expect(m.color >> 24, 0xFF, reason: 'opaque colour for ${m.title}');
      }
      expect(parseMoods(<String, dynamic>{}), isEmpty);
    });

    test('a mood page is shelves of playlists', () async {
      final shelves = await InnerTube(FakeNet(catalogue)).moodPage('x');
      expect(shelves, isNotEmpty);
      expect(shelves.expand((s) => s.items).where((i) => i.kind == ItemKind.playlist), isNotEmpty);
    });

    test('podcasts home, a show and its episodes', () async {
      final yt = InnerTube(FakeNet(catalogue));
      final home = await yt.podcasts();
      expect(home.expand((s) => s.items).any((i) => i.kind == ItemKind.podcast), isTrue);
      final show = await yt.podcast('MPSPPLQgtw2o0vlIraOBvCCiHzmKS4pNYYIolx');
      expect(show.tracks, isNotEmpty);
      expect(show.tracks.every((e) => e.kind == ItemKind.episode && e.isPlayable), isTrue);
    });

    test('search for shows and episodes', () async {
      final yt = InnerTube(FakeNet(catalogue));
      final shows = await yt.search('history', SearchFilter.podcasts);
      final eps = await yt.search('history', SearchFilter.episodes);
      expect(shows.where((i) => i.kind == ItemKind.podcast), isNotEmpty);
      expect(eps.where((i) => i.kind == ItemKind.episode), isNotEmpty);
    });

    test('episode durations in every format YouTube shows', () {
      expect(parseEpisodeDuration('1 hr 2 min'), 3720);
      expect(parseEpisodeDuration('45 min'), 2700);
      expect(parseEpisodeDuration('1:02:03'), 3723);
      expect(parseEpisodeDuration('nonsense'), isNull);
    });
  });

  group('listening stats', () {
    test('a play counts after 30 s in one go, minutes add up, repeats count', () async {
      final st = ListeningStats();
      await st.open();
      await st.reset();
      const a = Item(kind: ItemKind.song, id: 'a1', title: 'Song A', artists: [ArtistRef('Artist X', 'UCx')], album: 'Album Q', albumId: 'MPREq');
      const b = Item(kind: ItemKind.song, id: 'b1', title: 'Song B', artists: [ArtistRef('Artist Y')]);
      final y = DateTime.now().year;
      st.add(a, 20000, session: 's1');
      expect(st.year(y).plays, 0, reason: 'under 30 s');
      st.add(a, 15000, session: 's1');
      expect(st.year(y).plays, 1);
      st.add(a, 31000, session: 's2'); // played again
      st.add(b, 60000, session: 's3');
      final ys = st.year(y);
      expect(ys.plays, 3);
      expect(ys.songs.first.item.id, 'a1');
      expect(ys.artists.first.name, 'Artist X');
      expect(ys.albums.first.name, 'Album Q');
      expect(ys.totalMs, 126000);
    });

    test('the ticker caps a long sleep at 2 s', () async {
      final st = ListeningStats();
      await st.open();
      await st.reset();
      const a = Item(kind: ItemKind.song, id: 't1', title: 'T');
      final ticker = StatsTicker(st, isPlaying: () => true, current: () => a, playToken: () => 1);
      final t0 = DateTime(2026, 5, 1, 10);
      ticker.tick(t0);
      ticker.tick(t0.add(const Duration(hours: 3)));
      expect(st.year(2026).totalMs, 2000);
    });
  });

  test('backup: export, change things, import → back to the export', () async {
    await sv.library.toggleLike(const Item(kind: ItemKind.song, id: 'bk1', title: 'Backup song'));
    sv.settings.crossfadeSeconds = 6;
    final id = sv.settings.deviceId;
    final json = await backupJson();
    await sv.library.toggleLike(const Item(kind: ItemKind.song, id: 'bk1', title: 'Backup song'));
    sv.settings.crossfadeSeconds = 0;
    expect(sv.library.isLiked('bk1'), isFalse);
    final n = await importBackup(json);
    expect(n, greaterThan(0));
    expect(sv.library.isLiked('bk1'), isTrue);
    expect(sv.settings.crossfadeSeconds, 6);
    expect(sv.settings.deviceId, id, reason: 'the phone keeps its own id');
    expect(() => importBackup('{"app":"Other"}'), throwsFormatException);
  });

  group('listen together', () {
    test('codes: 6 characters, never the letters O or I', () {
      for (var i = 0; i < 500; i++) {
        final c = ListenTogether.newCode();
        expect(c, matches(RegExp(r'^[A-HJ-NP-Z0-9]{6}$')));
      }
      expect(ListenTogether.normaliseCode(' zwb-9yj '), 'ZWB9YJ');
      expect(ListenTogether.normaliseCode('ABCDOI'), 'ABCD01');
      expect(ListenTogether.normaliseCode('ABC'), isNull);
    });

    test('newer state wins: higher version, ties broken by device', () {
      const a = RoomState(atMs: 0, v: 3, by: 'a');
      const b = RoomState(atMs: 0, v: 4, by: 'a');
      const c = RoomState(atMs: 0, v: 4, by: 'b');
      expect(b.newerThan(a), isTrue);
      expect(a.newerThan(b), isFalse);
      expect(c.newerThan(b), isTrue);
      expect(b.newerThan(c), isFalse);
      expect(a.newerThan(null), isTrue);
      final round = RoomState.fromJson(const RoomState(atMs: 5, v: 9, by: 'z', capacity: 12, hostOnly: true, action: 'Paused').toJson());
      expect(round.capacity, 10, reason: 'clamped to 2–10');
      expect(round.hostOnly, isTrue);
      expect(round.action, 'Paused');
    });

    test('party links', () {
      expect(ByteLinks.partyCode('byte://listen/zwb9yj'), 'ZWB9YJ');
      expect(ByteLinks.partyCode('byte://listen/ZWB9YJ/'), 'ZWB9YJ');
      expect(ByteLinks.partyCode('https://example.com/listen/ZWB9YJ'), isNull);
      expect(ByteLinks.partyCode('byte://listen/'), isNull);
    });
  });

  group('settings that change behaviour', () {
    test("don't repeat songs in this session: radio skips what was already suggested", () async {
      sv.settings.noRepeatInSession = true;
      sv.settings.autoplay = true;
      final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
      await sv.player.playSong(album.tracks[0]);
      await pumpEventQueue(times: 50);
      final firstIds = sv.player.queueModel.playOrder.map((i) => i.id).toList();
      expect(firstIds.length, greaterThan(1), reason: 'radio added songs');
      await sv.player.playSong(album.tracks[1]);
      await pumpEventQueue(times: 50);
      final again = sv.player.queueModel.playOrder.map((i) => i.id).toList();
      // 1.4.5: up next has more sources than the song's radio, so the second
      // radio isn't simply shorter; nothing suggested once comes back.
      expect(again.skip(1).where(firstIds.contains), isEmpty);
      await sv.player.stop();
    });

    test('downloads wait for Wi-Fi when asked, and downloaded playlists pick up new songs', () async {
      final album = await sv.yt.album('MPREb_E4GfUXfDfhy');
      final gate = Completer<void>();
      sv.downloads.waitForWifi = () => gate.future;
      sv.settings.downloadWifiOnly = true;
      sv.settings.keepPlaylistsUpdated = true;
      final pl = await sv.library.createPlaylist('Offline', items: [album.tracks[2]]);
      await sv.downloads.downloadPlaylist(pl.id, pl.items);
      await pumpEventQueue();
      expect(sv.downloads.task(album.tracks[2].id)?.error, 'Waiting for Wi-Fi');
      expect(sv.library.downloadedPlaylists, contains(pl.id));
      // A song added later is queued by itself.
      await sv.library.addToPlaylist(pl.id, [album.tracks[3]]);
      sv.downloads.refreshPlaylists();
      expect(sv.downloads.task(album.tracks[3].id), isNotNull);
      gate.complete();
      sv.settings.downloadWifiOnly = false;
      sv.settings.keepPlaylistsUpdated = false;
    });
  });

  test('equalizer presets stretch to the phone\'s band count', () {
    expect(stretchPreset([0, 0, 0, 0, 0], 5), [0, 0, 0, 0, 0]);
    final ten = stretchPreset(eqPresets['Bass boost']!, 10);
    expect(ten.length, 10);
    expect(ten.first, 6);
    expect(ten.last, 0);
    expect(stretchPreset([1, 2], 3), [1, 1.5, 2]);
  });
}
