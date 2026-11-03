import 'dart:convert';
import 'dart:typed_data';

/// The Cast v2 wire format: one protobuf `CastMessage` per frame, each frame
/// prefixed with its length (4 bytes, big-endian). Only the fields Byte uses.
class CastMessage {
  final String sourceId;
  final String destinationId;
  final String namespace;
  final String payload; // UTF-8 JSON
  const CastMessage({required this.sourceId, required this.destinationId, required this.namespace, required this.payload});

  Map<String, dynamic> get json {
    try {
      return (jsonDecode(payload) as Map).cast<String, dynamic>();
    } catch (_) {
      return const {};
    }
  }

  /// Protobuf body (no length prefix).
  Uint8List encode() {
    final b = BytesBuilder();
    void varint(int v) {
      while (v >= 0x80) {
        b.addByte((v & 0x7f) | 0x80);
        v >>= 7;
      }
      b.addByte(v);
    }

    void str(int field, String s) {
      final bytes = utf8.encode(s);
      varint((field << 3) | 2);
      varint(bytes.length);
      b.add(bytes);
    }

    varint((1 << 3) | 0); // protocol_version = CASTV2_1_0
    varint(0);
    str(2, sourceId);
    str(3, destinationId);
    str(4, namespace);
    varint((5 << 3) | 0); // payload_type = STRING
    varint(0);
    str(6, payload);
    return b.toBytes();
  }

  /// One framed message, ready for the socket.
  Uint8List frame() {
    final body = encode();
    final out = Uint8List(4 + body.length);
    ByteData.sublistView(out).setUint32(0, body.length);
    out.setRange(4, out.length, body);
    return out;
  }

  static CastMessage decode(Uint8List data) {
    var i = 0;
    int varint() {
      var shift = 0, v = 0;
      while (true) {
        final x = data[i++];
        v |= (x & 0x7f) << shift;
        if (x < 0x80) return v;
        shift += 7;
      }
    }

    String src = '', dst = '', ns = '', payload = '';
    while (i < data.length) {
      final key = varint();
      final field = key >> 3, wire = key & 7;
      if (wire == 0) {
        varint();
      } else if (wire == 2) {
        final len = varint();
        final bytes = data.sublist(i, i + len);
        i += len;
        final s = field == 7 ? '' : utf8.decode(bytes, allowMalformed: true);
        switch (field) {
          case 2:
            src = s;
          case 3:
            dst = s;
          case 4:
            ns = s;
          case 6:
            payload = s;
        }
      } else if (wire == 5) {
        i += 4;
      } else if (wire == 1) {
        i += 8;
      } else {
        break;
      }
    }
    return CastMessage(sourceId: src, destinationId: dst, namespace: ns, payload: payload);
  }
}

/// Splits a byte stream into whole frames.
class CastFramer {
  final _buf = BytesBuilder(copy: false);
  Uint8List _pending = Uint8List(0);

  List<CastMessage> add(List<int> chunk) {
    _buf.add(_pending);
    _buf.add(chunk);
    var data = _buf.takeBytes();
    final out = <CastMessage>[];
    var off = 0;
    while (data.length - off >= 4) {
      final len = ByteData.sublistView(data, off, off + 4).getUint32(0);
      if (data.length - off - 4 < len) break;
      out.add(CastMessage.decode(Uint8List.sublistView(data, off + 4, off + 4 + len)));
      off += 4 + len;
    }
    _pending = Uint8List.fromList(data.sublist(off));
    return out;
  }
}

class CastNs {
  static const connection = 'urn:x-cast:com.google.cast.tp.connection';
  static const heartbeat = 'urn:x-cast:com.google.cast.tp.heartbeat';
  static const receiver = 'urn:x-cast:com.google.cast.receiver';
  static const media = 'urn:x-cast:com.google.cast.media';
}

/// The standard media receiver every Cast device has.
const defaultMediaReceiver = 'CC1AD845';
