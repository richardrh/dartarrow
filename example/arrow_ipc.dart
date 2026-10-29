import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/ipc.dart' as ipc;

/// Encodes and decodes standard Arrow IPC streams and files entirely in Dart.
void main() {
  final table = Table.fromDartMap(
    {
      'id': [1, 2],
      'label': ['Ada', null],
    },
    schema: schema([
      field('id', int64(), nullable: false),
      field('label', string()),
    ]),
  );

  final stream = (ipc.newStream(table.schema)..writeTable(table)).close();
  final restored = ipc.openStream(stream).readAll();
  final file = (ipc.newFile(restored.schema)..writeTable(restored)).close();
  final reader = ipc.openFile(file);
  print('IPC stream: ${stream.length} bytes');
  print('IPC file: ${file.length} bytes (${reader.numRecordBatches} batch)');
  print('Rows: ${reader.readAll().toDartList()}');
}
