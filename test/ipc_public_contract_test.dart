import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/ipc.dart' as ipc;
import 'package:test/test.dart';

void main() {
  final schema = Schema([field('n', int32())]);
  final batch = RecordBatch.fromArrays([
    array([7], type: int32()),
  ], schema: schema);

  test('IPC public objects expose stable schema, limits and tables', () {
    final streamWriter = ipc.newStream(schema)..writeBatch(batch);
    final fileWriter = ipc.newFile(schema)
      ..writeTable(Table.fromBatches([batch]));
    expect(streamWriter.schema, same(schema));
    expect(fileWriter.schema, same(schema));
    const limits = ipc.IpcLimits(maxRows: 1);
    final streamReader = ipc.openStream(streamWriter.close(), limits: limits);
    final fileReader = ipc.openFile(fileWriter.close(), limits: limits);
    expect(streamReader.limits, same(limits));
    expect(fileReader.limits, same(limits));
    expect(streamReader.schema, schema);
    expect(fileReader.schema, schema);
    final table = streamReader.readAll();
    expect(table.numRows, 1);
    expect(table.column(0).toDartList(), [7]);
    expect(fileReader.readAll().numRows, 1);
    expect(fileReader.numRecordBatches, 1);
    expect(() => fileReader.getBatch(1), throwsRangeError);
  });

  test('every public IPC limit retains its configured value', () {
    const limits = ipc.IpcLimits(
      maxDepth: 1,
      maxFields: 2,
      maxRows: 3,
      maxValues: 4,
      maxBuffers: 5,
      maxMessageBytes: 6,
      maxDictionaries: 7,
      maxBatches: 8,
    );
    expect(
      [
        limits.maxDepth,
        limits.maxFields,
        limits.maxRows,
        limits.maxValues,
        limits.maxBuffers,
        limits.maxMessageBytes,
        limits.maxDictionaries,
        limits.maxBatches,
      ],
      [1, 2, 3, 4, 5, 6, 7, 8],
    );
  });

  test('maxBuffers rejects excess buffers in both public readers', () {
    final stream = (ipc.newStream(schema)..writeBatch(batch)).close();
    final file = (ipc.newFile(schema)..writeBatch(batch)).close();
    const tight = ipc.IpcLimits(maxBuffers: 1);
    const enough = ipc.IpcLimits(maxBuffers: 2);
    expect(
      () => ipc.openStream(stream, limits: tight).readAll(),
      throwsFormatException,
    );
    expect(
      () => ipc.openFile(file, limits: tight).readAll(),
      throwsFormatException,
    );
    expect(ipc.openStream(stream, limits: enough).readAll().numRows, 1);
    expect(ipc.openFile(file, limits: enough).readAll().numRows, 1);
  });
}
