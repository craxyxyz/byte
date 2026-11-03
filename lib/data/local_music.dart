import 'dart:io';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/models.dart';
import 'library.dart';

const audioExtensions = ['.mp3', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wav', '.webm', '.mp4', '.aiff', '.aif'];

/// Music files already on the phone.
class LocalMusic extends ChangeNotifier {
  final Library library;
  bool scanning = false;
  String? message;
  LocalMusic(this.library);

  bool get supported => !kIsWeb;

  Future<bool> _askPermission() async {
    if (!Platform.isAndroid) return true;
    final audio = await Permission.audio.request();
    if (audio.isGranted) return true;
    final storage = await Permission.storage.request();
    return storage.isGranted;
  }

  /// Android: scans the usual music folders. iOS: nothing to scan (use [pickFiles]).
  Future<int> scanDevice({List<String>? extraDirs}) async {
    if (!supported || scanning) return 0;
    scanning = true;
    message = null;
    notifyListeners();
    var count = 0;
    try {
      if (Platform.isAndroid) {
        if (!await _askPermission()) {
          message = 'Allow "Music and audio" access to see songs on this phone';
          return 0;
        }
        final roots = <String>{
          '/storage/emulated/0/Music',
          '/storage/emulated/0/Download',
          '/storage/emulated/0/Downloads',
          '/storage/emulated/0/Audio',
          '/storage/emulated/0/Snaptube Audio',
          '/storage/emulated/0/Bluetooth',
          ...?extraDirs,
          ...((library.get('local_dirs') as List?)?.cast<String>() ?? const []),
        };
        final found = <Item>[];
        for (final r in roots) {
          found.addAll(await scanFolder(Directory(r)));
        }
        await library.setLocalTracks(found);
        count = found.length;
      }
    } catch (e) {
      message = 'Could not read music: $e';
    } finally {
      scanning = false;
      notifyListeners();
    }
    return count;
  }

  Future<void> addFolder() async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null) return;
    final dirs = {...((library.get('local_dirs') as List?)?.cast<String>() ?? const <String>[]), dir}.toList();
    await library.put('local_dirs', dirs);
    await scanDevice();
  }

  /// Pick individual files (iPhone/iPad, or any phone).
  Future<int> pickFiles() async {
    final res = await FilePicker.pickFiles(type: FileType.audio);
    if (res.isEmpty) return 0;
    final docs = await getApplicationDocumentsDirectory();
    final keep = Directory('${docs.path}/Byte Local');
    await keep.create(recursive: true);
    final items = <Item>[];
    for (final f in res) {
      if (f.path == null) continue;
      var path = f.path!;
      if (Platform.isIOS) {
        // picked files live in a temp inbox on iOS; keep our own copy
        final dest = File('${keep.path}/${f.name}');
        if (!await dest.exists()) await File(path).copy(dest.path);
        path = dest.path;
      }
      final it = await itemForFile(File(path));
      if (it != null) items.add(it);
    }
    await library.addLocalTracks(items);
    return items.length;
  }

  static Future<List<Item>> scanFolder(Directory d) async {
    final out = <Item>[];
    if (!await d.exists()) return out;
    try {
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final p = e.path.toLowerCase();
        if (p.contains('/.') || !audioExtensions.any(p.endsWith)) continue;
        if (await e.length() < 50 * 1024) continue; // ringtones / notification blips
        final it = await itemForFile(e);
        if (it != null) out.add(it);
      }
    } catch (_) {}
    return out;
  }

  static Future<Item?> itemForFile(File f) async {
    String title = f.uri.pathSegments.last.replaceFirst(RegExp(r'\.[^.]+$'), '');
    String? artist, album, thumb;
    int? dur;
    try {
      final m = readMetadata(f, getImage: true);
      if ((m.title ?? '').trim().isNotEmpty) title = m.title!.trim();
      artist = m.artist?.trim();
      album = m.album?.trim();
      dur = m.duration?.inSeconds;
      if (m.pictures.isNotEmpty) {
        final dir = await getTemporaryDirectory();
        final cf = File('${dir.path}/local_art/${f.path.hashCode}.img');
        if (!await cf.exists()) {
          await cf.parent.create(recursive: true);
          await cf.writeAsBytes(m.pictures.first.bytes);
        }
        thumb = cf.uri.toString();
      }
    } catch (_) {}
    return Item(
      kind: ItemKind.song,
      id: 'local:${f.path}',
      title: title,
      artists: [if (artist != null && artist.isNotEmpty) ArtistRef(artist)],
      album: (album?.isEmpty ?? true) ? null : album,
      durationSec: dur,
      thumb: thumb,
    );
  }
}
