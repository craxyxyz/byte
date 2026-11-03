# Byte

Music app for Android (phone + tablet), iPhone, Windows, macOS and Linux, built with Flutter.
© 2026 Apurba Laskar. All rights reserved.

- YouTube Music catalogue (home, search, charts, new releases, albums, artists, playlists)
- Background playback with notification, queue, shuffle/repeat, gapless, crossfade 0–12 s, speed, sleep timer
- Synced lyrics (LRCLIB) with word fill, plain-lyrics fallback
- Library: likes, playlists, history, downloads (tagged with cover art), songs on the device
- Optional YouTube Music sign-in with playlist sync, several accounts
- Playlist import from Spotify (also logged-in: private playlists + Liked Songs, with your own Client ID), Apple Music, YouTube, JioSaavn, Gaana, Amazon Music, SoundCloud, Deezer, pasted lists and CSV/TXT
- Listen together (Supabase Realtime; run Byte-supabase-setup.sql once), with reconnect
- 10-band equalizer (Android: system effect; iPhone: ios/Runner/ByteEQ.m audio tap)
- Scrobbling to ListenBrainz / Last.fm; playing from your own WebDAV server (Nextcloud, NAS)
- Automix (1.2): songs are decoded on the phone (Android MediaCodec / iPhone AVAssetReader) and analysed in Dart
  (lib/automix: tempo, beat grid, loudness, real start/end); two-deck beat-matched blends with bass swap and a small tempo match
- Look (1.2.1): the "b)" logo (lib/ui/logo.dart draws it), brand colours in ByteColors (lib/ui/style.dart), 15 app icons (lib/ui/app_icons.dart; Android activity-alias Logo<Name>, iPhone AppIcon-<Name> sets)
- Personal DJ (1.2): sessions from your own history and likes plus YouTube Music radio/search (lib/dj), spoken by the phone's own text-to-speech

## Build

    flutter pub get
    flutter analyze && flutter test
    # Android release (needs your signing key — see android/key.properties.example)
    BYTE_KEY_PROPERTIES=/path/to/key.properties flutter build apk --release --split-per-abi \
        --target-platform android-arm,android-arm64 --obfuscate --split-debug-info=build/symbols
    # Windows / macOS / Linux / iPhone (unsigned): GitHub Actions, .github/workflows/desktop.yml
    # (every push to main; the files land on the GitHub Release)
    flutter build linux --release   # needs clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev libsecret-1-dev

Desktop notes: on Windows and Linux songs play through packages/byte_desktop_audio (Byte's own
backend on media_kit / libmpv; Linux needs `sudo apt install libmpv2`). The window opens at
1280×820 (minimum 900×600), so the wide layout is used.

`flutter test test_shots/shots_test.dart` renders screenshots with live data (needs internet); `test_shots/v12_shots_test.dart` does the 1.2 screens and `test_shots/v121_shots_test.dart` the 1.2.1 look.
`dart run tool/analyze_pcm.dart file.raw` (mono s16le 11025 Hz) prints Automix's analysis; `tool/render_mix.dart` renders a planned blend to WAV.
`test_e2e/` (needs a local Supabase) and `test_live/` (live services) are run on demand, not by `flutter test`.

The web build only shows a notice: YouTube does not allow music to be fetched from a web page.

Third-party open-source licences are listed in the app under Settings → About → Licenses.
