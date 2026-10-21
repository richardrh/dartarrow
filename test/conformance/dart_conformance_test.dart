import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart' as pa;
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
      final type = pa.int32();
      expect(
        () => pa.Array.fromBuffers(type, -1, [null, pa.Buffer(Uint8List(0))]),
        throwsArgumentError,
      );
      expect(
        () => pa.Array.fromBuffers(type, 2, [null, pa.Buffer(Uint8List(4))]),
        throwsArgumentError,
      );
      expect(
        () => pa.Array.fromBuffers(type, 9, [
          pa.Buffer(Uint8List(1)),
          pa.Buffer(Uint8List(36)),
        ]),
        throwsArgumentError,
      );
      expect(
        () => pa.Array.fromBuffers(type, 1, [
          null,
          pa.Buffer(Uint8List(4)),
        ], nullCount: 1),
        throwsArgumentError,
      );
      final dictionary = pa.array(['x']);
      expect(
        () =>
            pa.Array.fromBuffers(pa.dictionary(pa.int8(), dictionary.type), 1, [
              null,
              pa.Buffer(Uint8List.fromList([1])),
            ], dictionary: dictionary),
        throwsArgumentError,
      );
      final values = pa.array([1], type: type);
      expect(() => values.slice(-1), throwsRangeError);
      expect(values.slice(0, 2).toDartList(), [1]);
      expect(
        () => pa.RecordBatch.fromArrays(
          [],
          schema: pa.schema([pa.field('a', type)]),
        ),
        throwsArgumentError,
      );
    },
  );

  test('parent validity masks independently populated child buffers', () {
    final child = pa.array([7, 8], type: pa.int8());
    final parent = pa.Array.fromBuffers(
      pa.struct([pa.field('', child.type, nullable: false)]),
      2,
      [
        pa.Buffer(Uint8List.fromList([2])),
      ],
      children: [child],
    );
    expect(parent[0].isValid, isFalse);
    expect(parent[0].asDart(), isNull);
    expect(child[0].asDart(), 7);
    expect(parent[1].asDart(), {'': 8});
  });
}
