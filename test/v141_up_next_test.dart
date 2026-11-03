import 'package:byte/core/models.dart';
import 'package:byte/dj/recommender.dart';
import 'package:byte/dj/up_next.dart';
import 'package:flutter_test/flutter_test.dart';

// Byte 1.4.1: up next ranked by the listener's own signals.

Item s(String id, String title, String artist, {ItemKind kind = ItemKind.song}) => Item(kind: kind, id: id, title: title, artists: [ArtistRef(artist)], durationSec: 240);

TasteProfile taste({List<Item> liked = const [], List<Item> skipped = const [], List<Item> recent = const [], Map<String, double> artists = const {}}) {
  final t = TasteProfile();
  for (final it in liked) {
    t.songs[it.id] = it;
    t.liked.add(it.id);
    t.plays[it.id] = 5;
    t.completion[it.id] = 0.95;
  }
  for (final it in skipped) {
    t.songs[it.id] = it;
    t.skips[it.id] = 3;
    t.artistSkipRate[it.artists.first.name.toLowerCase()] = 1.0;
  }
  t.recent.addAll(recent);
  t.artist.addAll(artists);
  return t;
}

void main() {
  final seed = s('seed', 'Kesariya (From "Brahmastra")', 'Arijit Singh');

  test('uploads of the same song count once; covers and slowed versions too', () {
    expect(songKey(s('a', 'Kesariya (Official Video) | Brahmastra', 'T-Series')), songKey(seed));
    expect(songKey(s('b', 'Kesariya Slowed + Reverb', 'Lofi Boy')), 'kesariya');
    expect(songKey(s('c', 'Tomake Chai Title track', 'Arijit Singh')), 'tomake chai');
    final radio = [
      s('v1', 'Kesariya - Lyrical Video', 'Sony Music India', kind: ItemKind.video),
      s('x1', 'Apna Bana Le', 'Arijit Singh'),
      s('x2', 'Apna Bana Le (Lyrics)', 'Lyrics Hub', kind: ItemKind.video),
      s('x3', 'Apna Bana Le - Slowed', 'Someone'),
    ];
    final out = PersonalRadio.rank(seed, [radio], taste());
    expect(out.map((p) => p.item.id), ['x1']); // the seed's own uploads gone, one Apna Bana Le
  });

  test('nothing from the last 50 plays; skipped songs and artists sink', () {
    final recent = [for (var i = 0; i < 50; i++) s('r$i', 'Recent $i', 'Artist $i')];
    final badArtist = s('b0', 'Paani Paani', 'Badshah');
    final radio = [s('r3', 'Recent 3', 'Artist 3'), s('b1', 'Genda Phool', 'Badshah'), s('ok', 'Raabta', 'Arijit Singh'), s('r49', 'Recent 49', 'Artist 49')];
    final out = PersonalRadio.rank(seed, [radio], taste(skipped: [badArtist], recent: recent));
    expect(out.map((p) => p.item.id).toList(), ['ok', 'b1']);
    // a 51st-oldest play may come back
    final out2 = PersonalRadio.rank(seed, [[s('r50', 'Old one', 'X')]], taste(recent: [...recent, s('r50', 'Old one', 'X')]));
    expect(out2.single.item.id, 'r50');
  });

  test('the seed\'s language is kept', () {
    final radio = [s('en', 'Shape of You', 'Ed Sheeran'), s('hi', 'Tum Hi Ho', 'Arijit Singh'), s('hi2', 'Raabta', 'Arijit Singh')];
    final out = PersonalRadio.rank(seed, [radio], taste());
    expect(out.last.item.id, 'en');
  });

  test('about 70 % familiar, 30 % new, at most 2 per artist in any 10', () {
    final known = [for (var i = 0; i < 20; i++) s('k$i', 'Loved $i', 'Fav ${i % 10}')];
    final fresh = [for (var i = 0; i < 20; i++) s('n$i', 'New $i', 'Other ${i % 10}')];
    final out = PersonalRadio.rank(seed, [fresh, known], taste(liked: known), count: 20);
    expect(out.length, 20);
    expect(out.where((p) => p.familiar).length, 14);
    for (var i = 0; i + 10 <= out.length; i++) {
      final w = out.sublist(i, i + 10);
      for (final p in w) {
        expect(w.where((q) => q.item.artistLine == p.item.artistLine).length, lessThanOrEqualTo(2));
      }
    }
  });

  test('their own seed: same artist first, then same language, never a song they skip', () {
    final liked = [s('l1', 'Raabta', 'Arijit Singh'), s('l2', 'Pehla Nasha', 'Udit Narayan')];
    final t = taste(liked: liked, skipped: [s('sk', 'Channa Mereya', 'Arijit Singh')]);
    expect(PersonalRadio.personalSeed(seed, t)!.id, 'l1');
    expect(PersonalRadio.ownSongsFor(seed, t).map((i) => i.id), contains('l1'));
  });

  test('Bengali songs written in Latin letters are Bengali', () {
    expect(languageOf(s('b', 'Tomake Chai', 'Arijit Singh')), 'bengali');
    expect(languageOf(s('b2', 'Bojhena Shey Bojhena', 'Arijit Singh')), 'bengali');
    expect(languageOf(s('h', 'Tum Hi Ho', 'Arijit Singh')), 'hindi');
  });
}
