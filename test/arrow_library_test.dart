import 'dart:convert';

import 'package:dartaframes/arrow.dart';
import 'package:test/test.dart';

void main() {
  group('datatypes', () {
    test('JSON round-trips every logical family', () {
      final types = <ArrowDataType>[
        const ArrowNullType(),
        const ArrowBooleanType(),
        for (final width in [8, 16, 32, 64, 128]) ...[
          ArrowIntegerType(width),
          ArrowIntegerType(width, signed: false),
        ],
        for (final width in [16, 32, 64]) ArrowFloatingType(width),
        ArrowDecimalType(38, 9),
        const ArrowUtf8Type(),
        const ArrowUtf8Type(ArrowOffsetWidth.large),
        const ArrowBinaryType(),
        const ArrowBinaryType(ArrowOffsetWidth.large),
        const ArrowDateType(),
        const ArrowDateType(ArrowDateUnit.millisecond),
        const ArrowTimestampType(ArrowTimeUnit.nanosecond, timeZone: 'UTC'),
        const ArrowTimestampType(ArrowTimeUnit.microsecond),
        const ArrowTimestampType(ArrowTimeUnit.millisecond),
        const ArrowDurationType(ArrowTimeUnit.nanosecond),
        const ArrowTimeType(ArrowTimeUnit.microsecond),
        ArrowListType(ArrowField('item', ArrowIntegerType(32))),
        ArrowFixedSizeListType(ArrowField('item', ArrowFloatingType(32)), 3),
        ArrowStructType([
          ArrowField('x', const ArrowBooleanType(), nullable: false),
          ArrowField('y', const ArrowUtf8Type()),
        ]),
        ArrowDictionaryType(
          ArrowIntegerType(16, signed: false),
          const ArrowUtf8Type(),
          ordered: true,
        ),
        ArrowExtensionType(
          'vendor.point',
          const ArrowBinaryType(),
          metadata: '{"version":1}',
        ),
      ];
      for (final type in types) {
        expect(
          ArrowDataType.fromJson(
            jsonDecode(jsonEncode(type.toJson())).cast<String, Object?>(),
          ),
          type,
        );
      }
    });

    test('rejects invalid decimal, list, dictionary and duplicate fields', () {
      expect(() => ArrowIntegerType(24), throwsArgumentError);
      expect(() => ArrowFloatingType(128), throwsArgumentError);
      expect(() => ArrowDecimalType(0, 0), throwsRangeError);
      expect(() => ArrowDecimalType(3, 4), throwsRangeError);
      expect(
        () =>
            ArrowFixedSizeListType(ArrowField('x', const ArrowNullType()), -1),
        throwsRangeError,
      );
      expect(
        () => ArrowDictionaryType(ArrowFloatingType(32), const ArrowUtf8Type()),
        throwsArgumentError,
      );
      expect(
        () => ArrowStructType([
          ArrowField('x', const ArrowNullType()),
          ArrowField('x', const ArrowNullType()),
        ]),
        throwsArgumentError,
      );
    });

    test('strictly validates descriptor units and booleans', () {
      expect(
        () => ArrowDataType.fromJson({'kind': 'date', 'unit': 'seconds'}),
        throwsFormatException,
      );
      expect(
        () => ArrowField.fromJson({
          'name': 'x',
          'dtype': {'kind': 'boolean'},
          'nullable': 'yes',
        }),
        throwsFormatException,
      );
      expect(
        () => ArrowDataType.fromJson({
          'kind': 'dictionary',
          'indexType': {'kind': 'int8'},
          'valueType': {'kind': 'string'},
          'ordered': 1,
        }),
        throwsFormatException,
      );
    });
  });

  group('values and arrays', () {
    test('validates signed, unsigned, 128-bit and uint64 boundaries', () {
      final int128 = ArrowIntegerType(128);
      final uint64 = ArrowIntegerType(64, signed: false);
      final minimum = -(BigInt.one << 127);
      final maximum = (BigInt.one << 127) - BigInt.one;
      expect(
        ArrowArray(int128, [
          ArrowIntegerValue(minimum),
          ArrowIntegerValue(maximum),
        ]).length,
        2,
      );
      expect(
        () => ArrowArray(int128, [ArrowIntegerValue(minimum - BigInt.one)]),
        throwsRangeError,
      );
      expect(
        ArrowArray(uint64, [ArrowIntegerValue('18446744073709551615')])[0],
        ArrowIntegerValue(BigInt.parse('18446744073709551615')),
      );
      expect(
        () => ArrowArray(uint64, [ArrowIntegerValue(-1)]),
        throwsRangeError,
      );
    });

    test('keeps raw Float16 bits and all Float64 bits', () {
      final half = ArrowFloatingValue.float16(0x7e01);
      expect(half.hexadecimalBits, '7e01');
      final array = ArrowArray(ArrowFloatingType(16), [half]);
      expect(array[0], half);
      expect(
        ArrowFloatingValue(
          64,
          BigInt.parse('fff0000000000000', radix: 16),
        ).hexadecimalBits,
        'fff0000000000000',
      );
    });

    test('validates decimal precision and raw temporal range', () {
      expect(
        ArrowArray(ArrowDecimalType(5, 2), [ArrowDecimalValue(-99999)]).length,
        1,
      );
      expect(
        () => ArrowArray(ArrowDecimalType(5, 2), [ArrowDecimalValue(100000)]),
        throwsRangeError,
      );
      expect(
        ArrowArray(const ArrowTimestampType(ArrowTimeUnit.nanosecond), [
          ArrowTemporalValue('9223372036854775807'),
        ]).length,
        1,
      );
      expect(
        () => ArrowArray(const ArrowTimeType(ArrowTimeUnit.nanosecond), [
          ArrowTemporalValue(BigInt.one << 63),
        ]),
        throwsRangeError,
      );
    });

    test('validates nested nullability, fixed width, and struct order', () {
      final fixed = ArrowFixedSizeListType(
        ArrowField('item', ArrowIntegerType(8), nullable: false),
        2,
      );
      expect(
        ArrowArray(fixed, [
          ArrowListValue([ArrowIntegerValue(1), ArrowIntegerValue(2)]),
        ]).length,
        1,
      );
      expect(
        () => ArrowArray(fixed, [
          ArrowListValue([ArrowIntegerValue(1)]),
        ]),
        throwsArgumentError,
      );
      expect(
        () => ArrowArray(fixed, [
          ArrowListValue([ArrowIntegerValue(1), null]),
        ]),
        throwsArgumentError,
      );

      final struct = ArrowStructType([
        ArrowField('a', const ArrowBooleanType(), nullable: false),
        ArrowField(
          'b',
          ArrowListType(ArrowField('item', const ArrowUtf8Type())),
        ),
      ]);
      final nested = ArrowStructValue([
        const ArrowStructEntry('a', ArrowBooleanValue(true)),
        ArrowStructEntry(
          'b',
          ArrowListValue([const ArrowStringValue('x'), null]),
        ),
      ]);
      expect(ArrowArray(struct, [nested, null]).validity, [true, false]);
      expect(
        () => ArrowArray(struct, [
          ArrowStructValue([
            const ArrowStructEntry('b', ArrowBooleanValue(true)),
            const ArrowStructEntry('a', null),
          ]),
        ]),
        throwsArgumentError,
      );
    });

    test('checks explicit validity and one-shot builder', () {
      expect(
        () => ArrowArray(
          const ArrowBooleanType(),
          [const ArrowBooleanValue(true)],
          validity: [false],
        ),
        throwsArgumentError,
      );
      final builder = ArrowArrayBuilder(const ArrowBooleanType())
        ..append(const ArrowBooleanValue(true))
        ..appendNull();
      expect(builder.build().validity, [true, false]);
      expect(builder.build, throwsStateError);
    });
  });

  group('schema and record batches', () {
    test('metadata is copied, immutable, and JSON round-trips', () {
      final source = {'source': 'test'};
      final schema = ArrowSchema([
        ArrowField(
          'id',
          ArrowIntegerType(64),
          nullable: false,
          metadata: source,
        ),
      ], metadata: source);
      source['source'] = 'changed';
      expect(schema.metadata['source'], 'test');
      expect(() => schema.metadata['new'] = 'x', throwsUnsupportedError);
      expect(ArrowSchema.fromJson(schema.toJson()), schema);
    });

    test('metadata equality and hash are independent of insertion order', () {
      final first = ArrowSchema([], metadata: {'a': '1', 'b': '2'});
      final second = ArrowSchema([], metadata: {'b': '2', 'a': '1'});
      final firstField = ArrowField(
        'x',
        const ArrowBooleanType(),
        metadata: {'a': '1', 'b': '2'},
      );
      final secondField = ArrowField(
        'x',
        const ArrowBooleanType(),
        metadata: {'b': '2', 'a': '1'},
      );
      expect(first, second);
      expect(first.hashCode, second.hashCode);
      expect({first}, contains(second));
      expect({firstField}, contains(secondField));
    });

    test('preserves explicit row counts for batches without columns', () {
      final batch = RecordBatch(ArrowSchema([]), [], rowCount: 3);
      const codec = OwnedBatchJsonCodec();
      final decoded = codec.decode(codec.encode(batch));
      expect(decoded.length, 3);
      expect(decoded.columns, isEmpty);
      expect(
        () => RecordBatch(ArrowSchema([]), [], rowCount: -1),
        throwsRangeError,
      );
    });

    test('validates datatype, nullability, and equal column lengths', () {
      final schema = ArrowSchema([
        ArrowField('a', const ArrowBooleanType(), nullable: false),
        ArrowField('b', const ArrowUtf8Type()),
      ]);
      expect(
        RecordBatch(schema, [
          ArrowArray(const ArrowBooleanType(), [const ArrowBooleanValue(true)]),
          ArrowArray(const ArrowUtf8Type(), [const ArrowStringValue('x')]),
        ]).length,
        1,
      );
      expect(
        () => RecordBatch(schema, [
          ArrowArray(const ArrowBooleanType(), [null]),
          ArrowArray(const ArrowUtf8Type(), [null]),
        ]),
        throwsArgumentError,
      );
      expect(
        () => RecordBatch(schema, [
          ArrowArray(const ArrowBooleanType(), [const ArrowBooleanValue(true)]),
          ArrowArray(const ArrowUtf8Type(), []),
        ]),
        throwsArgumentError,
      );
    });
  });

  group('dictionary, extension, and owned codec', () {
    test(
      'dictionary validates index type, bounds, and dictionary datatype',
      () {
        final type = ArrowDictionaryType(
          ArrowIntegerType(8, signed: false),
          const ArrowUtf8Type(),
        );
        final dictionary = ArrowArray(const ArrowUtf8Type(), [
          const ArrowStringValue('red'),
          const ArrowStringValue('blue'),
        ]);
        expect(
          ArrowArray(type, [
            ArrowDictionaryIndexValue(1),
            null,
          ], dictionary: dictionary).length,
          2,
        );
        expect(
          () => ArrowArray(type, [
            ArrowDictionaryIndexValue(2),
          ], dictionary: dictionary),
          throwsRangeError,
        );
      },
    );

    test('round-trips nested values, BigInt, dictionary, and extension', () {
      final dictionaryType = ArrowDictionaryType(
        ArrowIntegerType(16, signed: false),
        const ArrowUtf8Type(),
      );
      final extensionType = ArrowExtensionType(
        'vendor.uuid',
        const ArrowBinaryType(),
        metadata: 'v1',
      );
      final nestedType = ArrowListType(
        ArrowField(
          'item',
          ArrowStructType([
            ArrowField('n', ArrowIntegerType(128), nullable: false),
            ArrowField('s', const ArrowUtf8Type()),
          ]),
        ),
      );
      final schema = ArrowSchema(
        [
          ArrowField('nested', nestedType),
          ArrowField('category', dictionaryType),
          ArrowField('extension', extensionType),
          ArrowField('half', ArrowFloatingType(16)),
          ArrowField(
            'when',
            const ArrowTimestampType(ArrowTimeUnit.nanosecond, timeZone: 'UTC'),
          ),
          ArrowField('amount', ArrowDecimalType(38, 4)),
        ],
        metadata: const {'owner': 'dart'},
      );
      final dictionary = ArrowArray(const ArrowUtf8Type(), [
        const ArrowStringValue('a'),
        const ArrowStringValue('b'),
      ]);
      final batch = RecordBatch(schema, [
        ArrowArray(nestedType, [
          ArrowListValue([
            ArrowStructValue([
              ArrowStructEntry('n', ArrowIntegerValue(BigInt.one << 100)),
              const ArrowStructEntry('s', ArrowStringValue('hello')),
            ]),
            null,
          ]),
          null,
        ]),
        ArrowArray(dictionaryType, [
          ArrowDictionaryIndexValue(1),
          ArrowDictionaryIndexValue(0),
        ], dictionary: dictionary),
        ArrowArray(extensionType, [
          ArrowExtensionValue(ArrowBinaryValue([0, 1, 255])),
          null,
        ]),
        ArrowArray(ArrowFloatingType(16), [
          ArrowFloatingValue.float16(0x8000),
          ArrowFloatingValue.float16(0x7e01),
        ]),
        ArrowArray(
          const ArrowTimestampType(ArrowTimeUnit.nanosecond, timeZone: 'UTC'),
          [ArrowTemporalValue(-42), ArrowTemporalValue(42)],
        ),
        ArrowArray(ArrowDecimalType(38, 4), [
          ArrowDecimalValue('12340000'),
          ArrowDecimalValue('-1'),
        ]),
      ]);
      const codec = OwnedBatchJsonCodec();
      final wire = codec.encode(batch);
      expect(wire, contains('1267650600228229401496703205376'));
      final decoded = codec.decode(wire);
      expect(decoded.schema, schema);
      expect(decoded.length, 2);
      expect(decoded.columns[0].values, batch.columns[0].values);
      expect(decoded.columns[1].dictionary!.values, dictionary.values);
      expect(decoded.columns[2].values, batch.columns[2].values);
      expect(decoded.columns[3].values, batch.columns[3].values);
      expect(decoded.columns[4].values, batch.columns[4].values);
      expect(decoded.columns[5].values, batch.columns[5].values);
    });

    test('codec rejects malformed validity and declared length', () {
      const codec = OwnedBatchJsonCodec();
      final malformed = {
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
      };
      expect(() => codec.fromJson(malformed), throwsFormatException);
    });

    test('malformed nested and metadata shapes throw FormatException', () {
      expect(
        () => ArrowSchema.fromJson({
          'fields': [false],
        }),
        throwsFormatException,
      );
      expect(
        () => ArrowSchema.fromJson({
          'fields': [],
          'metadata': {'valid': 1},
        }),
        throwsFormatException,
      );
      expect(
        () => ArrowDataType.fromJson({
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
