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
}
