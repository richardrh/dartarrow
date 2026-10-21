import 'dart:convert';

import 'package:dartaframes_arrow/arrow.dart';

void main() {
  final type = ArrowIntegerType(32);
  final array = ArrowArray(type, [
    ArrowIntegerValue(10),
    null,
    ArrowIntegerValue(30),
  ]);
  final slice = array.slice(1, 2);
  final schema = ArrowSchema([ArrowField('value', type)]);
  final batch = RecordBatch(schema, [slice]);
  final json = const OwnedBatchJsonCodec().toJson(batch);
  print(jsonEncode(json));
}
