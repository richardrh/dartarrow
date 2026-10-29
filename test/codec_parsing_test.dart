import 'dart:convert';

import 'package:dartaframes_arrow/arrow.dart' as pa;
import 'package:dartaframes_arrow/json.dart';
import 'package:test/test.dart';

const codec = OwnedBatchJsonCodec();

String batchJson(Map<String, Object?> dtype, List<Object?> values) =>
    jsonEncode({
      'schema': {
        'fields': [
          {'name': 'c', 'dtype': dtype, 'nullable': true},
        ],
      },
      'length': values.length,
      'columns': [
        {
          'name': 'c',
          'dtype': dtype,
          'validity': [for (final v in values) v != null],
          'values': values,
        },
      ],
    });

pa.Scalar decodeOne(Map<String, Object?> dtype, Object? value) =>
    codec.decode(batchJson(dtype, [value])).column(0)[0];

Matcher get rejects => throwsA(isA<FormatException>());

void main() {
  group('canonical decimal integers', () {
    const int64 = {'kind': 'int64'};
    test('accepts canonical forms', () {
      for (final raw in ['0', '-1', '42', '-9223372036854775808']) {
        expect(decodeOne(int64, raw).value, int.parse(raw));
      }
    });

    test('rejects non-canonical forms', () {
      for (final raw in [
        '0x10',
        ' 5',
        '5 ',
        '5\n',
        '5\r\n',
        '+5',
        '05',
        '-0',
        '',
        '-',
        '1e3',
        '1.0',
        '١',
      ]) {
        expect(() => decodeOne(int64, raw), rejects, reason: raw);
      }
    });

    test('rejects non-string numbers', () {
      expect(() => decodeOne(int64, 5), rejects);
    });

    test('rejects over-long strings before parsing', () {
      final huge = '9' * 400000;
      final watch = Stopwatch()..start();
      expect(() => decodeOne(int64, huge), rejects);
      expect(() => decodeOne({'kind': 'uint8'}, '1' * 80), rejects);
      expect(watch.elapsedMilliseconds, lessThan(200));
    });

    test('applies to every BigInt-carrying value kind', () {
      final cases = <Map<String, Object?>, Object?>{
        {'kind': 'datetime', 'unit': 'seconds'}: '+1',
        {'kind': 'duration', 'unit': 'seconds'}: '0x1',
        {'kind': 'date', 'unit': 'days'}: '01',
        {'kind': 'time', 'unit': 'seconds'}: ' 1',
        {'kind': 'decimal', 'precision': 5, 'scale': 0}: {'unscaled': '+12'},
        {'kind': 'interval', 'unit': 'monthDayNano'}: {
          'months': 0,
          'days': 0,
          'nanoseconds': '0x10',
        },
      };
      cases.forEach((dtype, raw) {
        expect(() => decodeOne(dtype, raw), rejects, reason: '$dtype');
      });
      expect(
        () => decodeOne(
          {'kind': 'decimal', 'precision': 76, 'scale': 0, 'bitWidth': 256},
          {'unscaled': '9' * 400000},
        ),
        rejects,
      );
    });

    test('decimal256 and int bounds still round-trip at the limit', () {
      final max76 = '9' * 76;
      final decimal = {
        'kind': 'decimal',
        'precision': 76,
        'scale': 0,
        'bitWidth': 256,
      };
      expect(
        decodeOne(decimal, {'unscaled': '-$max76'}).value,
        pa.DecimalValue(BigInt.parse('-$max76'), 0),
      );
      final min128 = (-(BigInt.one << 127)).toString();
      expect(decodeOne({'kind': 'int128'}, min128).value, BigInt.parse(min128));
    });

    test('dictionary index must be canonical', () {
      final json = jsonDecode(
        batchJson(
          {
            'kind': 'dictionary',
            'indexType': {'kind': 'int8'},
            'valueType': {'kind': 'string'},
          },
          ['00'],
        ),
      ) as Map<String, Object?>;
      ((json['columns']! as List).single as Map)['dictionary'] = {
        'dtype': {'kind': 'string'},
        'validity': [true],
        'values': ['a'],
      };
      expect(() => codec.fromJson(json), rejects);
    });
  });

  group('floatBits', () {
    test('requires exactly bitWidth/4 hex digits', () {
      for (final (kind, bits) in [
        ('float16', '123\n'),
        ('float64', '0'),
        ('float32', '03f800000'),
        ('float16', '+3c0'),
        ('float16', '0x3c'),
        ('float64', '0' * 100000),
      ]) {
        expect(
          () => decodeOne({'kind': kind}, {'floatBits': bits}),
          rejects,
          reason: bits,
        );
      }
    });

    test('round-trips exact NaN payload and signed zero', () {
      for (final (kind, bits) in [
        ('float16', '7e01'),
        ('float32', '80000000'),
        ('float64', '7ff8000000000001'),
        ('float64', 'FFF0000000000000'),
      ]) {
        final value = decodeOne({'kind': kind}, {'floatBits': bits});
        expect(value.rawBits, BigInt.parse(bits, radix: 16));
      }
    });

    test('encoder output is accepted by the strict decoder', () {
      final batch = pa.RecordBatch.fromArrays(
        [
          pa.array([0.0, -0.0], type: pa.float64()),
        ],
        names: ['c'],
      );
      final decoded = codec.decode(codec.encode(batch));
      expect(decoded.column(0)[1].rawBits, BigInt.one << 63);
    });
  });
}
