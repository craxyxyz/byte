// just_audio's stream source API is marked experimental; the version is pinned.
// ignore_for_file: experimental_member_use
import 'dart:async';
import 'dart:io';

import 'package:just_audio/just_audio.dart';

/// Plays a YouTube stream by fetching it in bounded pieces.
///
/// The server paces an open-ended download to about playback speed, so a
/// single long request has no slack: one hiccup on mobile data and the
/// player runs dry halfway through the song. Asking for the file a piece at a
/// time (each piece arrives at full speed) keeps a buffer ahead, and a piece
/// that fails on the network is simply asked for again. An HTTP refusal (403,
/// an expired link) is passed on so the player fetches a fresh link.
class ChunkedHttpSource extends StreamAudioSource {
  final Uri url;
  final int length;
  final String mime;
  final String? userAgent;

  /// Bytes per request.
  final int chunk;

  /// Tries per piece on network errors.
  final int tries;

  /// Opens connections (tests swap it).
  final HttpClient Function() clientFactory;

  ChunkedHttpSource(
    this.url, {
    required this.length,
    required this.mime,
    this.userAgent,
    this.chunk = 1 << 20,
    this.tries = 3,
    HttpClient Function()? client,
    super.tag,
  }) : clientFactory = client ?? HttpClient.new;

  String get _contentType {
    final i = mime.indexOf(';');
    return (i < 0 ? mime : mime.substring(0, i)).trim();
  }

  @override
  Future<StreamAudioResponse> request([int? start, int? end]) async {
    final from = (start ?? 0).clamp(0, length);
    final to = (end ?? length).clamp(from, length);
    return StreamAudioResponse(
      rangeRequestsSupported: true,
      sourceLength: start != null || end != null ? length : null,
      contentLength: to - from,
      offset: start != null ? from : null,
      contentType: _contentType,
      stream: pieces(from, to),
    );
  }

  /// The bytes [from]..[to] (exclusive), fetched piece by piece.
  Stream<List<int>> pieces(int from, int to) async* {
    final http = clientFactory()..connectionTimeout = const Duration(seconds: 10);
    try {
      var at = from;
      while (at < to) {
        final last = (at + chunk).clamp(at, to) - 1;
        var attempt = 0;
        while (true) {
          attempt++;
          var got = 0;
          try {
            final req = await http.getUrl(url);
            if (userAgent != null) req.headers.set(HttpHeaders.userAgentHeader, userAgent!);
            req.headers.set(HttpHeaders.rangeHeader, 'bytes=$at-$last');
            final res = await req.close().timeout(const Duration(seconds: 15));
            if (res.statusCode != 206 && res.statusCode != 200) {
              await res.drain<void>().catchError((_) {});
              // Refused: a fresh link is needed, retrying this one won't help.
              throw StreamRefused(res.statusCode);
            }
            // A server that ignores the range sends the whole file: skip ahead.
            var skip = res.statusCode == 200 ? at : 0;
            await for (final data in res.timeout(const Duration(seconds: 20))) {
              var d = data;
              if (skip > 0) {
                if (d.length <= skip) {
                  skip -= d.length;
                  continue;
                }
                d = d.sublist(skip);
                skip = 0;
              }
              final room = last + 1 - (at + got);
              if (room <= 0) break;
              if (d.length > room) d = d.sublist(0, room);
              got += d.length;
              yield d;
            }
            at += got;
            if (got == 0) throw const SocketException('empty piece');
            break; // this piece done (or partly: the loop asks for the rest)
          } on StreamRefused {
            rethrow;
          } catch (_) {
            at += got; // keep what arrived
            if (attempt >= tries) rethrow;
            await Future<void>.delayed(Duration(milliseconds: 300 * attempt));
          }
        }
      }
    } finally {
      http.close(force: true);
    }
  }
}

/// The server refused the link (403 / 410 …): it needs a fresh one.
class StreamRefused implements Exception {
  final int status;
  const StreamRefused(this.status);
  @override
  String toString() => 'Response code: $status';
}
