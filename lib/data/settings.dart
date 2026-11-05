import 'dart:math';

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';

import '../core/streams.dart';

/// User preferences, persisted on the device.
class Settings extends ChangeNotifier {
  Box? _b;
  void changed() => notifyListeners();

  Future<void> open() async {
    _b = await Hive.openBox('settings');
    // 1.3: Best audio everywhere by default. Lifts the old "Normal" (the
    // previous mobile-data default) once; a choice made after this sticks.
    if (_b?.get('qBest13') != true) {
      for (final k in const ['qWifi', 'qMobile', 'qDownload']) {
        if (_b?.get(k) == AudioQuality.normal.index) await _b?.put(k, AudioQuality.high.index);
      }
      await _b?.put('qBest13', true);
    }
    // 1.4.4 (Apurba): lyrics in another script open Romanized by default.
    // 1.4.3's automatic dual look was never his pick, so any look saved
    // without the "picked by hand" mark is dropped once; a hand pick stays.
    if (_b?.get('lyrLook144') != true) {
      if (_b?.get('lyricsLookManual') != true) await _b?.delete('lyricsLook');
      await _b?.put('lyrLook144', true);
    }
  }

  T _get<T>(String k, T def) {
    final v = _b?.get(k);
    return v is T ? v : def;
  }

  Future<void> _set(String k, Object? v) async {
    await _b?.put(k, v);
    notifyListeners();
  }

  ThemeMode get themeMode => ThemeMode.values[_get('theme', ThemeMode.light.index)];
  set themeMode(ThemeMode m) => _set('theme', m.index);

  /// Colours follow the album art of the song playing.
  bool get dynamicColor => _get('dynamicColor', true);
  set dynamicColor(bool v) => _set('dynamicColor', v);

  /// Pure black backgrounds in dark mode (AMOLED).
  bool get pureBlack => _get('pureBlack', false);
  set pureBlack(bool v) => _set('pureBlack', v);

  AudioQuality get wifiQuality => AudioQuality.values[_get('qWifi', AudioQuality.high.index)];
  set wifiQuality(AudioQuality q) => _set('qWifi', q.index);
  // Best on mobile data too (Apurba, v1.3: "audio high quality mein hone chahiye sab")
  AudioQuality get mobileQuality => AudioQuality.values[_get('qMobile', AudioQuality.high.index)];
  set mobileQuality(AudioQuality q) => _set('qMobile', q.index);
  AudioQuality get downloadQuality => AudioQuality.values[_get('qDownload', AudioQuality.high.index)];
  set downloadQuality(AudioQuality q) => _set('qDownload', q.index);

  /// 0 = no blend (a short silence between songs, 1.4.5), up to 12 s of overlap.
  double get crossfadeSeconds => _get<double>('crossfade', 0.0);
  set crossfadeSeconds(double v) => _set('crossfade', v.clamp(0.0, 12.0));

  // Automix: level-matched, silence-trimmed hand-offs between songs. 2.0.0+2003:
  // the next song starts [automixSeconds] before this one ends and fades in
  // while this one fades out (Android / iPhone; the browser and cast cannot overlap).
  bool get automix => _get('automix', true);
  set automix(bool v) => _set('automix', v);

  /// true = Smart (beat-matched, bass swap; may start a little earlier to land
  /// on a beat), false = Simple (clean crossfade exactly [automixSeconds] before the end).
  bool get automixSmart => _get('automixSmart', false);
  set automixSmart(bool v) => _set('automixSmart', v);

  /// How long before a song's end the next one starts, and the length of the
  /// blend: 2–15 s, 8.5 s by default (Apurba: "8-9 sec pehle").
  /// Stored under a new key (automixLead2, like stopOnClose2): the 4.5 s (or any
  /// value) saved by an earlier build is left behind, so everybody starts at
  /// 8.5 s once; a change made afterwards is saved under the new key and sticks.
  static const double automixLeadDefault = 8.5;
  static const double automixLeadMin = 2.0, automixLeadMax = 15.0;
  double get automixSeconds {
    final v = _get<double>('automixLead2', automixLeadDefault);
    return (v.clamp(automixLeadMin, automixLeadMax) * 2).round() / 2;
  }

  set automixSeconds(double v) => _set('automixLead2', (v.clamp(automixLeadMin, automixLeadMax) * 2).round() / 2);

  /// With shuffle on, play the songs in the order that blends best.
  bool get automixSmartShuffle => _get('automixOrder', true);
  set automixSmartShuffle(bool v) => _set('automixOrder', v);

  // Personal DJ (1.4.3: the DJ never speaks; no voice settings)

  /// What the DJ calls you.
  String get djName {
    final v = _get('djName', '');
    return v.trim().isEmpty ? 'Apurba' : v.trim();
  }

  set djName(String v) => _set('djName', v.trim());

  /// 'hinglish' or 'english'.
  String get djLanguage => _get('djLang', 'hinglish');
  set djLanguage(String v) => _set('djLang', v);

  /// Android: Byte's own player on the lock screen while music plays.
  bool get lockScreenPlayer => _get('lockPlayer', true);
  set lockScreenPlayer(bool v) => _set('lockPlayer', v);

  /// DJ chat: the mic's language.
  String get djMicLocale => _get('djMicLocale', 'hi-IN');
  set djMicLocale(String v) => _set('djMicLocale', v);

  bool get normalizeVolume => _get('normalize', true);
  set normalizeVolume(bool v) => _set('normalize', v);

  bool get skipSilence => _get('skipSilence', false);
  set skipSilence(bool v) => _set('skipSilence', v);

  /// Keep playing similar songs when the queue runs out.
  bool get autoplay => _get('autoplay', true);
  set autoplay(bool v) => _set('autoplay', v);

  /// Smooth word-by-word fill even when the lyrics only have line timings.
  bool get lyricsWordFill => _get('lyricsFill', true); // 1.4.1: word-by-word fill by default, like the reference (off = the whole line lights up)
  set lyricsWordFill(bool v) => _set('lyricsFill', v);

  /// The letters lyrics are shown in, on the lyrics screen and in the line
  /// under the cover: 'hindi' (Devanagari letters, same words — the default),
  /// 'latin' (Roman letters) or 'original' (the song's own script).
  String get lyricsScript => _get('lyricsScript', 'latin');

  /// 1.4.4: the look picked by hand on the lyrics screen for lyrics in another
  /// script ('romanized', 'dual' = Both, 'original' = Song's own, 'hindi'),
  /// or null = the default, Romanized. Only a hand pick (lyricsLookManual)
  /// is ever returned; null clears it.
  String? get lyricsLook {
    if (_b?.get('lyricsLookManual') != true) return null;
    final v = _b?.get('lyricsLook');
    return v is String && const {'romanized', 'dual', 'original', 'hindi'}.contains(v) ? v : null;
  }

  set lyricsLook(String? v) {
    final ok = v != null && const {'romanized', 'dual', 'original', 'hindi'}.contains(v);
    if (ok) {
      _b?.put('lyricsLook', v);
    } else {
      _b?.delete('lyricsLook');
    }
    _b?.put('lyricsLookManual', ok);
    notifyListeners();
  }
  set lyricsScript(String v) => _set('lyricsScript', const {'hindi', 'latin', 'original'}.contains(v) ? v : 'latin');

  /// Lyrics timing nudge for every song, in ms (+ = lyrics earlier).
  int get lyricsOffsetMs => _get('lyricsOffset', 0);
  set lyricsOffsetMs(int v) => _set('lyricsOffset', v.clamp(-5000, 5000));

  /// Share how Byte is used (phone model, Byte version, songs played) with
  /// Byte's owner. No passwords, messages or location. Settings → Your data.
  bool get shareUsage => _get('shareUsage', true);
  set shareUsage(bool v) => _set('shareUsage', v);

  /// Per-song lyrics timing nudge in ms (+ = lyrics earlier), set from the
  /// lyrics source sheet when one song's lyrics run early or late.
  int lyricsOffsetFor(String songId) => ((_b?.get('lyOffsets') as Map?)?[songId] as num?)?.toInt() ?? 0;
  void setLyricsOffsetFor(String songId, int ms) {
    final m = {...((_b?.get('lyOffsets') as Map?) ?? const {})};
    if (ms == 0) {
      m.remove(songId);
    } else {
      m[songId] = ms.clamp(-10000, 10000);
    }
    _set('lyOffsets', m);
  }

  /// Lyrics text size: 0 small, 1 normal, 2 large.
  int get lyricsSize => _get('lyricsSize', 1);
  set lyricsSize(int v) => _set('lyricsSize', v.clamp(0, 2));

  String? get downloadDir => _b?.get('downloadDir') as String?;
  set downloadDir(String? v) => _set('downloadDir', v);

  bool get saveHistory => _get('saveHistory', true);
  set saveHistory(bool v) => _set('saveHistory', v);

  String get contentRegion => _get('region', 'IN');
  set contentRegion(String v) => _set('region', v);

  String get language => _get('hl', 'en');
  set language(String v) => _set('hl', v);

  double get speed => _get<double>('speed', 1.0);
  set speed(double v) => _set('speed', v.clamp(0.5, 2.0));

  /// Frosted-glass blur on bars (Settings → Performance). Off = solid bars, lighter on old phones.
  bool get glassEffects => _get('glass', true);

  /// Appearance → Liquid Glass: the floating glass bar (off = a plain bar).
  bool get liquidGlass => _get('liquid', true);
  set liquidGlass(bool v) => _set('liquid', v);

  set glassEffects(bool v) => _set('glass', v);

  /// 2.0, Settings → Performance → Real glass blur: bars blur what scrolls
  /// under them live (looks deeper, costs every frame). Off by default.
  bool get realBlur => _get('realBlur', false);
  set realBlur(bool v) => _set('realBlur', v);

  /// Fewer and shorter animations (Settings → Performance).
  bool get reduceMotion => _get('reduceMotion', false);
  set reduceMotion(bool v) => _set('reduceMotion', v);

  /// Load the next song in advance so it starts instantly.
  bool get preloadNext => _get('preloadNext', true);
  set preloadNext(bool v) => _set('preloadNext', v);

  /// Check a stream really plays past the first part before using it (slower start, fewer cut-offs).
  bool get verifyStreams => _get('verifyStreams', true);
  set verifyStreams(bool v) => _set('verifyStreams', v);

  /// Prefer a downloaded copy over streaming (Settings → Sources).
  bool get preferDownloads => _get('preferDownloads', true);
  set preferDownloads(bool v) => _set('preferDownloads', v);

  /// When Byte was first opened (Library → "Member since").
  DateTime get memberSince {
    final v = _b?.get('firstSeen');
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    final now = DateTime.now();
    _b?.put('firstSeen', now.millisecondsSinceEpoch);
    return now;
  }

  set memberSince(DateTime d) => _set('firstSeen', d.millisecondsSinceEpoch);

  /// Local music: hide clips under 30 s, WAV files and recordings.
  bool get filterShortAudio => _get('filterShort', true);
  set filterShortAudio(bool v) => _set('filterShort', v);

  // Appearance
  /// Album art fills the whole top of the player instead of a square sleeve.
  bool get fullScreenCover => _get('fullCover', true); // the video's look: edge-to-edge cover
  set fullScreenCover(bool v) => _set('fullCover', v);

  /// Moving colour gradient behind the player.
  bool get playerGradient => _get('playerGradient', true);
  set playerGradient(bool v) => _set('playerGradient', v);

  /// Lyrics tab shows time-synced lyrics (off = plain text).
  bool get syncedLyrics => _get('syncedLyrics', true);
  set syncedLyrics(bool v) => _set('syncedLyrics', v);

  /// Blur the lyric lines that aren't being sung.
  bool get blurLyrics => _get('blurLyrics2', false); // 2.0: off by default (a blur per line costs every frame)
  set blurLyrics(bool v) => _set('blurLyrics2', v);

  // Performance
  bool get highPerformance => _get('highPerf', false);
  set highPerformance(bool v) => _set('highPerf', v);

  // Downloads
  bool get downloadWifiOnly => _get('dlWifiOnly', false);
  set downloadWifiOnly(bool v) => _set('dlWifiOnly', v);

  /// Re-download new songs added to downloaded playlists.
  bool get keepPlaylistsUpdated => _get('dlKeepUpdated', false);
  set keepPlaylistsUpdated(bool v) => _set('dlKeepUpdated', v);

  // Miscellaneous
  bool get playNextOnSwipe => _get('swipePlayNext', true);
  set playNextOnSwipe(bool v) => _set('swipePlayNext', v);

  bool get noRepeatInSession => _get('noRepeat', true);
  set noRepeatInSession(bool v) => _set('noRepeat', v);

  /// Byte 2.0 (Apurba: "Recent app se app hatane ke baad gaana OFF ho jana
  /// chahiye"): ON by default. Swiping Byte away from recents ends the music
  /// (Android). Stored under a new key (stopOnClose2) so a choice saved by an
  /// earlier 2.0 build does not keep it off: everybody starts ON once.
  bool get stopOnClose => _get('stopOnClose2', true);
  set stopOnClose(bool v) {
    _set('stopOnClose2', v);
    onStopOnCloseChanged?.call(v);
  }

  /// Tells the Android playback service about the setting (set in main.dart).
  static void Function(bool on)? onStopOnCloseChanged;

  bool get showListenTogetherButton => _get('ltButton', false); // the video's bottom row: lyrics · output · queue (party lives in ⋯)
  set showListenTogetherButton(bool v) => _set('ltButton', v);

  bool get hideStatusBarInPlayer => _get('hideStatusBar', false);
  set hideStatusBarInPlayer(bool v) => _set('hideStatusBar', v);

  bool get showQueueHistory => _get('queueHistory', false);
  set showQueueHistory(bool v) => _set('queueHistory', v);

  bool get hideSongStatus => _get('hideSongStatus', false);
  set hideSongStatus(bool v) => _set('hideSongStatus', v);

  // Advanced
  bool get statsForNerds => _get('nerds', false);
  set statsForNerds(bool v) => _set('nerds', v);

  String get appIcon => _get('appIcon', 'default');
  set appIcon(String v) => _set('appIcon', v);

  // Equalizer (Android)
  bool get eqEnabled => _get('eqOn', false);
  set eqEnabled(bool v) => _set('eqOn', v);
  String get eqPreset => _get('eqPreset', 'Flat');
  set eqPreset(String v) => _set('eqPreset', v);

  /// Manual band gains in dB, one per band of the phone's equalizer.
  List<double> get eqBands => ((_b?.get('eqBands') as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
  set eqBands(List<double> v) => _set('eqBands', v);

  // Listen together: own server (empty = Apurba's default project)
  String get ltServerUrl => _get('ltUrl', '');
  set ltServerUrl(String v) => _set('ltUrl', v.trim());
  String get ltServerKey => _get('ltKey', '');
  set ltServerKey(String v) => _set('ltKey', v.trim());

  /// 1.4.3: the party this phone was in (code, host or guest, server), so a
  /// closed or killed app can resume it.
  String get ltSaved => _get('ltSaved', '');
  set ltSaved(String v) => _set('ltSaved', v);

  /// Name shown to others in Listen together.
  String get listenName => _get('ltName', '');
  set listenName(String v) => _set('ltName', v.trim());

  /// Random id for this phone (Listen together), made once.
  String get deviceId {
    final v = _b?.get('deviceId');
    if (v is String && v.isNotEmpty) return v;
    final rnd = Random.secure();
    final r = List.generate(16, (_) => 'abcdefghijklmnopqrstuvwxyz0123456789'[rnd.nextInt(36)]).join();
    _b?.put('deviceId', r);
    return r;
  }

  // ── v1.3 ──────────────────────────────────────────────────────────────
  /// Dolby Atmos versions when a source has them and the phone can play them.
  bool get dolbyAtmos => _get('atmos', false);
  set dolbyAtmos(bool v) => _set('atmos', v);

  /// Loudness normalization pauses while sound comes out of the phone's own speaker.
  bool get normalizeOffOnSpeaker => _get('normOffSpeaker', false);
  set normalizeOffOnSpeaker(bool v) => _set('normOffSpeaker', v);

  /// 0 battery saver · 1 balanced · 2 best.

  int get automixPerformance => _get('automixPerf', 1);
  set automixPerformance(int v) => _set('automixPerf', v.clamp(0, 2));

  /// default | serif | condensed | mono | rounded
  String get font => _get('font', 'default');
  set font(String v) => _set('font', v);

  bool get progressiveBlur => _get('progBlur', true);
  set progressiveBlur(bool v) => _set('progBlur', v);

  /// Slow moving colour blobs behind the player (instead of the still gradient).
  bool get meshGradient => _get('mesh', false);
  set meshGradient(bool v) => _set('mesh', v);

  /// Playback → Prefer USB DAC: send audio to a plugged-in USB DAC first.
  bool get preferUsbDac => _get('usbDac', true);
  set preferUsbDac(bool v) => _set('usbDac', v);

  /// Playback → Bit-perfect output (USB DAC only, Android 14+): no mixing, no volume.
  /// First-launch welcome finished (or skipped).
  bool get onboarded => _get('onboarded', false);
  set onboarded(bool v) => _set('onboarded', v);

  /// Lyrics: go full screen after a few seconds without a touch.
  bool get lyricsAutoFullScreen => _get('lyricsAutoFull', true);
  set lyricsAutoFullScreen(bool v) => _set('lyricsAutoFull', v);

  /// Appearance → Animated cover art: the player's cover drifts slowly.
  bool get animatedCover => _get('animCover', false);
  set animatedCover(bool v) => _set('animCover', v);

  /// Storage → Song cache limit (MB) for songs saved for smooth blends.
  int get songCacheMb => _get('songCacheMb', 200);
  set songCacheMb(int v) => _set('songCacheMb', v.clamp(50, 4000));

  bool get bitPerfect => _get('bitPerfect', false);
  set bitPerfect(bool v) => _set('bitPerfect', v);

  bool get hideVolumeBar => _get('hideVolume', false);
  set hideVolumeBar(bool v) => _set('hideVolume', v);

  /// Lyrics sources in the order they are tried; ones not listed are off.
  List<String> get lyricsOrder {
    final o = ((_b?.get('lyOrder') as List?) ?? const ['lrclib', 'kugou', 'ytm', 'ytcaptions', 'files', 'addons', 'musixmatch']).cast<String>().toList();
    // KuGou arrived in 1.3: an order saved before that gets it right after LRCLIB.
    if (!o.contains('kugou')) o.insert(o.contains('lrclib') ? o.indexOf('lrclib') + 1 : 0, 'kugou');
    return o;
  }
  set lyricsOrder(List<String> v) => _set('lyOrder', v);
  Set<String> get lyricsOff => ((_b?.get('lyOff') as List?) ?? const ['musixmatch']).cast<String>().toSet();
  set lyricsOff(Set<String> v) => _set('lyOff', v.toList());

  /// The language lyrics are translated into.
  String get translationLanguage => _get('trLang', 'en');
  set translationLanguage(String v) => _set('trLang', v);

  /// Your own Musixmatch developer key (optional lyrics source).
  String get musixmatchKey => _get('mxmKey', '');
  set musixmatchKey(String v) => _set('mxmKey', v.trim());

  /// Seconds a matched song may differ in length from the original.
  int get trackLengthTolerance => _get('lenTol', 3);
  set trackLengthTolerance(int v) => _set('lenTol', v.clamp(1, 30));

  /// Downloads as AAC (.m4a), which every player and car stereo opens.
  bool get compatibleDownloads => _get('dlCompat', false);
  set compatibleDownloads(bool v) => _set('dlCompat', v);

  /// Replay works out genres from Last.fm tags.
  bool get lastfmGenres => _get('lfmGenres', false);
  set lastfmGenres(bool v) => _set('lfmGenres', v);

  /// Last.fm API key used for genres (from Scrobbling, or typed here).
  String get lastfmApiKey => _get('lfmKey', '');
  set lastfmApiKey(String v) => _set('lfmKey', v.trim());

  /// Seen the DJ tab's "made from your listening" note.
  bool get djTabSeen => _get('djTabSeen', false);
  set djTabSeen(bool v) => _set('djTabSeen', v);
}
