import 'dart:convert';
import 'dart:typed_data';

import 'package:dartaframes_arrow/ipc.dart' as ipc;
import 'package:dartaframes_arrow/src/ipc_compression_web.dart' as web;
import 'package:test/test.dart';

// Generated independently with PyArrow 26, IpcWriteOptions(compression='lz4').
const _stream =
    '/////7AAAAAQAAAAAAAKAA4ABgAFAAgACgAAAAABBAAQAAAAAAAKAAwAAAAEAAgACgAAAEAAAAAEAAAAAQAAAAwAAAAIAAwABAAIAAgAAAAYAAAABAAAAAkAAABweWFycm93MjYAAAAGAAAAc291cmNlAAABAAAAFAAAABAAFAAIAAYABwAMAAAAEAAQAAAAAAABBRAAAAAcAAAABAAAAAAAAAAEAAAAdGV4dAAAAAAEAAQABAAAAP////+oAAAAFAAAAAAAAAAMABgABgAFAAgADAAMAAAAAAMEABwAAABoAAAAAAAAAAAAAAAMABwAEAAEAAgADAAMAAAAWAAAABwAAAAUAAAAAwAAAAAAAAAAAAAABAAEAAQAAAADAAAAAAAAAAAAAAAYAAAAAAAAABgAAAAAAAAAJwAAAAAAAABAAAAAAAAAACEAAAAAAAAAAAAAAAEAAAADAAAAAAAAAAEAAAAAAAAAAQAAAAAAAAAEIk0YYECCAQAAgAUAAAAAEAAAAAAAAAAEIk0YYECCEAAAgAAAAAAHAAAABwAAAAoAAAAAAAAAAAoAAAAAAAAABCJNGGBAggoAAIBHcsO8w59lQWRhAAAAAAAAAAAAAAD/////AAAAAA==';

void main() {
  test('public reader decodes independent PyArrow LZ4 stream', () {
    final table = ipc.openStream(base64Decode(_stream)).readAll();
    expect(table.numRows, 3);
    expect(utf8.decode(table.schema.metadata!['source']!), 'pyarrow26');
    expect(table.column(0).toDartList(), ['Grüße', null, 'Ada']);
  });

  // PyArrow compress(b'a' * 5000, codec='lz4_frame'), including overlapping
  // matches and extended match lengths. The same helper is exercised on VM
  // so ordinary coverage checks include browser-specific decoding logic.
  final repeated = base64Decode(
    'BCJNGGBAgh4AAAAfYQEA/////////////////////////4JQYWFhYWEAAAAA',
  );
  test('web decoder expands overlapping matches within the declared bound', () {
    expect(web.decompressIpcBuffer(0, repeated, 5000), List.filled(5000, 97));
    expect(
      () => web.decompressIpcBuffer(0, repeated, 4999),
      throwsFormatException,
    );
    expect(
      () => web.decompressIpcBuffer(0, repeated, 5001),
      throwsFormatException,
    );
  });
  test('every truncated frame is rejected', () {
    for (var length = 0; length < repeated.length; length++) {
      expect(
        () => web.decompressIpcBuffer(
          0,
          Uint8List.sublistView(repeated, 0, length),
          5000,
        ),
        throwsFormatException,
        reason: 'length $length',
      );
    }
  });
  test('trailing data and invalid magic are rejected', () {
    expect(
      () => web.decompressIpcBuffer(
        0,
        Uint8List.fromList([...repeated, 1]),
        5000,
      ),
      throwsFormatException,
    );
    final invalid = Uint8List.fromList(repeated)..[0] = 0;
    expect(
      () => web.decompressIpcBuffer(0, invalid, 5000),
      throwsFormatException,
    );
  });
  test('frame header flags and block bounds are validated', () {
    for (final (position, value) in [(4, 0), (4, 0x62), (5, 0x41), (5, 0x30)]) {
      final invalid = Uint8List.fromList(repeated)..[position] = value;
      expect(
        () => web.decompressIpcBuffer(0, invalid, 5000),
        throwsFormatException,
      );
    }
    final externalDictionary = Uint8List.fromList(repeated)..[4] = 0x61;
    expect(
      () => web.decompressIpcBuffer(0, externalDictionary, 5000),
      throwsUnsupportedError,
    );
    final oversizedBlock = Uint8List.fromList(repeated);
    ByteData.sublistView(oversizedBlock).setUint32(7, 65537, Endian.little);
    expect(
      () => web.decompressIpcBuffer(0, oversizedBlock, 5000),
      throwsFormatException,
    );
    final invalidDistance = Uint8List.fromList(repeated)
      ..[13] = 0
      ..[14] = 0;
    expect(
      () => web.decompressIpcBuffer(0, invalidDistance, 5000),
      throwsFormatException,
    );
  });
  test('optional content size must equal the IPC declared size', () {
    final size = Uint8List(8);
    ByteData.sublistView(size).setUint32(0, 5000, Endian.little);
    final framed = Uint8List.fromList([
      ...repeated.take(4),
      repeated[4] | 8,
      repeated[5],
      ...size,
      ...repeated.skip(6),
    ]);
    expect(web.decompressIpcBuffer(0, framed, 5000), List.filled(5000, 97));
    expect(
      () => web.decompressIpcBuffer(0, framed, 4999),
      throwsFormatException,
    );
  });
  test('web Zstandard is explicitly unsupported', () {
    expect(
      () => web.decompressIpcBuffer(1, repeated, 5000),
      throwsUnsupportedError,
    );
  });
}
