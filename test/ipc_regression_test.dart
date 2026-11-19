import 'dart:convert';

import 'package:dartarrow/arrow.dart';
import 'package:dartarrow/ipc.dart' as ipc;
import 'package:test/test.dart';

// PyArrow 26 ZSTD stream: one decimal256(40, 2) column, 55 rows, 19 nulls.
const _decimalZstd =
    '/////4AAAAAQAAAAAAAKAAwABgAFAAgACgAAAAABBAAMAAAACAAIAAAABAAIAAAABAAAAAEA'
    'AAAUAAAAEAAUAAgABgAHAAwAAAAQABAAAAAAAAEHEAAAABwAAAAEAAAAAAAAAAEAAABhAAoA'
    'EAAEAAgADAAKAAAAKAAAAAIAAAAAAQAAAAAAAP////+gAAAAFAAAAAAAAAAMABgABgAFAAgA'
    'DAAMAAAAAAMEABwAAAC4AAAAAAAAAAAAAAAMAB4AEAAEAAgADAAMAAAAUAAAACQAAAAYAAAA'
    'NwAAAAAAAAAAAAAAAAAGAAgABwAGAAAAAAAAAQIAAAAAAAAAAAAAABgAAAAAAAAAGAAAAAAA'
    'AACaAAAAAAAAAAAAAAABAAAANwAAAAAAAAATAAAAAAAAAAcAAAAAAAAAKLUv/SAHOQAAbds2'
    '223bNuAGAAAAAAAAKLUv/WDgBUUEAJIEDRbAJR3+//////9/M5ptttlmySKLNPwUCR1TSP2O'
    'n6G/4kfob/gJ+gt+gP7SD+nv/IwW4qsjAH8DpAohVATQHGgYgSSgOQKJQSNDi8PAaq4/RlCR'
    'cwAQMWAIYAgQMWAIYAgQMWAIYAgQMWAIYAgQMWAIYAgQMWAIMBQGEYY2N4SGgUbcYAgAAAAA'
    'AAD/////AAAAAA==';

// PyArrow 26 file and stream written with MetadataVersion.V4.
const _v4File =
    'QVJST1cxAAD/////qAAAABAAAAAAAAoADAAGAAUACAAKAAAAAAEDAAwAAAAIAAgAAAAEAAgA'
    'AAAEAAAAAgAAAEAAAAAEAAAA2P///wAAAQUQAAAAGAAAAAQAAAAAAAAAAQAAAHMAAAAEAAQA'
    'BAAAABAAFAAIAAYABwAMAAAAEAAQAAAAAAABAhAAAAAcAAAABAAAAAAAAAABAAAAYQAAAAgA'
    'DAAIAAcACAAAAAAAAAEgAAAAAAAAAP/////IAAAAFAAAAAAAAAAMABYABgAFAAgADAAMAAAA'
    'AAMDABgAAAA4AAAAAAAAAAAACgAYAAwABAAIAAoAAABsAAAAEAAAAAMAAAAAAAAAAAAAAAUA'
    'AAAAAAAAAAAAAAEAAAAAAAAACAAAAAAAAAAMAAAAAAAAABgAAAAAAAAAAQAAAAAAAAAgAAAA'
    'AAAAABAAAAAAAAAAMAAAAAAAAAACAAAAAAAAAAAAAAACAAAAAwAAAAAAAAABAAAAAAAAAAMA'
    'AAAAAAAAAQAAAAAAAAAFAAAAAAAAAAEAAAAAAAAAAwAAAAAAAAAFAAAAAAAAAAAAAAABAAAA'
    'AQAAAAIAAAB4egAAAAAAAP////8AAAAAEAAAAAwAFAAGAAgADAAQAAwAAAAAAAQAOAAAACgA'
    'AAAEAAAAAQAAALgAAAAAAAAA0AAAAAAAAAA4AAAAAAAAAAAAAAAAAAAACAAIAAAABAAIAAAA'
    'BAAAAAIAAABAAAAABAAAANj///8AAAEFEAAAABgAAAAEAAAAAAAAAAEAAABzAAAABAAEAAQA'
    'AAAQABQACAAGAAcADAAAABAAEAAAAAAAAQIQAAAAHAAAAAQAAAAAAAAAAQAAAGEAAAAIAAwA'
    'CAAHAAgAAAAAAAABIAAAANAAAABBUlJPVzE=';

const _v4Stream =
    '/////6gAAAAQAAAAAAAKAAwABgAFAAgACgAAAAABAwAMAAAACAAIAAAABAAIAAAABAAAAAIA'
    'AABAAAAABAAAANj///8AAAEFEAAAABgAAAAEAAAAAAAAAAEAAABzAAAABAAEAAQAAAAQABQA'
    'CAAGAAcADAAAABAAEAAAAAAAAQIQAAAAHAAAAAQAAAAAAAAAAQAAAGEAAAAIAAwACAAHAAgA'
    'AAAAAAABIAAAAAAAAAD/////yAAAABQAAAAAAAAADAAWAAYABQAIAAwADAAAAAADAwAYAAAA'
    'OAAAAAAAAAAAAAoAGAAMAAQACAAKAAAAbAAAABAAAAADAAAAAAAAAAAAAAAFAAAAAAAAAAAA'
    'AAABAAAAAAAAAAgAAAAAAAAADAAAAAAAAAAYAAAAAAAAAAEAAAAAAAAAIAAAAAAAAAAQAAAA'
    'AAAAADAAAAAAAAAAAgAAAAAAAAAAAAAAAgAAAAMAAAAAAAAAAQAAAAAAAAADAAAAAAAAAAEA'
    'AAAAAAAABQAAAAAAAAABAAAAAAAAAAMAAAAAAAAABQAAAAAAAAAAAAAAAQAAAAEAAAACAAAA'
    'eHoAAAAAAAD/////AAAAAA==';

const _isJs = identical(0, 0.0);

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

  // Values from PyArrow 26 ipc.open_stream(...).read_all().
  test('ZSTD decimal256 stream decodes', () {
    final table = ipc.openStream(base64Decode(_decimalZstd)).readAll();
    final column = table.column(0);
    expect(table.numRows, 55);
    expect(column.nullCount, 19);
    final values = column.toDartList();
    expect(values[0], DecimalValue(-500, 2));
    expect(values[1], isNull);
    expect(values[2], DecimalValue(-498, 2));
    expect(values[50], DecimalValue(-482, 2));
    expect(values[53], DecimalValue(-479, 2));
    expect(values[54], isNull);
  }, skip: _isJs ? 'ZSTD IPC decompression is VM-only' : false);

  // PyArrow 26 reads these as [{a: 1, s: x}, {a: None, s: None}, ...].
  test('metadata V4 input is unsupported, not malformed', () {
    expect(
      () => ipc.openStream(base64Decode(_v4Stream)).readAll(),
      throwsUnsupportedError,
    );
    expect(
      () => ipc.openFile(base64Decode(_v4File)).readAll(),
      throwsUnsupportedError,
    );
  });

}
