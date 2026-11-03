import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'cast_session.dart';

/// Finds Cast devices on the Wi-Fi (mDNS service `_googlecast._tcp`).
class CastDiscovery {
  static const service = '_googlecast._tcp.local';

  /// One scan; returns the devices that answered within [window].
  static Future<List<CastDevice>> scan({Duration window = const Duration(seconds: 5)}) async {
    // iPhone: raw multicast sockets need a special Apple permission, so the
    // system's own Bonjour browser finds the speakers (AppDelegate.swift).
    if (Platform.isIOS) return _scanIos(window);
    final client = MDnsClient(rawDatagramSocketFactory: (host, int port, {bool reuseAddress = true, bool reusePort = false, int ttl = 255}) {
      return RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: false, ttl: ttl);
    });
    final found = <String, CastDevice>{};
    try {
      await client.start();
      await for (final ptr in client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(service)).timeout(window, onTimeout: (s) => s.close())) {
        String? name, model, id;
        await for (final txt in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(ptr.domainName)).timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
          final kv = parseCastTxt(txt.text);
          name = kv['fn'];
          model = kv['md'];
          id = kv['id'];
        }
        await for (final srv in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(ptr.domainName)).timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
          await for (final ip in client.lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target)).timeout(const Duration(seconds: 2), onTimeout: (s) => s.close())) {
            final key = id ?? ptr.domainName;
            found[key] = CastDevice(id: key, name: name ?? ptr.domainName.split('.').first, host: ip.address.address, port: srv.port, model: model);
            break;
          }
          break;
        }
      }
    } catch (_) {
      // no Wi-Fi / multicast blocked: nothing found
    } finally {
      client.stop();
    }
    return found.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }
}

const _iosCast = MethodChannel('byte/cast');

Future<List<CastDevice>> _scanIos(Duration window) async {
  try {
    final list = await _iosCast.invokeListMethod<Map>('scan', {'seconds': window.inSeconds}) ?? const [];
    return castDevicesFromMaps(list);
  } catch (_) {
    return const [];
  }
}

/// Devices from the iPhone browser's answers: {id, name, host, port, model}.
List<CastDevice> castDevicesFromMaps(List<Map> list) {
  final out = <String, CastDevice>{};
  for (final m in list) {
    final host = m['host'] as String?;
    if (host == null || host.isEmpty) continue;
    final id = (m['id'] as String?)?.isNotEmpty == true ? m['id'] as String : host;
    // the same speaker can be reported twice; keep what each report knows
    out[id] = CastDevice(id: id, name: (m['name'] as String?) ?? out[id]?.name ?? host, host: host, port: (m['port'] as num?)?.toInt() ?? 8009, model: (m['model'] as String?) ?? out[id]?.model);
  }
  return out.values.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// Cast TXT records: `id=…`, `fn=Living Room TV`, `md=Chromecast`.
Map<String, String> parseCastTxt(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final i = line.indexOf('=');
    if (i > 0) out[line.substring(0, i).trim()] = line.substring(i + 1).trim();
  }
  return out;
}
