import 'dart:convert';
import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart' as pa;
import 'package:dartaframes_arrow/json.dart';
import 'package:test/test.dart';

pa.Array halfBits(List<int> bits) {
  final bytes = ByteData(bits.length * 2);
  for (var i = 0; i < bits.length; i++) {
    bytes.setUint16(i * 2, bits[i], Endian.little);
  }
  return pa.Array.fromBuffers(pa.float16(), bits.length, [
    null,
    pa.Buffer(bytes.buffer.asUint8List()),
  ]);
}

void main() {
  group('datatypes', () {
    test('JSON round-trips every logical family', () {
      final types = <pa.DataType>[
        pa.nullType(),
        pa.boolType(),
        for (final width in [8, 16, 32, 64, 128]) ...[
          pa.IntegerType(width),
          pa.IntegerType(width, signed: false),
        ],
        for (final width in [16, 32, 64]) pa.FloatingType(width),
        pa.decimal128(38, 9),
        pa.decimal128(3, 4),
        pa.decimal128(3, -4),
        pa.string(),
        pa.largeString(),
        pa.binary(),
        pa.largeBinary(),
        pa.date32(),
        pa.date64(),
        pa.timestamp('ns', tz: 'UTC'),
        pa.timestamp('us'),
        pa.timestamp('ms'),
        pa.duration('ns'),
        pa.time64('us'),
        pa.listType(pa.int32()),
        pa.listType(pa.float32(), listSize: 3),
        pa.struct([
          pa.Field('x', pa.boolType(), nullable: false),
          pa.Field('y', pa.string()),
        ]),
        pa.dictionary(pa.uint16(), pa.string(), ordered: true),
        pa.extension('vendor.point', pa.binary(), metadata: '{"version":1}'),
      ];
      for (final type in types) {
        expect(
          pa.DataType.fromJson(
            (jsonDecode(jsonEncode(type.toJson())) as Map)
                .cast<String, Object?>(),
          ),
          type,
        );
      }
    });

    test(
      'validates datatype parameters without restricting scale to precision',
      () {
        expect(() => pa.IntegerType(24), throwsArgumentError);
        expect(() => pa.FloatingType(128), throwsArgumentError);
        expect(() => pa.decimal128(0), throwsRangeError);
        expect(() => pa.decimal128(39), throwsRangeError);
        expect(() => pa.decimal128(3, 2147483648), throwsRangeError);
        expect(pa.decimal128(3, 4).scale, 4);
        expect(
          () => pa.FixedSizeListType(pa.Field('x', pa.nullType()), -1),
          throwsRangeError,
        );
        expect(
          () => pa.dictionary(pa.float32(), pa.string()),
          throwsArgumentError,
        );
      },
    );

    test('strictly validates descriptor units and booleans', () {
      expect(
        () => pa.DataType.fromJson({'kind': 'date', 'unit': 'seconds'}),
        throwsFormatException,
      );
      expect(
        () => pa.Field.fromJson({
          'name': 'x',
          'dtype': {'kind': 'boolean'},
          'nullable': 'yes',
        }),
        throwsFormatException,
      );
      expect(
        () => pa.DataType.fromJson({
          'kind': 'dictionary',
          'indexType': {'kind': 'int8'},
          'valueType': {'kind': 'string'},
          'ordered': 1,
        }),
        throwsFormatException,
      );
    });
  });

  group('native arrays and scalars', () {
    test('validates signed, unsigned, 128-bit and uint64 boundaries', () {
      final minimum = -(BigInt.one << 127);
      final maximum = (BigInt.one << 127) - BigInt.one;
      expect(
        pa.array([minimum, maximum], type: pa.bindingInt128()).toDartList(),
        [minimum, maximum],
      );
      expect(
        () => pa.array([minimum - BigInt.one], type: pa.bindingInt128()),
        throwsArgumentError,
      );
      final unsignedMaximum = BigInt.parse('18446744073709551615');
      expect(
        pa.scalar(unsignedMaximum, type: pa.uint64()).asDart(),
        unsignedMaximum,
      );
      expect(() => pa.array([-1], type: pa.uint64()), throwsArgumentError);
      expect(pa.array([-128, 127], type: pa.int8()).toDartList(), [-128, 127]);
      expect(() => pa.array([128], type: pa.int8()), throwsArgumentError);
    });

    test('preserves Float16 payloads and Float64 encodings', () {
      final half = halfBits([0x7e01, 0x8000]);
      expect(half[0].rawBits, BigInt.from(0x7e01));
      expect((half[0].asDart() as double).isNaN, isTrue);
      expect(half[0].isValid, isTrue);
      expect(half[1].rawBits, BigInt.from(0x8000));
      expect(
        pa.scalar(double.negativeInfinity).rawBits,
        BigInt.parse('fff0000000000000', radix: 16),
      );
      expect(pa.scalar(-0.0).rawBits, BigInt.one << 63);
    });

    test('validates exact decimals and temporal range', () {
      final decimal = pa.DecimalValue(-99999, 2);
      expect(pa.scalar(decimal, type: pa.decimal128(5, 2)).asDart(), decimal);
      expect(
        () => pa.array([pa.DecimalValue(100000, 2)], type: pa.decimal128(5, 2)),
        throwsArgumentError,
      );
      final tiny = pa.DecimalValue(123, 4);
      expect(pa.scalar(tiny, type: pa.decimal128(3, 4)).asDart(), tiny);
      final counter = BigInt.parse('9223372036854775807');
      final temporal = pa.TemporalValue(
        counter,
        pa.TimeUnit.nanosecond,
        kind: 'timestamp',
      );
      expect(pa.scalar(temporal, type: pa.timestamp('ns')).asDart(), temporal);
      expect(
        () => pa.array([BigInt.one << 63], type: pa.time64('ns')),
        throwsArgumentError,
      );
    });

    test(
      'preserves nested nullability declarations and validates fixed width',
      () {
        final fixed = pa.listType(
          pa.Field('item', pa.int8(), nullable: false),
          listSize: 2,
        );
        expect(
          pa.array([
            [1, 2],
          ], type: fixed).toDartList(),
          [
            [1, 2],
          ],
        );
        expect(
          () => pa.array([
            [1],
          ], type: fixed),
          throwsArgumentError,
        );
        final nullableValues = pa.array([
          [1, null],
        ], type: fixed);
        expect(nullableValues.toDartList(), [
          [1, null],
        ]);
        nullableValues.validate(full: true);
        final type = pa.struct([
          pa.Field('a', pa.boolType(), nullable: false),
          pa.Field('b', pa.listType(pa.string())),
        ]);
        final nested = pa.array([
          {
            'b': ['x', null],
            'a': true,
          },
          null,
        ], type: type);
        expect(nested.toDartList(), [
          {
            'a': true,
            'b': ['x', null],
          },
          null,
        ]);
        expect(nested[0].isValid, isTrue);
        expect(nested[1].isValid, isFalse);
        final nullableStruct = pa.array([
          {
            'a': null,
            'b': ['x'],
          },
        ], type: type);
        expect(nullableStruct.toDartList(), [
          {
            'a': null,
            'b': ['x'],
          },
        ]);
        nullableStruct.validate(full: true);
      },
    );

    test('mask controls nulls and validates its length', () {
      final values = pa.array([true, false], mask: [false, true]);
      expect(values.type, pa.boolType());
      expect(values.toDartList(), [true, null]);
      expect(values.nullCount, 1);
      expect(values[1].isValid, isFalse);
      expect(() => pa.array([true], mask: [false, true]), throwsArgumentError);
      expect(pa.array([null, null]).type, pa.nullType());
    });
  });

  group('schema and record batches', () {
    test('schema metadata is copied and JSON round-trips losslessly', () {
      final source = {'source': 'test'};
      final schema = pa.Schema([
        pa.Field('id', pa.int64(), nullable: false, metadata: source),
      ], metadata: source);
      source['source'] = 'changed';
      expect(
        schema.equals(
          pa.Schema(
            [
              pa.Field(
                'id',
                pa.int64(),
                nullable: false,
                metadata: {'source': 'test'},
              ),
            ],
            metadata: {'source': 'test'},
          ),
          checkMetadata: true,
        ),
        isTrue,
      );
      final decoded = pa.Schema.fromJson(schema.toJson());
      expect(decoded.equals(schema, checkMetadata: true), isTrue);
    });

    test('metadata equality is independent of insertion order', () {
      final first = pa.Schema([], metadata: {'a': '1', 'b': '2'});
      final second = pa.Schema([], metadata: {'b': '2', 'a': '1'});
      expect(first.equals(second, checkMetadata: true), isTrue);
      expect(first.hashCode, second.hashCode);
      expect({first}, contains(second));
    });

    test('preserves explicit row counts for batches without columns', () {
      final batch = pa.RecordBatch.fromDartList([
        {},
        {},
        {},
      ], schema: pa.Schema([]));
      const codec = OwnedBatchJsonCodec();
      final decoded = codec.decode(codec.encode(batch));
      expect(decoded.numRows, 3);
      expect(decoded.numColumns, 0);
    });

    test('constructs typed columns and validates equal column lengths', () {
      final schema = pa.Schema([
        pa.Field('a', pa.boolType(), nullable: false),
        pa.Field('b', pa.string()),
      ]);
      final batch = pa.RecordBatch.fromArrays([
        pa.array([true]),
        pa.array(['x']),
      ], schema: schema);
      expect(batch.numRows, 1);
      expect(batch.numColumns, 2);
      expect(batch.schema, schema);
      expect(
        () => pa.RecordBatch.fromArrays([
          pa.array([true]),
          pa.array([], type: pa.string()),
        ], schema: schema),
        throwsArgumentError,
      );
    });
  });

  group('dictionary, extension, and owned codec', () {
    test('dictionary checks integer indices and bounds', () {
      final dictionary = pa.array(['red', 'blue']);
      final values = pa.Array.fromDictionary(
        pa.array([1, null], type: pa.uint8()),
        dictionary,
      );
      expect(values.toDartList(), ['blue', null]);
      final entry = values[0] as pa.DictionaryScalar;
      expect(entry.index.asDart(), 1);
      expect(entry.value.asDart(), 'blue');
      expect(
        () => pa.Array.fromDictionary(pa.array([2]), dictionary),
        throwsRangeError,
      );
      expect(
        () => pa.Array.fromDictionary(pa.array([1.0]), dictionary),
        throwsArgumentError,
      );
    });

    test(
      'round-trips nested values, BigInt, dictionary, and extension losslessly',
      () {
        final extensionType = pa.extension(
          'vendor.uuid',
          pa.binary(),
          metadata: 'v1',
        );
        final nestedType = pa.listType(
          pa.struct([
            pa.Field('n', pa.bindingInt128(), nullable: false),
            pa.Field('s', pa.string()),
          ]),
        );
        final dictionary = pa.array(['a', 'b']);
        final binary = pa.array([
          Uint8List.fromList([0, 1, 255]),
          null,
        ], type: pa.binary());
        final columns = [
          pa.array([
            [
              {'n': BigInt.one << 100, 's': 'hello'},
              null,
            ],
            null,
          ], type: nestedType),
          pa.Array.fromDictionary(
            pa.array([1, 0], type: pa.uint16()),
            dictionary,
          ),
          pa.Array.fromBuffers(extensionType, 2, binary.buffers()),
          halfBits([0x8000, 0x7e01]),
          pa.array([-42, 42], type: pa.timestamp('ns', tz: 'UTC')),
          pa.array([
            pa.DecimalValue(12340000, 4),
            pa.DecimalValue(-1, 4),
          ], type: pa.decimal128(38, 4)),
        ];
        final schema = pa.Schema(
          [
            for (final entry in columns.indexed)
              pa.Field(
                [
                  'nested',
                  'category',
                  'extension',
                  'half',
                  'when',
                  'amount',
                ][entry.$1],
                entry.$2.type,
              ),
          ],
          metadata: {'owner': 'dart'},
        );
        final batch = pa.RecordBatch.fromArrays(columns, schema: schema);
        const codec = OwnedBatchJsonCodec();
        final wire = codec.encode(batch);
        expect(wire, contains('1267650600228229401496703205376'));
        final decoded = codec.decode(wire);
        expect(decoded.schema.equals(schema, checkMetadata: true), isTrue);
        expect(decoded.numRows, 2);
        for (final index in [0, 1, 2, 4, 5]) {
          expect(
            decoded.columns[index].toDartList(),
            columns[index].toDartList(),
          );
        }
        expect(
          decoded.columns[1].dictionary!.toDartList(),
          dictionary.toDartList(),
        );
        expect(decoded.columns[3][0].rawBits, BigInt.from(0x8000));
        expect(decoded.columns[3][1].rawBits, BigInt.from(0x7e01));
      },
    );

    test('codec rejects malformed validity and declared length', () {
      const codec = OwnedBatchJsonCodec();
      expect(
        () => codec.fromJson({
          'schema': {
            'fields': [
              {
                'name': 'x',
                'dtype': {'kind': 'boolean'},
                'nullable': true,
              },
            ],
          },
          'length': 2,
          'columns': [
            {
              'name': 'x',
              'dtype': {'kind': 'boolean'},
              'validity': [true],
              'values': [true],
            },
          ],
        }),
        throwsFormatException,
      );
    });

    test('malformed nested and metadata shapes throw FormatException', () {
      expect(
        () => pa.Schema.fromJson({
          'fields': [false],
        }),
        throwsFormatException,
      );
      expect(
        () => pa.Schema.fromJson({
          'fields': [],
          'metadata': {'valid': 1},
        }),
        throwsFormatException,
      );
      expect(
        () => pa.DataType.fromJson({
          'kind': 'struct',
          'fields': ['not a field'],
        }),
        throwsFormatException,
      );
    });

    test('public decoding enforces depth and collection limits', () {
      const depthLimited = OwnedBatchJsonCodec(maxNestingDepth: 4);
      expect(
        () => depthLimited.fromJson({
          'schema': {'fields': []},
          'columns': [],
          'extra': [
            [
              [
                [0],
              ],
            ],
          ],
        }),
        throwsFormatException,
      );
      const sizeLimited = OwnedBatchJsonCodec(maxCollectionSize: 5);
      expect(
        () => sizeLimited.fromJson({
          'schema': {'fields': []},
          'columns': [],
          'extra': [0, 1, 2, 3, 4, 5],
        }),
        throwsFormatException,
      );
    });
  });
}
