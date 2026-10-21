import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:test/test.dart';

void main() {
  test('temporal casts preserve exact raw nanosecond counters', () {
    final source = array([
      TemporalValue(9007199254740993, TimeUnit.nanosecond, kind: 'timestamp'),
    ], type: timestamp('ns'));
    expect(source.cast(int64())[0].asDart(), 9007199254740993);
    expect(
      source.cast(timestamp('us'), safe: false).cast(int64())[0].asDart(),
      9007199254740,
    );
    expect(() => source.cast(timestamp('us')), throwsArgumentError);
  });
  test('native construction infers nullable int64 and null arrays', () {
    expect(array([1, null, 2]).type, int64());
    expect(array([]).type, nullType());
    expect(array([null, null]).type, nullType());
  });
  test('mask excludes invalid inputs from conversion and inference', () {
    final result = array([1, 'ignored'], mask: [false, true]);
    expect(result[0].asDart(), 1);
    expect(result[1].asDart(), isNull);
  });
  test('construction overflow rejects even when unsafe', () {
    expect(() => array([128], type: int8(), safe: false), throwsArgumentError);
  });
  test('unsafe integer casting wraps but safe casting rejects overflow', () {
    final source = array([128]);
    expect(() => source.cast(int8()), throwsArgumentError);
    expect(source.cast(int8(), safe: false)[0].asDart(), -128);
  });
  test('binary and nested struct inference preserve native values', () {
    expect(
      array([
        Uint8List.fromList([1, 2]),
      ]).type,
      binary(),
    );
    final result = array([
      {'z': 2},
      {'a': 'x'},
    ]);
    expect((result.type as StructType).fields.map((f) => f.name), ['z', 'a']);
  });
  test('mixed numeric inference rejects lossy integer conversion', () {
    expect(() => array([9007199254740993, 1.0]), throwsArgumentError);
    expect(array([1, 1.5])[0].asDart(), 1.0);
  });
  test('extension construction encodes native storage values losslessly', () {
    final type = extension('binding.counter', int64(), metadata: 'v1');
    final values = array([1, null, 3], type: type);
    expect(values.toDartList(), [1, null, 3]);
    expect(values.type, type);
    values.validate(full: true);
  });
  test('typed scalar construction retains half-float NaN payloads', () {
    final source = Array.fromBuffers(float16(), 2, [
      null,
      Buffer(Uint8List.fromList([1, 126, 0, 128])),
    ]);
    final rebuilt = array(source.scalars, type: source.type);
    expect(rebuilt[0].rawBits, BigInt.from(0x7e01));
    expect(rebuilt[1].rawBits, BigInt.from(0x8000));
    expect(array([scalar(null, type: int16())]).type, int16());
  });
  test('Arrow conversion failures expose actual exception categories', () {
    expect(() => array([128], type: int8()), throwsA(isA<ArrowInvalid>()));
    expect(() => chunkedArray([]), throwsA(isA<ArrowInvalid>()));
    expect(
      () => chunkedArray([
        array([1]),
        array(['x']),
      ]),
      throwsA(isA<ArrowTypeError>()),
    );
  });
  test('array dispatch reuses arrays and combines chunks with exact types', () {
    final source = array([1, null], type: int16());
    expect(identical(array(source), source), isTrue);
    expect(array(chunkedArray([source, source])).toDartList(), [
      1,
      null,
      1,
      null,
    ]);
    expect(scalar(source[0]).type, int16());
  });
}
