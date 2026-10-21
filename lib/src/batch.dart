import 'array.dart';
import 'schema.dart';

final class RecordBatch {
  RecordBatch(this.schema, List<ArrowArray> columns, {int? rowCount})
    : columns = List.unmodifiable(columns),
      rowCount = rowCount ?? (columns.isEmpty ? 0 : columns.first.length) {
    if (this.rowCount < 0) {
      throw RangeError.value(this.rowCount, 'rowCount', 'must be non-negative');
    }
    if (columns.length != schema.fields.length) {
      throw ArgumentError(
        'Column count ${columns.length} does not match schema field count ${schema.fields.length}',
      );
    }
    for (var i = 0; i < columns.length; i++) {
      final field = schema.fields[i];
      final column = columns[i];
      if (column.type != field.type) {
        throw ArgumentError(
          'Column $i (${field.name}) datatype does not match schema',
        );
      }
      if (column.length != this.rowCount) {
        throw ArgumentError(
          'Column $i (${field.name}) length ${column.length} does not match row count ${this.rowCount}',
        );
      }
      if (!field.nullable && column.nullCount != 0) {
        throw ArgumentError('Column $i (${field.name}) is not nullable');
      }
    }
  }
  RecordBatch._(this.schema, this.columns, this.rowCount);
  final ArrowSchema schema;
  final List<ArrowArray> columns;
  final int rowCount;
  int get length => rowCount;
  int get columnCount => columns.length;

  RecordBatch slice(int start, [int? count]) {
    final size = count ?? rowCount - start;
    RangeError.checkValidRange(start, start + size, rowCount);
    return RecordBatch._(
      schema,
      List.unmodifiable(columns.map((c) => c.slice(start, size))),
      size,
    );
  }
}
