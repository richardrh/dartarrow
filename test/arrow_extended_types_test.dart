import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart' as pa;
import 'package:dartaframes_arrow/json.dart';
import 'package:test/test.dart';

pa.Array roundTrip(pa.Array array) {
  const codec = OwnedBatchJsonCodec();
  final batch = pa.RecordBatch.fromArrays([array], names: ['c']);
  return codec.decode(codec.encode(batch)).column(0);
}

pa.Buffer bytes(List<int> values) => pa.Buffer(Uint8List.fromList(values));

pa.Buffer int32s(List<int> values) {
  final data = ByteData(values.length * 4);
  for (var i = 0; i < values.length; i++) {
    data.setInt32(i * 4, values[i], Endian.little);
  }
  return pa.Buffer(data.buffer.asUint8List());
}

final str = pa.field('v', pa.string());

void main() {
  group('datatype JSON', () {
    final types = <pa.DataType>[
      pa.stringView(),
      pa.binaryView(),
      pa.binary(4),
      pa.binary(0),
      pa.largeList(str),
      pa.listView(str),
      pa.largeListView(str),
      pa.decimal32(9, 2),
      pa.decimal64(18, -3),
      pa.decimal256(76, 80),
      pa.mapType(pa.string(), pa.int32(), keysSorted: true),
      pa.denseUnion([pa.field('i', pa.int32()), str], typeCodes: [5, 9]),
      pa.sparseUnion([pa.field('i', pa.int32()), str]),
      for (final unit in pa.IntervalUnit.values) pa.IntervalType(unit),
      pa.runEndEncoded(pa.int16(), pa.string()),
    ];
    for (final type in types) {
      test('$type roundtrips', () {
        expect(pa.DataType.fromJson(type.toJson()), type);
        expect(pa.DataType.fromJson(type.toJson()).hashCode, type.hashCode);
      });
    }

    test('128-bit decimal keeps the original JSON shape', () {
      expect(pa.decimal128(38, 4).toJson(), {
        'kind': 'decimal',
        'precision': 38,
        'scale': 4,
      });
    });

    test('variants are distinct types', () {
      expect(pa.largeList(str), isNot(pa.listType(str)));
      expect(pa.listView(str), isNot(pa.largeListView(str)));
      expect(pa.stringView(), isNot(pa.string()));
      expect(pa.decimal64(9, 2), isNot(pa.decimal32(9, 2)));
      expect(pa.sparseUnion([str]), isNot(pa.denseUnion([str])));
    });

    test('factories follow PyArrow field conventions', () {
      final map = pa.mapType(pa.string(), pa.int32());
      expect(map.keyField.name, 'key');
      expect(map.keyField.nullable, isFalse);
      expect(map.valueField.name, 'value');
      expect(map.entriesField.name, 'entries');
      expect(map.entriesField.nullable, isFalse);
      expect(map.keyType, pa.string());
      expect(map.itemType, pa.int32());
      final ree = pa.runEndEncoded(pa.int32(), pa.float64());
      expect(ree.runEndsField.name, 'run_ends');
      expect(ree.valuesField.name, 'values');
      expect(pa.binary(), isA<pa.BinaryType>());
      expect((pa.binary(3) as pa.FixedSizeBinaryType).byteWidth, 3);
      expect(pa.monthDayNanoInterval().unit, pa.IntervalUnit.monthDayNano);
    });

    test('accepts PyArrow descriptor spellings', () {
      expect(
        pa.DataType.fromJson({
          'kind': 'map',
          'key': pa.field('key', pa.string(), nullable: false).toJson(),
          'item': pa.field('value', pa.int32()).toJson(),
          'keysSorted': false,
        }),
        pa.mapType(pa.string(), pa.int32()),
      );
      expect(
        pa.DataType.fromJson({
          'kind': 'denseUnion',
          'typeCodes': [2],
          'fields': [str.toJson()],
        }),
        pa.denseUnion([str], typeCodes: [2]),
      );
      expect(
        pa.DataType.fromJson({
          'kind': 'runEndEncoded',
          'runEndType': {'kind': 'int16'},
          'valueType': {'kind': 'string'},
        }),
        pa.runEndEncoded(pa.int16(), pa.string()),
      );
      expect(
        pa.DataType.fromJson({'kind': 'monthDayNanoInterval'}),
        pa.monthDayNanoInterval(),
      );
    });

    test('rejects malformed definitions', () {
      expect(() => pa.decimal32(10, 0), throwsRangeError);
      expect(() => pa.DecimalType(5, 0, bitWidth: 16), throwsArgumentError);
      expect(() => pa.binary(-2), throwsRangeError);
      expect(
        () => pa.ListType(str, offsetWidth: pa.OffsetWidth.view),
        throwsArgumentError,
      );
      expect(
        () => pa.MapType(pa.field('k', pa.int32()), pa.field('v', pa.int32())),
        throwsArgumentError,
      );
      expect(
        () => pa.sparseUnion([str, str], typeCodes: [1, 1]),
        throwsArgumentError,
      );
      expect(() => pa.sparseUnion([str], typeCodes: [128]), throwsRangeError);
      expect(
        () => pa.runEndEncoded(pa.int8(), pa.string()),
        throwsArgumentError,
      );
      expect(
        () => pa.RunEndEncodedType(pa.field('r', pa.int32()), str),
        throwsArgumentError,
      );
      expect(
        () => pa.DataType.fromJson({
          'kind': 'union',
          'mode': 'dense',
          'typeIds': [0, 0],
          'fields': [str.toJson(), str.toJson()],
        }),
        throwsFormatException,
      );
      expect(
        () => pa.DataType.fromJson({'kind': 'interval', 'unit': 'weeks'}),
        throwsFormatException,
      );
    });

    test('map entries metadata is preserved', () {
      final map = pa.MapType(
        pa.field('k', pa.int32(), nullable: false),
        pa.field('v', pa.int32()),
        entriesMetadata: {'x': 'y'},
      );
      expect(map.entriesField.metadata!['x'], 'y'.codeUnits);
      final decoded = pa.DataType.fromJson(map.toJson()) as pa.MapType;
      expect(decoded.equals(map, checkMetadata: true), isTrue);
      expect(
        pa
            .mapType(pa.int32(), pa.int32())
            .toJson()
            .containsKey('entriesMetadata'),
        isFalse,
      );
    });
  });

  group('arrays', () {
    final cases = <String, pa.Array>{
      'fixedSizeBinary': pa.array([
        Uint8List.fromList([1, 2]),
        null,
        'ab',
      ], type: pa.binary(2)),
      'stringView': pa.array([
        'short',
        null,
        'a long string beyond twelve bytes',
        '',
      ], type: pa.stringView()),
      'binaryView': pa.array([
        Uint8List(13),
        null,
        Uint8List.fromList([7]),
      ], type: pa.binaryView()),
      'largeList': pa.array([
        [1, null],
        null,
        <int>[],
        [4],
      ], type: pa.largeList(pa.int32())),
      'listView': pa.array([
        ['x', null],
        null,
        ['y'],
      ], type: pa.listView(str)),
      'largeListView': pa.array([
        [1.5],
        null,
        <double>[],
      ], type: pa.largeListView(pa.float64())),
      'decimal32': pa.array([
        pa.DecimalValue(BigInt.from(-123456789), 2),
        null,
      ], type: pa.decimal32(9, 2)),
      'decimal64': pa.array([
        pa.DecimalValue(BigInt.parse('9' * 18), 0),
        null,
      ], type: pa.decimal64(18)),
      'decimal256': pa.array([
        pa.DecimalValue(BigInt.parse('-${'9' * 76}'), -5),
        null,
      ], type: pa.decimal256(76, -5)),
      'map': pa.array([
        [('z', 1), ('a', null), ('z', 2)],
        null,
        {'k': 3},
        <String, int>{},
      ], type: pa.mapType(pa.string(), pa.int32())),
      'yearMonth': pa.array([
        pa.IntervalValue.yearMonth(-14),
        null,
      ], type: const pa.IntervalType(pa.IntervalUnit.yearMonth)),
      'dayTime': pa.array([
        pa.IntervalValue.dayTime(3, -500),
        null,
      ], type: const pa.IntervalType(pa.IntervalUnit.dayTime)),
      'monthDayNano': pa.array([
        (1, 2, BigInt.parse('-${'9' * 18}')),
        null,
        [0, -1, 5],
      ], type: pa.monthDayNanoInterval()),
      'runEndEncoded': pa.array([
        'a',
        'a',
        null,
        'b',
        'b',
      ], type: pa.runEndEncoded(pa.int16(), pa.string())),
      'sparseUnion': pa.Array.fromSparseUnion(
        pa.array([3, 7, 7], type: pa.int8()),
        [
          pa.array([1, null, 3], type: pa.int32()),
          pa.array(['a', 'b', null]),
        ],
        fieldNames: ['i', 's'],
        typeCodes: [3, 7],
      ),
      'denseUnion': pa.Array.fromDenseUnion(
        pa.array([0, 1, 0], type: pa.int8()),
        pa.array([0, 0, 1], type: pa.int32()),
        [
          pa.array([10, 20], type: pa.int64()),
          pa.array([null], type: pa.string()),
        ],
      ),
    };

    for (final MapEntry(key: name, value: array) in cases.entries) {
      test('$name validates, slices, concatenates and roundtrips', () {
        array.validate(full: true);
        final values = array.toDartList();
        for (var start = 0; start <= array.length; start++) {
          final sliced = array.slice(start);
          expect(sliced.toDartList(), values.sublist(start));
          sliced.validate(full: true);
        }
        final joined = pa.concatArrays([array.slice(1), array]);
        expect(joined.toDartList(), [...values.skip(1), ...values]);
        joined.validate(full: true);
        expect(joined.slice(array.length - 1).equals(array), isTrue);
        final rebuilt = pa.array(array.scalars.toList(), type: array.type);
        expect(rebuilt.equals(array), isTrue);
        final decoded = roundTrip(array);
        expect(decoded.type, array.type);
        expect(decoded.equals(array), isTrue);
        for (var i = 0; i < array.length; i++) {
          expect(array[i].equals(decoded[i]), isTrue);
          expect(array[i].hashCode, decoded[i].hashCode);
        }
      });
    }

    test('scalar values follow PyArrow conversions', () {
      expect(cases['fixedSizeBinary']![2].value, 'ab'.codeUnits);
      expect(
        cases['stringView']![2].value,
        'a long string beyond twelve bytes',
      );
      expect(cases['largeList']![0].value, [1, null]);
      expect(cases['map']![0].value, [('z', 1), ('a', null), ('z', 2)]);
      expect(cases['map']![2].asDart(), [('k', 3)]);
      expect(
        cases['monthDayNano']![2].value,
        pa.IntervalValue.monthDayNano(0, -1, 5),
      );
      expect(cases['runEndEncoded']!.toDartList(), ['a', 'a', null, 'b', 'b']);
      expect(cases['sparseUnion']!.toDartList(), [1, 'b', null]);
      expect(cases['denseUnion']!.toDartList(), [10, null, 20]);
    });

    test('unions and run-end encoding expose logical validity', () {
      final union = cases['sparseUnion']!;
      expect(union.nullCount, 0);
      expect(union[2].isValid, isFalse);
      expect(union.isNull().toDartList(), [false, false, true]);
      final ree = cases['runEndEncoded']!;
      expect(ree.nullCount, 0);
      expect(ree.isValid().toDartList(), [true, true, false, true, true]);
      expect(ree.children[0].toDartList(), [2, 3, 5]);
      expect(ree.children[1].toDartList(), ['a', null, 'b']);
    });

    test('decimal inference widens to decimal256 beyond 38 digits', () {
      final wide = pa.array([pa.DecimalValue(BigInt.parse('1' * 40), 0)]);
      expect(wide.type, pa.decimal256(40));
    });

    test('rejects invalid values', () {
      expect(
        () => pa.array([Uint8List(1)], type: pa.binary(2)),
        throwsA(isA<pa.ArrowInvalid>()),
      );
      expect(
        () => pa.array([
          pa.DecimalValue(BigInt.parse('9' * 10), 0),
        ], type: pa.decimal32(9)),
        throwsA(isA<pa.ArrowInvalid>()),
      );
      expect(
        () => pa.array([1], type: pa.sparseUnion([str])),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => pa.array([
          pa.IntervalValue.yearMonth(1),
        ], type: const pa.IntervalType(pa.IntervalUnit.dayTime)),
        throwsA(isA<pa.ArrowInvalid>()),
      );
      expect(
        () => pa.array([
          [(null, 1)],
        ], type: pa.mapType(pa.string(), pa.int32())),
        throwsA(isA<pa.ArrowInvalid>()),
      );
      expect(() => pa.IntervalValue.yearMonth(1 << 31), throwsRangeError);
    });

    test('codec rejects null map keys and undeclared union ids', () {
      const codec = OwnedBatchJsonCodec();
      final map = pa.RecordBatch.fromArrays([cases['map']!], names: ['m']);
      final json = codec.toJson(map);
      final column = (json['columns']! as List).single as Map;
      (((column['values'] as List).first as List).first as Map)['key'] = null;
      expect(() => codec.fromJson(json), throwsFormatException);

      final union = pa.RecordBatch.fromArrays(
        [cases['sparseUnion']!],
        names: ['u'],
      );
      final ujson = codec.toJson(union);
      final ucol = (ujson['columns']! as List).single as Map;
      ((ucol['values'] as List).first as Map)['typeId'] = 4;
      expect(() => codec.fromJson(ujson), throwsFormatException);
    });
  });

  group('physical validation', () {
    test('rejects malformed extended buffers', () {
      final union = pa.sparseUnion([str]);
      expect(
        () => pa.Array.fromBuffers(
          union,
          1,
          [
            bytes([1]),
            bytes([0]),
          ],
          children: [
            pa.array(['a']),
          ],
        ),
        throwsArgumentError,
        reason: 'unions have no validity bitmap',
      );
      expect(
        () => pa.Array.fromBuffers(
          union,
          1,
          [
            null,
            bytes([5]),
          ],
          children: [
            pa.array(['a']),
          ],
        ),
        throwsArgumentError,
        reason: 'undeclared type id',
      );
      expect(
        () => pa.Array.fromBuffers(
          pa.denseUnion([str]),
          1,
          [
            null,
            bytes([0]),
            int32s([3]),
          ],
          children: [
            pa.array(['a']),
          ],
        ),
        throwsArgumentError,
        reason: 'dense offset out of bounds',
      );
      expect(
        () => pa.Array.fromRunEnds(
          pa.array([2, 2], type: pa.int32()),
          pa.array([1, 2]),
        ),
        throwsArgumentError,
      );
      expect(
        () => pa.Array.fromBuffers(
          pa.runEndEncoded(pa.int32(), pa.int64()),
          5,
          [null],
          children: [
            pa.array([2], type: pa.int32()),
            pa.array([1]),
          ],
        ),
        throwsArgumentError,
        reason: 'run ends must cover the length',
      );
      final views = Uint8List(16);
      ByteData.sublistView(views)
        ..setInt32(0, 20, Endian.little)
        ..setInt32(8, 0, Endian.little)
        ..setInt32(12, 0, Endian.little);
      expect(
        () => pa.Array.fromBuffers(pa.stringView(), 1, [
          null,
          pa.Buffer(views),
          bytes([1, 2]),
        ]),
        throwsArgumentError,
        reason: 'view beyond its data buffer',
      );
      expect(
        () => pa.Array.fromBuffers(
          pa.listView(pa.int32()),
          1,
          [
            null,
            int32s([0]),
            int32s([4]),
          ],
          children: [
            pa.array([1], type: pa.int32()),
          ],
        ),
        throwsArgumentError,
        reason: 'list view beyond its child',
      );
      expect(
        () => pa.Array.fromBuffers(pa.binary(4), 2, [
          null,
          bytes([1, 2, 3]),
        ]),
        throwsArgumentError,
      );
    });

    test('views reference variadic data buffers', () {
      final views = Uint8List(32);
      final data = ByteData.sublistView(views);
      data.setInt32(0, 2, Endian.little);
      views.setRange(4, 6, 'hi'.codeUnits);
      data.setInt32(16, 13, Endian.little);
      views.setRange(20, 24, 'abcd'.codeUnits);
      data.setInt32(24, 1, Endian.little);
      data.setInt32(28, 2, Endian.little);
      final array = pa.Array.fromBuffers(pa.stringView(), 2, [
        null,
        pa.Buffer(views),
        bytes([]),
        pa.Buffer(Uint8List.fromList('..abcdefghijklm'.codeUnits)),
      ]);
      expect(array.toDartList(), ['hi', 'abcdefghijklm']);
      expect(array.buffers(), hasLength(4));
    });

    test('dense union slices keep child storage', () {
      final dense = pa.Array.fromDenseUnion(
        pa.array([0, 1, 0, 1], type: pa.int8()),
        pa.array([0, 0, 1, 1], type: pa.int32()),
        [
          pa.array([1, 2]),
          pa.array(['a', 'b']),
        ],
      );
      expect(dense.slice(1, 2).toDartList(), ['a', 2]);
      expect(dense.slice(2).equals(dense.slice(2)), isTrue);
      expect(dense.slice(0, 2).equals(dense.slice(2)), isFalse);
    });
  });
}
