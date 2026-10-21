import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart' as pa;
import 'package:test/test.dart';

void main() {
  test('schema preserves byte metadata and duplicate positional fields', () {
    final key = Uint8List.fromList([255, 0]);
    final field = pa.field(
      '',
      pa.int32(),
      metadata: {
        key: Uint8List.fromList([128]),
      },
    );
    final schema = pa.schema([field, ('', pa.string())], metadata: {});
    key[0] = 1;
    expect(field.metadata![Uint8List.fromList([255, 0])], [128]);
    expect(schema.names, ['', '']);
    expect(schema.getFieldIndex(''), -1);
    expect(schema.getAllFieldIndices(''), [0, 1]);
    expect(() => schema.field(''), throwsArgumentError);
    expect(field.equals(field.removeMetadata()), isTrue);
    expect(field.equals(field.removeMetadata(), checkMetadata: true), isFalse);
    expect(field.hashCode, field.removeMetadata().hashCode);
    expect(
      pa.Schema.fromJson(schema.toJson()).equals(schema, checkMetadata: true),
      isTrue,
    );
  });
  test('unaligned chunks produce PyArrow reference batch boundaries without flattening', () {
    final a = pa.chunkedArray([
      [1, 2],
      <int>[],
      [3, 4, 5],
    ]);
    final b = pa.chunkedArray([
      [10],
      [20, 30, 40],
      [50],
    ]);
    final table = pa.table({'a': a, 'b': b});
    expect(table.column('a'), isA<pa.ChunkedArray>());
    expect(table.toBatches(maxChunkSize: 2).map((b) => b.numRows), [
      1,
      1,
      0,
      2,
      1,
    ]);
    expect(table.toBatches(maxChunkSize: 2).map((b) => b.toDartMap()), [
      {
        'a': [1],
        'b': [10],
      },
      {
        'a': [2],
        'b': [20],
      },
      {'a': [], 'b': []},
      {
        'a': [3, 4],
        'b': [30, 40],
      },
      {
        'a': [5],
        'b': [50],
      },
    ]);
    expect(a.slice(1, 3).toDartList(), [2, 3, 4]);
    expect(a[-1].asDart(), 5);
    expect(table.combineChunks().column(0).numChunks, 1);
    expect(table.select([]).numRows, 5);
    expect(table.select([]).slice(1, 2).toBatches().single.numRows, 2);
    expect(pa.Table.fromBatches(table.select([]).toBatches()).numRows, 5);
  });
  test('explicit schemas define output and allow physical nulls in nonnullable fields', () {
    final schema = pa.schema(
      [pa.field('x', pa.int32(), nullable: false)],
      metadata: {'source': 'test'},
    );
    final batch = pa.recordBatch({
      'extra': [9],
      'x': [null],
    }, schema: schema);
    expect(batch.schema.equals(schema, checkMetadata: true), isTrue);
    expect(batch.columnNames, ['x']);
    expect(batch[0][0].isValid, isFalse);
    expect(batch.toDartList(), [
      {'x': null},
    ]);
    expect(
      () => pa.recordBatch({
        'extra': [9],
      }, schema: schema),
      throwsArgumentError,
    );
    expect(batch.select([]).slice(0, 1).numRows, 1);
    expect(batch.renameColumns(['y']).schema.metadata, isNull);
    expect(
      pa.Table.fromBatches([batch]).renameColumns(['y']).schema.metadata,
      isNull,
    );
    expect(pa.RecordBatch.fromDartList([<String, Object?>{}, {}]).numRows, 2);
  });
  test('nullable-generic native containers and lazy scalars preserve chunk behavior', () {
    final columns = <String, Object?>{
      'x': [1, null],
    };
    expect(pa.recordBatch(columns).toDartMap(), {
      'x': [1, null],
    });
    expect(pa.table(columns).toDartMap(), {
      'x': [1, null],
    });
    expect(
      pa
          .recordBatch(
            <Object?>[
              [1],
            ],
            names: ['x'],
          )
          .toDartMap(),
      {
        'x': [1],
      },
    );
    expect(
      pa
          .table(
            <Object?>[
              [1],
            ],
            names: ['x'],
          )
          .toDartMap(),
      {
        'x': [1],
      },
    );
    expect(
      () => pa.recordBatch(<String, Object?>{'x': null}),
      throwsArgumentError,
    );
    expect(() => pa.table(<String, Object?>{'x': null}), throwsArgumentError);
    final chunks = pa.chunkedArray(<Object?>[
      [],
      [1, null],
      [],
      [3],
    ], type: pa.int64());
    expect(chunks.slice(1, 2).chunks.map((c) => c.length), [1, 0, 1]);
    expect(chunks.scalars.map((s) => s.asDart()), [1, null, 3]);
  });
  test('logical length sums reject overflow without materializing rows', () {
    final huge = pa.Array.fromBuffers(pa.nullType(), 0x7fffffffffffffff, []);
    expect(pa.chunkedArray([huge]).length, 0x7fffffffffffffff);
    expect(
      () => pa.chunkedArray([
        huge,
        pa.array([null]),
      ]),
      throwsA(isA<pa.ArrowInvalid>()),
    );
    expect(
      () => pa.concatArrays([huge, huge, huge]),
      throwsA(isA<pa.ArrowInvalid>()),
    );
    final zeroColumns = pa.RecordBatch.fromArrays(
      [huge],
      names: ['x'],
    ).select([]);
    expect(zeroColumns.numRows, 0x7fffffffffffffff);
    expect(
      () => pa.Table.fromBatches([zeroColumns, zeroColumns, zeroColumns]),
      throwsA(isA<pa.ArrowInvalid>()),
    );
  });
  test('native primitive encoding owns bytes and preserves valid values', () {
    final bytes = Uint8List.fromList([128, 255]);
    final binary = pa.array([bytes], type: pa.binary());
    bytes[0] = 0;
    expect(binary.toDartList(), [
      [128, 255],
    ]);
    expect(pa.array([-128, 127, null], type: pa.int8()).toDartList(), [
      -128,
      127,
      null,
    ]);
    expect(pa.array([false, true, null], type: pa.boolType()).toDartList(), [
      false,
      true,
      null,
    ]);
    expect(
      pa.array([1.5, double.infinity, null], type: pa.float32()).toDartList(),
      [1.5, double.infinity, null],
    );
    expect(pa.array(['Dart', '', null], type: pa.string()).toDartList(), [
      'Dart',
      '',
      null,
    ]);
  });
}
