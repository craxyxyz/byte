// © 2026 Apurba Laskar
// 1.4.5.1 (shared part, in the Android/web 1.4.6 build): the output label on a
// computer says "This computer", not "Apurba's Phone". The Windows sound-filter
// tests live with the desktop player package (desktop builds).
import 'package:byte/player/audio_route.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('output label', () {
    tearDown(() => AudioRouteInfo.computer = () => false);
    test('on a computer: "This computer", not "<name>\'s Phone"', () {
      AudioRouteInfo.ownerName = () => 'Apurba Laskar';
      AudioRouteInfo.computer = () => true;
      expect(const AudioRouteInfo().label, 'This computer');
      expect(const AudioRouteInfo().outputKind, 'Computer speaker');
      AudioRouteInfo.computer = () => false;
      expect(const AudioRouteInfo().label, "Apurba's Phone");
    });
  });
}
