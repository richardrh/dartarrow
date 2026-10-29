import 'dart:typed_data';

/// Web-safe LZ4 frame decoding for Arrow IPC. Zstandard is VM-only.
///
/// Implements the LZ4 frame and block specifications. Frame checksums are
/// consumed but not verified; this is not an authenticity/integrity checker.
Uint8List decompressIpcBuffer(int codec, Uint8List input, int expectedLength) {
  if (codec != 0) {
    throw UnsupportedError(
      'Zstandard IPC decompression is not supported on web',
    );
  }
  final source = _Cursor(input);
  if (source.u32() != 0x184d2204) {
    throw const FormatException('Invalid LZ4 frame magic');
  }
  final (flags, maximum) = _readFrameHeader(source, expectedLength);
  final output = _Output(expectedLength);
  while (true) {
    final descriptor = source.u32();
    if (descriptor == 0) break;
    final length = descriptor & 0x7fffffff;
    if (length > maximum) {
      throw const FormatException('LZ4 encoded block exceeds its size limit');
    }
    final block = source.take(length);
    final start = output.position;
    if ((descriptor & 0x80000000) != 0) {
      output.literal(block);
    } else {
      _decodeBlock(block, output, (flags & 0x20) != 0 ? start : 0);
    }
    if (output.position - start > maximum) {
      throw const FormatException('LZ4 decoded block exceeds its size limit');
    }
    if ((flags & 0x10) != 0) source.u32(); // Optional block checksum.
  }
  if ((flags & 4) != 0) source.u32(); // Optional content checksum.
  if (source.remaining != 0 || output.position != expectedLength) {
    throw const FormatException('LZ4 frame size or trailing data mismatch');
  }
  return output.bytes;
}

(int, int) _readFrameHeader(_Cursor source, int expectedLength) {
  final flags = source.byte();
  final descriptor = source.byte();
  if ((flags >> 6) != 1 || (flags & 2) != 0 || (descriptor & 0x8f) != 0) {
    throw const FormatException('Invalid LZ4 frame descriptor');
  }
  if ((flags & 1) != 0) {
    throw UnsupportedError('LZ4 external dictionaries are unsupported');
  }
  final maximum = switch ((descriptor >> 4) & 7) {
    4 => 64 * 1024,
    5 => 256 * 1024,
    6 => 1024 * 1024,
    7 => 4 * 1024 * 1024,
    _ => throw const FormatException('Invalid LZ4 maximum block size'),
  };
  if ((flags & 8) != 0) {
    final low = source.u32();
    final high = source.u32();
    final declared = (BigInt.from(high) << 32) | BigInt.from(low);
    if (declared != BigInt.from(expectedLength)) {
      throw const FormatException('LZ4 frame and IPC sizes disagree');
    }
  }
  source.byte(); // Header checksum; see public function documentation.
  return (flags, maximum);
}

void _decodeBlock(Uint8List bytes, _Output output, int historyStart) {
  final input = _Cursor(bytes);
  while (input.remaining > 0) {
    final token = input.byte();
    output.literal(input.take(_length(input, token >> 4)));
    if (input.remaining == 0) return;
    final distance = input.byte() | (input.byte() << 8);
    final count = _length(input, token & 15) + 4;
    output.match(distance, count, historyStart);
  }
}

int _length(_Cursor input, int initial) {
  var length = initial;
  if (initial == 15) {
    int extra;
    do {
      extra = input.byte();
      length += extra;
    } while (extra == 255);
  }
  return length;
}

final class _Cursor {
  _Cursor(this.bytes);
  final Uint8List bytes;
  int position = 0;
  int get remaining => bytes.length - position;
  int byte() {
    if (remaining < 1) throw const FormatException('Truncated LZ4 frame');
    return bytes[position++];
  }

  int u32() {
    final data = take(4);
    return ByteData.sublistView(data).getUint32(0, Endian.little);
  }

  Uint8List take(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('Truncated LZ4 data');
    }
    final result = Uint8List.sublistView(bytes, position, position + count);
    position += count;
    return result;
  }
}

final class _Output {
  _Output(int length) : bytes = Uint8List(length);
  final Uint8List bytes;
  int position = 0;
  void literal(Uint8List source) {
    _checkSize(source.length);
    bytes.setRange(position, position + source.length, source);
    position += source.length;
  }

  void match(int distance, int count, int historyStart) {
    if (distance <= 0 || distance > position - historyStart) {
      throw const FormatException('Invalid LZ4 back-reference');
    }
    _checkSize(count);
    for (var i = 0; i < count; i++) {
      bytes[position] = bytes[position - distance];
      position++;
    }
  }

  void _checkSize(int count) {
    if (count < 0 || count > bytes.length - position) {
      throw const FormatException('LZ4 exceeds declared decompressed size');
    }
  }
}
