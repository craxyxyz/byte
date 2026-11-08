# Byte changelog

© 2026 Apurba Laskar

## 2.0.8 (computer build 2.0.0+2008, Windows)

- Windows: a setup program (Byte-2.0.0.2008-setup.exe) that installs per user, lists Byte under Installed apps, adds a Start menu entry, and uninstalls cleanly; installing over an older build upgrades it in place.
- Computers: plain arrow keys: ← / → seek 5 s, ↑ / ↓ turn the volume 5 % while a song plays (with nothing playing the arrows still move the focus).
- Computers: the pointer changes to a hand over buttons and rows, and a right click opens the same menu a long press opens on a phone.
- Computers: the library's shelf tiles take a right click too.

## 1.4.6 (2013 arm64 / 1013 armv7)

- Smoothness (phone, tablet, computer): the player no longer redraws the whole screen nonstop. With the player or lyrics open it used to draw every screen refresh (60–120 times a second), playing or paused. Now paused draws nothing, and a playing song's player and lyrics draw about 30 times a second. The cover background is blurred once per song instead of live on every frame; lyric lines and the seek bar have their own layers; the seek bar only redraws when its time changes; long titles scroll only while a song plays. Computers: smooth mouse-wheel scrolling.
- Listen together: a guest who leaves the app (home button, other app, screen off) keeps playing. Between songs the guest's phone now stays "playing" for Android (awake, in the foreground) like the host's, so the next song still starts; a pause by hand still shows as paused.
- Listen together: when the host presses Next, guests start the new song at 0:00 (it used to start in the middle, carrying the old song's spot). Guests also reset a carried-over spot from a 1.4.5 host. Seek bar drag stays inside the new song.
- Search: original songs come before slowed / reverb / lofi edits.
- Import: a link Byte can't import says so.
- Lyrics: full screen opens by itself only while a song is playing (not when paused or nothing is playing); full screen is still allowed after a pause by hand.
- Playlists: an empty name or an empty playlist gives a clear message. Reordering no longer crashes on a stale position.
- Small screens and big text: nothing cut off at 320 px or large text (text follows the phone up to 1.3x); long titles end with "…".
- Web: when the browser can't play a song, Byte says once that playback is blocked instead of skipping through the queue. Byte's web proxy recognises the catalogue's robot check.
- Output label on a computer says "This computer" / "Computer speaker" instead of "<name>'s Phone".
- Stress checks: Next spam, a 1500-song queue, seeking past the end and 0:00 songs.

## 1.4.5 (2012 / 1012)

- 2.5 s of silence between songs on auto-advance (manual Next stays instant), party repeat fix, endless queue, Audio Lab on every song, share sound, new Home, tablet full-screen lyrics, background-close fix, bug-hunt fixes.
