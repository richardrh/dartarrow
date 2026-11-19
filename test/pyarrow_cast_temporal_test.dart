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

  // Expected values: PyArrow 26.0.0 (ArrowNotImplementedError / ArrowInvalid).
  group('cast validation', () {
    test('counter reinterpretations are not implemented', () {
      expect(
        () => pa.array([5], type: pa.time32('s')).cast(pa.timestamp('s')),
        throwsUnsupportedError,
      );
      expect(
        () => pa.array([5], type: pa.duration('s')).cast(pa.timestamp('s')),
        throwsUnsupportedError,
      );
      expect(
        () => pa.array([5], type: pa.timestamp('s')).cast(pa.duration('s')),
        throwsUnsupportedError,
      );
    });

    test('string to integer accepts only Arrow spellings', () {
      expect(
        pa.array(['-5', '007', '0x10', '0XfF']).cast(pa.int64()).toDartList(),
        [-5, 7, 16, 255],
      );
      expect(pa.array(['0xff', '0x80']).cast(pa.int8()).toDartList(), [
        -1,
        -128,
      ]);
      expect(pa.array(['255']).cast(pa.uint8()).toDartList(), [255]);
      for (final (text, type) in [
        (' 12 ', pa.int64()),
        ('+5', pa.int64()),
        ('', pa.int64()),
        ('-0x10', pa.int64()),
        ('0x0010', pa.int8()),
        ('128', pa.int8()),
        ('-0', pa.uint8()),
      ]) {
        expect(
          () => pa.array([text]).cast(type, safe: false),
          throwsA(isA<pa.ArrowInvalid>()),
          reason: text,
        );
      }
    });

    test('string to float accepts only Arrow spellings', () {
      final parsed = pa
          .array([
            '+2.5',
            '1e3',
            '.5',
            '5.',
            'inf',
            '-inf',
            'Infinity',
            '-INF',
            '1e400',
          ])
          .cast(pa.float64())
          .toDartList();
      expect(parsed, [
        2.5,
        1000.0,
        0.5,
        5.0,
        double.infinity,
        double.negativeInfinity,
        double.infinity,
        double.negativeInfinity,
        double.infinity,
      ]);
      final nans = pa.array(['nan', 'NaN', '-nan']).cast(pa.float64());
      expect(nans.toDartList().every((v) => (v as double).isNaN), isTrue);
      for (final text in [' 1.5', '1.5 ', '1,5', '0x10', '1e', 'infin']) {
        expect(
          () => pa.array([text]).cast(pa.float64()),
          throwsA(isA<pa.ArrowInvalid>()),
          reason: text,
        );
      }
    });

    test('dictionary cast honours the requested index type', () {
      final small = pa
          .array(List.generate(128, (i) => i))
          .cast(pa.dictionary(pa.int8(), pa.int64()));
      expect(small.type, pa.dictionary(pa.int8(), pa.int64()));
      expect(
        () => pa
            .array(List.generate(200, (i) => i))
            .cast(pa.dictionary(pa.int8(), pa.int64())),
        throwsA(isA<pa.ArrowInvalid>()),
      );
    });
  });

  // Expected values: PyArrow 26.0.0 `pa.array([1], type=pa.string())` raises
  // ArrowTypeError.
  group('host type mismatch', () {
    test('wrong host kind for an explicit type is an ArrowTypeError', () {
      expect(
        () => pa.array([1], type: pa.string()),
        throwsA(isA<pa.ArrowTypeError>()),
      );
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

    // PyArrow 26: pa.array([1e300]).type, [-1e300], [1e19], [1e20] -> double.
    // On JS platforms the literal 1e19 is the integer 10^19 (< 2^64), the same
    // value as BigInt 10^19 on the VM, which is out of int64 range and raises
    // ArrowInvalid there too (PyArrow raises OverflowError for 10**19).
    test('whole doubles outside the 64-bit domain infer float64', () {
      for (final v in [1e300, -1e300, 1e20]) {
        expect(pa.array([v]).type, pa.float64(), reason: '$v');
        expect(pa.scalar(v).type, pa.float64(), reason: '$v');
      }
      if (identical(0, 0.0)) {
        expect(() => pa.array([1e19]), throwsA(isA<pa.ArrowInvalid>()));
        expect(
          () => pa.array([BigInt.parse('10000000000000000000')]),
          throwsA(isA<pa.ArrowInvalid>()),
        );
      } else {
        expect(pa.array([1e19]).type, pa.float64());
      }
    });
  });

  // Expected values: PyArrow 26.0.0 `pa.scalar(c, type).as_py()` where Python
  // datetime can hold it (timestamp[us] ±(2**53+1) -> 2255-06-05
  // 23:47:34.740993 / 1684-07-28 00:12:25.259007, -1 -> 1969-12-31
  // 23:59:59.999999, timestamp[s] -62135596800 -> 0001-01-01); DateTime's
  // extremes (±8.64e15 ms) lie beyond Python's range.
  group('temporal host conversion is platform independent', () {
    test('representable values become equal UTC DateTimes', () {
      for (final (type, counter, expected) in [
        (pa.date32(), '-100000000', DateTime.utc(-271821, 4, 20)),
        (pa.date32(), '100000000', DateTime.utc(275760, 9, 13)),
        (pa.date64(), '-8640000000000000', DateTime.utc(-271821, 4, 20)),
        (pa.date64(), '8640000000000000', DateTime.utc(275760, 9, 13)),
        (
          pa.timestamp('us'),
          '9007199254740993',
          DateTime.utc(2255, 6, 5, 23, 47, 34, 740, 993),
        ),
        (
          pa.timestamp('us'),
          '-9007199254740993',
          DateTime.utc(1684, 7, 28, 0, 12, 25, 259, 7),
        ),
        (
          pa.timestamp('us'),
          '-1',
          DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 999),
        ),
        (
          pa.timestamp('ns'),
          '-1000',
          DateTime.utc(1969, 12, 31, 23, 59, 59, 999, 999),
        ),
        (pa.timestamp('s'), '-62135596800', DateTime.utc(1)),
        (
          pa.timestamp('us'),
          '8639999999999999999',
          DateTime.utc(275760, 9, 12, 23, 59, 59, 999, 999),
        ),
      ]) {
        final value = pa.scalar(BigInt.parse(counter), type: type).asDart();
        expect(value, isA<DateTime>(), reason: '$type $counter');
        expect((value as DateTime).isUtc, isTrue);
        expect(value, expected, reason: '$type $counter');
      }
    });

    test('unrepresentable values stay TemporalValue', () {
      for (final (type, counter) in [
        (pa.timestamp('us'), '8640000000000000001'),
        (pa.timestamp('ns'), '-1'),
        (pa.date32(), '100000001'),
      ]) {
        expect(
          pa.scalar(BigInt.parse(counter), type: type).asDart(),
          isA<pa.TemporalValue>(),
          reason: '$type $counter',
        );
      }
    });
  });
}
