import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../core/streams.dart';
import '../data/downloads.dart' show fetchToFile;
import '../data/library.dart';
import '../data/settings.dart';
import 'analysis.dart';

/// Turns an audio file on the phone into mono 16-bit PCM for analysis.
abstract class PcmDecoder {
  /// Sample rate the decoder delivers.
  int get rate;
  Future<Int16List> decode(String path);
}

/// The phone's own decoders: MediaCodec on Android, AVAssetReader on iPhone
/// (Byte's native code, see MainActivity.kt / AutomixDecoder.swift).
class PlatformPcmDecoder implements PcmDecoder {
  static const _ch = MethodChannel('byte/automix');
  @override
  final int rate = 11025;
  @override
  Future<Int16List> decode(String path) async {
    if (kIsWeb) throw UnsupportedError('no decoder on the web');
    if (defaultTargetPlatform == TargetPlatform.iOS && path.toLowerCase().endsWith('.webm')) {
      throw UnsupportedError('iPhone can\'t read WebM');
    }
    final r = await _ch.invokeMethod<Uint8List>('decode', {'path': path, 'rate': rate, 'maxSeconds': 1200});
    if (r == null || r.length < 2) throw StateError('nothing decoded');
    final copy = Uint8List.fromList(r); // aligned for the Int16 view
    return Int16List.view(copy.buffer, 0, copy.length ~/ 2);
  }
}

/// A song ready for Automix: a file on the phone and (if it worked) its analysis.
class AutomixTrack {
  final String? path;
  final TrackAnalysis? analysis;
  const AutomixTrack(this.path, this.analysis);
}

/// Fetches upcoming songs to the phone ahead of time (so the blend never
/// waits on the network), analyses them once and remembers the result.
class AutomixService extends ChangeNotifier {
  final StreamResolver resolver;
  final Library library;
  final Settings settings;
  PcmDecoder decoder;

  /// Runs the analysis (a background isolate on the phone; tests swap it).
  Future<TrackAnalysis> Function(Int16List pcm, int rate) runAnalysis = (pcm, rate) => Isolate.run(() => analyzePcm(pcm, rate));

  /// Downloads a stream into a file (tests swap it).
  Future<void> Function(Uri url, File out, int? total, String? userAgent) fetch = (u, f, t, ua) => fetchToFile(u, f, t, ua, (_) {});

  /// Where fetched songs are kept (tests swap it).
  Future<Directory> Function() cacheDir = () async => Directory('${(await getTemporaryDirectory()).path}/automix');

  /// Most fetched songs kept on the phone at once, and their total size.
  int maxFiles = 10;
  int maxBytes = 200 * 1024 * 1024;

  Box? _box;
  final Map<String, TrackAnalysis> _mem = {};
  final Map<String, String> _files = {};
  final Map<String, Future<AutomixTrack>> _inflight = {};
  final Set<String> _failedAnalysis = {};

  AutomixService({required this.resolver, required this.library, required this.settings, PcmDecoder? decoder})
    : decoder = decoder ?? PlatformPcmDecoder();

  Future<void> open() async {
    try {
      _box = await Hive.openBox('automix');
    } catch (_) {}
  }

  /// Analysis already known for [id] (memory or disk).
  TrackAnalysis? analysisOf(String id) {
    final m = _mem[id];
    if (m != null) return m;
    final raw = _box?.get(id);
    if (raw is String) {
      try {
        final a = TrackAnalysis.fromJson(jsonDecode(raw) as Map);
        if (a != null) _mem[id] = a;
        return a;
      } catch (_) {}
    }
    return null;
  }

  Future<void> _remember(String id, TrackAnalysis a) async {
    _mem[id] = a;
    try {
      await _box?.put(id, jsonEncode(a.toJson()));
      if ((_box?.length ?? 0) > 3000) await _box?.deleteAt(0);
    } catch (_) {}
  }

  /// A fetched copy of [id] on the phone, if there is one.
  String? cachedFile(String id) {
    final p = _files[id];
    if (p != null && !kIsWeb && File(p).existsSync()) return p;
    _files.remove(id);
    return null;
  }

  /// The file this song can be read from without the network: a download,
  /// a device song, or Automix's own fetched copy.
  String? localPathFor(Item it) {
    if (kIsWeb) return null;
    if (it.isOnPhone) return it.id.substring(6);
    if (it.isLocal) return null;
    final dl = library.download(it.id);
    if (dl != null && File(dl.path).existsSync()) return dl.path;
    return cachedFile(it.id);
  }

  bool isPreparing(String id) => _inflight.containsKey(id);

  /// Gets [it] onto the phone and analysed. Never throws: a song that can't
  /// be fetched or analysed comes back with what worked (a plain crossfade
  /// is used for it).
  Future<AutomixTrack> prepare(Item it, {bool preferMp4 = false}) {
    final running = _inflight[it.id];
    if (running != null) return running;
    final f = _prepare(it, preferMp4).whenComplete(() {
      _inflight.remove(it.id);
    });
    _inflight[it.id] = f;
    return f;
  }

  Future<AutomixTrack> _prepare(Item it, bool preferMp4) async {
    if (it.isDav || it.isAddon || it.isSmb || kIsWeb) return AutomixTrack(null, analysisOf(it.id));
    var path = localPathFor(it);
    // Battery saver: only songs already on the phone are analysed.
    if (path == null && settings.automixPerformance > 0) {
      try {
        path = await _fetch(it, preferMp4);
      } catch (_) {
        path = null;
      }
    }
    var a = analysisOf(it.id);
    if (a == null && path != null && !_failedAnalysis.contains(it.id)) {
      try {
        final pcm = await decoder.decode(path);
        a = await runAnalysis(pcm, decoder.rate);
        await _remember(it.id, a);
      } catch (_) {
        _failedAnalysis.add(it.id);
      }
    }
    notifyListeners();
    return AutomixTrack(path, a);
  }

  Future<String> _fetch(Item it, bool preferMp4) async {
    final s = await resolver.resolve(it.id, settings.wifiQuality, preferMp4: preferMp4, probe: false);
    final dir = await cacheDir();
    await dir.create(recursive: true);
    final file = File('${dir.path}/${it.id}.${s.extension}');
    if (file.existsSync() && (s.contentLength == null || file.lengthSync() == s.contentLength)) {
      _files[it.id] = file.path;
      return file.path;
    }
    final tmp = File('${file.path}.part');
    try {
      await fetch(Uri.parse(s.url), tmp, s.contentLength, s.userAgent);
      await tmp.rename(file.path);
    } catch (e) {
      try {
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {}
      rethrow;
    }
    _files[it.id] = file.path;
    return file.path;
  }

  /// Keeps the cache small: the songs in [keep] stay, then the newest ones.
  Future<void> trim(Set<String> keep) async {
    if (kIsWeb) return;
    try {
      final dir = await cacheDir();
      if (!dir.existsSync()) return;
      final files = dir.listSync().whereType<File>().where((f) => !f.path.endsWith('.part')).toList()
        ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
      var count = 0, bytes = 0;
      for (final f in files) {
        final name = f.uri.pathSegments.last;
        final id = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
        final len = f.lengthSync();
        if (keep.contains(id) || (count < maxFiles && bytes + len <= maxBytes)) {
          count++;
          bytes += len;
          continue;
        }
        _files.remove(id);
        f.deleteSync();
      }
    } catch (_) {}
  }

  /// Deletes Automix's fetched copy of [id] (and its leftovers); returns the bytes freed.
  Future<int> evict(String id) async {
    var freed = 0;
    if (kIsWeb) return 0;
    try {
      final known = _files.remove(id);
      final dir = await cacheDir();
      final doomed = <File>[if (known != null) File(known)];
      if (dir.existsSync()) {
        for (final f in dir.listSync().whereType<File>()) {
          final name = f.uri.pathSegments.last;
          final base = name.contains('.') ? name.substring(0, name.lastIndexOf('.')) : name;
          if (base == id || name.startsWith('$id.')) doomed.add(f);
        }
      }
      for (final f in doomed.toSet()) {
        if (f.existsSync()) {
          freed += f.lengthSync();
          f.deleteSync();
        }
      }
    } catch (_) {}
    return freed;
  }

  /// Settings → Storage: drop every fetched copy (analyses are tiny and stay).
  Future<int> clearCache() async {
    var freed = 0;
    if (kIsWeb) return 0;
    try {
      final dir = await cacheDir();
      if (dir.existsSync()) {
        for (final f in dir.listSync().whereType<File>()) {
          freed += f.lengthSync();
          f.deleteSync();
        }
      }
    } catch (_) {}
    _files.clear();
    return freed;
  }

  Future<int> cacheBytes() async {
    if (kIsWeb) return 0;
    try {
      final dir = await cacheDir();
      if (!dir.existsSync()) return 0;
      return dir.listSync().whereType<File>().fold<int>(0, (a, f) => a + f.lengthSync());
    } catch (_) {
      return 0;
    }
  }
}
