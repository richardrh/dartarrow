part of 'core.dart';

final class Table {
  Table._(this.schema, List<ChunkedArray> columns, this.numRows)
    : columns = List.unmodifiable(columns) {
    if (numRows < 0 || columns.length != schema.length)
      throw ArrowInvalid('Invalid table shape');
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].length != numRows ||
          columns[i].type != schema.fields[i].type)
        throw ArrowInvalid('Column $i does not match schema or row count');
    }
  }
  factory Table.fromArrays(
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
    final columns = <ChunkedArray>[];
    for (var i = 0; i < values.length; i++) {
      final value = values[i];
      final type = schema?.fields[i].type;
      if (value == null) throw ArgumentError('Column $i must not be null');
      final chunked = value is ChunkedArray
          ? value
          : ChunkedArray([value], type: value is Array ? value.type : type);
      columns.add(
        type != null && type != chunked.type ? chunked.cast(type) : chunked,
      );
    }
    return Table._(
      schema ??
          Schema([
            for (var i = 0; i < columns.length; i++)
              Field(names![i], columns[i].type),
          ], metadata: metadata),
      columns,
      columns.isEmpty ? 0 : columns.first.length,
    );
  }
  factory Table.fromDartMap(
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
    return Table.fromArrays(
      values,
      names: schema == null ? names : null,
      schema: schema,
      metadata: metadata,
    );
  }
  factory Table.fromDartList(
    List<Map<String, Object?>> rows, {
    Schema? schema,
    Map<Object, Object>? metadata,
  }) => Table.fromBatches([
    RecordBatch.fromDartList(rows, schema: schema, metadata: metadata),
  ]);
  factory Table.fromBatches(Iterable<RecordBatch> batches, {Schema? schema}) {
    final values = batches.toList();
    if (schema == null && values.isEmpty)
      throw ArgumentError('Empty batches require a schema');
    schema ??= values.first.schema;
    var rows = 0;
    for (final batch in values) {
      if (!schema.equals(batch.schema))
        throw ArgumentError('Batch schemas must match');
      rows = _checkedLengthAdd(rows, batch.numRows);
    }
    return Table._(schema, [
      for (var i = 0; i < schema.length; i++)
        ChunkedArray([
          for (final batch in values) batch.columns[i],
        ], type: schema.fields[i].type),
    ], rows);
  }
  final Schema schema;
  final List<ChunkedArray> columns;
  final int numRows;
  int get length => numRows;
  int get numColumns => columns.length;
  List<String> get columnNames => schema.names;
  ChunkedArray column(Object indexOrName) =>
      columns[_fieldIndex(schema, indexOrName)];
  ChunkedArray operator [](Object indexOrName) => column(indexOrName);
  Table select(Iterable<Object> columns) {
    final indices = columns.map((c) => _fieldIndex(schema, c)).toList();
    return Table._(
      Schema(indices.map((i) => schema.fields[i]), metadata: schema.metadata),
      indices.map((i) => this.columns[i]).toList(),
      numRows,
    );
  }

  Table slice([int offset = 0, int? length]) => Table._(
    schema,
    columns.map((c) => c.slice(offset, length)).toList(),
    _tabularSliceLength(numRows, offset, length),
  );
  Table renameColumns(List<String> names) {
    if (names.length != numColumns) throw ArgumentError('Incorrect name count');
    return Table._(
      Schema([
        for (var i = 0; i < numColumns; i++)
          schema.fields[i].withName(names[i]),
      ]),
      columns,
      numRows,
    );
  }

  Table replaceSchemaMetadata(Map<Object, Object>? metadata) =>
      Table._(schema.withMetadata(metadata), columns, numRows);
  Table combineChunks() => Table._(schema, [
    for (final column in columns) ChunkedArray([column.combineChunks()]),
  ], numRows);
  Table cast(Schema targetSchema, {bool safe = true}) {
    if (targetSchema.length != numColumns)
      throw ArgumentError('Target schema names must match');
    for (var i = 0; i < numColumns; i++) {
      if (targetSchema.fields[i].name != schema.fields[i].name)
        throw ArgumentError('Target schema names must match');
    }
    return Table._(targetSchema, [
      for (var i = 0; i < numColumns; i++)
        columns[i].cast(targetSchema.fields[i].type, safe: safe),
    ], numRows);
  }

  List<RecordBatch> toBatches({int? maxChunkSize}) {
    if (maxChunkSize != null && maxChunkSize <= 0)
      throw ArgumentError.value(maxChunkSize, 'maxChunkSize');
    final result = <RecordBatch>[];
    if (numRows == 0) return result;
    final indices = List<int>.filled(numColumns, 0);
    final offsets = List<int>.filled(numColumns, 0);
    var row = 0;
    while (row < numRows) {
      var count = maxChunkSize == null || maxChunkSize > numRows - row
          ? numRows - row
          : maxChunkSize;
      for (var i = 0; i < numColumns; i++) {
        final chunks = columns[i].chunks;
        final available = chunks[indices[i]].length - offsets[i];
        if (available < count) count = available;
      }
      if (numColumns == 0) {
        result.add(
          RecordBatch.fromStructArray(
            Array.fromBuffers(StructType([]), count, [null]),
          ).replaceSchemaMetadata(schema.metadata),
        );
      } else {
        result.add(
          RecordBatch.fromArrays([
            for (var i = 0; i < numColumns; i++)
              columns[i].chunks[indices[i]].slice(offsets[i], count),
          ], schema: schema),
        );
      }
      for (var i = 0; i < numColumns; i++) {
        offsets[i] += count;
        if (offsets[i] == columns[i].chunks[indices[i]].length) {
          indices[i]++;
          offsets[i] = 0;
        }
      }
      row += count;
    }
    return result;
  }

  Map<String, List<Object?>> toDartMap() => {
    for (var i = 0; i < numColumns; i++)
      schema.fields[i].name: columns[i].toDartList(),
  };
  List<Map<String, Object?>> toDartList() => [
    for (final batch in toBatches()) ...batch.toDartList(),
  ];
  bool equals(Table other, {bool checkMetadata = false}) {
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
      for (final chunk in column.chunks) {
        chunk.validate(full: full);
      }
    }
  }
}

Table table(
  Object data, {
  List<String>? names,
  Schema? schema,
  Map<Object, Object>? metadata,
}) {
  if (data is Map<String, Object?>) {
    if (names != null)
      throw ArgumentError('names is not supported for mappings');
    return Table.fromDartMap(data, schema: schema, metadata: metadata);
  }
  if (data is Iterable<Object?>)
    return Table.fromArrays(
      data,
      names: names,
      schema: schema,
      metadata: metadata,
    );
  throw ArgumentError.value(data, 'data', 'Expected mapping or arrays');
}
