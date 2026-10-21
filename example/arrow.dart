import 'package:dartaframes_arrow/arrow.dart' as pa;

void main() {
  final values = pa.array([10, null, 30], type: pa.int32());
  final slice = values.slice(1, 2);
  print(slice.toDartList()); // [null, 30]
  print(values[0].asDart()); // 10
  print(values[1].isValid); // false
}
