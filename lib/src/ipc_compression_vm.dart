import 'dart:typed_data';

import 'package:libcompress/libcompress.dart' as compression;

/// Bounded compression support for Arrow IPC on the Dart VM.
Uint8List decompressIpcBuffer(int codec, Uint8List input, int expectedLength) {
  return switch (codec) {
    0 => compression.Lz4Codec(
      maxDecompressedSize: expectedLength,
    ).decompress(input),
    1 => compression.ZstdCodec(
      maxDecompressedSize: expectedLength,
    ).decompress(input),
    _ => throw UnsupportedError('Unsupported IPC compression codec $codec'),
  };
}
