import 'innertube.dart';
import 'innertube_parse.dart';

enum AudioQuality { low, normal, high }

class AudioStream {
  final int itag;
  final String url;
  final String mime; // e.g. audio/webm; codecs="opus"
  final int bitrate;
  final int? contentLength;
  final int? durationMs;
  final double? loudnessDb;
  final DateTime expiresAt;
  final String client;
  final String? userAgent;
  const AudioStream({
    required this.itag,
    required this.url,
    required this.mime,
    required this.bitrate,
    this.contentLength,
    this.durationMs,
    this.loudnessDb,
    required this.expiresAt,
    required this.client,
    this.userAgent,
  });
  bool get isOpus => mime.contains('opus');
  bool get isMp4 => mime.startsWith('audio/mp4');
  String get extension => isMp4 ? 'm4a' : 'webm';
  bool get expired => DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 10)));
  @override
  String toString() => 'AudioStream(itag $itag, $mime, ${bitrate ~/ 1000} kbps, $client)';
}

/// Picks the audio stream for a quality. [preferMp4] is required on iOS/Safari
/// (no WebM/Opus there); Android plays both.
AudioStream? pickAudioStream(Map<String, dynamic> player, AudioQuality q, {bool preferMp4 = false}) {
  final fmts = (dig(player, ['streamingData', 'adaptiveFormats']) as List? ?? const [])
      .whereType<Map>()
      .where((f) => (f['mimeType'] as String? ?? '').startsWith('audio/') && f['url'] is String)
      .toList();
  if (fmts.isEmpty) return null;
  var pool = fmts;
  if (preferMp4) {
    final mp4 = fmts.where((f) => (f['mimeType'] as String).startsWith('audio/mp4')).toList();
    if (mp4.isNotEmpty) pool = mp4;
  }
  // drop DRC / dubbed duplicates when an original exists
  final originals = pool.where((f) => f['isDrc'] != true && !(f['audioTrack'] is Map && (f['audioTrack'] as Map)['audioIsDefault'] == false)).toList();
  if (originals.isNotEmpty) pool = originals;
  pool.sort((a, b) => (a['bitrate'] as num? ?? 0).compareTo(b['bitrate'] as num? ?? 0));
  final Map f = switch (q) {
    AudioQuality.low => pool.first,
    AudioQuality.high => bestAudioFormat(pool),
    AudioQuality.normal => pool.lastWhere((f) => (f['bitrate'] as num? ?? 0) <= 140000, orElse: () => pool.first),
  };
  final url = f['url'] as String;
  final exp = int.tryParse(Uri.parse(url).queryParameters['expire'] ?? '');
  final client = player['_client'] as String? ?? '';
  return AudioStream(
    itag: (f['itag'] as num).toInt(),
    url: url,
    mime: f['mimeType'] as String,
    bitrate: (f['bitrate'] as num? ?? 0).toInt(),
    contentLength: int.tryParse('${f['contentLength'] ?? ''}'),
    durationMs: int.tryParse('${f['approxDurationMs'] ?? ''}'),
    loudnessDb: (f['loudnessDb'] as num?)?.toDouble(),
    expiresAt: exp != null ? DateTime.fromMillisecondsSinceEpoch(exp * 1000) : DateTime.now().add(const Duration(hours: 5)),
    client: client,
    userAgent: switch (client) {
      'IOS' => iosClient.userAgent,
      'ANDROID_VR' => androidVr.userAgent,
      _ => visionOs.userAgent,
    },
  );
}

/// Best audio: the highest-quality audio-only stream. Opus 256 (774), then
/// Opus 160 (251), then AAC 256 (141), AAC 128 (140); anything else by bitrate.
Map bestAudioFormat(List<Map> pool) {
  const rank = {774: 5, 251: 4, 141: 3, 140: 2};
  Map best = pool.first;
  for (final f in pool) {
    final rf = rank[(f['itag'] as num?)?.toInt()] ?? 0, rb = rank[(best['itag'] as num?)?.toInt()] ?? 0;
    final bf = (f['bitrate'] as num? ?? 0), bb = (best['bitrate'] as num? ?? 0);
    if (rf > rb || (rf == rb && bf > bb)) best = f;
  }
  return best;
}

/// Under this a "Best" stream counts as a low fallback (worth one more try on the main client).
const lowBitrate = 100000;

class StreamResolver {
  final InnerTube yt;
  final Map<String, (AudioQuality, bool, AudioStream)> _cache = {};
  final Duration retryPause;
  StreamResolver(this.yt, {this.retryPause = const Duration(milliseconds: 300)});

  /// Resolves a playable audio stream. Each candidate client's stream is
  /// probed past its first megabyte (where YouTube cuts off streams that
  /// need tokens Byte can't make), so the player only ever gets one that
  /// will play to the end.
  ///
  /// [avoid] names clients whose stream just failed mid-song: they're tried last.
  Future<AudioStream> resolve(String videoId, AudioQuality q, {bool preferMp4 = false, bool probe = true, Set<String> avoid = const {}}) async {
    final c = _cache[videoId];
    // (an Opus stream cached for Android must not be handed to an iPhone player)
    if (avoid.isEmpty && c != null && c.$1 == q && (c.$2 == preferMp4 || c.$3.isMp4) && !c.$3.expired) return c.$3;
    Object? lastError;
    AudioStream? fallback;
    final order = [...playerClients.where((c) => !avoid.contains(c.name)), ...playerClients.where((c) => avoid.contains(c.name))];
    for (final client in order) {
      // A network hiccup on the good client must not push playback onto a
      // client whose streams stop after 1 MB: each client gets a second try.
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final p = await yt.player(videoId, clients: [client]);
          final s = pickAudioStream(p, q, preferMp4: preferMp4);
          if (s == null) break;
          if (probe) {
            final whole = await _servesWholeFile(s);
            if (whole == false) {
              lastError = StateError('stream from ${client.name} stops after the first part');
              break;
            }
            if (whole == null) {
              lastError = StateError('could not check the stream from ${client.name}');
              await Future<void>.delayed(retryPause);
              continue;
            }
          }
          // A backup client that only had a low stream: try the main client
          // once more for the high one before settling for it.
          if (q == AudioQuality.high && s.bitrate < lowBitrate && client != order.first && fallback == null) {
            fallback = s;
            final again = await _tryClient(videoId, order.first, q, preferMp4, probe);
            if (again != null && again.bitrate > s.bitrate) {
              _cache[videoId] = (q, preferMp4, again);
              return again;
            }
          }
          _cache[videoId] = (q, preferMp4, s);
          if (_cache.length > 200) _cache.remove(_cache.keys.first);
          return s;
        } catch (e) {
          lastError = e;
          await Future<void>.delayed(retryPause);
        }
      }
    }
    throw lastError ?? StateError('No audio stream for $videoId');
  }

  Future<AudioStream?> _tryClient(String videoId, ClientSpec client, AudioQuality q, bool preferMp4, bool probe) async {
    try {
      await Future<void>.delayed(retryPause);
      final p = await yt.player(videoId, clients: [client]);
      final s = pickAudioStream(p, q, preferMp4: preferMp4);
      if (s == null) return null;
      if (probe && await _servesWholeFile(s) != true) return null;
      return s;
    } catch (_) {
      return null;
    }
  }

  /// true = plays to the end, false = cut off after the first part, null = couldn't tell (network).
  Future<bool?> _servesWholeFile(AudioStream s) async {
    final len = s.contentLength;
    if (len == null || len < 1500000) return true;
    try {
      final start = len - 2048;
      final r = await yt.net.get(
        Uri.parse('${s.url}&range=$start-${len - 1}'),
        headers: s.userAgent == null ? const {} : {'User-Agent': s.userAgent!},
        timeout: const Duration(seconds: 12),
      );
      if (r.status == 200 || r.status == 206) return true;
      if (r.status == 403 || r.status == 404 || r.status == 410) return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  void forget(String videoId) => _cache.remove(videoId);

  /// The stream already resolved for [videoId], if any.
  AudioStream? cached(String videoId) => _cache[videoId]?.$3;
}

// ── Upgrade quality (player menu) ───────────────────────────────────────

/// "Opus · 160 kbps" for a stream (what the menu and Song info show).
String streamLabel(AudioStream s) => '${s.isMp4 ? 'AAC' : s.isOpus ? 'Opus' : 'Audio'} · ${(s.bitrate / 1000).round()} kbps';

int _codecRank(AudioStream s) => switch (s.itag) {
  774 => 5,
  251 => 4,
  141 => 3,
  140 => 2,
  _ => 0,
};

/// Is [best] a real step up from the stream that is [playing] (null = unknown,
/// e.g. a cached file)? Higher bitrate, or the same bitrate in a better codec.
bool shouldUpgrade(AudioStream? playing, AudioStream best) {
  if (playing == null) return true;
  if (best.bitrate != playing.bitrate) return best.bitrate > playing.bitrate;
  return _codecRank(best) > _codecRank(playing);
}

enum QualityUpgradeKind { upgraded, alreadyBest, unavailable, failed, nothingPlaying }

/// What "Upgrade quality" did, in words for a toast.
class QualityUpgrade {
  final QualityUpgradeKind kind;
  final String message;
  final AudioStream? stream;
  const QualityUpgrade(this.kind, this.message, [this.stream]);
}
