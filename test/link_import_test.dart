import 'package:byte/core/innertube.dart';
import 'package:byte/core/models.dart';
import 'package:byte/data/link_import.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('parseLink', () {
    final cases = <String, (LinkKind, String)>{
      'https://music.youtube.com/playlist?list=PLabcdefghijklmnop': (LinkKind.ytPlaylist, 'PLabcdefghijklmnop'),
      'https://www.youtube.com/playlist?list=PLabcdefghijklmnop&si=xyz': (LinkKind.ytPlaylist, 'PLabcdefghijklmnop'),
      'https://youtube.com/watch?v=dQw4w9WgXcQ&list=PLabcdefghijklmnop&index=3': (LinkKind.ytPlaylist, 'PLabcdefghijklmnop'),
      'https://youtu.be/dQw4w9WgXcQ?si=abc': (LinkKind.ytVideo, 'dQw4w9WgXcQ'),
      'https://m.youtube.com/watch?v=dQw4w9WgXcQ': (LinkKind.ytVideo, 'dQw4w9WgXcQ'),
      'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVMdQw4w9WgXcQ': (LinkKind.ytVideo, 'dQw4w9WgXcQ'),
      'https://youtube.com/shorts/dQw4w9WgXcQ': (LinkKind.ytVideo, 'dQw4w9WgXcQ'),
      'https://music.youtube.com/browse/MPREb_E4GfUXfDfhy': (LinkKind.ytAlbum, 'MPREb_E4GfUXfDfhy'),
      'https://music.youtube.com/playlist?list=OLAK5uy_kDxY4xsmWdGvYXIzj1bhPEDBkd7cqOTCY': (LinkKind.ytAlbum, 'OLAK5uy_kDxY4xsmWdGvYXIzj1bhPEDBkd7cqOTCY'),
      'https://music.youtube.com/channel/UCDxKh1gFWeYsqePvgVzmPoQ': (LinkKind.ytArtist, 'UCDxKh1gFWeYsqePvgVzmPoQ'),
      'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=1234': (LinkKind.spotifyPlaylist, '37i9dQZF1DXcBWIGoYBM5M'),
      'https://open.spotify.com/intl-de/album/4aawyAB9vmqN3uQ7FjRGTy': (LinkKind.spotifyAlbum, '4aawyAB9vmqN3uQ7FjRGTy'),
      'spotify:track:7bxaFZ1O3cHkgLKMsdC3xR': (LinkKind.spotifyTrack, '7bxaFZ1O3cHkgLKMsdC3xR'),
      'Check this out! https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M': (LinkKind.spotifyPlaylist, '37i9dQZF1DXcBWIGoYBM5M'),
      'https://spotify.link/AbCdEf': (LinkKind.spotifyShort, 'https://spotify.link/AbCdEf'),
      'PLabcdefghijklmnop': (LinkKind.ytPlaylist, 'PLabcdefghijklmnop'),
      'arijit singh songs': (LinkKind.unknown, ''),
      'https://example.com/playlist?list=PL1': (LinkKind.unknown, ''),
    };
    cases.forEach((input, want) {
      test(input, () {
        final p = parseLink(input);
        expect((p.kind, p.id), want);
      });
    });
  });

  test('Spotify embed page → playlist name and tracks (no account needed)', () {
    final l = parseSpotifyEmbed(fixture('spotify_embed.html'))!;
    expect(l.name, isNotEmpty);
    expect(l.tracks.length, greaterThanOrEqualTo(40));
    expect(l.tracks.first.title, isNotEmpty);
    expect(l.tracks.first.artists, isNotEmpty);
    expect(l.tracks.first.durationMs, greaterThan(60000));
    expect(parseSpotifyEmbed('<html>nothing</html>'), isNull);
  });

  test('matching a Spotify track to the right YouTube Music song', () {
    const t = SpotifyTrack('Tum Hi Ho', 'Arijit Singh', 262000);
    final cands = [
      const Item(kind: ItemKind.video, id: 'v1', title: 'Tum Hi Ho Karaoke', artists: [ArtistRef('Karaoke Hub')], durationSec: 300),
      const Item(kind: ItemKind.song, id: 's1', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')], durationSec: 262),
    ];
    expect(pickMatch(t, cands)!.id, 's1');
    expect(pickMatch(const SpotifyTrack('Completely Different', 'Nobody', 100000), cands), isNull);
  });

  test('import a YouTube Music playlist link end to end (fake network)', () async {
    final net = FakeNet(catalogue);
    final r = await LinkImporter(InnerTube(net), net).import('https://music.youtube.com/playlist?list=PLNjIr3ro3NNdl0GFDzvr0ypQYbHsZAy_g');
    expect(r.items.length, greaterThanOrEqualTo(100));
    expect(r.source, 'youtube:PLNjIr3ro3NNdl0GFDzvr0ypQYbHsZAy_g');
    // follows continuations until YouTube stops giving them (fake: same page)
    expect(net.log.where((x) => x.url.path.endsWith('/browse')).length, greaterThan(1));
  });

  test('unknown link gives a friendly error', () async {
    final net = FakeNet(catalogue);
    expect(() => LinkImporter(InnerTube(net), net).import('hello'), throwsA(isA<FormatException>()));
  });
}
