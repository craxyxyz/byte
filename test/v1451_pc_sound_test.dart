// © 2026 Apurba Laskar
// 1.4.5.1 (PC no sound): the Windows player has no sound filters. Any Audio
// Lab chain made it log "No such filter: 'alimiter'" → "Audio filter
// initialized failed!" → "Audio: no audio" and the song played silently while
// the progress bar moved. Windows now never gets a chain; a player that still
// refuses one turns the filters off and keeps the sound. Also: the output
// label on a computer says "This computer", not "Apurba's Phone".
import 'package:byte/audiolab/audio_lab.dart';
import 'package:byte/audiolab/desktop_sound_backend.dart';
import 'package:byte/audiolab/mpv_filters.dart';
import 'package:byte/player/audio_route.dart';
import 'package:byte_desktop_audio/byte_desktop_audio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The player's own lines, recorded on Windows with the bundled player.
  const windowsLines = [
    "AVFilterGraph: No such filter: 'alimiter'",
    'AVFilterGraph: Error creating filters',
    'parsing the filter graph failed',
    "Creating filter 'lavfi' failed.",
    'Audio filter initialized failed!',
  ];

  test('the Windows player\'s filter-failure lines are recognised; normal lines are not', () {
    for (final l in windowsLines) {
      expect(ByteDesktopAudio.isFilterFailure(l), isTrue, reason: l);
    }
    for (final l in ['AO: [wasapi] 48000Hz stereo 2ch float', '(+) Audio --aid=1 (opus 2ch 48000Hz)', 'Playing: https://example.com/a', 'Audio: no audio for a video track']) {
      expect(ByteDesktopAudio.isFilterFailure(l), isFalse, reason: l);
    }
  });

  group('a computer whose player has no sound filters (Windows)', () {
    setUp(() {
      ByteDesktopAudio.filtersSupported = false;
      ByteDesktopAudio.effects = '';
    });
    tearDown(() {
      ByteDesktopAudio.filtersSupported = ByteDesktopAudio.defaultFiltersSupported();
      ByteDesktopAudio.effects = '';
    });

    test('an Audio Lab chain is never sent to the player (default, Flat, Bass Booster, everything on)', () async {
      for (final m in <Map<String, Object?>>[
        {},
        {'eqOn': true, 'preset': 'Flat', 'nodes': [for (final n in nodesFromBands(eqPresets['Flat']!)) n.toJson()]},
        {'eqOn': true, 'preset': 'Bass Booster', 'nodes': [for (final n in nodesFromBands(eqPresets['Bass Booster']!)) n.toJson()]},
        {'eqOn': true, 'preset': 'Bass Booster', 'nodes': [for (final n in nodesFromBands(eqPresets['Bass Booster']!)) n.toJson()], 'rvOn': true, 'ldOn': true, 'xfOn': true, 'mono': true, 'bal': -0.25},
      ]) {
        final lab = AudioLab()..openForTest(m);
        await const DesktopSoundBackend().apply(lab, lab.nativeConfig());
        expect(ByteDesktopAudio.usableEffects, '', reason: 'chain for $m reached the player');
      }
    });

    test('the Audio Lab says "Not available on this computer" there, speed and pitch stay', () {
      final caps = const DesktopSoundBackend().caps;
      expect(caps.eq, isFalse);
      expect(caps.loudness, isFalse);
      expect(caps.reverb, isFalse);
      expect(caps.note, 'Not available on this computer');
    });
  });

  test('a computer with a full player (Linux) still gets the Audio Lab', () async {
    ByteDesktopAudio.filtersSupported = true;
    addTearDown(() {
      ByteDesktopAudio.filtersSupported = ByteDesktopAudio.defaultFiltersSupported();
      ByteDesktopAudio.effects = '';
    });
    final lab = AudioLab()..openForTest({'eqOn': true, 'preset': 'Bass Booster', 'nodes': [for (final n in nodesFromBands(eqPresets['Bass Booster']!)) n.toJson()]});
    await ByteDesktopAudio.setEffects(mpvFilterGraph(lab));
    expect(ByteDesktopAudio.usableEffects, contains('equalizer'));
  });

  test('the default is no filters on Windows, filters on Linux', () {
    // The rule itself (Platform is the host here): Windows never.
    expect(ByteDesktopAudio.defaultFiltersSupported(), isTrue); // the test host is Linux
  });

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
