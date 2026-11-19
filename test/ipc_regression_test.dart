import 'package:dartarrow/arrow.dart';
import 'package:dartarrow/ipc.dart' as ipc;
import 'package:test/test.dart';


Array _dict(List<int> indices, List<String> values) =>
    Array.fromDictionary(array(indices, type: int32()), array(values));

void main() {
  // Expected rows from PyArrow 26 ipc.open_file(...).read_all() of the same
  // write sequence, which also passes validate(full=True).
  group('failed writes leave the writer unchanged', () {
    final type = DictionaryType(int32(), string());
    final schema = Schema([field('b', type), field('a', type)]);
    RecordBatch batch(Array b, Array a) =>
        RecordBatch.fromArrays([b, a], schema: schema);

    test('rejected file batch records no dictionaries', () {
      final writer = ipc.newFile(schema)
        ..writeBatch(batch(_dict([0], ['p']), _dict([0], ['x'])));
      expect(
        () =>
            writer.writeBatch(batch(_dict([0], ['q']), _dict([1], ['x', 'y']))),
        throwsUnsupportedError,
      );
      writer.writeBatch(batch(_dict([0], ['p']), _dict([1], ['x', 'y'])));
      final table = ipc.openFile(writer.close()).readAll();
      expect(table.toDartList(), [
        {'b': 'p', 'a': 'x'},
        {'b': 'p', 'a': 'y'},
      ]);
    });

    test('writeTable is all-or-nothing', () {
      final first = batch(_dict([0], ['p']), _dict([0], ['x']));
      final writer = ipc.newFile(schema)..writeBatch(first);
      final table = Table.fromBatches([
        batch(_dict([0], ['p']), _dict([1], ['x', 'y'])),
        batch(_dict([0], ['q']), _dict([0], ['x'])),
      ]);
      expect(() => writer.writeTable(table), throwsUnsupportedError);
      expect(() => writer.write(table), throwsUnsupportedError);
      final expected = (ipc.newFile(schema)..writeBatch(first)).close();
      expect(writer.close(), expected);
    });
  });

}
