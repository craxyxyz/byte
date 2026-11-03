import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'cast_protocol.dart';

/// A speaker or TV found on the Wi-Fi.
class CastDevice {
  final String id;
  final String name;
  final String host;
  final int port;
  final String? model;
  const CastDevice({required this.id, required this.name, required this.host, this.port = 8009, this.model});
  @override
  bool operator ==(Object other) => other is CastDevice && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// What the receiver says about the song it is playing.
class CastMediaState {
  final String playerState; // IDLE | PLAYING | PAUSED | BUFFERING
  final double currentTime;
  final double? duration;
  final String? idleReason; // FINISHED | ERROR | CANCELLED | INTERRUPTED
  const CastMediaState(this.playerState, this.currentTime, {this.duration, this.idleReason});
  bool get playing => playerState == 'PLAYING' || playerState == 'BUFFERING';
}

/// The byte pipe a session talks over (a TLS socket on a real device; a fake in tests).
abstract class CastLink {
  Stream<List<int>> get input;
  void add(List<int> bytes);
  Future<void> close();
}

class _SocketLink implements CastLink {
  final SecureSocket s;
  _SocketLink(this.s);
  @override
  Stream<List<int>> get input => s;
  @override
  void add(List<int> bytes) => s.add(bytes);
  @override
  Future<void> close() async => s.destroy();
}

Future<CastLink> connectCastLink(CastDevice d) async {
  // Cast devices present a self-signed certificate on the local network.
  final s = await SecureSocket.connect(d.host, d.port, onBadCertificate: (_) => true, timeout: const Duration(seconds: 8));
  return _SocketLink(s);
}

/// One open connection to a Cast device running the standard media receiver.
class CastSession {
  final CastLink link;
  final String sender = 'sender-byte';
  final _framer = CastFramer();
  final _status = StreamController<CastMediaState>.broadcast();
  final Map<int, Completer<Map<String, dynamic>>> _waiting = {};
  StreamSubscription? _sub;
  Timer? _beat;
  int _req = 1;
  String? transportId;
  String? sessionId;
  int? mediaSessionId;
  CastMediaState? last;
  bool closed = false;

  CastSession(this.link);

  Stream<CastMediaState> get status => _status.stream;

  void _send(String ns, String dest, Map<String, dynamic> payload) {
    if (closed) return;
    link.add(CastMessage(sourceId: sender, destinationId: dest, namespace: ns, payload: jsonEncode(payload)).frame());
  }

  Future<Map<String, dynamic>> _request(String ns, String dest, Map<String, dynamic> payload, {Duration timeout = const Duration(seconds: 15)}) {
    final id = _req++;
    final c = Completer<Map<String, dynamic>>();
    _waiting[id] = c;
    _send(ns, dest, {...payload, 'requestId': id});
    return c.future.timeout(timeout, onTimeout: () {
      _waiting.remove(id);
      throw TimeoutException('The speaker did not answer');
    });
  }

  void _onMessage(CastMessage m) {
    final j = m.json;
    final type = j['type'];
    if (m.namespace == CastNs.heartbeat && type == 'PING') {
      _send(CastNs.heartbeat, m.sourceId, {'type': 'PONG'});
      return;
    }
    if (m.namespace == CastNs.connection && type == 'CLOSE') {
      close();
      return;
    }
    if (m.namespace == CastNs.media && type == 'MEDIA_STATUS') {
      final list = (j['status'] as List?) ?? const [];
      if (list.isNotEmpty) {
        final s = (list.first as Map).cast<String, dynamic>();
        mediaSessionId = (s['mediaSessionId'] as num?)?.toInt() ?? mediaSessionId;
        final media = s['media'] as Map?;
        last = CastMediaState(
          s['playerState'] as String? ?? 'IDLE',
          (s['currentTime'] as num?)?.toDouble() ?? 0,
          duration: (media?['duration'] as num?)?.toDouble() ?? last?.duration,
          idleReason: s['idleReason'] as String?,
        );
        _status.add(last!);
      }
    }
    final rid = (j['requestId'] as num?)?.toInt();
    if (rid != null && rid != 0) _waiting.remove(rid)?.complete(j);
  }

  /// Connects, starts the media receiver and joins it.
  Future<void> open() async {
    _sub = link.input.listen((b) {
      for (final m in _framer.add(b)) {
        _onMessage(m);
      }
    }, onDone: close, onError: (_) => close());
    _send(CastNs.connection, 'receiver-0', {'type': 'CONNECT'});
    _beat = Timer.periodic(const Duration(seconds: 5), (_) => _send(CastNs.heartbeat, 'receiver-0', {'type': 'PING'}));
    final r = await _request(CastNs.receiver, 'receiver-0', {'type': 'LAUNCH', 'appId': defaultMediaReceiver});
    final apps = (((r['status'] as Map?)?['applications']) as List?) ?? const [];
    final app = apps.whereType<Map>().firstWhere((a) => a['appId'] == defaultMediaReceiver, orElse: () => const {});
    transportId = app['transportId'] as String?;
    sessionId = app['sessionId'] as String?;
    if (transportId == null) throw StateError('The speaker did not start the player');
    _send(CastNs.connection, transportId!, {'type': 'CONNECT'});
  }

  /// Plays [url] on the device. [contentType] e.g. audio/mp4.
  Future<void> load({
    required String url,
    required String contentType,
    required String title,
    String? artist,
    String? album,
    String? image,
    double startAt = 0,
    double? duration,
  }) async {
    if (transportId == null) throw StateError('Not connected');
    final r = await _request(CastNs.media, transportId!, {
      'type': 'LOAD',
      'sessionId': sessionId,
      'autoplay': true,
      'currentTime': startAt,
      'media': {
        'contentId': url,
        'contentUrl': url,
        'streamType': 'BUFFERED',
        'contentType': contentType,
        'duration': ?duration,
        'metadata': {
          'metadataType': 3, // music track
          'title': title,
          'artist': ?artist,
          'albumName': ?album,
          if (image != null)
            'images': [
              {'url': image},
            ],
        },
      },
    });
    if (r['type'] == 'LOAD_FAILED' || r['type'] == 'LOAD_CANCELLED' || r['type'] == 'INVALID_REQUEST') {
      throw StateError('The speaker could not play this song');
    }
  }

  void _media(String type, [Map<String, dynamic> extra = const {}]) {
    if (transportId == null || mediaSessionId == null) return;
    _send(CastNs.media, transportId!, {'type': type, 'mediaSessionId': mediaSessionId, 'requestId': _req++, ...extra});
  }

  void play() => _media('PLAY');
  void pause() => _media('PAUSE');
  void seek(double seconds) => _media('SEEK', {'currentTime': seconds});
  void setVolume(double level) => _send(CastNs.receiver, 'receiver-0', {'type': 'SET_VOLUME', 'volume': {'level': level.clamp(0.0, 1.0)}, 'requestId': _req++});

  /// Stops the player on the device and closes the connection.
  Future<void> stopAndClose() async {
    if (sessionId != null) _send(CastNs.receiver, 'receiver-0', {'type': 'STOP', 'sessionId': sessionId, 'requestId': _req++});
    await close();
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    _beat?.cancel();
    await _sub?.cancel();
    for (final c in _waiting.values) {
      if (!c.isCompleted) c.completeError(StateError('Disconnected'));
    }
    _waiting.clear();
    await _status.close();
    await link.close();
  }
}
