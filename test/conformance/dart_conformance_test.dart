import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:test/test.dart';

import 'dart_probe.dart' as conformance;

void main() {
  test('independent PyArrow 26 physical capability fixtures', () async {
    final fixture = conformance.object(
      jsonDecode(
        File.fromUri(
          (await Isolate.resolvePackageUri(
            Uri.parse('package:dartaframes_arrow/arrow.dart'),
          ))!.resolve('../test/conformance/fixtures/pyarrow.json'),
        ).readAsStringSync(),
      ),
    );
    final results = conformance.probe(fixture);
    expect(results.where((r) => r['status'] == 'fail'), isEmpty);
  });

  test(
    'foreign bounds, validity, dictionary and batch shape reject invalid input',
    () {
      final type = ArrowIntegerType(32);
      expect(
        () => ArrowArray.fromBuffers(
          type,
          length: -1,
          buffers: [null, Uint8List(0)],
        ),
        throwsArgumentError,
      );
      expect(
        () => ArrowArray.fromBuffers(
          type,
          length: 2,
          buffers: [null, Uint8List(4)],
        ),
        throwsArgumentError,
      );
      expect(
        () => ArrowArray.fromBuffers(
          type,
          length: 9,
          buffers: [Uint8List(1), Uint8List(36)],
        ),
        throwsArgumentError,
      );
      expect(
        () => ArrowArray.fromBuffers(
          type,
          length: 1,
          nullCount: 1,
          buffers: [null, Uint8List(4)],
        ),
        throwsArgumentError,
      );
      final dictionary = ArrowArray(const ArrowUtf8Type(), const [
        ArrowStringValue('x'),
      ]);
      expect(
        () => ArrowArray.fromBuffers(
          ArrowDictionaryType(ArrowIntegerType(8), dictionary.type),
          length: 1,
          buffers: [
            null,
            Uint8List.fromList([1]),
          ],
          dictionary: dictionary,
        ),
        throwsArgumentError,
      );
      final values = ArrowArray(type, [ArrowIntegerValue(1)]);
      expect(() => values.slice(-1), throwsRangeError);
      expect(() => values.slice(0, 2), throwsRangeError);
      expect(
        () => RecordBatch(ArrowSchema([ArrowField('a', type)]), []),
        throwsArgumentError,
      );
    },
  );

  test('parent validity masks independently populated child buffers', () {
    final child = ArrowArray(ArrowIntegerType(8), [
      ArrowIntegerValue(7),
      ArrowIntegerValue(8),
    ]);
    final parent = ArrowArray.fromBuffers(
      ArrowStructType([ArrowField('', child.type, nullable: false)]),
      length: 2,
      buffers: [
        Uint8List.fromList([2]),
      ],
      children: [child],
    );
    expect(parent[0], isNull);
    expect(child[0], ArrowIntegerValue(7));
    expect(
      parent[1],
      ArrowStructValue([ArrowStructEntry('', ArrowIntegerValue(8))]),
    );
  });
}
