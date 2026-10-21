import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:test/test.dart';

void main() {
  test(
    'buffers borrow storage but expose immutable views and copied bytes',
    () {
      final source = Uint8List.fromList([1, 2, 3]);
      final buffer = Buffer(source);
      expect(buffer.size, 3);
      expect(buffer.isMutable, isFalse);
      expect(buffer.slice(1, 2).toBytes(), [2, 3]);
      expect(() => buffer.slice(1, 99), throwsRangeError);
      expect(() => buffer.slice(-1), throwsRangeError);
      expect(() => buffer.slice(4), throwsRangeError);
      expect(() => buffer.slice(0, -1), throwsRangeError);
      final copy = buffer.toBytes()..[0] = 9;
      expect(copy[0], 9);
      expect(buffer.toBytes(), [1, 2, 3]);
      source[1] = 7;
      expect(buffer.slice(1).toBytes(), [7, 3]);
    },
  );

  test('scalars preserve exact integer decimal and temporal values', () {
    expect(scalar(42).asDart(), 42);
    final large = BigInt.parse('18446744073709551615');
    expect(scalar(large, type: uint64()).asDart(), large);
    final decimal = DecimalValue(BigInt.from(12345), 3);
    expect(scalar(decimal, type: decimal128(8, 3)).asDart(), decimal);
    expect(DecimalValue.parse('-12.345e2'), DecimalValue(-12345, 1));
    expect(DecimalValue.parse('.001'), DecimalValue(1, 3));
    expect(() => DecimalValue.parse('NaN'), throwsFormatException);
    final exact = scalar(DateTime.utc(1970), type: timestamp('us'));
    expect(exact.value, 0);
    expect(exact.type, timestamp('us'));
    final instant = TemporalValue(1, TimeUnit.nanosecond, kind: 'timestamp');
    expect(scalar(instant, type: timestamp('ns')).asDart(), instant);
    expect(scalar(double.nan).isValid, isTrue);
    expect((scalar(double.nan).asDart() as double).isNaN, isTrue);
  });

  test('dictionary scalars expose typed indices and decoded nulls', () {
    final values = array([
      'a',
      null,
      'a',
    ], type: DictionaryType(int8(), const Utf8Type()));
    final first = values[0] as DictionaryScalar;
    expect(first.index.type, int8());
    expect(first.index.asDart(), 0);
    expect(first.value.asDart(), 'a');
    expect(first.asDart(), 'a');
    final absent = values[1] as DictionaryScalar;
    expect(absent.isValid, isFalse);
    expect(absent.index.isValid, isFalse);
    expect(absent.value.isValid, isFalse);
    expect(absent.asDart(), isNull);
  });

  test('nested values and exact temporal host conversions are recursive', () {
    expect(
      scalar([
        [1, null],
        [2],
      ]).asDart(),
      [
        [1, null],
        [2],
      ],
    );
    final instant = DateTime.utc(2024, 1, 2, 3, 4, 5, 6, 7);
    expect(scalar(instant).asDart(), instant);
    final annotated = TemporalValue(
      0,
      TimeUnit.second,
      timeZone: 'Europe/Paris',
      kind: 'timestamp',
    );
    expect(scalar(annotated).asDart(), annotated);
    final floating = scalar(-0.0);
    expect(floating.rawBits, BigInt.one << 63);
    expect(1 / (floating.asDart() as double), double.negativeInfinity);
  });
  test('scalar nested casts retain visible dictionary child context', () {
    final encoded = array(['red', 'blue'], type: dictionary(int8(), string()));
    final offsets = Uint8List(12);
    ByteData.sublistView(offsets)
      ..setInt32(4, 1, Endian.little)
      ..setInt32(8, 2, Endian.little);
    final lists = Array.fromBuffers(
      listType(encoded.type),
      2,
      [null, Buffer(offsets)],
      children: [encoded],
    );
    expect(lists[1].cast(listType(string())).asDart(), ['blue']);
    final fixed = Array.fromBuffers(
      listType(encoded.type, listSize: 1),
      2,
      [null],
      children: [encoded],
    );
    expect(fixed[1].cast(listType(string(), listSize: 1)).asDart(), ['blue']);
    final structs = Array.fromBuffers(
      struct([field('x', encoded.type)]),
      2,
      [null],
      children: [encoded],
    );
    expect(structs[1].cast(struct([field('x', string())])).asDart(), {
      'x': 'blue',
    });
    final values = array([
      [1000],
      [1],
    ], type: listType(int64(), listSize: 1));
    expect(values[1].cast(listType(int8(), listSize: 1)).asDart(), [1]);
  });
  test(
    'validity masks retain sliced bitmaps and distinguish NaN from null',
    () {
      final source = array([true, null, false, true]).slice(1, 2);
      final valid = source.isValid();
      expect(valid.offset, source.offset);
      expect(valid.toDartList(), [false, true]);
      expect(valid.nullCount, 0);
      expect(source.isNull().toDartList(), [true, false]);
      for (final dtype in [float16(), float32(), float64()]) {
        final floats = array([double.nan, null, 1.0], type: dtype);
        expect(floats.isNull().toDartList(), [false, true, false]);
        expect(floats.isNull(nanIsNull: true).toDartList(), [
          true,
          true,
          false,
        ]);
      }
      final chunks = chunkedArray([
        [1],
        <int>[],
        [null],
      ], type: int32());
      expect(chunks.isValid().chunks.map((c) => c.length), [1, 1]);
      expect(chunks.isNull().chunks.map((c) => c.length), [2]);
    },
  );
}
