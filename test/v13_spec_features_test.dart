import 'package:audio_service/audio_service.dart';
import 'package:byte/core/models.dart';
import 'package:byte/player/byte_handler.dart';
import 'package:byte/services.dart';
import 'package:byte/ui/player_parts.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Item s(String id) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')], durationSec: 30);

/// Features from the behaviour study that Byte was missing.
void main() {
  late Services sv;
  late ByteAudioHandler p;
  setUp(() async {
    sv = await makeServices();
    p = sv.player;
    sv.settings.autoplay = false;
    fakeAudio.durationFor = (_) => const Duration(seconds: 30);
  });
  tearDown(() async => p.stop());

  test('pinned playlists come first in the Library, unpinning restores the order', () async {
    final a = await sv.library.createPlaylist('Alpha');
    final b = await sv.library.createPlaylist('Bravo');
    final c = await sv.library.createPlaylist('Charlie');
    await sv.library.setPinned(a.id, true);
    expect(sv.library.playlists.first.id, a.id);
    await sv.library.setPinned(c.id, true);
    expect(sv.library.playlists.take(2).map((x) => x.id).toSet(), {a.id, c.id});
    await sv.library.setPinned(a.id, false);
    await sv.library.setPinned(c.id, false);
    expect(sv.library.isPinned(a.id), isFalse);
    expect(sv.library.playlists.map((x) => x.id), containsAll([a.id, b.id, c.id]));
    for (final x in [a, b, c]) {
      await sv.library.deletePlaylist(x.id);
    }
  });

  test('song info: release year from the album page, your plays and listening time', () async {
    expect(releaseYearFrom('Album • Arijit Singh • 2022'), '2022');
    expect(releaseYearFrom('Single • 1998'), '1998');
    expect(releaseYearFrom('Playlist • 120 songs'), isNull);
    final it = s('songinfo001');
    sv.stats.add(it, 95000, session: 'x1');
    sv.stats.add(it, 40000, session: 'x2');
    final (plays, ms) = sv.stats.song('songinfo001');
    expect(plays, 2);
    expect(ms, 135000);
    expect(sv.stats.song('never00001'), (0, 0));
  });

  test('Android Auto: folders at the root, songs inside, a tap plays that list from that song', () async {
    final liked = [s('carliked001'), s('carliked002'), s('carliked003')];
    for (final it in liked) {
      await sv.library.setLiked(it, true);
    }
    final pl = await sv.library.createPlaylist('Drive', items: [s('cardrive001'), s('cardrive002')]);
    final root = await p.getChildren(AudioService.browsableRootId);
    expect(root.map((m) => m.title), containsAll(['Recently played', 'Liked songs', 'Playlists', 'Downloads']));
    expect(root.every((m) => m.playable == false), isTrue);
    final likedKids = await p.getChildren('liked');
    expect(likedKids.map((m) => m.title), containsAll(['Song carliked001', 'Song carliked002']));
    final pls = await p.getChildren('playlists');
    final drive = pls.firstWhere((m) => m.title == 'Drive');
    final driveSongs = await p.getChildren(drive.id);
    expect(driveSongs.length, 2);
    await p.playFromMediaId(driveSongs[1].id);
    expect(p.current.value!.id, 'cardrive002');
    expect(p.playingFrom.value, 'Drive');
    await sv.library.deletePlaylist(pl.id);
  });
}
