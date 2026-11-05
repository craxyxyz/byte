import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Byte 2.0 © 2026 Apurba Laskar.
//
// Runtime check (emulator): the headphone list stayed on "Loading the list…"
// in the release app because assets/audiolab/ was not listed in pubspec.yaml
// (tests read the file from disk, so nothing noticed). Every assets/… path the
// code mentions must be covered by a pubspec assets entry.
void main() {
  test('every asset path used in lib/ is declared in pubspec.yaml', () {
    final pub = File('pubspec.yaml').readAsStringSync();
    final declared = <String>[
      for (final m in RegExp(r'^\s*-\s+(assets/[^\s#]+)\s*$', multiLine: true).allMatches(pub)) m.group(1)!,
    ];
    expect(declared, isNotEmpty);
    final used = <String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      for (final m in RegExp(r"'(assets/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+)'").allMatches(f.readAsStringSync())) {
        used.add(m.group(1)!);
      }
    }
    expect(used, contains('assets/audiolab/headphones.tsv'));
    for (final u in used) {
      final ok = declared.any((d) => d == u || (d.endsWith('/') && u.startsWith(d)));
      expect(ok, isTrue, reason: '$u is used in lib/ but not declared in pubspec.yaml assets');
    }
    // Icons are built as 'assets/icons/$id.png' — the folder must be declared.
    expect(declared.any((d) => d == 'assets/icons/'), isTrue);
    for (final d in declared) {
      expect(d.endsWith('/') ? Directory(d).existsSync() : File(d).existsSync(), isTrue, reason: '$d does not exist');
    }
  });
}
