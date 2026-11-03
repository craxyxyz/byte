// Byte © 2026 Apurba Laskar.
//
// 1.4.5 (Apurba: "phone pe kabhi kabhi Byte app close ho jata hai"): every
// error nobody caught is written to a small file on the phone, so the next
// time Byte closes by itself the real reason can be read (Settings → About →
// Report a problem). Android's own crash reports and the reason Android gave
// for closing Byte (low memory, crash, ANR…) land in the same file from the
// Android side (ByteCrashLog.kt). Two files of at most [maxBytes] each: the
// current one and the one before it.
import 'dart:io' show File, FileMode;
import 'dart:isolate';

import 'package:flutter/foundation.dart';

class CrashLog {
  /// The folder the log lives in (null = kept in memory only, e.g. web).
  final String? dir;
  final int maxBytes;
  final String Function() version;
  final DateTime Function() now;

  CrashLog({this.dir, this.maxBytes = 64 * 1024, String Function()? version, DateTime Function()? now})
    : version = version ?? (() => ''),
      now = now ?? DateTime.now;

  /// The app's log (set by [install]).
  static CrashLog? i;

  static const fileName = 'crash_log.txt';
  static const oldName = 'crash_log.1.txt';

  final StringBuffer _mem = StringBuffer();
  String? _lastKey;
  DateTime? _lastAt;
  int count = 0;

  File? get _file => dir == null ? null : File('$dir/$fileName');
  File? get _old => dir == null ? null : File('$dir/$oldName');

  /// Adds one error. Never throws; the same error repeating within 5 s is
  /// written once (a broken frame would otherwise fill the file).
  void record(Object error, StackTrace? stack, {String source = 'Dart'}) {
    try {
      final t = now();
      final first = error.toString().split('\n').first;
      final key = '$source|$first';
      if (key == _lastKey && _lastAt != null && t.difference(_lastAt!).inSeconds < 5) return;
      _lastKey = key;
      _lastAt = t;
      count++;
      final st = (stack ?? StackTrace.empty).toString().split('\n').where((l) => l.trim().isNotEmpty).take(25).join('\n');
      final v = version();
      final entry = '\n[${t.toIso8601String()}] $source error${v.isEmpty ? '' : ' · Byte $v'}\n$error\n${st.isEmpty ? '' : '$st\n'}';
      append(entry);
    } catch (_) {}
  }

  /// Writes [text] at the end, starting a fresh file once this one is full.
  void append(String text) {
    final f = _file;
    if (f == null) {
      _mem.write(text);
      if (_mem.length > maxBytes) {
        final s = _mem.toString();
        _mem
          ..clear()
          ..write(s.substring(s.length - maxBytes ~/ 2));
      }
      return;
    }
    try {
      if (f.existsSync() && f.lengthSync() + text.length > maxBytes) {
        final o = _old!;
        if (o.existsSync()) o.deleteSync();
        f.renameSync(o.path);
      }
      f.writeAsStringSync(text, mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  /// Everything kept, oldest first ('' when nothing went wrong).
  String read() {
    final f = _file;
    if (f == null) return _mem.toString().trim();
    final b = StringBuffer();
    for (final x in [_old!, f]) {
      try {
        if (x.existsSync()) b.write(x.readAsStringSync());
      } catch (_) {}
    }
    return b.toString().trim();
  }

  void clear() {
    _mem.clear();
    for (final x in [_old, _file]) {
      try {
        if (x != null && x.existsSync()) x.deleteSync();
      } catch (_) {}
    }
    _lastKey = null;
  }

  /// The text "Report a problem" shares.
  String report({String device = ''}) {
    final log = read();
    final head = 'Byte ${version()}${device.isEmpty ? '' : ' · $device'}';
    return log.isEmpty ? '$head\nNo errors recorded.' : '$head\n$log';
  }

  /// Catches what nobody else did: Flutter's own errors (build, layout,
  /// paint), errors in async code (PlatformDispatcher), and errors on the
  /// main isolate outside Flutter (Isolate error listener).
  static void install(CrashLog log) {
    i = log;
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      log.record(details.exception, details.stack, source: 'Flutter${details.library == null ? '' : ' (${details.library})'}');
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    final prevPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      log.record(error, stack, source: 'Async');
      if (prevPlatform != null) prevPlatform(error, stack);
      return true; // handled: an uncaught async error must not close Byte
    };
    if (!kIsWeb) {
      try {
        final port = RawReceivePort((Object? pair) {
          if (pair is List && pair.length == 2) {
            log.record(pair[0] ?? 'unknown', StackTrace.fromString('${pair[1] ?? ''}'), source: 'Isolate');
          }
        });
        Isolate.current.addErrorListener(port.sendPort);
      } catch (_) {}
    }
  }
}
