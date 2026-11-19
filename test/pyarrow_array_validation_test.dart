import 'dart:typed_data';

import 'package:dartarrow/arrow.dart' as pa;
import 'package:test/test.dart';

void main() {
  // Expected outcomes from PyArrow 26.0.0 `UnionArray.from_sparse` and
  // `Array.from_buffers(...).validate(full=True)`.
  group('sparse union child length', () {
    final sparse = pa.sparseUnion([
      pa.field('0', pa.int32()),
      pa.field('1', pa.string()),
    ]);
    pa.Buffer ids(List<int> values) => pa.Buffer(Uint8List.fromList(values));

    test('fromSparseUnion rejects a child shorter than typeIds', () {
      expect(
        () => pa.Array.fromSparseUnion(pa.array([0, 0, 0], type: pa.int8()), [
          pa.array([1, 2, 3], type: pa.int32()),
          pa.array(['p', 'q']),
        ]),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Sparse UnionArray must have len(child) == len(type_ids)'),
          ),
        ),
      );
    });

    test('fromSparseUnion rejects a child longer than typeIds', () {
      expect(
        () => pa.Array.fromSparseUnion(pa.array([0, 0], type: pa.int8()), [
          pa.array([1, 2, 3], type: pa.int32()),
          pa.array(['p', 'q']),
        ]),
        throwsArgumentError,
      );
    });

    test('fromBuffers requires every child to cover offset + length', () {
      final children = [
        pa.array([1, 2, 3], type: pa.int32()),
        pa.array(['p', 'q']),
      ];
      expect(
        pa.Array.fromBuffers(sparse, 2, [
          null,
          ids([0, 0, 0]),
        ], children: children).toDartList(),
        [1, 2],
      );
      for (final (length, offset) in [(2, 1), (3, 0)]) {
        expect(
          () => pa.Array.fromBuffers(
            sparse,
            length,
            [
              null,
              ids([0, 0, 0]),
            ],
            offset: offset,
            children: children,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('Sparse union child array #1 has length smaller'),
            ),
          ),
        );
      }
    });
  });

  // PyArrow 26.0.0: large_list_view with offsets [2**62], sizes [2**62] and
  // a 2-element child raises "Offset invariant failure".
  test('large list view bounds check does not overflow', () {
    final bytes = ByteData(8)
      ..setUint32(0, 0, Endian.little)
      ..setUint32(4, 0x40000000, Endian.little);
    final huge = pa.Buffer(bytes.buffer.asUint8List());
    expect(
      () => pa.Array.fromBuffers(
        pa.largeListView(pa.int64()),
        1,
        [null, huge, huge],
        children: [
          pa.array([1, 2]),
        ],
      ),
      throwsArgumentError,
    );
  });

  // PyArrow 26.0.0: Array.from_buffers(pa.null(), 2, [None]) -> [None, None].
  test('null type fromBuffers round-trips buffers()', () {
    final nulls = pa.array([null, null]);
    expect(nulls.buffers(), [null]);
    expect(
      pa.Array.fromBuffers(pa.nullType(), 2, nulls.buffers()).toDartList(),
      [null, null],
    );
    expect(pa.Array.fromBuffers(pa.nullType(), 2, []).toDartList(), [
      null,
      null,
    ]);
  });

  test('buffer count error names public buffers', () {
    expect(
      () => pa.Array.fromBuffers(pa.int32(), 0, [null]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          startsWith('Expected 2 buffers for '),
        ),
      ),
    );
  });
}
