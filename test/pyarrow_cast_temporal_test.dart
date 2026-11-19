import 'package:dartarrow/arrow.dart' as pa;
import 'package:test/test.dart';

List<Object?> _counters(pa.Array array) => [
  for (var i = 0; i < array.length; i++) array[i].value,
];

List<Object?> _strings(pa.Array array) => array.cast(pa.string()).toDartList();

void main() {
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
