import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/cover_cache.dart';
import '../core/models.dart';
import 'byte_handler.dart';

/// Keeps the home-screen widget (Android) showing what's playing: cover,
/// title, artist and the play/pause state. Sends only real changes.
class HomeWidgetSync {
  final ValueListenable<Item?> current;
  final Stream<PlaybackState> playback;
  final Future<Object?> Function(String method, Map<String, Object?> args) invoke;
  final Future<File?> Function(Item it) artFile;
  StreamSubscription<PlaybackState>? _sub;
  String? _last;
  bool _playing = false;

  static const channel = MethodChannel('byte/widget');

  HomeWidgetSync({
    required this.current,
    required this.playback,
    Future<Object?> Function(String method, Map<String, Object?> args)? invoke,
    Future<File?> Function(Item it)? artFile,
  }) : invoke = invoke ?? ((m, a) => channel.invokeMethod<Object?>(m, a)),
       artFile = artFile ?? defaultArtFile;

  /// The song's square cover as a file the widget can read.
  static Future<File?> defaultArtFile(Item it) async {
    final sq = await squareArtFor(it);
    if (sq != null) return sq;
    final url = it.thumbAt(544);
    if (url == null) return null;
    if (url.startsWith('/')) return File(url);
    await CoverCache.bytes(url);
    return CoverCache.fileFor(url);
  }

  void start() {
    current.addListener(_send);
    _sub = playback.listen((s) {
      if (s.playing != _playing) {
        _playing = s.playing;
        _send();
      }
    });
    _send();
  }

  Future<void> _send() async {
    final it = current.value;
    final art = it == null ? null : await artFile(it).catchError((_) => null);
    if (current.value?.id != it?.id) return; // moved on meanwhile
    final args = <String, Object?>{
      'title': it?.title,
      'artist': it?.artistLine,
      'playing': _playing,
      'art': art?.path,
    };
    final key = '${args['title']}|${args['artist']}|${args['playing']}|${args['art']}';
    if (key == _last) return;
    _last = key;
    try {
      await invoke('update', args);
    } catch (_) {
      // no widget support on this platform
    }
  }

  void stop() {
    current.removeListener(_send);
    _sub?.cancel();
  }
}
