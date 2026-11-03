# Byte changes to audio_service 0.18.19 (MIT)

© 2026 Apurba Laskar for the changes; the package itself stays under its MIT license (LICENSE).

android/src/main/java/com/ryanheise/audioservice/AudioService.java:
- enterPlayingState / internalStartForeground: a foreground start that Android 12+ refuses
  (ForegroundServiceStartNotAllowedException, e.g. music resuming by itself after a phone call
  while the app is in the background) is caught; the notification is posted normally instead
  of the app being killed.
- exitPlayingState: on pause (androidStopForegroundOnPause) the wake lock is released at once
  but the service leaves the foreground only after PAUSED_FOREGROUND_MS (10 min). After that the
  notification is detached (still shown with its play button, swipe to dismiss).
- setState: a paused player that never played in this process (restored last song) shows its
  notification / lock-screen controls (showPausedNotification).
