import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/streams.dart';
import '../player/byte_handler.dart';
import 'cast_discovery.dart';
import 'cast_relay.dart';
import 'cast_session.dart';

/// Casting: find speakers/TVs, send the queue to one, and keep the player's
/// buttons, seek bar and song changes working while it plays there.
class CastController extends ChangeNotifier implements RemoteOutput {
  final ByteAudioHandler player;
  final Future<List<CastDevice>> Function() scanner;
  final Future<CastLink> Function(CastDevice) connector;
  final Future<RelaySource?> Function(Item item) sourceFor;
  final CastRelay relay;

  List<CastDevice> devices = const [];
  bool scanning = false;
  CastDevice? device;
  CastSession? _session;
  StreamSubscription? _statusSub;
  String? error;
  String? _loadedId;
  bool _playing = false;
  double _pos = 0;
  double? _dur;
  DateTime _posAt = DateTime.now();

  CastController({
    required this.player,
    required this.sourceFor,
    Future<List<CastDevice>> Function()? scanner,
    Future<CastLink> Function(CastDevice)? connector,
    CastRelay? relay,
  }) : scanner = scanner ?? CastDiscovery.scan,
       connector = connector ?? connectCastLink,
       relay = relay ?? CastRelay();

  bool get connected => _session != null && !_session!.closed;

  /// Tests swap the network scan for a fake.
  @visibleForTesting
  Future<List<CastDevice>> Function()? scannerForTest;

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    error = null;
    notifyListeners();
    try {
      devices = await (scannerForTest ?? scanner)();
    } catch (e) {
      devices = const [];
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  /// Moves playback to [d]: the phone goes quiet and the speaker takes over
  /// from the same spot in the same song.
  Future<void> connect(CastDevice d) async {
    await disconnect(resumeHere: false);
    error = null;
    device = d;
    notifyListeners();
    try {
      final link = await connector(d);
      final s = CastSession(link);
      await s.open();
      _session = s;
      _statusSub = s.status.listen(_onStatus);
      await relay.start();
      final at = Duration(milliseconds: player.clock.nowMs);
      player.remote = this;
      await player.pauseLocalForRemote();
      final it = player.current.value;
      if (it != null) await load(it, startAt: at);
    } catch (e) {
      error = 'Couldn\'t connect to ${d.name}';
      device = null;
      player.remote = null;
      await _session?.close();
      _session = null;
    }
    notifyListeners();
  }

  /// Back to the phone, at the same spot.
  Future<void> disconnect({bool resumeHere = true}) async {
    final s = _session;
    if (s == null && device == null) return;
    final at = Duration(milliseconds: positionMs);
    final wasPlaying = _playing;
    _session = null;
    device = null;
    _loadedId = null;
    await _statusSub?.cancel();
    _statusSub = null;
    player.remote = null;
    await s?.stopAndClose();
    await relay.stop();
    notifyListeners();
    if (resumeHere && player.current.value != null) await player.resumeLocalAfterRemote(at, play: wasPlaying);
  }

  void _onStatus(CastMediaState st) {
    _playing = st.playing;
    _pos = st.currentTime;
    _posAt = DateTime.now();
    _dur = st.duration ?? _dur;
    player.remoteChanged();
    if (st.playerState == 'IDLE' && st.idleReason == 'FINISHED' && _loadedId != null) {
      _loadedId = null;
      unawaited(player.remoteEnded());
    } else if (st.playerState == 'IDLE' && st.idleReason == 'ERROR') {
      error = 'The speaker couldn\'t play this song';
      notifyListeners();
    }
  }

  // ── RemoteOutput ──
  @override
  String get remoteName => device?.name ?? 'Cast';

  @override
  bool get remotePlaying => _playing;

  @override
  int get positionMs => (_playing ? (_pos * 1000 + DateTime.now().difference(_posAt).inMilliseconds) : _pos * 1000).round();

  @override
  Duration? get remoteDuration => _dur == null ? null : Duration(milliseconds: (_dur! * 1000).round());

  @override
  Future<void> load(Item it, {Duration? startAt}) async {
    final s = _session;
    if (s == null) return;
    final src = await sourceFor(it);
    if (src == null) {
      error = 'This song can\'t be sent to the speaker';
      notifyListeners();
      return;
    }
    final url = relay.publish(src);
    _loadedId = it.id;
    _pos = (startAt?.inMilliseconds ?? 0) / 1000;
    _posAt = DateTime.now();
    _dur = it.durationSec?.toDouble();
    try {
      await s.load(
        url: url.toString(),
        contentType: src.contentType,
        title: it.title,
        artist: it.artistLine,
        album: it.album,
        image: it.thumbAt(544),
        startAt: _pos,
        duration: _dur,
      );
      _playing = true;
      error = null;
    } catch (e) {
      error = '$e'.replaceFirst('Bad state: ', '');
    }
    player.remoteChanged();
    notifyListeners();
  }

  @override
  Future<void> remotePlay() async {
    _session?.play();
    _playing = true;
    _posAt = DateTime.now();
    player.remoteChanged();
  }

  @override
  Future<void> remotePause() async {
    _pos = positionMs / 1000;
    _session?.pause();
    _playing = false;
    player.remoteChanged();
  }

  @override
  Future<void> remoteSeek(Duration d) async {
    _pos = d.inMilliseconds / 1000;
    _posAt = DateTime.now();
    _session?.seek(_pos);
    player.remoteChanged();
  }

  @override
  Future<void> remoteVolume(double v) async => _session?.setVolume(v);
}

/// How the speaker gets the song: a stream in a format every Cast device
/// plays (AAC in MP4), or the downloaded / local file itself.
Future<RelaySource?> defaultCastSource(Item it, {required StreamResolver resolver, required String? Function(String id) downloadedPath, required AudioQuality quality}) async {
  String typeFor(String path) {
    final ext = path.split('.').last.toLowerCase();
    return switch (ext) {
      'mp3' => 'audio/mpeg',
      'flac' => 'audio/flac',
      'wav' => 'audio/wav',
      'ogg' || 'opus' => 'audio/ogg',
      'webm' => 'audio/webm',
      _ => 'audio/mp4',
    };
  }

  final dl = downloadedPath(it.id);
  if (dl != null) return RelaySource.file(dl, typeFor(dl));
  if (it.id.startsWith('local:')) {
    final p = it.id.substring(6);
    return RelaySource.file(p, typeFor(p));
  }
  if (it.id.startsWith('dav:')) return RelaySource.url(Uri.parse(it.id.substring(4)), typeFor(it.id));
  final s = await resolver.resolve(it.id, quality, preferMp4: true);
  return RelaySource.url(Uri.parse(s.url), s.isMp4 ? 'audio/mp4' : 'audio/webm', headers: {if (s.userAgent != null) 'User-Agent': s.userAgent!});
}
