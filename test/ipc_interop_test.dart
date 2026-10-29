// Interoperability tests against independent PyArrow-generated fixtures.
//
// Fixtures and expectations live in test/conformance/fixtures/arrow_ipc and
// are produced by tool/conformance/arrow_ipc_interop.py with pyarrow==26.0.0
// (see that script for the canonical JSON value encoding mirrored by
// `_encode` below). These tests run without Python: they decode every
// committed fixture through the public readers and compare schema, metadata,
// batch boundaries, null counts, dictionary layout and canonical values (raw
// float bits, unscaled decimals, raw temporal counters) with the PyArrow
// expectations, and then check that the public writers re-encode the same
// content.
//
// The Dart -> PyArrow direction needs PyArrow and is exercised by
//   dart run tool/conformance/arrow_ipc_interop.dart --out DIR
//   python tool/conformance/arrow_ipc_interop.py verify --output DIR
//
// Gaps are explicit: every fixture listed in [_knownGaps] must still fail
// with the recorded error type. A gap that starts passing fails the test so
// the list is kept honest, and any failure outside the list fails as usual.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/ipc.dart' as ipc;
import 'package:test/test.dart';

const _root = 'test/conformance/fixtures/arrow_ipc';

/// Fixture keys (`family/name`) the codec does not support, mapped to the
/// error type it is expected to raise.
const Map<String, Type> _knownGaps = {
  // ExtensionType.metadata is a String; non-UTF-8 extension metadata bytes
  // are rejected rather than decoded lossily.
  'extension/binary_metadata': FormatException,
};

void main() {
  final manifest = jsonDecode(
    File('$_root/manifest.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final entries = (manifest['fixtures']! as List).cast<Map<String, Object?>>();

  test('manifest lists fixtures and known gaps refer to real fixtures', () {
    final keys = {for (final e in entries) '${e['family']}/${e['name']}'};
    expect(keys, isNotEmpty);
    for (final gap in _knownGaps.keys) {
      expect(keys, contains(gap), reason: 'stale known gap $gap');
    }
  });

  for (final entry in entries) {
    final key = '${entry['family']}/${entry['name']}';
    final expectation = jsonDecode(
      File('$_root/${entry['expectation']}').readAsStringSync(),
    ) as Map<String, Object?>;
    final files = (expectation['files']! as Map).cast<String, String>();
    group(key, () {
      for (final MapEntry(key: format, value: fileName) in files.entries) {
        final bytes = File('$_root/${entry['family']}/$fileName')
            .readAsBytesSync();
        final gap = _knownGaps[key];
        if (gap != null) {
          test('$format: known gap still raises $gap', () {
            Object? error;
            (Schema, List<RecordBatch>)? read;
            try {
              read = _read(format, bytes);
            } catch (e) {
              error = e;
            }
            if (read != null) {
              final problems = _compare(expectation, read);
              fail(
                'Known gap $key now decodes '
                '(${problems.isEmpty ? 'and matches PyArrow' : 'but differs: ${problems.join('; ')}'}). '
                'Remove it from _knownGaps and verify with the interop tool.',
              );
            }
            expect(
              error.runtimeType.toString(),
              startsWith(gap.toString()),
              reason: 'unexpected error for known gap: $error',
            );
          });
          continue;
        }
        test('$format: PyArrow -> Dart matches expectation', () {
          final problems = _compare(expectation, _read(format, bytes));
          expect(problems, isEmpty, reason: problems.join('\n'));
        });
        test('$format: Dart writer re-encodes identical content', () {
          final (schema, batches) = _read(format, bytes);
          final Uint8List written;
          if (format == 'file') {
            final writer = ipc.newFile(schema);
            batches.forEach(writer.writeBatch);
            written = writer.close();
          } else {
            final writer = ipc.newStream(schema);
            batches.forEach(writer.writeBatch);
            written = writer.close();
          }
          final problems = _compare(
            expectation,
            _read(format, written),
            dictionaries: false,
          );
          expect(problems, isEmpty, reason: problems.join('\n'));
        });
      }
    });
  }
}

(Schema, List<RecordBatch>) _read(String format, Uint8List bytes) {
  if (format == 'file') {
    final reader = ipc.openFile(bytes);
    return (
      reader.schema,
      [for (var i = 0; i < reader.numRecordBatches; i++) reader.getBatch(i)],
    );
  }
  final reader = ipc.openStream(bytes);
  return (reader.schema, reader.toList());
}

/// Compares a decoded table with a PyArrow expectation. When [dictionaries]
/// is false the physical per-batch dictionary layout is ignored (writers may
/// legitimately re-emit dictionaries differently, e.g. without deltas).
List<String> _compare(
  Map<String, Object?> expectation,
  (Schema, List<RecordBatch>) read, {
  bool dictionaries = true,
}) {
  final got = _summarize(read.$1, read.$2);
  final want = <String, Object?>{
    for (final k in ['schema', 'num_rows', 'batch_row_counts', 'columns'])
      // Deep copy: the expectation map is shared between tests.
      k: jsonDecode(jsonEncode(expectation[k])),
  };
  if (!dictionaries) {
    for (final cols in [want['columns'], got['columns']]) {
      for (final c in (cols! as List).cast<Map>()) {
        c.remove('dictionary');
      }
    }
  }
  final problems = <String>[];
  _diff('', want, got, problems);
  return problems;
}

Map<String, Object?> _summarize(Schema schema, List<RecordBatch> batches) {
  final columns = <Object?>[];
  for (var i = 0; i < schema.length; i++) {
    final chunks = [for (final b in batches) _storageOf(b.columns[i])];
    columns.add({
      'name': schema.fields[i].name,
      'null_count': chunks.fold<int>(0, (n, c) => n + c.nullCount),
      'values': [for (final chunk in chunks) ..._encode(chunk)],
      if (chunks.isNotEmpty && chunks.first.type is DictionaryType)
        'dictionary': [
          for (final chunk in chunks)
            {
              'indices': _encode(_indices(chunk)),
              'values': _encode(chunk.dictionary!),
            },
        ],
    });
  }
  return {
    'schema': {
      'fields': [for (final f in schema.fields) _describeField(f)],
      ...?_metadata(schema.metadata, 'metadata'),
    },
    'num_rows': batches.fold<int>(0, (n, b) => n + b.numRows),
    'batch_row_counts': [for (final b in batches) b.numRows],
    'columns': columns,
  };
}

/// Buffers owned by [array] itself (excluding its children's buffers).
List<Buffer?> _own(Array array) {
  final all = array.buffers();
  final nested = array.children.fold<int>(0, (n, c) => n + c.buffers().length);
  return all.sublist(0, all.length - nested);
}

/// The storage view of an extension array (same buffers, storage type).
Array _storageOf(Array array) {
  final type = array.type;
  if (type is! ExtensionType) return array;
  final storage = type.storageType;
  return _storageOf(
    Array.fromBuffers(
      storage,
      array.length,
      storage is NullType ? const [] : _own(array),
      offset: array.offset,
      children: array.children,
      dictionary: array.dictionary,
    ),
  );
}

Array _indices(Array dictionaryArray) {
  final type = dictionaryArray.type as DictionaryType;
  return Array.fromBuffers(
    type.indexType,
    dictionaryArray.length,
    _own(dictionaryArray),
    offset: dictionaryArray.offset,
  );
}

int _offsetAt(Array array, int slot, int index, int width) {
  final data = ByteData.sublistView(_own(array)[slot]!.bytes);
  return width == 4
      ? data.getInt32(index * 4, Endian.little)
      : data.getInt64(index * 8, Endian.little);
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Canonical per-row JSON values, mirroring `encode` in the Python oracle.
List<Object?> _encode(Array input) {
  final array = _storageOf(input);
  final type = array.type;
  final n = array.length;
  final base = array.offset;
  bool valid(int i) => array[i].isValid;
  switch (type) {
    case NullType():
      return List.filled(n, null);
    case DictionaryType():
      final values = _encode(array.dictionary!);
      final indices = _indices(array);
      return [
        for (var i = 0; i < n; i++)
          indices[i].isValid ? values[indices[i].value! as int] : null,
      ];
    case RunEndEncodedType():
      final ends = array.children[0];
      final values = _encode(array.children[1]);
      var run = 0;
      return [
        for (var i = 0; i < n; i++)
          () {
            while ((ends[run].value! as int) <= base + i) {
              run++;
            }
            return values[run];
          }(),
      ];
    case UnionType(:final mode, :final typeIds):
      final codes = _own(array)[1]!.bytes;
      final children = [for (final c in array.children) _encode(c)];
      return [
        for (var i = 0; i < n; i++)
          {
            'type_code': codes[base + i],
            'value':
                children[typeIds.indexOf(codes[base + i])][mode ==
                        UnionMode.dense
                    ? _offsetAt(array, 2, base + i, 4)
                    : base + i],
          },
      ];
    case StructType(:final fields):
      final columns = [for (final c in array.children) _encode(c)];
      return [
        for (var r = 0; r < n; r++)
          valid(r)
              ? {
                  for (var c = 0; c < fields.length; c++)
                    fields[c].name: columns[c][base + r],
                }
              : null,
      ];
    case FixedSizeListType(:final size):
      final values = _encode(array.children[0]);
      return [
        for (var r = 0; r < n; r++)
          valid(r)
              ? values.sublist((base + r) * size, (base + r + 1) * size)
              : null,
      ];
    case ListType(:final view, :final offsetWidth):
      final width = offsetWidth == OffsetWidth.large ? 8 : 4;
      final values = _encode(array.children[0]);
      return [
        for (var r = 0; r < n; r++)
          if (!valid(r))
            null
          else if (view)
            values.sublist(
              _offsetAt(array, 1, base + r, width),
              _offsetAt(array, 1, base + r, width) +
                  _offsetAt(array, 2, base + r, width),
            )
          else
            values.sublist(
              _offsetAt(array, 1, base + r, width),
              _offsetAt(array, 1, base + r + 1, width),
            ),
      ];
    case MapType():
      final entries = _encode(array.children[0]);
      final fields = (array.children[0].type as StructType).fields;
      return [
        for (var r = 0; r < n; r++)
          valid(r)
              ? [
                  for (final e in entries.sublist(
                    _offsetAt(array, 1, base + r, 4),
                    _offsetAt(array, 1, base + r + 1, 4),
                  ))
                    [(e! as Map)[fields[0].name], (e as Map)[fields[1].name]],
                ]
              : null,
      ];
    default:
      return [for (var i = 0; i < n; i++) _leaf(type, array[i])];
  }
}

Object? _leaf(DataType type, Scalar scalar) {
  if (!scalar.isValid) return null;
  final value = scalar.value;
  return switch (type) {
    BooleanType() || Utf8Type() => value,
    IntegerType(:final bitWidth) => bitWidth == 64 ? value.toString() : value,
    FloatingType(:final bitWidth) =>
      '0x${scalar.rawBits!.toRadixString(16).padLeft(bitWidth ~/ 4, '0')}',
    DecimalType() => (value! as DecimalValue).unscaled.toString(),
    DateType(unit: DateUnit.day) => value,
    TimeType(:final unit)
        when unit == TimeUnit.second || unit == TimeUnit.millisecond =>
      value,
    DateType() ||
    TimeType() ||
    TimestampType() ||
    DurationType() => value.toString(),
    IntervalType() => switch (value! as IntervalValue) {
      final v => [v.months, v.days, v.nanoseconds.toString()],
    },
    BinaryType() || FixedSizeBinaryType() => _hex(value! as List<int>),
    _ => throw StateError('unexpected leaf type $type'),
  };
}

Map<String, Object?>? _metadata(ByteMetadata? metadata, String key) {
  if (metadata == null || metadata.isEmpty) return null;
  final entries = metadata.entries.toList()
    ..sort((a, b) => _compareBytes(a.key, b.key));
  return {
    key: {
      for (final e in entries)
        utf8.decode(e.key): () {
          try {
            return utf8.decode(e.value);
          } on FormatException {
            return 'hex:${_hex(e.value)}';
          }
        }(),
    },
  };
}

int _compareBytes(List<int> a, List<int> b) {
  for (var i = 0; i < a.length && i < b.length; i++) {
    if (a[i] != b[i]) return a[i] - b[i];
  }
  return a.length - b.length;
}

Map<String, Object?> _describeField(Field f) {
  var type = f.type;
  final metadata = <Object, Object>{...?f.metadata};
  if (type is ExtensionType) {
    metadata['ARROW:extension:name'] = type.name;
    if (type.metadata != null) {
      metadata['ARROW:extension:metadata'] = type.metadata!;
    }
    type = type.storageType;
  }
  return {
    'name': f.name,
    'nullable': f.nullable,
    'type': _describeType(type),
    ...?_metadata(ByteMetadata(metadata), 'metadata'),
  };
}

const _unitNames = {
  TimeUnit.second: 's',
  TimeUnit.millisecond: 'ms',
  TimeUnit.microsecond: 'us',
  TimeUnit.nanosecond: 'ns',
};

String _layout(String base, OffsetWidth w) => switch (w) {
  OffsetWidth.normal => base,
  OffsetWidth.large => 'large_$base',
  OffsetWidth.view => '${base}_view',
};

Map<String, Object?> _describeType(DataType t) => switch (t) {
  NullType() => {'id': 'null'},
  BooleanType() => {'id': 'bool'},
  IntegerType(:final bitWidth, :final signed) => {
    'id': '${signed ? 'int' : 'uint'}$bitWidth',
  },
  FloatingType(:final bitWidth) => {'id': 'float$bitWidth'},
  DecimalType(:final bitWidth, :final precision, :final scale) => {
    'id': 'decimal$bitWidth',
    'precision': precision,
    'scale': scale,
  },
  Utf8Type(:final offsetWidth) => {'id': _layout('utf8', offsetWidth)},
  BinaryType(:final offsetWidth) => {'id': _layout('binary', offsetWidth)},
  FixedSizeBinaryType(:final byteWidth) => {
    'id': 'fixed_size_binary',
    'byte_width': byteWidth,
  },
  DateType(:final unit) => {'id': unit == DateUnit.day ? 'date32' : 'date64'},
  TimeType(:final unit) => {
    'id': unit == TimeUnit.second || unit == TimeUnit.millisecond
        ? 'time32'
        : 'time64',
    'unit': _unitNames[unit],
  },
  TimestampType(:final unit, :final timeZone) => {
    'id': 'timestamp',
    'unit': _unitNames[unit],
    'timezone': timeZone,
  },
  DurationType(:final unit) => {'id': 'duration', 'unit': _unitNames[unit]},
  IntervalType(:final unit) => {
    'id': switch (unit) {
      IntervalUnit.monthDayNano => 'interval_month_day_nano',
      IntervalUnit.yearMonth => 'interval_year_month',
      IntervalUnit.dayTime => 'interval_day_time',
    },
  },
  ListType(:final field, :final offsetWidth, :final view) => {
    'id':
        '${offsetWidth == OffsetWidth.large ? 'large_' : ''}'
        'list${view ? '_view' : ''}',
    'children': [_describeField(field)],
  },
  FixedSizeListType(:final field, :final size) => {
    'id': 'fixed_size_list',
    'list_size': size,
    'children': [_describeField(field)],
  },
  StructType(:final fields) => {
    'id': 'struct',
    'children': [for (final f in fields) _describeField(f)],
  },
  DictionaryType(:final indexType, :final valueType, :final ordered) => {
    'id': 'dictionary',
    'index': _describeType(indexType),
    'value': _describeType(valueType),
    'ordered': ordered,
  },
  MapType(:final keysSorted) => {
    'id': 'map',
    'keys_sorted': keysSorted,
    'children': [_describeField(t.entriesField)],
  },
  UnionType(:final mode, :final typeIds, :final fields) => {
    'id': '${mode.name}_union',
    'type_codes': typeIds,
    'children': [for (final f in fields) _describeField(f)],
  },
  RunEndEncodedType(:final runEndsField, :final valuesField) => {
    'id': 'run_end_encoded',
    'children': [_describeField(runEndsField), _describeField(valuesField)],
  },
  ExtensionType() => throw StateError('nested extension $t'),
};

void _diff(String path, Object? want, Object? got, List<String> out) {
  if (out.length >= 20) return;
  if (want is Map && got is Map) {
    for (final k in {...want.keys, ...got.keys}) {
      if (!want.containsKey(k)) {
        out.add('$path.$k: unexpected ${_short(got[k])}');
      } else if (!got.containsKey(k)) {
        out.add('$path.$k: missing (expected ${_short(want[k])})');
      } else {
        _diff('$path.$k', want[k], got[k], out);
      }
    }
  } else if (want is List && got is List) {
    if (want.length != got.length) {
      out.add('$path: length ${got.length} != expected ${want.length}');
    }
    for (var i = 0; i < want.length && i < got.length; i++) {
      _diff('$path[$i]', want[i], got[i], out);
    }
  } else if (want != got) {
    out.add('$path: got ${_short(got)} expected ${_short(want)}');
  }
}

String _short(Object? v) {
  final s = jsonEncode(v);
  return s.length > 120 ? '${s.substring(0, 120)}...' : s;
}
