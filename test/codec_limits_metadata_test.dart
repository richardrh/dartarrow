// ByteMetadata looks String keys up by their UTF-8 bytes.
// ignore_for_file: collection_methods_unrelated_type

import 'dart:typed_data';

import 'package:dartarrow/arrow.dart' as pa;
import 'package:dartarrow/json.dart';
import 'package:test/test.dart';

Map<String, Object?> _batch(Map<String, Object?> dtype, List<Object?> values) =>
    {
      'schema': {
        'fields': [
          {'name': 'c', 'dtype': dtype, 'nullable': true},
        ],
      },
      'columns': [
        {
          'name': 'c',
          'dtype': dtype,
          'validity': [for (final v in values) v != null],
          'values': values,
        },
      ],
    };

void main() {
  const codec = OwnedBatchJsonCodec();

  group('owned JSON rejects null slots expanded from declared widths', () {
    Map<String, Object?> fsl(int size, [pa.DataType? child]) =>
        pa.listType(child ?? pa.int32(), listSize: size).toJson();
    Map<String, Object?> fsb(int width) =>
        pa.binary(2).toJson()..['byteWidth'] = width;

    test('fixed-size list of huge size', () {
      for (final size in [10000000, 1000000000]) {
        expect(
          () => codec.fromJson(_batch(fsl(size), [null])),
          throwsFormatException,
        );
      }
    });

    test('fixed-size binary of huge width', () {
      expect(
        () => codec.fromJson(_batch(fsb(1000000000000), [null, null])),
        throwsFormatException,
      );
    });

    test('nested through fixed-size lists, structs and lists', () {
      final nested = fsl(100000)
        ..['field'] = {'name': 'item', 'dtype': fsl(100000), 'nullable': true};
      expect(
        () => codec.fromJson(_batch(nested, [null])),
        throwsFormatException,
      );
      final struct = pa.struct([pa.field('x', pa.int8())]).toJson();
      ((struct['fields'] as List)[0] as Map)['dtype'] = fsl(1000000000);
      expect(
        () => codec.fromJson(_batch(struct, [null])),
        throwsFormatException,
      );
      final list = pa.listType(pa.int8()).toJson();
      (list['field'] as Map)['dtype'] = fsb(1000000000000);
      expect(
        () => codec.fromJson(
          _batch(list, [
            [null, null],
          ]),
        ),
        throwsFormatException,
      );
    });

    test('scalarFromJson', () {
      final type = pa.DataType.fromJson(fsl(1000000000));
      expect(() => scalarFromJson(type, null), throwsFormatException);
    });

    // PyArrow 26: pa.array([[1,2],None], pa.list_(pa.int32(),2)).to_pylist()
    // == [[1, 2], None]; pa.array([b'ab',None], pa.binary(2)) == [b'ab', None].
    test('legitimate null fixed-size slots still round-trip', () {
      final batch = pa.RecordBatch.fromArrays(
        [
          pa.array([
            [1, 2],
            null,
          ], type: pa.listType(pa.int32(), listSize: 2)),
          pa.array([
            Uint8List.fromList([97, 98]),
            null,
          ], type: pa.binary(2)),
        ],
        names: ['l', 'b'],
      );
      final decoded = codec.decode(codec.encode(batch));
      expect(decoded.column(0).toDartList(), [
        [1, 2],
        null,
      ]);
      expect(decoded.column(1).toDartList(), [
        [97, 98],
        null,
      ]);
    });
  });

  // PyArrow 26: m = pa.schema([...], metadata={'k': 'v'}).metadata;
  // b'k' in m == True, b'v' in m.values() == True, m[b'k'] == b'v'.
  group('ByteMetadata membership compares by content', () {
    final metadata = pa
        .schema([pa.field('a', pa.int8())], metadata: {'k': 'v'})
        .metadata!;

    test('containsKey', () {
      expect(metadata.containsKey(Uint8List.fromList([107])), isTrue);
      expect(metadata.containsKey('k'), isTrue);
      expect(metadata.containsKey('x'), isFalse);
      expect(metadata.containsKey(42), isFalse);
    });

    test('containsValue', () {
      expect(metadata.containsValue(Uint8List.fromList([118])), isTrue);
      expect(metadata.containsValue('v'), isTrue);
      expect(metadata.containsValue('k'), isFalse);
    });

    test('putIfAbsent on an existing key returns it; mutators throw', () {
      expect(
        metadata.putIfAbsent(Uint8List.fromList([107]), () => Uint8List(0)),
        [118],
      );
      expect(
        () => metadata.putIfAbsent(Uint8List(1), () => Uint8List(0)),
        throwsUnsupportedError,
      );
      expect(() => metadata.remove('k'), throwsUnsupportedError);
      expect(metadata, hasLength(1));
    });
  });
}
