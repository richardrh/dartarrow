import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart' as pa;
import 'package:test/test.dart';

pa.Array structView(
  List<pa.Field> fields,
  List<pa.Array> children, {
  int length = 2,
  int offset = 0,
  int bitmap = 2,
}) => pa.Array.fromBuffers(
  pa.struct(fields),
  length,
  [
    pa.Buffer(Uint8List.fromList([bitmap])),
  ],
  offset: offset,
  children: children,
);

void main() {
  test(
    'fromStructArray propagates parent validity without changing value storage',
    () {
      final child = pa.array([99, 1], type: pa.int64());
      final field = pa.field(
        'x',
        child.type,
        nullable: false,
        metadata: {'origin': 'test'},
      );
      final parent = structView([field], [child]);
      final batch = pa.RecordBatch.fromStructArray(parent);
      expect(batch.toDartMap(), {
        'x': [null, 1],
      });
      expect(batch.numRows, 2);
      expect(batch.schema.field(0).equals(field, checkMetadata: true), isTrue);
      expect(batch[0].buffers()[1]!.toBytes(), child.buffers()[1]!.toBytes());
      batch.validate(full: true);
    },
  );

  test('parent mask intersects child validity and respects both offsets', () {
    final child = pa
        .array([777, 99, null, 3, 888], type: pa.int64())
        .slice(1, 3);
    final parent = structView(
      [pa.field('x', child.type)],
      [child],
      length: 2,
      offset: 1,
      bitmap: 2,
    );
    expect(pa.RecordBatch.fromStructArray(parent).toDartMap(), {
      'x': [null, null],
    });
    final allValid = structView(
      [pa.field('x', child.type)],
      [child],
      length: 2,
      offset: 1,
      bitmap: 6,
    );
    final projected = pa.RecordBatch.fromStructArray(allValid);
    expect(projected.toDartMap(), {
      'x': [null, 3],
    });
    expect(projected[0].offset, 2);
  });

  test(
    'nested and dictionary columns retain encoding while parent masks rows',
    () {
      final dictionary = pa.Array.fromDictionary(
        pa.array([0, 1], type: pa.int8()),
        pa.array(['red', 'blue']),
      );
      final nested = pa.array([
        {'n': 99},
        {'n': 1},
      ]);
      final parent = structView(
        [pa.field('d', dictionary.type), pa.field('s', nested.type)],
        [dictionary, nested],
      );
      final batch = pa.RecordBatch.fromStructArray(parent);
      expect(batch.toDartMap(), {
        'd': [null, 'blue'],
        's': [
          null,
          {'n': 1},
        ],
      });
      expect(identical(batch[0].dictionary, dictionary.dictionary), isTrue);
      expect(
        identical(batch[1].children.single, nested.children.single),
        isTrue,
      );
      batch.validate(full: true);
    },
  );

  test('parent mask preserves exact IEEE and temporal bytes, including borrowed buffers', () {
    final bits = Uint8List(4);
    ByteData.sublistView(bits)
      ..setUint16(0, 0x7e01, Endian.little)
      ..setUint16(2, 0x7e02, Endian.little);
    final floating = pa.Array.fromBuffers(pa.float16(), 2, [
      null,
      pa.Buffer(bits),
    ]);
    final temporal = pa.array([
      pa.TemporalValue(123456789, pa.TimeUnit.nanosecond, kind: 'timestamp'),
      pa.TemporalValue(987654321, pa.TimeUnit.nanosecond, kind: 'timestamp'),
    ], type: pa.timestamp('ns'));
    final parent = structView(
      [pa.field('f', floating.type), pa.field('t', temporal.type)],
      [floating, temporal],
    );
    final batch = pa.RecordBatch.fromStructArray(parent);
    expect(batch[0][0].isValid, isFalse);
    expect(batch[0][1].rawBits, BigInt.from(0x7e02));
    expect(batch[1][1].value, 987654321);
    expect(batch[0].buffers()[1]!.toBytes(), bits);
    expect(batch[1].buffers()[1]!.toBytes(), temporal.buffers()[1]!.toBytes());
  });

  test('zero-column struct retains positive height and null-type children remain null', () {
    final empty = structView([], [], length: 2);
    expect(pa.RecordBatch.fromStructArray(empty).numRows, 2);
    final child = pa.array([null, null]);
    final parent = structView([pa.field('n', child.type)], [child]);
    expect(pa.RecordBatch.fromStructArray(parent).toDartMap(), {
      'n': [null, null],
    });
  });
}
