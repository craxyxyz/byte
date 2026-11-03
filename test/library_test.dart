import 'package:byte/core/models.dart';
import 'package:byte/data/library.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Item s(String id) => Item(kind: ItemKind.song, id: id, title: 'Song $id', artists: const [ArtistRef('A')]);

void main() {
  late Library lib;
  setUpAll(() async {
    lib = (await makeServices()).library;
  });

  test('likes: newest first, toggle', () async {
    await lib.setLiked(s('1'), true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await lib.setLiked(s('2'), true);
    expect(lib.likes.map((e) => e.id), ['2', '1']);
    expect(await lib.toggleLike(s('1')), isFalse);
    expect(lib.isLiked('1'), isFalse);
  });

  test('playlists: create, add (no duplicates), rename, reorder, remove', () async {
    final a = await lib.createPlaylist('Road trip');
    final b = await lib.createPlaylist('Gym');
    expect(await lib.addToPlaylist(a.id, [s('1'), s('2'), s('3')]), 3);
    expect(await lib.addToPlaylist(a.id, [s('2'), s('4')]), 1);
    expect(lib.playlist(a.id)!.items.map((e) => e.id), ['1', '2', '3', '4']);
    await lib.renamePlaylist(a.id, 'Long drive');
    expect(lib.playlist(a.id)!.name, 'Long drive');
    await lib.reorderPlaylistItem(a.id, 3, 0);
    expect(lib.playlist(a.id)!.items.map((e) => e.id), ['4', '1', '2', '3']);
    await lib.removeFromPlaylist(a.id, 1);
    expect(lib.playlist(a.id)!.items.map((e) => e.id), ['4', '2', '3']);
    final order = lib.playlists.map((p) => p.id).toList();
    await lib.reorderPlaylists(order.indexOf(b.id), 0);
    expect(lib.playlists.first.id, b.id);
    await lib.deletePlaylist(b.id);
    expect(lib.playlist(b.id), isNull);
  });

  test('history: newest first, no repeats, can clear', () async {
    await lib.addHistory(s('1'));
    await lib.addHistory(s('2'));
    await lib.addHistory(s('1'));
    expect(lib.history.map((e) => e.item.id).take(2), ['1', '2']);
    expect(lib.history.where((e) => e.item.id == '1').length, 1);
    await lib.clearHistory();
    expect(lib.history, isEmpty);
  });

  test('recent searches', () async {
    await lib.addSearch('arijit');
    await lib.addSearch('kesariya');
    await lib.addSearch('arijit');
    expect(lib.searches, ['arijit', 'kesariya']);
    await lib.removeSearch('arijit');
    expect(lib.searches, ['kesariya']);
  });

  test('download records keep the song info', () async {
    await lib.putDownload(DownloadRecord(item: s('d1'), path: '/x/d1.m4a', coverPath: null, bytes: 123, mime: 'audio/mp4', at: DateTime(2026)));
    expect(lib.isDownloaded('d1'), isTrue);
    expect(lib.download('d1')!.item.title, 'Song d1');
    await lib.removeDownloadRecord('d1');
    expect(lib.isDownloaded('d1'), isFalse);
  });
}
