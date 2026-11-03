import 'package:smb_connect/smb_connect.dart';

import 'smb_source.dart';

// Byte © 2026 Apurba Laskar. The SMB client (phones and desktops only).

Future<SmbBackend> connectSmb(String host, String user, String pass, String domain) async {
  final c = await SmbConnect.connectAuth(host: host, domain: domain, username: user, password: pass);
  return _RealSmb(c);
}

class _RealSmb implements SmbBackend {
  final SmbConnect c;
  _RealSmb(this.c);
  static String _clean(String p) => p.endsWith('/') ? p.substring(0, p.length - 1) : p;
  @override
  Future<List<SmbEntry>> shares() async => [
    for (final f in await c.listShares())
      if (!f.name.endsWith(r'$')) SmbEntry(f.name, '/${f.name}/', true),
  ];
  @override
  Future<List<SmbEntry>> list(String path) async {
    final folder = await c.file(path.endsWith('/') ? path : '$path/');
    final out = <SmbEntry>[];
    for (final f in await c.listFiles(folder)) {
      if (f.name.startsWith('.')) continue;
      out.add(SmbEntry(f.name, _clean(f.path), f.isDirectory(), size: f.isDirectory() ? null : f.size));
    }
    out.sort((a, b) => a.folder == b.folder ? a.name.toLowerCase().compareTo(b.name.toLowerCase()) : (a.folder ? -1 : 1));
    return out;
  }

  @override
  Future<int> length(String path) async => (await c.file(path)).size;
  @override
  Future<Stream<List<int>>> read(String path, int start, int endExclusive) async => await c.openRead(await c.file(path), start, endExclusive);
  @override
  Future<void> close() => c.close();
}

/// Your SMB share as a Byte source: browse folders, play songs straight from it.
