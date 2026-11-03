import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Byte 1.3.1: no other app, service or vendor is named anywhere a person can
/// read it. Technical strings (web addresses, ids, patterns, user agents)
/// may still carry a name; words shown on screen may not.
void main() {
  const banned = [
    'Spotify', 'YouTube', 'Apple Music', 'JioSaavn', 'Gaana', 'Amazon', 'SoundCloud', 'Deezer', 'Wynk',
    'Last.fm', 'ListenBrainz', 'Musixmatch', 'KuGou', 'LRCLIB', 'Google', 'Chromecast', 'Dolby', 'Gmail',
    'Supabase', 'BitChord', 'Discord', 'Nextcloud', 'ownCloud', 'Synology', 'QNAP', 'Exportify', 'TuneMyMusic', 'Soundiiz',
  ];
  bool technical(String s) =>
      s.contains('http') || s.contains('Mozilla') || s.contains('(?:') || s.contains(r'\') || s.startsWith('com.') ||
      s.startsWith('urn:') || s.contains('://') || !s.contains(' ');
  final str = RegExp('\'((?:[^\'\\\\\\n]|\\\\.)*)\'|"((?:[^"\\\\\\n]|\\\\.)*)"');

  // Apurba (Nov 2): logging in to / importing from another music app may
  // name that app. Only those screens and labels may.
  const loginScreens = {
    'lib/ui/screens/integrations_pages.dart', // Spotify / ListenBrainz / Last.fm log-in
    'lib/ui/import_sheet.dart', // "Works with" list on the importer
    'lib/ui/screens/login_screen.dart', // Google sign-in
    'lib/ui/account_ui.dart', // account sheet: Sign in with Google
    'lib/data/spotify_account.dart', // Spotify log-in errors
    'lib/ui/web_logins.dart', // 1.4: in-app sign-in pages (Spotify / Last.fm / ListenBrainz)
    'lib/ui/screens/onboarding_screen.dart', // 1.4: first launch "Connect YouTube Music" button
    'lib/ui/music_apps.dart', // 1.4.1: Music apps — Log in on each app's own page (Apurba, Nov 3)
    'lib/data/service_library.dart', // 1.4.1: that log-in's library readers and their errors
    'lib/ui/imported_row.dart', // 1.4.2: Home row labels each imported playlist with the app it came from ("Amazon Music · 42 songs")
  };
  const loginLabels = [
    'Sign in with Google', 'Spotify account', 'Log in with Spotify', 'My Spotify playlists', 'YouTube Music playlists',
    'import playlists from Spotify', 'Spotify, Apple Music', 'ListenBrainz', 'Last.fm', 'Google account', 'Google sign-in', '(Gmail works)', 'Google: ',
    'Log in to ', // 1.4.1: "Log in to Amazon Music, Apple Music, …" (Settings → Music apps row)
  ];
  bool loginLabel(String s) => loginLabels.any(s.contains) || s == 'YouTube Music';

  test('no other app or vendor name in any on-screen text (log-in / import labels excepted)', () {
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart') && !loginScreens.contains(f.path))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final t = lines[i].trimLeft();
        if (t.startsWith('//') || t.startsWith('import ') || t.startsWith('export ')) continue;
        for (final m in str.allMatches(lines[i])) {
          final s = m.group(1) ?? m.group(2) ?? '';
          if (technical(s) || loginLabel(s)) continue;
          for (final b in banned) {
            if (s.contains(b)) found.add('${f.path}:${i + 1}: $s');
          }
        }
      }
    }
    expect(found, isEmpty, reason: found.join('\n'));
  });

  test('the Library row for imported playlists is called "Imported"', () {
    final src = File('lib/ui/screens/library_screen.dart').readAsStringSync();
    expect(src.contains("title: 'Imported'"), isTrue);
    expect(src.contains("title: 'Spotify'"), isFalse);
  });
}
