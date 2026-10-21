import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/json.dart';
import 'package:test/test.dart';

void main() {
  test('owned buffers pack boolean and validity, slices share storage', () {
    final values = array([true, null, false, true], type: const BooleanType());
    final buffers = values.buffers();
    expect(buffers[0]!.toBytes(), [13]);
    expect(buffers[1]!.toBytes(), [9]);
    final slice = values.slice(1, 2);
    expect(slice.offset, 1);
    for (var i = 0; i < buffers.length; i++) {
      expect(identical(slice.buffers()[i]!.bytes, buffers[i]!.bytes), isTrue);
    }
    expect(slice.toDartList(), [null, false]);
    expect(slice.nullCount, 1);
    expect(() => buffers[1]!.bytes[0] = 0, throwsUnsupportedError);
    final copy = buffers[1]!.toBytes();
    copy[0] = 0;
    expect(buffers[1]!.toBytes(), [9]);
    expect(values.slice(4).length, 0);
    expect(values.slice(20).length, 0);
    expect(values.slice(2, 20).toDartList(), [false, true]);
    expect(() => values.slice(-1), throwsRangeError);
    expect(() => values.slice(2, -1), throwsArgumentError);
  });
  test(
    'foreign bit offsets cross byte boundaries and primitive offsets apply',
    () {
      final booleans = Array.fromBuffers(const BooleanType(), 4, [
        Buffer(Uint8List.fromList([64, 3])),
        Buffer(Uint8List.fromList([192, 2])),
      ], offset: 6);
      expect(booleans.toDartList(), [true, null, false, true]);
      expect(booleans.slice(1, 3).nullCount, 1);
      final data = Uint8List(12);
      final view = ByteData.sublistView(data);
      view.setInt32(4, -7, Endian.little);
      view.setInt32(8, 11, Endian.little);
      final buffer = Buffer(data);
      final numbers = Array.fromBuffers(IntegerType(32), 2, [
        null,
        buffer,
      ], offset: 1);
      expect(numbers.toDartList(), [-7, 11]);
      expect(numbers.slice(1)[0].asDart(), 11);
      view.setInt32(8, 17, Endian.little);
      expect(numbers[1].asDart(), 17);
      view.setInt32(8, 11, Endian.little);
      expect(numbers.buffers()[1]!.bytes.offsetInBytes, data.offsetInBytes);
    },
  );
  test('borrowed buffers preserve floating bits', () {
    final bytes = Uint8List.fromList([1, 0, 192, 127, 0, 0, 0, 128]);
    final values = Array.fromBuffers(FloatingType(32), 2, [
      null,
      Buffer(bytes),
    ]);
    expect(values[0].rawBits, BigInt.from(0x7fc00001));
    expect(values[0].asDart(), isNaN);
    expect(values[0].isValid, isTrue);
    expect(values.slice(1)[0].rawBits, BigInt.from(0x80000000));
    expect(1 / (values[1].asDart() as double), double.negativeInfinity);
  });
  test('foreign offsets and bitmap bounds are checked', () {
    expect(
      () => Array.fromBuffers(const BooleanType(), 9, [
        Buffer(Uint8List(1)),
        Buffer(Uint8List(2)),
      ]),
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
        () => Array.fromBuffers(const Utf8Type(), 2, [
          null,
          Buffer(raw),
          Buffer(Uint8List(3)),
        ]),
        throwsArgumentError,
      );
    }
  });
  test('nested sliced arrays round trip through owned JSON', () {
    final type = StructType([
      Field('list', ListType(Field('', IntegerType(32)))),
      Field('fixed', FixedSizeListType(Field('', const Utf8Type()), 2)),
    ]);
    final row = <String, Object?>{
      'list': [7, null],
      'fixed': ['a', 'b'],
    };
    final values = array([null, row, row], type: type).slice(1, 2).slice(1, 1);
    expect(values[0].asDart(), row);
    final batch = RecordBatch.fromArrays([
      values,
    ], schema: Schema([Field('', type)]));
    const codec = OwnedBatchJsonCodec();
    expect(codec.decode(codec.encode(batch)).columns[0].toDartList(), [row]);
    expect(batch.slice(0, 1).columns[0].offset, 2);
    final duplicates = RecordBatch.fromArrays([
      values,
      array([null], type: type),
    ], schema: Schema([Field('', type), Field('', type)]));
    final decoded = codec.decode(codec.encode(duplicates));
    expect(decoded.schema, duplicates.schema);
    expect(decoded.columns[0].toDartList(), [row]);
    expect(decoded.columns[1].toDartList(), [null]);
  });
  test('sliced child list offsets are child logical indices', () {
    final child = array([0, 1, 2, 3, 4], type: IntegerType(32)).slice(2);
    final offsets = Uint8List(8);
    ByteData.sublistView(offsets).setInt32(4, 2, Endian.little);
    final list = Array.fromBuffers(
      ListType(Field('', child.type)),
      1,
      [null, Buffer(offsets)],
      children: [child],
    );
    expect(list[0].asDart(), [2, 3]);
  });
  test(
    'null struct masks nonnullable child and null dictionary skips indices',
    () {
      final child = array([null, 1], type: IntegerType(8));
      final struct = Array.fromBuffers(
        StructType([Field('', child.type, nullable: false)]),
        2,
        [
          Buffer(Uint8List.fromList([2])),
        ],
        children: [child],
      );
      expect(struct[0].isValid, isFalse);
      expect(struct[0].asDart(), isNull);
      expect(struct.slice(1).nullCount, 0);
      final dictionary = array(['x'], type: const Utf8Type());
      final indices = Array.fromBuffers(IntegerType(8), 1, [
        Buffer(Uint8List(1)),
        Buffer(Uint8List.fromList([127])),
      ]);
      final encoded = Array.fromDictionary(indices, dictionary);
      expect(encoded[0].isValid, isFalse);
      expect(encoded[0].asDart(), isNull);
    },
  );
  test('unknown and known null counts and empty buffer policy', () {
    Array imported(int count) => Array.fromBuffers(const BooleanType(), 2, [
      Buffer(Uint8List.fromList([1])),
      Buffer(Uint8List(1)),
    ], nullCount: count);
    expect(imported(-1).nullCount, 1);
    expect(imported(1).slice(1).nullCount, 1);
    expect(() => imported(0), throwsArgumentError);
    expect(() => imported(-2), throwsArgumentError);
    expect(
      Array.fromBuffers(IntegerType(32), 0, [
        null,
        Buffer(Uint8List(0)),
      ]).toDartList(),
      isEmpty,
    );
    expect(
      () => Array.fromBuffers(IntegerType(32), 0, [null, null]),
      throwsArgumentError,
    );
  });
  test('dictionary arguments are checked even for null extension storage', () {
    final dictionary = array(['x'], type: const Utf8Type());
    for (final type in [
      const NullType(),
      ExtensionType('null', const NullType()),
    ]) {
      expect(
        () => Array.fromBuffers(type, 1, [], dictionary: dictionary),
        throwsArgumentError,
      );
    }
  });
  test(
    'physical nested dictionaries retain values and reject lossy owned JSON',
    () {
      final dictionary = array(['x'], type: const Utf8Type());
      final child = Array.fromDictionary(
        array([0], type: IntegerType(8)),
        dictionary,
      );
      final offsets = Uint8List(8);
      ByteData.sublistView(offsets).setInt32(4, 1, Endian.little);
      final list = Array.fromBuffers(
        ListType(Field('', child.type)),
        1,
        [null, Buffer(offsets)],
        children: [child],
      );
      expect(list[0].asDart(), ['x']);
      expect((list.children[0][0] as DictionaryScalar).index.asDart(), 0);
      expect(list.children[0].dictionary![0].asDart(), 'x');
      list.validate(full: true);
      final batch = RecordBatch.fromArrays([
        list,
      ], schema: Schema([Field('', list.type)]));
      expect(
        () => const OwnedBatchJsonCodec().encode(batch),
        throwsUnsupportedError,
      );
    },
  );
  test('foreign geometry cannot wrap required buffer sizes', () {
    expect(
      () => Array.fromBuffers(IntegerType(64), 1 << 61, [
        null,
        Buffer(Uint8List(0)),
      ]),
      throwsArgumentError,
    );
    expect(
      () => Array.fromBuffers(
        const NullType(),
        1,
        [],
        offset: 0x7fffffffffffffff,
      ),
      throwsArgumentError,
    );
    expect(
      () => Array.fromBuffers(const BooleanType(), 0x7fffffffffffffff, [
        Buffer(Uint8List(0)),
        Buffer(Uint8List(0)),
      ]),
      throwsArgumentError,
    );
    expect(
      () => Array.fromBuffers(const Utf8Type(OffsetWidth.large), 1 << 61, [
        null,
        Buffer(Uint8List(0)),
        Buffer(Uint8List(0)),
      ]),
      throwsArgumentError,
    );
    final child = array([], type: IntegerType(32));
    expect(
      () => Array.fromBuffers(
        FixedSizeListType(Field('', child.type), 1 << 62),
        4,
        [null],
        children: [child],
      ),
      throwsArgumentError,
    );
    expect(
      Array.fromBuffers(
        FixedSizeListType(Field('', child.type), 0),
        2,
        [null],
        children: [child],
      ).toDartList(),
      [[], []],
    );
  });
}
