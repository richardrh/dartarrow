/// Buffer-backed Arrow arrays, schemas, logical values, and owned JSON.
///
/// Little-endian physical buffers support borrowed imports and cheap slices
/// without a native dependency. This is not the complete Apache Arrow
/// specification and does not implement Arrow IPC or compute kernels.
/// Deliberately unsupported families include maps, unions, intervals,
/// fixed-size binary, list/string/binary views, large lists, and run-end
/// encoding. `int128` and `uint128` are binding extensions rather than Apache
/// Arrow integer types.
library dartaframes_arrow;

export 'src/array.dart';
export 'src/batch.dart';
export 'src/codec.dart';
export 'src/schema.dart';
export 'src/type.dart';
export 'src/value.dart';
