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

  // Expected values: PyArrow 26.0.0 timestamp -> date32/date64 casts.
  group('timestamp to date', () {
    final seconds = pa.array([
      -1,
      -86400,
      -86401,
      0,
      86399,
    ], type: pa.timestamp('s'));

    test('floors to the day', () {
      expect(_counters(seconds.cast(pa.date32())), [-1, -1, -2, 0, 0]);
      expect(_counters(seconds.cast(pa.date64())), [
        -86400000,
        -86400000,
        -172800000,
        0,
        0,
      ]);
    });

    test('drops the time of day even when safe', () {
      final noon = pa.array([DateTime.utc(2020, 1, 1, 12)]);
      expect(noon.cast(pa.date32()).toDartList(), [DateTime.utc(2020)]);
      final ms = pa.array([
        DateTime.utc(2020, 1, 1, 12),
        DateTime.utc(1969, 12, 31, 23),
      ], type: pa.timestamp('ms'));
      expect(_counters(ms.cast(pa.date64())), [1577836800000, -86400000]);
    });

    test('uses the zone-local date for UTC names and fixed offsets', () {
      final early = DateTime.utc(2020, 1, 1, 3);
      expect(
        pa
            .array([early], type: pa.timestamp('us', tz: 'UTC'))
            .cast(pa.date32())
            .toDartList(),
        [DateTime.utc(2020)],
      );
      expect(
        pa
            .array([early], type: pa.timestamp('us', tz: 'Etc/GMT'))
            .cast(pa.date32())
            .toDartList(),
        [DateTime.utc(2020)],
      );
      final evening = DateTime.utc(2020, 1, 1, 20);
      expect(
        pa
            .array([evening], type: pa.timestamp('us', tz: '+05:30'))
            .cast(pa.date32())
            .toDartList(),
        [DateTime.utc(2020, 1, 2)],
      );
      expect(
        _counters(
          pa
              .array([1577905200], type: pa.timestamp('s', tz: '-08:00'))
              .cast(pa.date64()),
        ),
        [1577836800000],
      );
    });

    test('rejects zone names that need a time zone database', () {
      final ny = pa.array([
        DateTime.utc(2020, 1, 1, 3),
      ], type: pa.timestamp('us', tz: 'America/New_York'));
      expect(
        () => ny.cast(pa.date32()),
        throwsA(
          isA<UnsupportedError>().having(
            (e) => e.message,
            'message',
            contains('time zone database'),
          ),
        ),
      );
    });

    test('date64 to date32 keeps Arrow truncation semantics', () {
      final date64 = pa.array([86400001, -1], type: pa.date64());
      expect(() => date64.cast(pa.date32()), throwsA(isA<pa.ArrowInvalid>()));
      expect(_counters(date64.cast(pa.date32(), safe: false)), [1, 0]);
    });
  });

  // Expected values: PyArrow 26.0.0 `pa.array([datetime(...)], type=date32/64)`
  // for post-epoch values; pre-epoch date64 follows the calendar-date rule.
  group('DateTime to date', () {
    test('stores the DateTime calendar date', () {
      expect(
        _counters(pa.array([DateTime.utc(2020, 1, 1, 12)], type: pa.date64())),
        [1577836800000],
      );
      expect(
        pa.array([
          DateTime.utc(2020, 1, 1, 12),
        ], type: pa.date32()).toDartList(),
        [DateTime.utc(2020)],
      );
      expect(
        _counters(
          pa.array([DateTime.utc(1969, 12, 31, 23)], type: pa.date32()),
        ),
        [-1],
      );
      expect(
        _counters(
          pa.array([DateTime.utc(1969, 12, 31, 23)], type: pa.date64()),
        ),
        [-86400000],
      );
    });

    test('uses local DateTime fields, not the instant', () {
      final local = DateTime(2020, 1, 1, 23, 30);
      expect(pa.array([local], type: pa.date32()).toDartList(), [
        DateTime.utc(2020),
      ]);
    });

    test('raw date64 integers are stored unchanged', () {
      expect(_counters(pa.array([5], type: pa.date64())), [5]);
    });
  });

  // Expected values: PyArrow 26.0.0 float -> string casts.
  group('float to string', () {
    test('float64 matches Arrow formatting', () {
      expect(
        _strings(
          pa.array([
            1.0,
            double.nan,
            double.infinity,
            double.negativeInfinity,
            -0.0,
            1e15,
            1e16,
            123456789012345680.0,
            1e-5,
            1e-4,
            1e-7,
            1.5e300,
            5e-324,
            100.0,
            1234.5,
          ], type: pa.float64()),
        ),
        [
          '1',
          'nan',
          'inf',
          '-inf',
          '-0',
          '1e+15',
          '1e+16',
          '1.2345678901234568e+17',
          '0.00001',
          '0.0001',
          '1e-7',
          '1.5e+300',
          '5e-324',
          '100',
          '1234.5',
        ],
      );
    });

    test('float32 uses the shortest float32 round-trip digits', () {
      expect(
        _strings(
          pa.array([
            0.1,
            16777216.0,
            3.4028234663852886e38,
            1e-10,
            -20906.4375,
            482830.125,
            1e9,
            1e10,
          ], type: pa.float32()),
        ),
        [
          '0.1',
          '16777216',
          '3.4028235e+38',
          '1e-10',
          '-20906.438',
          '482830.12',
          '1000000000',
          '1e+10',
        ],
      );
    });

    test('float16 formats its exact value as a double', () {
      expect(_strings(pa.array([0.1, 65504.0], type: pa.float16())), [
        '0.0999755859375',
        '65504',
      ]);
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
