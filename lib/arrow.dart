/// Polars-focused, owned Arrow interchange values.
///
/// This library implements the copied logical-value subset used by the
/// DartAframes Polars binding, not the complete Apache Arrow specification.
/// Deliberately unsupported families include maps, unions, intervals,
/// fixed-size binary, list/string/binary views, large lists, and run-end
/// encoding. `int128` and `uint128` are binding extensions rather than Apache
/// Arrow integer types.
library dartaframes_arrow;

export 'src/arrow/array.dart';
export 'src/arrow/batch.dart';
export 'src/arrow/codec.dart';
export 'src/arrow/schema.dart';
export 'src/arrow/type.dart';
export 'src/arrow/value.dart';
