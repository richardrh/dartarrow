import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/ipc.dart' as ipc;
import 'package:test/test.dart';

Uint8List _stream(Array column) {
  final schema = Schema([field('value', column.type)]);
  return (ipc.newStream(
    schema,
  )..writeBatch(RecordBatch.fromArrays([column], schema: schema))).close();
}

/// Bit-exact equality (NaN payloads included) via the canonical scalars.
bool _same(Array a, Array b) {
  if (a.type != b.type || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].isValid != b[i].isValid ||
        a[i].rawBits != b[i].rawBits ||
        '${a[i].value}' != '${b[i].value}') {
      return false;
    }
  }
  return true;
}

/// Round-trips [column] and every one-row-trimmed slice through both formats.
void _roundtrip(Array column) {
  for (final input in [
    column,
    if (column.length > 1) column.slice(1),
    if (column.length > 2) column.slice(1, column.length - 2),
  ]) {
    final read = ipc.openStream(_stream(input)).single.columns.single;
    expect(_same(read, input), isTrue, reason: '${read.toDartList()}');
    final schema = Schema([field('value', input.type)]);
    final file = (ipc.newFile(
      schema,
    )..writeBatch(RecordBatch.fromArrays([read], schema: schema))).close();
    final reread = ipc.openFile(file).getBatch(0).columns.single;
    expect(_same(reread, input), isTrue, reason: '${reread.toDartList()}');
  }
}

Buffer _bytes(List<int> values) => Buffer(Uint8List.fromList(values));

Buffer _int32s(List<int> values) {
  final data = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setInt32(i * 4, values[i], Endian.little);
  }
  return Buffer(data.buffer.asUint8List());
}

void main() {
  test('binary view inline boundary and external data', () {
    for (final size in [0, 1, 12, 13, 100]) {
      _roundtrip(
        array([
          Uint8List.fromList(List.generate(size, (i) => i % 256)),
          null,
          Uint8List.fromList([7]),
        ], type: binaryView()),
      );
      _roundtrip(array(['é' * size, null, 'x' * 20], type: stringView()));
    }
  });

  test('fixed binary including zero width', () {
    for (final width in [0, 1, 16]) {
      _roundtrip(
        array([
          Uint8List.fromList(List.filled(width, 255)),
          null,
          Uint8List(width),
        ], type: FixedSizeBinaryType(width)),
      );
    }
  });

  test('large binary/string and large lists rebase 64-bit offsets', () {
    _roundtrip(array(['a', null, 'bc', ''], type: largeString()));
    _roundtrip(
      array([
        Uint8List.fromList([1]),
        null,
        Uint8List.fromList([2, 3]),
      ], type: largeBinary()),
    );
    _roundtrip(
      array([
        [1],
        null,
        [2, 3],
      ], type: largeList(int32())),
    );
  });

  test('both list view widths preserve null and empty rows', () {
    for (final type in [listView(int32()), largeListView(int32())]) {
      _roundtrip(
        array([
          [7, null],
          null,
          <int>[],
          [1, 2, 3],
        ], type: type),
      );
    }
  });

  test('map keeps duplicate ordered keys and nullable values', () {
    _roundtrip(
      array([
        [('a', 1), ('a', null)],
        null,
        <(String, int)>[],
        [('b', 2)],
      ], type: mapType(string(), int32())),
    );
  });

  test('union arbitrary tags preserve selected nulls and float bits', () {
    final fields = [field('f', float64()), field('s', string())];
    final nan = ByteData(8)
      ..setUint32(0, 1, Endian.little)
      ..setUint32(4, 0x7ff80000, Endian.little);
    final f64 = Array.fromBuffers(float64(), 1, [
      null,
      Buffer(nan.buffer.asUint8List()),
    ]);
    final strings = array([null, 'hello'], type: string());
    final dense = Array.fromBuffers(
      UnionType(fields, mode: UnionMode.dense, typeIds: [5, 97]),
      3,
      [
        null,
        _bytes([5, 97, 97]),
        _int32s([0, 0, 1]),
      ],
      children: [f64, strings],
    );
    _roundtrip(dense);
    final sparse = Array.fromBuffers(
      UnionType(fields, typeIds: [5, 97]),
      3,
      [
        null,
        _bytes([5, 97, 97]),
      ],
      children: [
        concatArrays([
          f64,
          array([null, null], type: float64()),
        ]),
        array([null, null, 'hello'], type: string()),
      ],
    );
    _roundtrip(sparse);
  });

  test('all interval units preserve signed components', () {
    final values = [
      IntervalValue.yearMonth(-2147483648),
      IntervalValue.dayTime(-7, 2147483647),
      IntervalValue.monthDayNano(-1, 2, BigInt.parse('-9223372036854775808')),
    ];
    for (final value in values) {
      _roundtrip(array([value, null, value], type: IntervalType(value.unit)));
    }
  });

  test('run end widths preserve repeated values and null runs', () {
    for (final width in [16, 32, 64]) {
      final type = RunEndEncodedType(
        field('run_ends', IntegerType(width), nullable: false),
        field('values', int32()),
      );
      _roundtrip(array([7, 7, null, null, -1], type: type));
      _roundtrip(array(<int>[], type: type));
    }
  });

  test('REE logical length is budget checked', () {
    final type = runEndEncoded(int32(), int32());
    final bytes = _stream(array(List.filled(1000, 1), type: type));
    expect(
      () => ipc
          .openStream(bytes, limits: const ipc.IpcLimits(maxValues: 10))
          .readAll(),
      throwsFormatException,
    );
  });

  test('uncompressed reads are zero-copy views of the input', () {
    final bytes = _stream(array([1, 2, 3], type: int64()));
    final column = ipc.openStream(bytes).single.columns.single;
    final data = column.buffers()[1]!.bytes;
    expect(data.buffer.lengthInBytes, bytes.lengthInBytes);
    // The values buffer aliases the input: mutating the input is visible.
    final at = data.offsetInBytes + 16;
    expect(bytes[at], 3);
    bytes[at] = 9;
    expect(column[2].value, 9);
  });

  test('byte corruption of extended layouts is rejected cleanly', () {
    final columns = [
      array(['short', null, 'a much longer string value'], type: stringView()),
      array([
        [1, 2],
        null,
        [3],
      ], type: listView(int32())),
      array([
        [('k', 1)],
        null,
        <(String, int)>[],
      ], type: mapType(string(), int32())),
      array([1, 1, null], type: runEndEncoded(int16(), int32())),
      array([
        IntervalValue.monthDayNano(1, 2, 3),
        null,
        IntervalValue.monthDayNano(-1, 0, 9),
      ], type: monthDayNanoInterval()),
      Array.fromBuffers(
        UnionType([field('i', int32())], mode: UnionMode.dense),
        3,
        [
          null,
          _bytes([0, 0, 0]),
          _int32s([0, 1, 2]),
        ],
        children: [
          array([1, null, 3], type: int32()),
        ],
      ),
    ];
    final schema = Schema([
      for (var i = 0; i < columns.length; i++) field('c$i', columns[i].type),
    ]);
    final stream = (ipc.newStream(
      schema,
    )..writeBatch(RecordBatch.fromArrays(columns, schema: schema))).close();
    expect(ipc.openStream(stream).readAll().numRows, 3);
    for (var i = 0; i < stream.length; i++) {
      final copy = Uint8List.fromList(stream);
      copy[i] ^= 0xa5;
      try {
        ipc.openStream(copy).readAll();
      } on FormatException {
        // expected
      } on UnsupportedError {
        // expected
      }
    }
  });
}
