import 'package:dartarrow/arrow.dart' as pa;
import 'package:dartarrow/ipc.dart' as ipc;

void main() {
  final values = pa.array([10, null, 30], type: pa.int32());
  print(values[0].asDart()); // 10
  print(values[1].isValid); // false: a typed int32 null Scalar
  print(values.slice(1, 2).toDartList()); // [null, 30]

  final table = pa.table({
    'id': pa.chunkedArray([values.slice(0, 1), values.slice(1)]),
  });

  // Arrow IPC round trip (format V5, in memory).
  final bytes = (ipc.newStream(table.schema)..writeTable(table)).close();
  print(ipc.openStream(bytes).readAll().numRows); // 3
}
