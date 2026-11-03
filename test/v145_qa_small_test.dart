// Byte © 2026 Apurba Laskar
// 1.4.5 QA (bug hunt notes): small crash fixes.
import 'package:byte/data/genres.dart';
import 'package:byte/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test('Android Auto: a malformed media id does nothing instead of throwing', () async {
    final Services sv = await makeServices();
    await sv.player.playFromMediaId('item:no-colon-here');
    await sv.player.playFromMediaId('item::x');
    expect(sv.player.current.value, isNull);
  });

  test('genres: an empty or blank tag is skipped instead of crashing', () async {
    final g = GenreGuesser(
      FakeNet(
        (r, body) => jsonRes({
          'toptags': {
            'tag': [
              {'name': '', 'count': 90},
              {'name': '  ', 'count': 50},
              {'name': 'rock', 'count': 80},
            ],
          },
        }),
      ),
    );
    final top = await g.topGenres([('A', 100)], 'k');
    expect(top.map((e) => e.$1), ['Rock']);
  });
}
