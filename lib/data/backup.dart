import 'dart:convert';
import 'dart:io';

import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../brand.dart';
import '../services.dart';

/// Boxes that travel in a backup. Downloads and Local Music are left out:
/// they point at files on this phone.
const backupBoxes = ['settings', 'likes', 'playlists', 'history', 'library_misc', 'stats'];

/// Settings that belong to this phone, not to the person.
const _deviceKeys = {'deviceId'};

Object? _enc(Object? v) {
  if (v is DateTime) return {r'$dt': v.millisecondsSinceEpoch};
  if (v is Map) return {for (final e in v.entries) '${e.key}': _enc(e.value)};
  if (v is List) return [for (final x in v) _enc(x)];
  return v;
}

Object? _dec(Object? v) {
  if (v is Map) {
    if (v.length == 1 && v[r'$dt'] is int) return DateTime.fromMillisecondsSinceEpoch(v[r'$dt'] as int);
    return {for (final e in v.entries) e.key: _dec(e.value)};
  }
  if (v is List) return [for (final x in v) _dec(x)];
  return v;
}

/// Everything as one JSON string.
Future<String> backupJson() async {
  final boxes = <String, Object?>{};
  for (final name in backupBoxes) {
    final b = Hive.isBoxOpen(name) ? Hive.box(name) : await Hive.openBox(name);
    boxes[name] = {
      for (final k in b.keys)
        if (!(name == 'settings' && _deviceKeys.contains(k))) '$k': _enc(b.get(k)),
    };
  }
  return jsonEncode({'app': Brand.appName, 'format': 1, 'version': Brand.version, 'at': DateTime.now().toIso8601String(), 'boxes': boxes});
}

Future<File> exportBackup() async {
  final dir = await getTemporaryDirectory();
  final d = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final f = File('${dir.path}/Byte-backup-${d.year}-${two(d.month)}-${two(d.day)}.json');
  await f.writeAsString(await backupJson());
  return f;
}

/// Replaces this phone's data with a backup. Returns how many entries came in.
/// Throws [FormatException] for a file that isn't a Byte backup.
Future<int> importBackup(String json, {bool reloadServices = true}) async {
  final m = jsonDecode(json);
  if (m is! Map || m['app'] != Brand.appName || m['boxes'] is! Map) throw const FormatException('not a Byte backup');
  final boxes = m['boxes'] as Map;
  var n = 0;
  for (final name in backupBoxes) {
    final data = boxes[name];
    if (data is! Map) continue;
    final b = Hive.isBoxOpen(name) ? Hive.box(name) : await Hive.openBox(name);
    final keep = name == 'settings' ? {for (final k in _deviceKeys) k: b.get(k)} : const <String, Object?>{};
    await b.clear();
    for (final e in data.entries) {
      await b.put(e.key, _dec(e.value));
      n++;
    }
    for (final e in keep.entries) {
      if (e.value != null) await b.put(e.key, e.value);
    }
  }
  if (reloadServices) {
    final s = Services.i;
    await s.stats.reload();
    s.library.changed();
    s.settings.changed();
    s.feedVersion.value++;
  }
  return n;
}
