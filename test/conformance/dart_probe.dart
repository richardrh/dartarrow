import 'dart:convert';
import 'dart:io';

import 'package:dartaframes_arrow/arrow.dart';

Map<String, dynamic> object(Object? value) =>
    (value as Map).cast<String, dynamic>();

ArrowArray importArray(Map<String, dynamic> a) => ArrowArray.fromBuffers(
  ArrowDataType.fromJson(object(a['descriptor'])),
  length: a['length'] as int,
  offset: a['offset'] as int,
  nullCount: a['nullCount'] as int,
  buffers: [
    for (final b in a['buffers'] as List)
      b == null ? null : base64Decode(b as String),
  ],
  children: [for (final c in a['children'] as List) importArray(object(c))],
  dictionary: a['dictionary'] == null
      ? null
      : importArray(object(a['dictionary'])),
);

ArrowValue? oracle(Object? raw) {
  if (raw == null) return null;
  final v = object(raw);
  return switch (v['tag']) {
    'integer' => ArrowIntegerValue(v['value'] as String),
    'decimal' => ArrowDecimalValue(v['value'] as String),
    'temporal' => ArrowTemporalValue(v['value'] as String),
    'dictionary' => ArrowDictionaryIndexValue(v['value'] as String),
    'extension' => ArrowExtensionValue(oracle(v['storage'])!),
    'float' => ArrowFloatingValue(
      v['width'] as int,
      BigInt.parse(v['bits'] as String, radix: 16),
    ),
    'boolean' => ArrowBooleanValue(v['value'] as bool),
    'string' => ArrowStringValue(v['value'] as String),
    'binary' => ArrowBinaryValue((v['value'] as List).cast<int>()),
    'list' => ArrowListValue([for (final x in v['values'] as List) oracle(x)]),
    'struct' => ArrowStructValue([
      for (final x in v['fields'] as List)
        ArrowStructEntry(
          object(x)['name'] as String,
          oracle(object(x)['value']),
        ),
    ]),
    _ => throw StateError('No independent value oracle for ${v['tag']}'),
  };
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

void checkValues(ArrowArray a, List<ArrowValue?> expected, String label) {
  check(a.length == expected.length, '$label length');
  check(
    a.nullCount == expected.where((v) => v == null).length,
    '$label null count',
  );
  for (var i = 0; i < expected.length; i++) {
    check(
      a[i] == expected[i],
      '$label value[$i] differs from independent oracle',
    );
    check(a.validity[i] == (expected[i] != null), '$label validity[$i]');
  }
}

List<Map<String, Object?>> probe(Map<String, dynamic> manifest) {
  check(
    object(manifest['producer'])['version'] == '26.0.0',
    'Fixtures require pinned PyArrow 26.0.0',
  );
  final results = <Map<String, Object?>>[];
  for (final raw in manifest['cases'] as List) {
    final c = object(raw);
    final id = c['id'] as String;
    final declaredMissing = c['missing'] == true;
    String status;
    String detail;
    if (declaredMissing) {
      // An absent descriptor must actually be rejected, not silently coerced.
      try {
        final t = ArrowDataType.fromJson(object(c['descriptor']));
        final normalized = t.toJson();
        if (c['descriptor'].toString() != normalized.toString()) {
          status = 'missing';
          detail =
              'No faithful datatype descriptor: input ${c['descriptor']}; decoded $normalized';
        } else {
          status = 'fail';
          detail = 'Inventory declares missing but descriptor now exists; add full oracle coverage';
        }
      } on FormatException catch (e) {
        status = 'missing';
        detail = 'Declared absent datatype rejected: $e';
      }
    } else {
      try {
        final expected = [for (final v in c['expected'] as List) oracle(v)];
        final a = importArray(object(c['array']));
        checkValues(a, expected, 'foreign');
        check(
          a.type == ArrowDataType.fromJson(object(c['descriptor'])),
          'datatype',
        );
        final unknownCount = object(c['array']);
        checkValues(
          importArray({...unknownCount, 'nullCount': -1}),
          expected,
          'unknown null count',
        );
        for (var start = 0; start <= a.length; start++) {
          final sliced = a.slice(start);
          checkValues(sliced, expected.sublist(start), 'slice $start');
          check(
            identical(sliced.buffers, a.buffers),
            'slice must share buffer list',
          );
        }
        // Nested dictionary construction has no dictionary-child parameter;
        // physical support is tested here, ownership gets a separate inventory row.
        if (!id.startsWith('list.dictionary')) {
          final owned = ArrowArray(a.type, expected, dictionary: a.dictionary);
          checkValues(owned, expected, 'owned');
          if (a.length > 0 &&
              a.offset == 0 &&
              a.nullCount == 0 &&
              a.children.isEmpty &&
              a.dictionary == null) {
            for (var i = 1; i < a.buffers.length; i++) {
              check(
                base64Encode(owned.buffers[i]!) == base64Encode(a.buffers[i]!),
                'owned physical buffer $i',
              );
            }
          }
          if (a.dictionary == null && !id.startsWith('list.dictionary')) {
            final schema = ArrowSchema(
              [ArrowField('', a.type), ArrowField('', a.type)],
              metadata: {'source': 'independent-pyarrow'},
            );
            final batch = RecordBatch(schema, [owned, owned]);
            const codec = OwnedBatchJsonCodec();
            final decoded = codec.decode(codec.encode(batch));
            check(
              decoded.schema == schema,
              'duplicate empty names/schema metadata roundtrip',
            );
            checkValues(decoded.columns[0], expected, 'owned JSON');
          }
          if (owned.buffers.length > 1 && owned.buffers[1]!.isNotEmpty) {
            var rejected = false;
            try {
              owned.buffers[1]![0] = 0;
            } on UnsupportedError {
              rejected = true;
            }
            check(rejected, 'owned buffers must be immutable');
          }
        }
        status = 'pass';
        detail = 'Independent PyArrow physical values, nulls, every suffix slice, borrowed nullCount; owned values/bytes/JSON where representable';
      } catch (e, st) {
        status = 'fail';
        detail = '$e\n$st';
      }
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
      final source = object(c['schema']);
      final schema = ArrowSchema.fromJson(source);
      check(
        schema.fields.length == 2 && schema.fields.every((f) => f.name.isEmpty),
        'duplicate empty field names',
      );
      check(
        !schema.fields[0].nullable && schema.fields[1].nullable,
        'independent nullability',
      );
      check(
        schema.fields[0].metadata['field'] == 'value' &&
            schema.metadata['source'] == 'pyarrow-26',
        'independent metadata',
      );
      check(
        ArrowSchema.fromJson(schema.toJson()) == schema,
        'schema roundtrip',
      );
      results.add({
        'id': c['id'],
        'surface': 'dart',
        'status': 'pass',
        'detail': 'PyArrow-produced schema field order, duplicate empty names, nullability and field/schema metadata',
      });
    } catch (e) {
      results.add({
        'id': c['id'],
        'surface': 'dart',
        'status': 'fail',
        'detail': '$e',
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
  final requireFull = args.contains('--require-full');
  if (results.any(
    (r) => r['status'] == 'fail' || (requireFull && r['status'] == 'missing'),
  )) {
    exitCode = 1;
  }
}
