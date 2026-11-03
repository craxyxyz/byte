// Listen together on Apurba's REAL server with no Byte tables (the setup file
// not run yet): host + guest over the live channel only. Network test:
//   flutter test test_live/lt_live_only_test.dart
import 'package:byte/core/models.dart';
import 'package:byte/data/listen_together.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeSync implements SyncPlayer {
  final String name;
  FakeSync(this.name);
  @override
  Item? item;
  bool playing = false;
  int _posMs = 0;
  int _at = DateTime.now().millisecondsSinceEpoch;
  final ValueNotifier<int> _changes = ValueNotifier(0);
  final List<String> log = [];
  @override
  Listenable get changes => _changes;
  @override
  bool get isPlaying => playing;
  @override
  Duration get position => Duration(milliseconds: playing ? _posMs + DateTime.now().millisecondsSinceEpoch - _at : _posMs);
  void _mark(int pos) {
    _posMs = pos;
    _at = DateTime.now().millisecondsSinceEpoch;
  }

  // local user actions (host side)
  void userPlay(Item it) {
    item = it;
    playing = true;
    _mark(0);
    _changes.value++;
  }

  void userPause() {
    _mark(position.inMilliseconds);
    playing = false;
    _changes.value++;
  }

  void userResume() {
    _mark(position.inMilliseconds);
    playing = true;
    _changes.value++;
  }

  void userSeek(int ms) {
    _mark(ms);
    _changes.value++;
  }

  // driven by ListenTogether (guest side)
  @override
  Future<void> load(Item it, Duration at, {required bool play}) async {
    log.add('load ${it.id} ${at.inMilliseconds} $play');
    item = it;
    playing = play;
    _mark(at.inMilliseconds);
  }

  @override
  Future<void> seekTo(Duration d) async {
    log.add('seek ${d.inMilliseconds}');
    _mark(d.inMilliseconds);
  }

  @override
  Future<void> setPlaying(bool play) async {
    log.add('play $play');
    _mark(position.inMilliseconds);
    playing = play;
  }
}

void main() {
  const song1 = Item(kind: ItemKind.song, id: 'abc123', title: 'Tum Hi Ho', artists: [ArtistRef('Arijit Singh')]);
  test('party works on the live channel alone (no tables on the server)', () async {
    final hp = FakeSync('host'), gp = FakeSync('guest');
    final host = ListenTogether(player: hp, deviceId: 'h-${DateTime.now().millisecondsSinceEpoch}', displayName: () => 'Apurba');
    final guest = ListenTogether(player: gp, deviceId: 'g-${DateTime.now().millisecondsSinceEpoch}', displayName: () => 'Friend');
    hp.userPlay(song1);
    expect(await host.host(capacity: 4), isTrue, reason: host.error);
    expect(host.liveOnly, isTrue, reason: 'this server has no Byte tables yet');
    final code = host.code!;
    expect(await guest.join(code), isTrue, reason: guest.error);
    expect(guest.liveOnly, isTrue);
    expect(gp.item?.id, 'abc123');
    expect(guest.hostName, 'Apurba');
    hp.userSeek(60000);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect((gp.position.inMilliseconds - hp.position.inMilliseconds).abs(), lessThan(1500));
    // a wrong code says so instead of hanging
    final lost = ListenTogether(player: FakeSync('x'), deviceId: 'x-${DateTime.now().millisecondsSinceEpoch}', displayName: () => 'X');
    expect(await lost.join('ZZZZZ9'), isFalse);
    expect(lost.error, contains('No party'));
    await guest.leave();
    await host.leave();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
