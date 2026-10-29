import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/json.dart';

Map<String, dynamic> object(Object? value) =>
    (value as Map).cast<String, dynamic>();

final _backing = Expando<List<Uint8List?>>();
Array importArray(Map<String, dynamic> a) {
  final bytes = [
    for (final b in a['buffers'] as List)
      b == null ? null : base64Decode(b as String),
  ];
  final result = Array.fromBuffers(
    DataType.fromJson(object(a['descriptor'])),
    a['length'] as int,
    [for (final b in bytes) b == null ? null : Buffer(b)],
    offset: a['offset'] as int,
    nullCount: a['nullCount'] as int,
    children: [for (final c in a['children'] as List) importArray(object(c))],
    dictionary: a['dictionary'] == null
        ? null
        : importArray(object(a['dictionary'])),
  );
  _backing[result] = bytes;
  return result;
}

void checkSharedBuffers(Array original, Array sliced) {
  final before = original.buffers();
  final after = sliced.buffers();
  check(before.length == after.length, 'shared buffer count');
  final backing = _backing[original]!;
  for (var i = 0; i < backing.length; i++) {
    final bytes = backing[i];
    if (bytes == null) {
      check(after[i] == null, 'shared null buffer');
    } else if (bytes.isNotEmpty) {
      final old = bytes[0];
      try {
        bytes[0] ^= 255;
        check(
          after[i]!.bytes[0] == bytes[0],
          'slice must alias borrowed buffer $i',
        );
      } finally {
        bytes[0] = old;
      }
    }
  }
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Object? oracle(Object? raw, DataType type, {Array? context}) {
  if (raw == null) return null;
  final v = object(raw);
  if (type is RunEndEncodedType) {
    return oracle(raw, type.valuesField.type, context: context?.children[1]);
  }
  switch (v['tag']) {
    case 'interval':
      final c = (v['components'] as List).cast<int>();
      return switch ((type as IntervalType).unit) {
        IntervalUnit.yearMonth => IntervalValue.yearMonth(c[0]),
        IntervalUnit.dayTime => IntervalValue.dayTime(c[0], c[1]),
        IntervalUnit.monthDayNano => IntervalValue.monthDayNano(
          c[0],
          c[1],
          c[2],
        ),
      };
    case 'map':
      final map = type as MapType;
      return [
        for (final e in v['entries'] as List)
          (
            oracle(object(e)['key'], map.keyField.type),
            oracle(object(e)['value'], map.valueField.type),
          ),
      ];
    case 'union':
      final union = type as UnionType;
      final child = union.typeIds.indexOf(v['typeCode'] as int);
      return oracle(
        v['value'],
        union.fields[child].type,
        context: context?.children[child],
      );
    case 'integer':
      return BigInt.parse(v['value'] as String);
    case 'decimal':
      return DecimalValue(
        BigInt.parse(v['value'] as String),
        (type as DecimalType).scale,
      );
    case 'temporal':
      return BigInt.parse(v['value'] as String);
    case 'dictionary':
      final index = int.parse(v['value'] as String);
      return context!.dictionary![index].value;
    case 'extension':
      return oracle(
        v['storage'],
        (type as ExtensionType).storageType,
        context: context,
      );
    case 'float':
      final bits = BigInt.parse(v['bits'] as String, radix: 16);
      final width = v['width'] as int;
      if (width == 16) {
        final b = bits.toInt();
        final exp = (b >> 10) & 31;
        final frac = b & 1023;
        if (exp == 31)
          return frac == 0
              ? (b & 32768 == 0 ? double.infinity : double.negativeInfinity)
              : double.nan;
        final magnitude = exp == 0
            ? frac * math.pow(2, -24).toDouble()
            : (1024 + frac) * math.pow(2, exp - 25).toDouble();
        return b & 32768 == 0 ? magnitude : -magnitude;
      }
      final data = ByteData(width ~/ 8);
      for (var i = 0; i < width ~/ 8; i++)
        data.setUint8(i, ((bits >> (i * 8)) & BigInt.from(255)).toInt());
      return width == 32
          ? data.getFloat32(0, Endian.little)
          : data.getFloat64(0, Endian.little);
    case 'boolean':
    case 'string':
      return v['value'];
    case 'binary':
      return Uint8List.fromList((v['value'] as List).cast<int>());
    case 'list':
      final child = type is ListType
          ? type.field.type
          : (type as FixedSizeListType).field.type;
      return [
        for (final x in v['values'] as List)
          oracle(x, child, context: context?.children.single),
      ];
    case 'struct':
      final fields = (type as StructType).fields;
      final rawFields = v['fields'] as List;
      return {
        for (var i = 0; i < fields.length; i++)
          fields[i].name: oracle(
            object(rawFields[i])['value'],
            fields[i].type,
            context: context?.children[i],
          ),
      };
    default:
      throw StateError('No independent oracle for ${v['tag']}');
  }
}

bool equalValue(Object? actual, Object? expected) {
  if (actual is DictionaryScalar) return equalValue(actual.asDart(), expected);
  if (actual is Scalar) return equalValue(actual.value, expected);
  if (actual is TemporalValue)
    return expected is BigInt && actual.counter == expected;
  if (actual is int && expected is BigInt)
    return BigInt.from(actual) == expected;
  if (actual is double && expected is double) {
    if (actual.isNaN || expected.isNaN) return actual.isNaN && expected.isNaN;
    if (actual == 0 && expected == 0)
      return actual.isNegative == expected.isNegative;
    return actual == expected;
  }
  if (actual is (Object?, Object?) && expected is (Object?, Object?))
    return equalValue(actual.$1, expected.$1) &&
        equalValue(actual.$2, expected.$2);
  if (actual is List && expected is List)
    return actual.length == expected.length &&
        List.generate(
          actual.length,
          (i) => i,
        ).every((i) => equalValue(actual[i], expected[i]));
  if (actual is Map && expected is Map)
    return actual.length == expected.length &&
        actual.keys.every(
          (k) => expected.containsKey(k) && equalValue(actual[k], expected[k]),
        );
  return actual == expected;
}

void checkValues(Array a, List expected, String label) {
  check(a.length == expected.length, '$label length');
  // Unions and run-end encoded arrays have no validity bitmap: PyArrow
  // reports a zero null count while scalars expose child validity.
  final storage = a.type is ExtensionType
      ? (a.type as ExtensionType).storageType
      : a.type;
  check(
    a.nullCount ==
        (storage is UnionType || storage is RunEndEncodedType
            ? 0
            : expected.where((v) => v == null).length),
    '$label null count',
  );
  for (var i = 0; i < expected.length; i++) {
    final s = a[i];
    final raw = expected[i];
    check(
      s.type == a.type && s.isValid == (raw != null),
      '$label typed validity[$i]',
    );
    if (raw != null && object(raw)['tag'] == 'float') {
      check(
        s.rawBits == BigInt.parse(object(raw)['bits'] as String, radix: 16),
        '$label exact float bits[$i]',
      );
    }
    if (s is DictionaryScalar && raw != null) {
      check(
        equalValue(s.index.value, BigInt.parse(object(raw)['value'] as String)),
        '$label dictionary index[$i]',
      );
      check(
        equalValue(s.asDart(), oracle(raw, a.type, context: a)),
        '$label decoded dictionary[$i]',
      );
    } else {
      check(
        equalValue(
          s is DictionaryScalar ? s.asDart() : s.value,
          oracle(raw, a.type, context: a),
        ),
        '$label value[$i] differs from independent oracle',
      );
    }
  }
}

List<Map<String, Object?>> probe(Map<String, dynamic> manifest) {
  check(
    object(manifest['producer'])['version'] == '26.0.0',
    'Pinned PyArrow 26 required',
  );
  final results = <Map<String, Object?>>[];
  for (final raw in manifest['cases'] as List) {
    final c = object(raw);
    final id = c['id'] as String;
    var status = 'pass';
    var detail =
        'Independent physical values, scalar validity, float bits, dictionary indices/decoding, suffix slices, owned construction/bytes/JSON';
    try {
      if (c['missing'] == true) {
        try {
          final decoded = DataType.fromJson(object(c['descriptor']));
          if (jsonEncode(decoded.toJson()) == jsonEncode(c['descriptor'])) {
            throw StateError(
              'Declared missing type now exists: promote with full oracle coverage',
            );
          }
          status = 'missing';
          detail = 'No faithful descriptor for declared missing datatype';
        } on FormatException {
          status = 'missing';
          detail = 'Declared absent datatype rejected';
        }
      } else {
        final expected = c['expected'] as List;
        final a = importArray(object(c['array']));
        checkValues(a, expected, 'foreign');
        check(a.type == DataType.fromJson(object(c['descriptor'])), 'datatype');
        checkValues(
          importArray({...object(c['array']), 'nullCount': -1}),
          expected,
          'unknown null count',
        );
        for (var start = 0; start <= a.length; start++) {
          final sliced = a.slice(start);
          checkValues(sliced, expected.sublist(start), 'slice $start');
          checkSharedBuffers(a, sliced);
        }
        if (!id.startsWith('list.dictionary')) {
          final owned = a.type is DictionaryType
              ? Array.fromDictionary(
                  array([
                    for (final v in expected)
                      v == null
                          ? null
                          : BigInt.parse(object(v)['value'] as String),
                  ], type: (a.type as DictionaryType).indexType),
                  a.dictionary!,
                  ordered: (a.type as DictionaryType).ordered,
                )
              : array([for (var i = 0; i < a.length; i++) a[i]], type: a.type);
          checkValues(owned, expected, 'owned');
          final buffers = owned.buffers();
          if (a.length > 0 &&
              a.offset == 0 &&
              a.nullCount == 0 &&
              a.children.isEmpty &&
              a.dictionary == null) {
            for (var i = 1; i < buffers.length; i++) {
              check(
                base64Encode(buffers[i]!.toBytes()) ==
                    base64Encode(a.buffers()[i]!.toBytes()),
                'owned physical buffer $i',
              );
            }
          }
          if (a.dictionary == null) {
            final schema = Schema(
              [Field('', a.type), Field('', a.type)],
              metadata: {'source': 'independent-pyarrow'},
            );
            final batch = RecordBatch.fromArrays([
              owned,
              owned,
            ], schema: schema);
            const codec = OwnedBatchJsonCodec();
            final decoded = codec.decode(codec.encode(batch));
            check(
              decoded.schema.equals(schema, checkMetadata: true),
              'duplicate names/schema metadata JSON',
            );
            checkValues(decoded.columns[0], expected, 'owned JSON');
          }
          for (final buffer in buffers) {
            if (buffer == null || buffer.size == 0) continue;
            var rejected = false;
            try {
              buffer.bytes[0] = 0;
            } on UnsupportedError {
              rejected = true;
            }
            check(rejected, 'owned buffers must be immutable');
          }
        }
      }
    } on Object catch (error, stack) {
      status = 'fail';
      detail = '$error\n$stack';
    }
    results.add({
      'id': id,
      'surface': 'dart',
      'status': status,
      'detail': detail,
    });
  }
  for (final raw in manifest['schemas'] as List? ?? []) {
    final c = object(raw);
    try {
      final schema = Schema.fromJson(object(c['schema']));
      check(
        schema.fields.length == 2 && schema.fields.every((f) => f.name.isEmpty),
        'duplicate empty names',
      );
      check(
        !schema.fields[0].nullable && schema.fields[1].nullable,
        'nullability',
      );
      check(
        equalValue(schema.fields[0].metadata?['field'], utf8.encode('value')) &&
            equalValue(schema.metadata?['source'], utf8.encode('pyarrow-26')),
        'metadata bytes',
      );
      check(
        Schema.fromJson(schema.toJson()).equals(schema, checkMetadata: true),
        'schema roundtrip',
      );
      results.add({
        'id': c['id'],
        'surface': 'dart',
        'status': 'pass',
        'detail': 'Independent schema order, names, nullability, byte metadata',
      });
    } on Object catch (error) {
      results.add({
        'id': c['id'],
        'surface': 'dart',
        'status': 'fail',
        'detail': '$error',
      });
    }
  }
  return results;
}

void main(List<String> args) {
  String option(String key, String fallback) {
    final i = args.indexOf(key);
    return i < 0 ? fallback : args[i + 1];
  }

  final manifest = object(
    jsonDecode(
      File(
        option(
          '--manifest',
          File.fromUri(Platform.script.resolve('fixtures/pyarrow.json')).path,
        ),
      ).readAsStringSync(),
    ),
  );
  final results = probe(manifest);
  final output = jsonEncode({'results': results});
  final path = option('--output', '');
  if (path.isEmpty) {
    stdout.writeln(output);
  } else {
    File(path).writeAsStringSync('$output\n');
  }
  if (results.any(
    (r) =>
        r['status'] == 'fail' ||
        (args.contains('--require-full') && r['status'] == 'missing'),
  ))
    exitCode = 1;
}
