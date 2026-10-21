import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart' as pa;

Map<String, dynamic> object(Object? value) =>
    (value as Map).cast<String, dynamic>();
Map<String, Object?> describe(pa.DataType type) {
  Object? canonical(Object? raw) {
    if (raw is List) return raw.map(canonical).toList();
    if (raw is! Map) return raw;
    final result = <String, Object?>{
      for (final e in raw.entries)
        (e.key == 'dtype' ? 'type' : e.key as String): canonical(e.value),
    };
    if (result['kind'] == 'string') result['kind'] = 'utf8';
    if (result['kind'] == 'largeString') result['kind'] = 'largeUtf8';
    if (result['kind'] == 'datetime') result['kind'] = 'timestamp';
    if (result.containsKey('name') && result.containsKey('nullable')) {
      result.putIfAbsent('metadata', () => <String, Object?>{});
    }
    return result;
  }

  return (canonical(type.toJson()) as Map).cast<String, Object?>();
}

pa.DataType dtype(Object? spec) {
  if (spec is String) {
    return switch (spec) {
      'null' => pa.nullType(),
      'bool' => pa.boolType(),
      'int8' => pa.int8(),
      'int16' => pa.int16(),
      'int32' => pa.int32(),
      'int64' => pa.int64(),
      'uint8' => pa.uint8(),
      'uint16' => pa.uint16(),
      'uint32' => pa.uint32(),
      'uint64' => pa.uint64(),
      'float16' => pa.float16(),
      'float32' => pa.float32(),
      'float64' => pa.float64(),
      'string' => pa.string(),
      'binary' => pa.binary(),
      'date32' => pa.date32(),
      'date64' => pa.date64(),
      _ => throw StateError('Unknown fixture datatype $spec'),
    };
  }
  final args = spec as List;
  return switch (args[0]) {
    'list' => pa.listType(
      args[1] is Map
          ? pa.field(
              object(args[1])['name'] as String,
              dtype(object(args[1])['type']),
              nullable: object(args[1])['nullable'] as bool? ?? true,
            )
          : dtype(args[1]),
      listSize: args.length > 2 ? args[2] as int : -1,
    ),
    'struct' => pa.struct([
      for (final f in args[1] as List)
        pa.field(
          (f as List)[0] as String,
          dtype(f[1]),
          nullable: f.length > 2 ? f[2] as bool : true,
        ),
    ]),
    'dictionary' => pa.dictionary(dtype(args[1]), dtype(args[2])),
    'timestamp' => pa.timestamp(args[1] as String),
    'duration' => pa.duration(args[1] as String),
    'time32' => pa.time32(args[1] as String),
    'time64' => pa.time64(args[1] as String),
    'decimal128' => pa.decimal128(args[1] as int, args[2] as int),
    _ => throw StateError('Unknown fixture datatype $spec'),
  };
}

Object? native(Object? value) {
  if (value is List) return value.map(native).toList();
  if (value is! Map) return value;
  if (value.containsKey(r'$scalar')) return evaluate(object(value[r'$scalar']));
  if (value.containsKey(r'$bytes')) {
    return Uint8List.fromList((value[r'$bytes'] as List).cast<int>());
  }
  if (value.containsKey(r'$int')) return BigInt.parse(value[r'$int'] as String);
  if (value.containsKey(r'$temporal')) {
    final t = object(value[r'$temporal']);
    return pa.TemporalValue(
      BigInt.parse(t['counter'] as String),
      pa.TimeUnit.parse(t['unit'] as String),
      kind: 'timestamp',
    );
  }
  if (value.containsKey(r'$datetime')) {
    // A timezone-free reference timestamp maps to a UTC-based Dart instant;
    // the Arrow type retains whether a timezone annotation exists.
    return DateTime.parse('${value[r'$datetime']}Z');
  }
  if (value.containsKey(r'$decimal')) {
    final text = value[r'$decimal'] as String;
    final split = text.split('.');
    return pa.DecimalValue(
      BigInt.parse(split.join()),
      split.length == 1 ? 0 : split[1].length,
    );
  }
  if (value.containsKey(r'$float')) {
    final bits = value[r'$float'] as String;
    final data = ByteData(8);
    for (var i = 0; i < 8; i++) {
      data.setUint8(i, int.parse(bits.substring(i * 2, i * 2 + 2), radix: 16));
    }
    return data.getFloat64(0, Endian.big);
  }
  return {for (final e in value.entries) e.key as String: native(e.value)};
}

Object? normalized(Object? value) {
  if (value == null || value is bool || value is String) return value;
  if (value is int || value is BigInt) return {'integer': '$value'};
  if (value is double) {
    if (value.isNaN) return {'float64': 'nan'};
    final data = ByteData(8)..setFloat64(0, value, Endian.big);
    return {
      'float64': [
        for (var i = 0; i < 8; i++)
          data.getUint8(i).toRadixString(16).padLeft(2, '0'),
      ].join(),
    };
  }
  if (value is Uint8List) return {'bytes': value.toList()};
  if (value is pa.DecimalValue) {
    return {
      'decimal': {'unscaled': '${value.unscaled}', 'scale': value.scale},
    };
  }
  if (value is List) return value.map(normalized).toList();
  if (value is Map)
    return {for (final e in value.entries) e.key: normalized(e.value)};
  throw StateError('Unnormalized native value ${value.runtimeType}');
}

Object? logical(Object? value, pa.DataType type) {
  if (value == null) return null;
  if (type is pa.TimestampType) {
    BigInt counter;
    if (value is pa.TemporalValue) {
      counter = value.counter;
      if (value.unit != type.unit || value.timeZone != type.timeZone) {
        throw StateError('Temporal annotation mismatch');
      }
    } else if (value is DateTime) {
      final micros = BigInt.from(value.microsecondsSinceEpoch);
      counter = switch (type.unit) {
        pa.TimeUnit.second => micros ~/ BigInt.from(1000000),
        pa.TimeUnit.millisecond => micros ~/ BigInt.from(1000),
        pa.TimeUnit.microsecond => micros,
        pa.TimeUnit.nanosecond => micros * BigInt.from(1000),
      };
    } else {
      throw StateError('Timestamp was not converted losslessly');
    }
    return {
      'temporal': {'counter': '$counter', 'type': describe(type)},
    };
  }
  return normalized(value);
}

List<Object?>? metadata(Map? value) {
  if (value == null) return null;
  final entries = [
    for (final e in value.entries)
      [List<int>.from(e.key as Iterable), List<int>.from(e.value as Iterable)],
  ];
  entries.sort((a, b) {
    final x = a[0];
    final y = b[0];
    for (var i = 0; i < x.length && i < y.length; i++) {
      if (x[i] != y[i]) return x[i].compareTo(y[i]);
    }
    return x.length.compareTo(y.length);
  });
  return entries;
}

Object? output(Object? value) {
  if (value is pa.Scalar) {
    return {
      'kind': 'Scalar',
      'type': describe(value.type),
      'isValid': value.isValid,
      'value': logical(value.asDart(), value.type),
      if (value.type is pa.FloatingType && value.isValid)
        'rawBits': value.rawBits!
            .toRadixString(16)
            .padLeft((value.type as pa.FloatingType).bitWidth ~/ 4, '0'),
      if (value is pa.DictionaryScalar) ...{
        'index': output(value.index),
        'dictionaryValue': output(value.value),
      },
    };
  }
  if (value is pa.Array || value is pa.ChunkedArray) {
    final dynamic a = value;
    final pa.DataType type = a.type as pa.DataType;
    final values = a.toDartList() as List;
    final scalars = [for (var i = 0; i < a.length; i++) output(a[i])];
    final viewed = (a.scalars as Iterable<pa.Scalar>).map(output).toList();
    if (!equivalent(viewed, scalars)) {
      throw StateError('Scalar view differs from typed scalar indexing');
    }
    return {
      'kind': value is pa.Array ? 'Array' : 'ChunkedArray',
      'type': describe(type),
      'length': a.length,
      'nullCount': a.nullCount,
      'values': [for (final v in values) logical(v, type)],
      'scalars': scalars,
      if (value is pa.ChunkedArray) 'chunks': value.chunks.map(output).toList(),
    };
  }
  if (value is pa.Field) {
    return {
      'name': value.name,
      'type': describe(value.type),
      'nullable': value.nullable,
      'metadata': metadata(value.metadata),
    };
  }
  if (value is pa.Schema) {
    return {
      'fields': value.fields.map(output).toList(),
      'metadata': metadata(value.metadata),
    };
  }
  if (value is pa.RecordBatch || value is pa.Table) {
    final dynamic tab = value;
    return {
      'kind': value is pa.Table ? 'Table' : 'RecordBatch',
      'numRows': tab.numRows,
      'numColumns': tab.numColumns,
      'schema': output(tab.schema),
      'columns': (tab.columns as List).map(output).toList(),
      'rows': normalized(tab.toDartList()),
    };
  }
  if (value is List) return value.map(output).toList();
  return normalized(value);
}

Map<Object, Object>? inputMetadata(Map<String, dynamic> e) =>
    !e.containsKey('metadata')
    ? null
    : {
        for (final pair in e['metadata'] as List)
          Uint8List.fromList((pair[0] as List).cast<int>()): Uint8List.fromList(
            (pair[1] as List).cast<int>(),
          ),
      };

class ApiFailure implements Exception {
  ApiFailure(this.category, this.cause);
  final String category;
  final Object cause;
}

String category(Object error) {
  if (error is pa.ArrowTypeError || error is TypeError) return 'type';
  if (error is pa.ArrowInvalid || error is FormatException) return 'conversion';
  if (error is RangeError) return 'range';
  if (error is ArgumentError) return 'argument';
  throw error;
}

Object? evaluate(Map<String, dynamic> e) {
  try {
    return evaluateOperation(e);
  } on ApiFailure {
    rethrow;
  } on Object catch (error) {
    throw ApiFailure(category(error), error);
  }
}

Object? evaluateOperation(Map<String, dynamic> e) {
  final op = e['op'] as String;
  switch (op) {
    case 'array':
      final values = e.containsKey('source')
          ? evaluate(object(e['source']))
          : native(e['values']);
      return pa.array(
        e['iterator'] == true ? (values as List).map((v) => v) : values!,
        type: e.containsKey('type') ? dtype(e['type']) : null,
        mask: (e['mask'] as List?)?.cast<bool>(),
        size: e['size'] as int?,
        safe: e['safe'] as bool? ?? true,
      );
    case 'scalar':
      return pa.scalar(
        e.containsKey('source')
            ? evaluate(object(e['source']))
            : native(e['value']),
        type: e.containsKey('type') ? dtype(e['type']) : null,
      );
    case 'rawHalf':
      return pa.Array.fromBuffers(pa.float16(), 2, [
        pa.Buffer(Uint8List.fromList([1])),
        pa.Buffer(Uint8List.fromList([1, 126, 0, 0])),
      ]);
    case 'dictionary':
      return pa.Array.fromDictionary(
        evaluate(object(e['indices'])) as pa.Array,
        evaluate(object(e['dictionary'])) as pa.Array,
      );
    case 'chunked':
      return pa.chunkedArray([
        for (final c in e['chunks'] as List) evaluate(object(c)) as pa.Array,
      ], type: e.containsKey('type') ? dtype(e['type']) : null);
    case 'field':
      return pa.field(
        e['name'] as String,
        dtype(e['type']),
        nullable: e['nullable'] as bool? ?? true,
        metadata: inputMetadata(e),
      );
    case 'schema':
      return pa.schema([
        for (final f in e['fields'] as List) evaluate(object(f)) as pa.Field,
      ], metadata: inputMetadata(e));
    case 'batch':
    case 'table':
      final raw = e['data'];
      final Object data = raw is Map
          ? {
              for (final entry in raw.entries)
                entry.key as String: evaluate(object(entry.value)),
            }
          : [for (final c in raw as List) evaluate(object(c))];
      final schema = e.containsKey('schema')
          ? evaluate(object(e['schema'])) as pa.Schema
          : null;
      final names = (e['names'] as List?)?.cast<String>();
      return op == 'batch'
          ? pa.recordBatch(
              data,
              names: names,
              schema: schema,
              metadata: inputMetadata(e),
            )
          : pa.table(
              data,
              names: names,
              schema: schema,
              metadata: inputMetadata(e),
            );
  }
  final dynamic source = evaluate(object(e['source']));
  if (op == 'validateFull') {
    source.validate(full: true);
    return source;
  }
  if (op == 'scalarCompare') {
    final other = evaluate(object(e['other'])) as pa.Scalar;
    final scalar = source as pa.Scalar;
    final equal = scalar.equals(other);
    return {
      'equals': equal,
      'operatorEquals': scalar == other,
      'equalHash': equal ? scalar.hashCode == other.hashCode : null,
    };
  }
  return switch (op) {
    'index' => source[e['index'] as int],
    'slice' => source.slice(e['offset'] as int? ?? 0, e['length'] as int?),
    'cast' => source.cast(dtype(e['type']), safe: e['safe'] as bool? ?? true),
    'combine' => source.combineChunks(),
    'batches' => source.toBatches(maxChunkSize: e['maxChunkSize'] as int?),
    'column' => source.column(e['index']),
    'fieldIndex' => source.getFieldIndex(e['name'] as String),
    'allFieldIndices' => source.getAllFieldIndices(e['name'] as String),
    'lookup' => source.field(e['name'] as String),
    'arrayEquals' => source.equals(evaluate(object(e['other']))),
    'isValid' => source.isValid(),
    'isNull' => source.isNull(nanIsNull: e['nanIsNull'] as bool? ?? false),
    'scalarValue' => source.value,
    'equals' => source.equals(
      evaluate(object(e['other'])),
      checkMetadata: e['checkMetadata'] as bool? ?? false,
    ),
    'select' => source.select((e['columns'] as List).cast<Object>()),
    _ => throw StateError('Unknown expression $op'),
  };
}

bool equivalent(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && equivalent(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => equivalent(a[i], b[i]));
  }
  return a == b;
}

List<Map<String, Object?>> probe(Map<String, dynamic> fixture) {
  if (object(fixture['producer'])['version'] != '26.0.0') {
    throw StateError('Expected pinned PyArrow 26.0.0 fixture');
  }
  return [for (final raw in fixture['cases'] as List) runCase(object(raw))];
}

Map<String, Object?> runCase(Map<String, dynamic> c) {
  try {
    Object actual;
    String? cause;
    try {
      actual = {'ok': output(evaluate(object(c['input'])))};
    } on ApiFailure catch (failure) {
      actual = {'error': failure.category};
      cause = '${failure.cause}';
    }
    final matches = equivalent(actual, c['expected']);
    return {
      'id': c['id'],
      'status': matches ? 'pass' : 'fail',
      if (!matches) ...{
        'expected': c['expected'],
        'actual': actual,
        if (cause != null) 'cause': cause,
      },
    };
  } on Object catch (error, stack) {
    return {'id': c['id'], 'status': 'fail', 'detail': '$error\n$stack'};
  }
}

void main(List<String> args) {
  String option(String name, String fallback) {
    final i = args.indexOf(name);
    return i < 0 ? fallback : args[i + 1];
  }

  final path = option(
    '--fixtures',
    'test/conformance/fixtures/api_pyarrow.json',
  );
  final results = probe(object(jsonDecode(File(path).readAsStringSync())));
  final failed = results.where((r) => r['status'] == 'fail').length;
  final report = {
    'producer': 'PyArrow 26.0.0 public API',
    'passed': results.length - failed,
    'failed': failed,
    'cases': results,
  };
  final text = '${const JsonEncoder.withIndent('  ').convert(report)}\n';
  if (args.contains('--output')) {
    File(option('--output', '')).writeAsStringSync(text);
  } else {
    stdout.write(text);
  }
  if (failed != 0) exitCode = 1;
}
