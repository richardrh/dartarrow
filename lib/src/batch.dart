part of 'core.dart';

final class RecordBatch {
  RecordBatch._(this.schema, List<Array> columns, this.numRows)
    : columns = List.unmodifiable(columns) {
    if (numRows < 0 || columns.length != schema.length)
      throw ArgumentError('Invalid batch shape');
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].length != numRows ||
          columns[i].type != schema.fields[i].type)
        throw ArgumentError('Column $i does not match schema or row count');
    }
  }
  factory RecordBatch.fromArrays(
    Iterable<Object?> arrays, {
    List<String>? names,
    Schema? schema,
    Map<Object, Object>? metadata,
  }) {
    _checkTabularOptions(names, schema, metadata);
    final values = arrays.toList();
    if (schema != null && values.length != schema.length)
      throw ArgumentError('Schema and column counts differ');
    if (schema == null && (names == null || names.length != values.length))
      throw ArgumentError('Names or schema required for each column');
    final columns = <Array>[];
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      if (value == null) throw ArgumentError('Column $i must not be null');
      final type = schema?.fields[i].type;
      final column = value is Array
          ? (type != null && type != value.type ? value.cast(type) : value)
          : value is Iterable
          ? array(value, type: type)
          : throw ArgumentError('Expected array or iterable');
      columns.add(column);
    }
    final resolved =
        schema ??
        Schema([
          for (var i = 0; i < columns.length; i++)
            Field(names![i], columns[i].type),
        ], metadata: metadata);
    return RecordBatch._(
      resolved,
      columns,
      columns.isEmpty ? 0 : columns.first.length,
    );
  }
  factory RecordBatch.fromDartMap(
    Map<String, Object?> data, {
    Schema? schema,
    Map<Object, Object>? metadata,
  }) {
    final names = schema?.names ?? data.keys.toList();
    final values = <Object?>[];
    for (final name in names) {
      if (!data.containsKey(name))
        throw ArgumentError('Missing column "$name"');
      values.add(data[name]);
    }
    return RecordBatch.fromArrays(
      values,
      names: schema == null ? names : null,
      schema: schema,
      metadata: metadata,
    );
  }
  factory RecordBatch.fromDartList(
    List<Map<String, Object?>> rows, {
    Schema? schema,
    Map<Object, Object>? metadata,
  }) {
    final names =
        schema?.names ?? (rows.isEmpty ? <String>[] : rows.first.keys.toList());
    final result = RecordBatch.fromArrays(
      [
        for (final name in names) [for (final row in rows) row[name]],
      ],
      names: schema == null ? names : null,
      schema: schema,
      metadata: metadata,
    );
    return RecordBatch._(result.schema, result.columns, rows.length);
  }
  factory RecordBatch.fromStructArray(Array array) {
    final type = array.type;
    if (type is! StructType) throw ArgumentError('Expected struct array');
    final hasParentNulls = array.nullCount != 0;
    return RecordBatch._(Schema(type.fields), [
      for (final child in array.children)
        if (hasParentNulls)
          _maskStructChild(array, child.slice(array.offset, array.length))
        else
          child.slice(array.offset, array.length),
    ], array.length);
  }
  final Schema schema;
  final List<Array> columns;
  final int numRows;
  int get numColumns => columns.length;
  int get length => numRows;
  List<String> get columnNames => schema.names;
  Array column(Object indexOrName) => columns[_fieldIndex(schema, indexOrName)];
  Array operator [](Object indexOrName) => column(indexOrName);
  RecordBatch select(Iterable<Object> columns) {
    final indices = columns.map((c) => _fieldIndex(schema, c)).toList();
    return RecordBatch._(
      Schema(indices.map((i) => schema.fields[i]), metadata: schema.metadata),
      indices.map((i) => this.columns[i]).toList(),
      numRows,
    );
  }

  RecordBatch slice([int offset = 0, int? length]) {
    final size = _tabularSliceLength(numRows, offset, length);
    return RecordBatch._(
      schema,
      columns.map((c) => c.slice(offset, size)).toList(),
      size,
    );
  }

  RecordBatch renameColumns(List<String> names) {
    if (names.length != numColumns) throw ArgumentError('Incorrect name count');
    return RecordBatch._(
      Schema([
        for (var i = 0; i < numColumns; i++)
          schema.fields[i].withName(names[i]),
      ]),
      columns,
      numRows,
    );
  }

  RecordBatch replaceSchemaMetadata(Map<Object, Object>? metadata) =>
      RecordBatch._(schema.withMetadata(metadata), columns, numRows);
  RecordBatch cast(Schema targetSchema, {bool safe = true}) {
    if (targetSchema.length != numColumns)
      throw ArgumentError('Target schema names must match');
    for (var i = 0; i < numColumns; i++) {
      if (targetSchema.fields[i].name != schema.fields[i].name)
        throw ArgumentError('Target schema names must match');
    }
    return RecordBatch._(targetSchema, [
      for (var i = 0; i < numColumns; i++)
        columns[i].cast(targetSchema.fields[i].type, safe: safe),
    ], numRows);
  }

  Map<String, List<Object?>> toDartMap() => {
    for (var i = 0; i < numColumns; i++)
      schema.fields[i].name: columns[i].toDartList(),
  };
  List<Map<String, Object?>> toDartList() => [
    for (var row = 0; row < numRows; row++)
      {
        for (var i = 0; i < numColumns; i++)
          schema.fields[i].name: columns[i][row].asDart(),
      },
  ];
  bool equals(RecordBatch other, {bool checkMetadata = false}) {
    if (numRows != other.numRows ||
        !schema.equals(other.schema, checkMetadata: checkMetadata))
      return false;
    for (var i = 0; i < numColumns; i++) {
      if (!columns[i].equals(other.columns[i])) return false;
    }
    return true;
  }

  void validate({bool full = false}) {
    for (final column in columns) {
      column.validate(full: full);
    }
  }
}

void _checkTabularOptions(
  List<String>? names,
  Schema? schema,
  Map<Object, Object>? metadata,
) {
  if (schema != null && (names != null || metadata != null))
    throw ArgumentError('schema cannot be combined with names or metadata');
}

int _tabularSliceLength(int rows, int offset, int? length) {
  if (offset < 0) throw RangeError.value(offset, 'offset');
  if (length != null && length < 0) throw ArgumentError.value(length, 'length');
  final available = offset >= rows ? 0 : rows - offset;
  return length == null || length > available ? available : length;
}

RecordBatch recordBatch(
  Object data, {
  List<String>? names,
  Schema? schema,
  Map<Object, Object>? metadata,
}) {
  if (data is Map<String, Object?>) {
    if (names != null)
      throw ArgumentError('names is not supported for mappings');
    return RecordBatch.fromDartMap(data, schema: schema, metadata: metadata);
  }
  if (data is Iterable<Object?>)
    return RecordBatch.fromArrays(
      data,
      names: names,
      schema: schema,
      metadata: metadata,
    );
  throw ArgumentError.value(data, 'data', 'Expected mapping or arrays');
}

Array _maskStructChild(Array parent, Array child) {
  if (child._storage is NullType || child.length == 0) return child;
  Uint8List? validity;
  if (child.offset == parent.offset && child.nullCount == 0) {
    // The parent bitmap already has exactly the required physical alignment.
    validity = parent._physicalBuffers.first;
  } else {
    final original = child._physicalBuffers.first;
    for (var i = 0; i < child.length; i++) {
      if (parent._isValid(i) || !child._isValid(i)) continue;
      if (validity == null) {
        final end = _checkedLengthAdd(child.offset, child.length);
        final bytes = end ~/ 8 + (end % 8 == 0 ? 0 : 1);
        validity = Uint8List(bytes);
        if (original == null) {
          validity.fillRange(0, bytes, 255);
          if (end % 8 != 0) validity[bytes - 1] &= (1 << (end % 8)) - 1;
        } else {
          validity.setRange(0, bytes, original);
        }
      }
      final physical = child.offset + i;
      validity[physical >> 3] &= ~(1 << (physical & 7));
    }
  }
  if (validity == null) return child;
  return Array._(
    child.type,
    child.length,
    child.offset,
    List<Uint8List?>.unmodifiable([
      validity.asUnmodifiableView(),
      ...child._physicalBuffers.skip(1),
    ]),
    child.children,
    child.dictionary,
    (parent, child),
  );
}
