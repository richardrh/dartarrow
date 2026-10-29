import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/ipc.dart' as ipc;
import 'package:test/test.dart';

Uint8List _stream(Schema schema, List<RecordBatch> batches) {
  final writer = ipc.newStream(schema);
  batches.forEach(writer.writeBatch);
  return writer.close();
}

Uint8List _file(Schema schema, List<RecordBatch> batches) {
  final writer = ipc.newFile(schema);
  batches.forEach(writer.writeBatch);
  return writer.close();
}

List<RecordBatch> _readStream(
  Uint8List bytes, {
  ipc.IpcLimits limits = const ipc.IpcLimits(),
}) => ipc.openStream(bytes, limits: limits).toList();

List<RecordBatch> _readFile(
  Uint8List bytes, {
  ipc.IpcLimits limits = const ipc.IpcLimits(),
}) {
  final reader = ipc.openFile(bytes, limits: limits);
  return [for (var i = 0; i < reader.numRecordBatches; i++) reader.getBatch(i)];
}

RecordBatch _batch(Schema schema, List<Array> columns) =>
    RecordBatch.fromArrays(columns, schema: schema);

Array _words(List<String> words) => array(words, type: string());

Array _dictionaryArray(
  DictionaryType type,
  List<int?> indices,
  Array dictionary,
) => Array.fromDictionary(
  array(indices, type: type.indexType),
  dictionary,
  ordered: type.ordered,
);

// Minimal metadata addressing for mutations of public-writer output.
int _slot(ByteData data, int table, int field) {
  final vt = table - data.getInt32(table, Endian.little);
  final entry = vt + 4 + field * 2;
  if (entry >= vt + data.getUint16(vt, Endian.little)) return 0;
  final offset = data.getUint16(entry, Endian.little);
  return offset == 0 ? 0 : table + offset;
}

int _ref(ByteData data, int at) => at + data.getUint32(at, Endian.little);

int _i64(ByteData data, int at) =>
    data.getInt32(at + 4, Endian.little) * 4294967296 +
    data.getUint32(at, Endian.little);

void _putI64(ByteData data, int at, int value) {
  final low = value % 4294967296;
  data.setUint32(at, low, Endian.little);
  data.setInt32(at + 4, (value - low) ~/ 4294967296, Endian.little);
}

List<({int start, int end, int header, int kind})> _messages(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final result = <({int start, int end, int header, int kind})>[];
  var start = 0;
  while (start < bytes.length - 8) {
    final length = data.getInt32(start + 4, Endian.little);
    if (length == 0) break;
    final message = _ref(data, start + 8);
    final bodySlot = _slot(data, message, 3);
    final bodyLength = bodySlot == 0 ? 0 : _i64(data, bodySlot);
    final end = start + 8 + length + bodyLength;
    result.add((
      start: start,
      end: end,
      header: _ref(data, _slot(data, message, 2)),
      kind: data.getUint8(_slot(data, message, 1)),
    ));
    start = end;
  }
  return result;
}

List<int> _schemaDictionaryIdSlots(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final result = <int>[];
  void fields(int vectorSlot) {
    if (vectorSlot == 0) return;
    final vector = _ref(data, vectorSlot);
    final length = data.getUint32(vector, Endian.little);
    for (var i = 0; i < length; i++) {
      final field = _ref(data, vector + 4 + i * 4);
      final dictionary = _slot(data, field, 4);
      if (dictionary != 0) {
        result.add(_slot(data, _ref(data, dictionary), 0));
      }
      fields(_slot(data, field, 5));
    }
  }

  fields(_slot(data, _messages(bytes).first.header, 1));
  return result;
}

Array _floatBits(int bitWidth, List<int> bits, List<bool> valid) {
  final width = bitWidth ~/ 8;
  final data = ByteData(bits.length * width);
  for (var i = 0; i < bits.length; i++) {
    switch (width) {
      case 2:
        data.setUint16(i * 2, bits[i], Endian.little);
      case 4:
        data.setUint32(i * 4, bits[i], Endian.little);
      default:
        // 64-bit samples here are below 2^32, so the halves stay web-safe.
        data.setUint32(i * 8, bits[i], Endian.little);
    }
  }
  final validity = Uint8List(1);
  for (var i = 0; i < valid.length; i++) {
    if (valid[i]) validity[0] |= 1 << i;
  }
  return Array.fromBuffers(FloatingType(bitWidth), bits.length, [
    Buffer(validity),
    Buffer(data.buffer.asUint8List()),
  ]);
}

(Schema, List<RecordBatch>) _sample() {
  final intList = ListType(field('item', int32()));
  final large = largeList(field('item', string()));
  final fixedList = FixedSizeListType(field('item', float64()), 2);
  final structType = struct([field('a', uint16()), field('b', boolType())]);
  final dict = dictionary(int8(), string());
  final ext = extension('my.uuid', binary(), metadata: 'v1');
  final columns = <(String, Array)>[
    ('i8', array([-128, null, 127], type: int8())),
    ('i64', array([-(1 << 62), 0, null], type: int64())),
    (
      'u64',
      array([BigInt.parse('18446744073709551615'), null, 1], type: uint64()),
    ),
    ('f32', _floatBits(32, [0x3fc00000, 0x7fc00001, 0], [true, true, false])),
    ('f16', _floatBits(16, [0x3c00, 0, 0], [true, false, false])),
    (
      'dec',
      array([
        DecimalValue(BigInt.parse('-12345678901234567890123'), 2),
        null,
        DecimalValue(1, 2),
      ], type: decimal128(38, 2)),
    ),
    ('bool', array([true, null, false], type: boolType())),
    ('null', array([null, null, null], type: nullType())),
    ('s', array(['héllo', null, ''], type: string())),
    ('ls', array(['x', null, null], type: largeString())),
    (
      'bin',
      array([
        Uint8List.fromList([0, 255]),
        null,
        Uint8List(0),
      ], type: binary()),
    ),
    ('d32', array([-1, 19000, null], type: date32())),
    ('d64', array([1, null, null], type: date64())),
    ('t32', array([1000, null, null], type: time32('ms'))),
    ('t64', array([86399999999999, null, null], type: time64('ns'))),
    ('ts', array([-5, null, 5], type: timestamp('us', tz: 'UTC'))),
    ('dur', array([42, null, null], type: duration('s'))),
    (
      'list',
      array([
        [1, null],
        null,
        <int>[],
      ], type: intList),
    ),
    (
      'llist',
      array([
        ['a'],
        null,
        null,
      ], type: large),
    ),
    (
      'fl',
      array([
        [1.0, -0.0],
        null,
        null,
      ], type: fixedList),
    ),
    (
      'st',
      array([
        {'a': 65535, 'b': null},
        null,
        {'a': null, 'b': true},
      ], type: structType),
    ),
    (
      'ext',
      array([
        Uint8List.fromList([1, 2, 3]),
        null,
        null,
      ], type: ext),
    ),
    ('dict', _dictionaryArray(dict, [1, null, 0], _words(['red', 'blue']))),
  ];
  final schema = Schema(
    [for (final (name, column) in columns) field(name, column.type)],
    metadata: {'origin': 'test'},
  );
  final batch = _batch(schema, [for (final (_, column) in columns) column]);
  // A sliced second batch exercises rebasing of every layout.
  final sliced = RecordBatch.fromArrays([
    for (final (_, column) in columns)
      concatArrays([column, column]).slice(1, 3),
  ], schema: schema);
  return (schema, [batch, sliced]);
}

/// Array equality that also matches NaN payloads bit for bit.
bool _same(Array a, Array b) {
  if (a.type is! FloatingType) return a.equals(b);
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].isValid != b[i].isValid || a[i].rawBits != b[i].rawBits) {
      return false;
    }
  }
  return true;
}

void _expectSameBatches(List<RecordBatch> actual, List<RecordBatch> expected) {
  expect(actual, hasLength(expected.length));
  for (var b = 0; b < expected.length; b++) {
    expect(actual[b].numRows, expected[b].numRows);
    for (var c = 0; c < expected[b].numColumns; c++) {
      final name = expected[b].schema.fields[c].name;
      expect(
        _same(actual[b].columns[c], expected[b].columns[c]),
        isTrue,
        reason:
            '$name: ${actual[b].columns[c].toDartList()} != '
            '${expected[b].columns[c].toDartList()}',
      );
      expect(actual[b].columns[c].offset, 0, reason: name);
    }
  }
}

int _indexOf(Uint8List haystack, Uint8List needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void main() {
  group('Arrow IPC dictionary protocol', () {
    final dict = dictionary(int8(), string());
    final ext = extension('example.dictionary', dict, metadata: 'v1');

    test('append-only dictionaries emit deltas with bounded merged size', () {
      final schema = Schema([field('d', dict)]);
      RecordBatch batch(List<String> values) => _batch(schema, [
        _dictionaryArray(dict, [values.length - 1], _words(values)),
      ]);
      final batches = [
        batch(['a']),
        batch(['a', 'b']),
      ];
      final bytes = _stream(schema, batches);
      final data = ByteData.sublistView(bytes);
      final dictionaryMessages = _messages(bytes)
          .where((m) => m.kind == 2)
          .toList();
      expect(dictionaryMessages.length, 2);
      expect(bytes[_slot(data, dictionaryMessages.last.header, 2)], 1);
      final read = _readStream(bytes);
      expect(read.first.columns.single.dictionary!.length, 1);
      expect(read.last.columns.single.dictionary!.length, 2);
      expect(
        () => _readStream(bytes, limits: const ipc.IpcLimits(maxRows: 1)),
        throwsFormatException,
      );
      final file = _file(schema, batches);
      expect(
        _readFile(file).last.columns.single.dictionary!
            .equals(_words(['a', 'b'])),
        isTrue,
      );
    });

    test('out-of-range dictionary indices are rejected by public reader', () {
      final schema = Schema([field('d', dict)]);
      final bytes = _stream(schema, [
        _batch(schema, [
          _dictionaryArray(dict, [0], _words(['red'])),
        ]),
      ]);
      final data = ByteData.sublistView(bytes);
      final batch = _messages(bytes).last;
      final buffers = _ref(data, _slot(data, batch.header, 2));
      final indicesOffset = _i64(data, buffers + 4 + 16);
      final body =
          batch.start + 8 + data.getInt32(batch.start + 4, Endian.little);
      bytes[body + indicesOffset] = 127;
      expect(() => _readStream(bytes), throwsFormatException);
    });

    test(
      'extension dictionary root and struct child preserve dictionaries',
      () {
        final structType = struct([field('child', ext)]);
        final dictionary = _words(['red']);
        final encoded = _dictionaryArray(dict, [0, null], dictionary);
        final root = Array.fromBuffers(
          ext,
          2,
          encoded.buffers(),
          dictionary: dictionary,
        );
        final validity = Uint8List.fromList([1]);
        final nested = Array.fromBuffers(
          structType,
          2,
          [Buffer(validity)],
          children: [root],
        );
        final schema = Schema([
          field('root', ext),
          field('nested', structType),
        ]);
        final batches = [
          _batch(schema, [root, nested]),
        ];
        for (final read in [
          _readStream(_stream(schema, batches)),
          _readFile(_file(schema, batches)),
        ]) {
          _expectSameBatches(read, batches);
          final columns = read.single.columns;
          expect(columns[0].dictionary!.equals(dictionary), isTrue);
          expect(
            columns[1].children.single.dictionary!.equals(dictionary),
            isTrue,
          );
        }
      },
    );

    test(
      'dictionary of list dictionary follows inner replacement snapshots',
      () {
        final list = ListType(field('item', dict));
        final outer = dictionary(int16(), list);
        final schema = Schema([field('outer', outer)]);
        RecordBatch batch(String word) {
          final inner = _dictionaryArray(dict, [0], _words([word]));
          final values = Array.fromBuffers(
            list,
            1,
            [
              null,
              Buffer(Uint8List.fromList([0, 0, 0, 0, 1, 0, 0, 0])),
            ],
            children: [inner],
          );
          return _batch(schema, [
            _dictionaryArray(outer, [0], values),
          ]);
        }

        final input = [batch('old'), batch('new')];
        final read = _readStream(_stream(schema, input));
        for (var i = 0; i < 2; i++) {
          final inner = read[i].columns.single.dictionary!.children.single;
          expect(
            inner.dictionary!.equals(
              input[i].columns.single.dictionary!.children.single.dictionary!,
            ),
            isTrue,
          );
        }
        _expectSameBatches(read, input);
        final file = _readFile(_file(schema, [input.first]));
        expect(
          file.single.columns.single.dictionary!.children.single.dictionary!
              .equals(_words(['old'])),
          isTrue,
        );
      },
    );

    Uint8List twoFields({bool incompatible = false}) {
      final second = incompatible
          ? dictionary(int16(), int32())
          : dictionary(int16(), string());
      final schema = Schema([field('a', dict), field('b', second)]);
      return _stream(schema, [
        _batch(schema, [
          _dictionaryArray(dict, [0], _words(['red'])),
          _dictionaryArray(second, [
            0,
          ], incompatible ? array([9], type: int32()) : _words(['red'])),
        ]),
      ]);
    }

    test('compatible fields share a negative dictionary wire id', () {
      final bytes = twoFields();
      final data = ByteData.sublistView(bytes);
      for (final at in _schemaDictionaryIdSlots(bytes)) {
        _putI64(data, at, -7);
      }
      final dictionaries = _messages(bytes).where((m) => m.kind == 2).toList();
      _putI64(data, _slot(data, dictionaries.first.header, 0), -7);
      final dropped = dictionaries.last;
      final shared = Uint8List.fromList([
        ...bytes.sublist(0, dropped.start),
        ...bytes.sublist(dropped.end),
      ]);
      final columns = _readStream(shared).single.columns;
      expect(columns[0].dictionary!.equals(_words(['red'])), isTrue);
      expect(columns[1].dictionary!.equals(_words(['red'])), isTrue);
    });

    test('incompatible shared dictionary types rejected', () {
      final bytes = twoFields(incompatible: true);
      final data = ByteData.sublistView(bytes);
      for (final at in _schemaDictionaryIdSlots(bytes)) {
        _putI64(data, at, -1);
      }
      expect(() => _readStream(bytes), throwsFormatException);
    });

    test('unknown ids, missing dictionaries and base-less deltas rejected', () {
      final original = twoFields();
      final dictionaries = _messages(original)
          .where((m) => m.kind == 2)
          .toList();
      final first = dictionaries.first;
      final unknown = Uint8List.fromList(original);
      final data = ByteData.sublistView(unknown);
      _putI64(data, _slot(data, first.header, 0), 999);
      expect(() => _readStream(unknown), throwsFormatException);
      final delta = Uint8List.fromList(original);
      delta[_slot(ByteData.sublistView(delta), first.header, 2)] = 1;
      expect(() => _readStream(delta), throwsFormatException);
      final missing = Uint8List.fromList([
        ...original.sublist(0, first.start),
        ...original.sublist(first.end),
      ]);
      expect(() => _readStream(missing), throwsFormatException);
    });

    test('dictionary count, value and body limits are enforced', () {
      final bytes = twoFields();
      for (final limits in [
        const ipc.IpcLimits(maxDictionaries: 1),
        const ipc.IpcLimits(maxValues: 1),
        const ipc.IpcLimits(maxMessageBytes: 1),
      ]) {
        expect(() => _readStream(bytes, limits: limits), throwsFormatException);
      }
      final schema = Schema([field('large', string())]);
      final batches = [
        _batch(schema, [
          array(['x' * 4096], type: string()),
        ]),
      ];
      const limits = ipc.IpcLimits(maxMessageBytes: 1024);
      expect(
        () => _readStream(_stream(schema, batches), limits: limits),
        throwsFormatException,
      );
      expect(
        () => _readFile(_file(schema, batches), limits: limits),
        throwsFormatException,
      );
    });

    test('stream emits dictionary replacement between batches', () {
      final type = dictionary(int32(), string());
      final schema = Schema([field('d', type)]);
      RecordBatch batch(String word) => _batch(schema, [
        _dictionaryArray(type, [0], _words([word])),
      ]);
      final batches = [batch('a'), batch('b')];
      final read = _readStream(_stream(schema, batches));
      expect(read[1].columns.single.dictionary!.toDartList(), ['b']);
      expect(() => _file(schema, batches), throwsUnsupportedError);
    });

    test('nested dictionaries roundtrip through file and stream', () {
      final type = ListType(field('item', dict));
      final schema = Schema([field('x', type)]);
      final dictionaryValues = _words(['red', 'blue']);
      final child = _dictionaryArray(dict, [1, null, 0], dictionaryValues);
      final offsets = ByteData(16)
        ..setInt32(4, 3, Endian.little)
        ..setInt32(8, 3, Endian.little)
        ..setInt32(12, 3, Endian.little);
      final column = Array.fromBuffers(
        type,
        3,
        [
          Buffer(Uint8List.fromList([5])),
          Buffer(offsets.buffer.asUint8List()),
        ],
        children: [child],
      );
      final batches = [
        _batch(schema, [column]),
      ];
      for (final read in [
        _readStream(_stream(schema, batches)),
        _readFile(_file(schema, batches)),
      ]) {
        _expectSameBatches(read, batches);
        expect(
          read.single.columns.single.children.single.dictionary!.equals(
            dictionaryValues,
          ),
          isTrue,
        );
      }
    });
  });

  group('Arrow IPC round trip', () {
    test('stream preserves all core types and rebases slices', () {
      final (schema, batches) = _sample();
      final bytes = _stream(schema, batches);
      expect(bytes.length % 8, 0);
      final reader = ipc.openStream(bytes);
      expect(reader.schema.equals(schema, checkMetadata: true), isTrue);
      _expectSameBatches(reader.toList(), batches);
    });

    test('file preserves all core types and carries ARROW1 magic', () {
      final (schema, batches) = _sample();
      final bytes = _file(schema, batches);
      expect(String.fromCharCodes(bytes.sublist(0, 6)), 'ARROW1');
      expect(String.fromCharCodes(bytes.sublist(bytes.length - 6)), 'ARROW1');
      final reader = ipc.openFile(bytes);
      expect(reader.schema.equals(schema, checkMetadata: true), isTrue);
      expect(reader.numRecordBatches, 2);
      _expectSameBatches(_readFile(bytes), batches);
      final table = reader.readAll();
      expect(table.numRows, 6);
      expect(table.schema.equals(schema, checkMetadata: true), isTrue);
    });

    test('empty table and zero-row batch', () {
      final schema = Schema([field('s', string())]);
      final table = ipc.openStream(_stream(schema, const [])).readAll();
      expect(table.schema, schema);
      expect(table.numRows, 0);
      final zero = _batch(schema, [array(<String>[], type: string())]);
      final reader = ipc.openFile(_file(schema, [zero]));
      expect(reader.getBatch(0).numRows, 0);
    });

    test('writeTable, write and close follow the PyArrow writer shape', () {
      final (schema, batches) = _sample();
      final table = Table.fromBatches(batches);
      final writer = ipc.newStream(schema)
        ..writeTable(table, maxChunkSize: 2)
        ..write(batches.first);
      final bytes = writer.close();
      expect(writer.close(), same(bytes));
      expect(() => writer.writeBatch(batches.first), throwsStateError);
      final read = ipc.openStream(bytes).readAll();
      expect(read.numRows, 9);
      expect(read.columns.first.numChunks, 5);
      expect(() => ipc.newFile(schema).write(1), throwsArgumentError);
      final other = Schema([field('z', nullType())]);
      expect(
        () => ipc.newStream(other).writeBatch(batches.first),
        throwsArgumentError,
      );
      final stream = ipc.openStream(bytes);
      expect(stream.readNextBatch()!.numRows, 2);
      expect(stream.readAll().numRows, 7);
      expect(stream.readNextBatch(), isNull);
    });
  });

  group('Arrow IPC rejects', () {
    test('nonstandard 128-bit integers', () {
      for (final type in [bindingInt128(), bindingUint128()]) {
        final schema = Schema([field('x', type)]);
        expect(() => ipc.newStream(schema), throwsUnsupportedError);
        expect(() => ipc.newFile(schema), throwsUnsupportedError);
      }
    });
  });

  group('Arrow IPC malformed input', () {
    late Uint8List stream;
    late Uint8List file;
    setUp(() {
      final (schema, batches) = _sample();
      stream = _stream(schema, batches);
      file = _file(schema, batches);
    });

    final rejected = anyOf(throwsFormatException, throwsUnsupportedError);

    test('empty and garbage input', () {
      expect(() => ipc.openStream(Uint8List(0)), throwsFormatException);
      expect(() => ipc.openFile(Uint8List(3)), throwsFormatException);
      expect(
        () => ipc.openStream(
          Uint8List.fromList([255, 255, 255, 255, 255, 255, 255, 127]),
        ),
        throwsFormatException,
      );
    });

    test('every truncation of a stream fails cleanly', () {
      for (var n = 1; n < stream.length - 8; n += 7) {
        final cut = Uint8List.sublistView(stream, 0, n);
        expect(() => _readStream(cut), rejected, reason: 'length $n');
      }
    });

    test('every truncation of a file fails cleanly', () {
      for (var n = 0; n < file.length; n++) {
        final cut = Uint8List.sublistView(file, 0, n);
        expect(() => _readFile(cut), rejected, reason: 'length $n');
      }
    });

    test('file block lengths and footer boundaries cannot be forged', () {
      final data = ByteData.sublistView(file);
      final footerStart =
          file.length - 10 - data.getInt32(file.length - 10, Endian.little);
      final footer = _ref(data, footerStart);
      final vector = _ref(data, _slot(data, footer, 3));
      final block = vector + 4;
      for (final delta in [-8, 8]) {
        final copy = Uint8List.fromList(file);
        ByteData.sublistView(copy).setInt32(
          block + 8,
          data.getInt32(block + 8, Endian.little) + delta,
          Endian.little,
        );
        expect(() => _readFile(copy), throwsFormatException);
      }
      final outside = Uint8List.fromList(file);
      _putI64(ByteData.sublistView(outside), block, footerStart);
      expect(() => _readFile(outside), throwsFormatException);
      final wrongKind = Uint8List.fromList(file);
      final dictionaryVector = _ref(data, _slot(data, footer, 2));
      wrongKind.setRange(block, block + 24, file, dictionaryVector + 4);
      expect(() => _readFile(wrongKind), throwsFormatException);
    });

    test('byte corruption never escapes as an uncaught crash', () {
      for (var i = 0; i < stream.length; i += 3) {
        final copy = Uint8List.fromList(stream);
        copy[i] ^= 0xa5;
        try {
          _readStream(copy);
        } on FormatException {
          // expected
        } on UnsupportedError {
          // expected
        }
      }
    });

    test('Null batch claiming a billion rows is rejected', () {
      final schema = Schema([field('n', nullType())]);
      final bytes = _stream(schema, [
        _batch(schema, [
          array([null], type: nullType()),
        ]),
      ]);
      // FieldNode struct {length: 1, null_count: 1}, patched to 2^30 rows.
      final node = Uint8List(16)
        ..[0] = 1
        ..[8] = 1;
      final at = _indexOf(bytes, node);
      expect(at, greaterThan(0));
      final evil = Uint8List.fromList(bytes);
      ByteData.sublistView(evil)
        ..setUint32(at, 1 << 30, Endian.little)
        ..setUint32(at + 8, 1 << 30, Endian.little);
      expect(() => _readStream(evil), throwsFormatException);
      expect(
        () => _readStream(
          evil,
          limits: const ipc.IpcLimits(maxRows: 1099511627776),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('maxValues'),
          ),
        ),
      );
    });

    test('limits bound depth, rows and batches', () {
      for (final limits in const [
        ipc.IpcLimits(maxBatches: 1),
        ipc.IpcLimits(maxDepth: 1),
        ipc.IpcLimits(maxRows: 2),
      ]) {
        expect(
          () => _readStream(stream, limits: limits),
          throwsFormatException,
        );
      }
    });
  });
}
