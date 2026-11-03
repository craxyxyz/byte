import 'package:byte/core/models.dart';
import 'package:byte/data/playlist_import.dart';
import 'package:byte/ui/import_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

/// Playlist import from other apps: page readers (shapes copied from the real
/// pages), text / CSV / M3U lists, service detection and match scoring.
void main() {
  test('every service is recognised from its share link', () {
    const cases = {
      'https://open.spotify.com/playlist/6WgaVgtRZgtmDrWVUWU1R5?si=x': MusicService.spotify,
      'https://spotify.link/abc': MusicService.spotify,
      'https://music.apple.com/in/playlist/x/pl.d60caf02': MusicService.apple,
      'https://music.youtube.com/playlist?list=PL1': MusicService.youtube,
      'https://youtu.be/abc': MusicService.youtube,
      'https://www.jiosaavn.com/featured/x/Iz0pi7nkjUE_': MusicService.jiosaavn,
      'https://gaana.com/playlist/gaana-dj-hindi-top-50-1': MusicService.gaana,
      'https://music.amazon.in/playlists/B09Z31W6FV': MusicService.amazon,
      'https://soundcloud.com/u/sets/s': MusicService.soundcloud,
      'https://www.deezer.com/en/playlist/5714603022': MusicService.deezer,
      'https://wynk.in/music/playlist/x/bb_1': MusicService.wynk,
      'https://example.com/my-list': MusicService.web,
    };
    cases.forEach((k, v) => expect(detectService(k), v, reason: k));
    expect(detectService('not a link'), isNull);
    expect(firstLink('Listen on Spotify: https://open.spotify.com/playlist/abc?si=1 enjoy'), 'https://open.spotify.com/playlist/abc?si=1');
  });

  test('pasted song lists', () {
    final t = parseTextList("""
1. Tum Hi Ho - Arijit Singh
2) Kesariya – Pritam
- Apna Bana Le by Sachin-Jigar
• তোমায় হৃদ মাঝারে রাখিব — Lopamudra Mitra
Raabta

# a comment
""");
    expect(t.map((e) => e.title), ['Tum Hi Ho', 'Kesariya', 'Apna Bana Le', 'তোমায় হৃদ মাঝারে রাখিব', 'Raabta']);
    expect(t.map((e) => e.artists), ['Arijit Singh', 'Pritam', 'Sachin-Jigar', 'Lopamudra Mitra', '']);
  });

  test('CSV from Exportify and TuneMyMusic, TSV, quoted commas', () {
    final exportify = parseCsvList('"Track URI","Track Name","Artist URI(s)","Artist Name(s)","Album Name","Duration (ms)"\r\n'
        '"spotify:track:1","Tum Hi Ho","x","Arijit Singh","Aashiqui 2","262000"\r\n'
        '"spotify:track:2","Hello, Goodbye","x","The Beatles","Magical, Mystery","210000"\r\n');
    expect(exportify.length, 2);
    expect(exportify[1].title, 'Hello, Goodbye');
    expect(exportify[1].album, 'Magical, Mystery');
    expect(exportify[0].durationMs, 262000);
    final tmm = parseCsvList('Track name,Artist name,Album,Playlist name,Type,ISRC\nKesariya,Pritam;Arijit Singh,Brahmastra,Mine,Playlist,X\n');
    expect(tmm.single.artists, 'Pritam, Arijit Singh');
    final tsv = parseCsvList('Title\tArtist\tLength\nRaabta\tArijit Singh\t4:03\n');
    expect(tsv.single.durationMs, 243000);
    expect(parseCsvList('Tum Hi Ho - Arijit Singh\nKesariya - Pritam').length, 2, reason: 'plain TXT');
  });

  test('M3U lists', () {
    final m = parseM3u('#EXTM3U\n#EXTINF:262,Arijit Singh - Tum Hi Ho\n/music/a.mp3\n/sdcard/Music/Kesariya - Pritam.mp3\n');
    expect(m.length, 2);
    expect(m[1].title, 'Kesariya');
  });

  test('schema.org playlists (Gaana and other sites)', () {
    const html = '<script type="application/ld+json">{"@type":"WebPage"}</script>'
        '<script type="application/ld+json">{"@context":"https://schema.org","@type":"MusicPlaylist","name":"Hindi Top 50","numTracks":100,'
        '"image":"https://x/c.webp","track":[{"@type":"MusicRecording","name":"Parvati","inAlbum":{"name":"Hanuman Ansh"},"duration":"PT04M44S",'
        '"byArtist":{"@type":"Person","name":"Sadhu Tiwari"}},{"@type":"MusicRecording","name":"Jai Jai Ram &amp; Sita","byArtist":[{"name":"A"},{"name":"B"}]}]}</script>';
    final l = parseJsonLdList(html, MusicService.gaana, 'gaana:x')!;
    expect(l.name, 'Hindi Top 50');
    expect(l.tracks.length, 2);
    expect(l.tracks.first.durationMs, 284000);
    expect(l.tracks.first.album, 'Hanuman Ansh');
    expect(l.tracks[1].title, 'Jai Jai Ram & Sita');
    expect(l.tracks[1].artists, 'A, B');
    expect(l.partial, isTrue);
  });

  test('Apple Music page data', () {
    const html = '<meta property="og:title" content="Bollywood Hits on Apple Music">'
        '<script type="application/json" id="serialized-server-data">{"data":[{"data":{"sections":[{"items":['
        '{"id":"track-lockup - pl - 1","title":"Chann","artistName":"Sachin-Jigar & Arijit Singh","duration":217765,'
        '"contentDescriptor":{"kind":"song"},"tertiaryLinks":[{"title":"Udta Teer"}]},'
        '{"id":"track-lockup - pl - 2","title":"Naal Nachna","artistName":"Shashwat Sachdev","duration":180000,"contentDescriptor":{"kind":"song"}}'
        ']}]}}]}</script>';
    final l = parseAppleMusic(html, 'apple:pl')!;
    expect(l.name, 'Bollywood Hits');
    expect(l.tracks.length, 2);
    expect(l.tracks.first.album, 'Udta Teer');
    expect(l.tracks.first.durationMs, 217765);
  });

  test('Amazon Music page rows', () {
    const html = '<music-detail-header image-src="https://m/c.jpg" headline="Long Drive with Bollywood" tertiary-text="60 SONGS  •  4 HOURS"></music-detail-header>'
        '<music-image-row index="1" primary-text="Tu Mil Jaaye (From &quot;KING&quot;)" duration="03:30"><music-link secondary-text-1="Arijit Singh"></music-link>'
        '<x secondary-text-2="KING"></x></music-image-row>'
        '<music-image-row index="2" primary-text="Patakha Guddi" duration="04:07" secondary-text-1="Nooran Sisters"></music-image-row>';
    final l = parseAmazonMusic(html, 'amazon:x')!;
    expect(l.name, 'Long Drive with Bollywood');
    expect(l.tracks.length, 2);
    expect(l.tracks.first.title, 'Tu Mil Jaaye (From "KING")');
    expect(l.tracks.first.artists, 'Arijit Singh');
    expect(l.tracks.first.album, 'KING');
    expect(l.tracks[1].durationMs, 247000);
    expect(l.total, 60);
  });

  test('SoundCloud hydration: full tracks and ids still to fetch', () {
    const html = '<script>window.__sc_hydration = [{"hydratable":"user","data":{}},{"hydratable":"playlist","data":{"title":"Lofi Bollywood","track_count":3,'
        '"tracks":[{"id":1,"title":"Mehrama - Lofi","duration":169041,"user":{"username":"unique music"},"publisher_metadata":{"artist":"Pritam"}},{"id":2},{"id":3}]}}];</script>';
    final p = parseSoundCloud(html)!;
    expect(p.name, 'Lofi Bollywood');
    expect(p.tracks.single.artists, 'Pritam');
    expect(p.missing, [2, 3]);
    expect(p.total, 3);
  });

  test('helpers', () {
    expect(spotifyGidHex('79jYT83v4bMOWEgwjQxSx2'), 'eaf0367bd89a47c3b70c352a3b4afdb0');
    expect(unescapeHtml('Kesariya (From &quot;Brahmastra&quot;) &amp; more &#39;x&#39; &#x263A;'), 'Kesariya (From "Brahmastra") & more \'x\' ☺');
    expect(isoDurationMs('PT1H2M3S'), 3723000);
    expect(clockMs('1:02:03'), 3723000);
  });

  group('match scoring', () {
    const src = ExtTrack('Tum Hi Ho', 'Arijit Singh', durationMs: 262000);
    const right = Item(kind: ItemKind.song, id: 'a', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], durationSec: 262);
    const remix = Item(kind: ItemKind.song, id: 'b', title: 'Tum Hi Ho (Remix)', artists: [ArtistRef('DJ X')], durationSec: 200);
    const cover = Item(kind: ItemKind.video, id: 'c', title: 'Tum Hi Ho cover', artists: [ArtistRef('Someone')], durationSec: 250);
    test('the original beats remixes and covers', () {
      expect(matchScore(src, right), greaterThan(matchScore(src, remix)));
      expect(matchScore(src, right), greaterThan(matchScore(src, cover)));
      expect(matchScore(src, right), greaterThanOrEqualTo(PlaylistMatcher.minScore));
      expect(matchScore(src, remix), lessThan(PlaylistMatcher.minScore));
    });
    test('"(From …)" and "feat." don\'t hurt', () {
      const s2 = ExtTrack('Kesariya (From "Brahmastra")', 'Pritam, Arijit Singh');
      const c2 = Item(kind: ItemKind.song, id: 'k', title: 'Kesariya', artists: [ArtistRef('Pritam'), ArtistRef('Arijit Singh')]);
      expect(matchScore(s2, c2), greaterThan(2.5));
    });
    test('an "Artist - Song" line works either way round', () {
      const swapped = ExtTrack('Arijit Singh', 'Tum Hi Ho');
      expect(matchScore(swapped, right), greaterThanOrEqualTo(PlaylistMatcher.minScore));
    });
    test('Hindi and Bengali titles', () {
      const s3 = ExtTrack('তোমায় হৃদ মাঝারে রাখিব', 'Lopamudra Mitra');
      const c3 = Item(kind: ItemKind.song, id: 'z', title: 'তোমায় হৃদ মাঝারে রাখিব', artists: [ArtistRef('Lopamudra Mitra')]);
      expect(matchScore(s3, c3), greaterThan(2.5));
    });
  });
}
