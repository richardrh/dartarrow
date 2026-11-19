import 'dart:typed_data';

import 'package:libcompress/libcompress.dart' as compression;

/// Bounded compression support for Arrow IPC on the Dart VM.
///
/// `size:` caps decoding at [expectedLength] and rejects any other output
/// length; `maxSize: null` lifts libcompress's own default ceiling so the
/// caller's IPC budget is the only limit.
Uint8List decompressIpcBuffer(int codec, Uint8List input, int expectedLength) {
  return switch (codec) {
    0 => compression.Lz4Codec(
      maxSize: null,
    ).decompress(input, size: expectedLength),
    1 => compression.ZstdCodec(
      maxSize: null,
    ).decompress(input, size: expectedLength),
    _ => throw UnsupportedError('Unsupported IPC compression codec $codec'),
  };
}
