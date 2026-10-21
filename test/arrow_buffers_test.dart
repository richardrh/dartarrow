import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:test/test.dart';

void main() {
  test('owned buffers pack boolean and validity, slices share storage', () {
    final array = ArrowArray(const ArrowBooleanType(), [
      const ArrowBooleanValue(true),
      null,
      const ArrowBooleanValue(false),
      const ArrowBooleanValue(true),
    ]);
    expect(array.buffers[0], [13]);
    expect(array.buffers[1], [9]);
    final slice = array.slice(1, 2);
    expect(slice.offset, 1);
    expect(identical(slice.buffers, array.buffers), isTrue);
    expect(slice.values, [null, const ArrowBooleanValue(false)]);
    expect(slice.nullCount, 1);
    expect(() => array.buffers[1]![0] = 0, throwsUnsupportedError);
    expect(array.slice(4).length, 0);
    expect(() => array.slice(2, -1), throwsRangeError);
  });
  test(
    'foreign bit offsets cross byte boundaries and primitive offsets apply',
    () {
      final booleans = ArrowArray.fromBuffers(
        const ArrowBooleanType(),
        length: 4,
        offset: 6,
        buffers: [
          Uint8List.fromList([64, 3]),
          Uint8List.fromList([192, 2]),
        ],
      );
      expect(booleans.values, [
        const ArrowBooleanValue(true),
        null,
        const ArrowBooleanValue(false),
        const ArrowBooleanValue(true),
      ]);
      expect(booleans.slice(1, 3).nullCount, 1);
      final data = Uint8List(12);
      final view = ByteData.sublistView(data);
      view.setInt32(4, -7, Endian.little);
      view.setInt32(8, 11, Endian.little);
      final numbers = ArrowArray.fromBuffers(
        ArrowIntegerType(32),
        length: 2,
        offset: 1,
        buffers: [null, data],
      );
      expect(numbers.values, [ArrowIntegerValue(-7), ArrowIntegerValue(11)]);
      expect(numbers.slice(1)[0], ArrowIntegerValue(11));
    },
  );
  test('borrowed buffers preserve floating bits', () {
    final bytes = Uint8List.fromList([1, 0, 192, 127, 0, 0, 0, 128]);
    final array = ArrowArray.fromBuffers(
      ArrowFloatingType(32),
      length: 2,
      buffers: [null, bytes],
    );
    expect((array[0] as ArrowFloatingValue).hexadecimalBits, '7fc00001');
    expect(
      (array.slice(1)[0] as ArrowFloatingValue).hexadecimalBits,
      '80000000',
    );
  });
  test('foreign offsets and bitmap bounds are checked', () {
    expect(
      () => ArrowArray.fromBuffers(
        const ArrowBooleanType(),
        length: 9,
        buffers: [Uint8List(1), Uint8List(2)],
      ),
      throwsArgumentError,
    );
    for (final offsets in [
      [0, 2, 1],
      [0, 0, 4],
      [255, 0, 0],
    ]) {
      final raw = Uint8List(12);
      for (var i = 0; i < offsets.length; i++) {
        ByteData.sublistView(raw).setInt32(i * 4, offsets[i], Endian.little);
      }
      expect(
        () => ArrowArray.fromBuffers(
          const ArrowUtf8Type(),
          length: 2,
          buffers: [null, raw, Uint8List(3)],
        ),
        throwsArgumentError,
      );
    }
  });
  test('nested sliced arrays round trip through owned JSON', () {
    final type = ArrowStructType([
      ArrowField('', ArrowListType(ArrowField('', ArrowIntegerType(32)))),
      ArrowField(
        '',
        ArrowFixedSizeListType(ArrowField('', const ArrowUtf8Type()), 2),
      ),
    ]);
    final row = ArrowStructValue([
      ArrowStructEntry('', ArrowListValue([ArrowIntegerValue(7), null])),
      ArrowStructEntry(
        '',
        ArrowListValue(const [ArrowStringValue('a'), ArrowStringValue('b')]),
      ),
    ]);
    final array = ArrowArray(type, [null, row, row]).slice(1, 2).slice(1, 1);
    expect(array[0], row);
    final batch = RecordBatch(ArrowSchema([ArrowField('', type)]), [array]);
    const codec = OwnedBatchJsonCodec();
    expect(codec.decode(codec.encode(batch)).columns[0].values, [row]);
    expect(batch.slice(0, 1).columns[0].offset, 2);
    final duplicates = RecordBatch(
      ArrowSchema([ArrowField('', type), ArrowField('', type)]),
      [
        array,
        ArrowArray(type, [null]),
      ],
    );
    final decoded = codec.decode(codec.encode(duplicates));
    expect(decoded.schema, duplicates.schema);
    expect(decoded.columns[0].values, [row]);
    expect(decoded.columns[1].values, [null]);
  });
  test('sliced child list offsets are child logical indices', () {
    final child = ArrowArray(ArrowIntegerType(32), [
      for (var i = 0; i < 5; i++) ArrowIntegerValue(i),
    ]).slice(2);
    final offsets = Uint8List(8);
    ByteData.sublistView(offsets).setInt32(4, 2, Endian.little);
    final list = ArrowArray.fromBuffers(
      ArrowListType(ArrowField('', child.type)),
      length: 1,
      buffers: [null, offsets],
      children: [child],
    );
    expect((list[0] as ArrowListValue).values, [
      ArrowIntegerValue(2),
      ArrowIntegerValue(3),
    ]);
  });
  test(
    'null struct masks nonnullable child and null dictionary skips indices',
    () {
      final child = ArrowArray(ArrowIntegerType(8), [
        null,
        ArrowIntegerValue(1),
      ]);
      final struct = ArrowArray.fromBuffers(
        ArrowStructType([ArrowField('', child.type, nullable: false)]),
        length: 2,
        buffers: [
          Uint8List.fromList([2]),
        ],
        children: [child],
      );
      expect(struct[0], isNull);
      expect(struct.slice(1).nullCount, 0);
      final dictionary = ArrowArray(const ArrowUtf8Type(), const [
        ArrowStringValue('x'),
      ]);
      final indices = ArrowArray.fromBuffers(
        ArrowDictionaryType(ArrowIntegerType(8), dictionary.type),
        length: 1,
        buffers: [
          Uint8List(1),
          Uint8List.fromList([127]),
        ],
        dictionary: dictionary,
      );
      expect(indices[0], isNull);
    },
  );
  test('unknown and known null counts and empty buffer policy', () {
    ArrowArray imported(int? count) => ArrowArray.fromBuffers(
      const ArrowBooleanType(),
      length: 2,
      buffers: [
        Uint8List.fromList([1]),
        Uint8List(1),
      ],
      nullCount: count,
    );
    expect(imported(-1).nullCount, 1);
    expect(imported(1).slice(1).nullCount, 1);
    expect(() => imported(0), throwsArgumentError);
    expect(() => imported(-2), throwsArgumentError);
    expect(
      ArrowArray.fromBuffers(
        ArrowIntegerType(32),
        length: 0,
        buffers: [null, Uint8List(0)],
      ).values,
      isEmpty,
    );
    expect(
      () => ArrowArray.fromBuffers(
        ArrowIntegerType(32),
        length: 0,
        buffers: [null, null],
      ),
      throwsArgumentError,
    );
  });
  test('dictionary arguments are checked even for null extension storage', () {
    final dictionary = ArrowArray(const ArrowUtf8Type(), const [
      ArrowStringValue('x'),
    ]);
    for (final type in [
      const ArrowNullType(),
      ArrowExtensionType('null', const ArrowNullType()),
    ]) {
      expect(
        () => ArrowArray(type, [null], dictionary: dictionary),
        throwsArgumentError,
      );
    }
  });
  test(
    'physical nested dictionaries retain values and reject lossy owned JSON',
    () {
      final dictionary = ArrowArray(const ArrowUtf8Type(), const [
        ArrowStringValue('x'),
      ]);
      final child = ArrowArray(
        ArrowDictionaryType(ArrowIntegerType(8), dictionary.type),
        [ArrowDictionaryIndexValue(0)],
        dictionary: dictionary,
      );
      final offsets = Uint8List(8);
      ByteData.sublistView(offsets).setInt32(4, 1, Endian.little);
      final list = ArrowArray.fromBuffers(
        ArrowListType(ArrowField('', child.type)),
        length: 1,
        buffers: [null, offsets],
        children: [child],
      );
      expect((list[0] as ArrowListValue).values, [
        ArrowDictionaryIndexValue(0),
      ]);
      expect(list.children[0].dictionary![0], const ArrowStringValue('x'));
      final batch = RecordBatch(ArrowSchema([ArrowField('', list.type)]), [
        list,
      ]);
      expect(
        () => const OwnedBatchJsonCodec().encode(batch),
        throwsUnsupportedError,
      );
    },
  );
  test('foreign geometry cannot wrap required buffer sizes', () {
    expect(
      () => ArrowArray.fromBuffers(
        ArrowIntegerType(64),
        length: 1 << 61,
        buffers: [null, Uint8List(0)],
      ),
      throwsArgumentError,
    );
    expect(
      () => ArrowArray.fromBuffers(
        const ArrowNullType(),
        length: 1,
        offset: 0x7fffffffffffffff,
        buffers: [],
      ),
      throwsArgumentError,
    );
    expect(
      () => ArrowArray.fromBuffers(
        const ArrowBooleanType(),
        length: 0x7fffffffffffffff,
        buffers: [Uint8List(0), Uint8List(0)],
      ),
      throwsArgumentError,
    );
    expect(
      () => ArrowArray.fromBuffers(
        const ArrowUtf8Type(ArrowOffsetWidth.large),
        length: 1 << 61,
        buffers: [null, Uint8List(0), Uint8List(0)],
      ),
      throwsArgumentError,
    );
    final child = ArrowArray(ArrowIntegerType(32), []);
    expect(
      () => ArrowArray.fromBuffers(
        ArrowFixedSizeListType(ArrowField('', child.type), 1 << 62),
        length: 4,
        buffers: [null],
        children: [child],
      ),
      throwsArgumentError,
    );
    expect(
      ArrowArray.fromBuffers(
        ArrowFixedSizeListType(ArrowField('', child.type), 0),
        length: 2,
        buffers: [null],
        children: [child],
      ).values,
      [ArrowListValue([]), ArrowListValue([])],
    );
  });
}
