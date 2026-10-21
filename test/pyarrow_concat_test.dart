import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart' as pa;
import 'package:test/test.dart';

void main() {
  test(
    'concatenation unifies dictionaries inside list children losslessly',
    () {
      pa.Array list(pa.Array child) => pa.Array.fromBuffers(
        pa.listType(child.type),
        1,
        [
          null,
          pa.Buffer(
            (ByteData(8)..setInt32(4, 2, Endian.little)).buffer.asUint8List(),
          ),
        ],
        children: [child],
      );
      final left = list(
        pa.Array.fromDictionary(
          pa.array([0, 1], type: pa.int8()),
          pa.array(['a', 'b']),
        ),
      );
      final right = list(
        pa.Array.fromDictionary(
          pa.array([1, 0], type: pa.int8()),
          pa.array(['b', 'a']),
        ),
      );
      // PyArrow equality preserves encoded dictionary mappings, even nested.
      expect(left.equals(right), isFalse);
      final combined = pa.concatArrays([left, right]);
      expect(combined.toDartList(), [
        ['a', 'b'],
        ['a', 'b'],
      ]);
      expect(combined.children.single.dictionary!.toDartList(), ['a', 'b']);
      combined.validate(full: true);
    },
  );
  test(
    'array equality follows floating logical values rather than bit equality',
    () {
      expect(pa.array([0.0]).equals(pa.array([-0.0])), isTrue);
      expect(pa.array([double.nan]).equals(pa.array([double.nan])), isFalse);
    },
  );
  test(
    'unsafe construction still rejects integers beyond float exact range',
    () {
      expect(
        () => pa.array([9007199254740993, 1.0], safe: false),
        throwsArgumentError,
      );
    },
  );
}
