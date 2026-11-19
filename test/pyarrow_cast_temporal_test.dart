import 'package:dartarrow/arrow.dart' as pa;
import 'package:test/test.dart';

List<Object?> _counters(pa.Array array) => [
  for (var i = 0; i < array.length; i++) array[i].value,
];

List<Object?> _strings(pa.Array array) => array.cast(pa.string()).toDartList();

void main() {
  // Expected values: PyArrow 26.0.0, `pa.array([...], type).cast(pa.string())`.
  group('decimal to string', () {
    test('uses Arrow decimal text for every width', () {
      final values = [
        pa.DecimalValue(123, 2),
        pa.DecimalValue(50000, 2),
        pa.DecimalValue(-5, 2),
        pa.DecimalValue(0, 2),
      ];
      for (final type in [
        pa.decimal32(5, 2),
        pa.decimal64(10, 2),
        pa.decimal128(10, 2),
        pa.decimal256(10, 2),
      ]) {
        expect(_strings(pa.array(values, type: type)), [
          '1.23',
          '500.00',
          '-0.05',
          '0.00',
        ]);
      }
    });

    test('switches to scientific notation like Arrow', () {
      expect(
        _strings(
          pa.array([
            pa.DecimalValue(5, -2),
            pa.DecimalValue(-12, -2),
            pa.DecimalValue(0, -2),
          ], type: pa.decimal128(5, -2)),
        ),
        ['5E+2', '-1.2E+3', '0E+2'],
      );
      expect(
        _strings(
          pa.array([
            pa.DecimalValue(1, 7),
            pa.DecimalValue(123, 7),
            pa.DecimalValue(10, 7),
            pa.DecimalValue(-1, 7),
          ], type: pa.decimal256(10, 7)),
        ),
        ['1E-7', '0.0000123', '0.0000010', '-1E-7'],
      );
      expect(
        _strings(
          pa.array([
            pa.DecimalValue(5, 0),
            pa.DecimalValue(-17, 0),
          ], type: pa.decimal32(5, 0)),
        ),
        ['5', '-17'],
      );
      expect(pa.DecimalValue(123, 2).toString(), 'DecimalValue(123, 2)');
    });
  });

  // Expected values: PyArrow 26.0.0 `pa.scalar(-0.0)` / `pa.scalar(-inf)`
  // infer double; web-relevant, also hold on the VM.
  group('host numbers', () {
    test('non-finite numbers and negative zero infer float64', () {
      expect(pa.scalar(double.negativeInfinity).type, pa.float64());
      expect(pa.scalar(double.infinity).type, pa.float64());
      expect(pa.scalar(-0.0).type, pa.float64());
      expect(pa.scalar(-0.0).asDart(), isA<double>());
      expect((pa.scalar(-0.0).asDart() as double).isNegative, isTrue);
      expect(pa.array([1, double.nan]).type, pa.float64());
    });

    test('integers beyond 2^53 survive host conversion exactly', () {
      final big = BigInt.parse('1152921504606846977');
      expect(pa.array([big]).toDartList().single.toString(), big.toString());
      final ns = BigInt.parse('1600000000000000001');
      expect(
        pa.scalar(ns, type: pa.timestamp('ns')).value.toString(),
        ns.toString(),
      );
    });
  });
}
