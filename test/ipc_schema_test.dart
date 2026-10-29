import 'dart:convert';
import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/ipc.dart' as ipc;
import 'package:test/test.dart';

Schema _readStreamSchema(
  Schema schema, {
  ipc.IpcLimits limits = const ipc.IpcLimits(),
}) => ipc.openStream(ipc.newStream(schema).close(), limits: limits).schema;

void main() {
  test('schema field count and depth limits reject before materialization', () {
    final schema = Schema([
      for (var i = 0; i < 8; i++) field('f$i', nullType()),
    ]);
    expect(
      () =>
          _readStreamSchema(schema, limits: const ipc.IpcLimits(maxFields: 7)),
      throwsFormatException,
    );
    expect(
      _readStreamSchema(schema, limits: const ipc.IpcLimits(maxFields: 8)),
      schema,
    );
    final nested = Schema([
      field('parent', ListType(field('child', string()))),
    ]);
    expect(
      () => _readStreamSchema(nested, limits: const ipc.IpcLimits(maxDepth: 0)),
      throwsFormatException,
    );
  });

  test('map children may share a standard Arrow field name', () {
    final type = MapType(
      field('same', string(), nullable: false),
      field('same', int32()),
    );
    final schema = Schema([field('map', type)]);
    expect(_readStreamSchema(schema), schema);
  });

  test('IPC rejects wrapper compositions it cannot preserve', () {
    for (final type in <DataType>[
      ExtensionType('outer', ExtensionType('inner', string())),
      DictionaryType(int8(), ExtensionType('inner', string())),
    ]) {
      final schema = Schema([field('value', type)]);
      expect(() => ipc.newStream(schema), throwsUnsupportedError);
      expect(() => ipc.newFile(schema), throwsUnsupportedError);
    }
  });

  test('reserved extension metadata cannot change the declared field type', () {
    for (final key in ['ARROW:extension:name', 'ARROW:extension:metadata']) {
      final schema = Schema([
        field('value', string(), metadata: {key: 'spoof'}),
      ]);
      expect(() => ipc.newStream(schema), throwsArgumentError);
      expect(() => ipc.newFile(schema), throwsArgumentError);
    }
  });

  test('binary field and schema metadata bytes are preserved exactly', () {
    final key = Uint8List.fromList([0, 255, 1]);
    final value = Uint8List.fromList([0xfe, 0, 0x80]);
    final schema = Schema(
      [
        field('value', int32(), metadata: {key: value}),
      ],
      metadata: {key: value, 'text': 'ünï'},
    );
    final read = _readStreamSchema(schema);
    expect(read.equals(schema, checkMetadata: true), isTrue);
    expect(read.fields.single.metadata![key], value);
    expect(utf8.decode(read.metadata!['text']!), 'ünï');
  });

  final child = field('item', int32());
  final types = <DataType>[
    nullType(),
    boolType(),
    for (final width in [8, 16, 32, 64]) ...[
      IntegerType(width),
      IntegerType(width, signed: false),
    ],
    for (final width in [16, 32, 64]) FloatingType(width),
    for (final width in [32, 64, 128, 256]) DecimalType(3, -2, bitWidth: width),
    DecimalType(3, 4),
    for (final width in OffsetWidth.values) ...[
      Utf8Type(width),
      BinaryType(width),
    ],
    FixedSizeBinaryType(0),
    FixedSizeBinaryType(12),
    for (final unit in DateUnit.values) DateType(unit),
    for (final unit in TimeUnit.values) ...[
      TimeType(unit),
      TimestampType(unit),
      TimestampType(unit, timeZone: 'Europe/London'),
      DurationType(unit),
    ],
    for (final unit in IntervalUnit.values) IntervalType(unit),
    ListType(child),
    ListType(child, offsetWidth: OffsetWidth.large),
    ListType(child, view: true),
    ListType(child, offsetWidth: OffsetWidth.large, view: true),
    FixedSizeListType(child, 3),
    StructType([child]),
    MapType(field('key', string(), nullable: false), child, keysSorted: true),
    MapType(
      field('k', string(), nullable: false),
      child,
      entriesName: 'pairs',
      entriesMetadata: {'role': 'entries'},
    ),
    for (final mode in UnionMode.values)
      UnionType([child, field('text', string())], typeIds: [3, 7], mode: mode),
    RunEndEncodedType(field('run_ends', int16(), nullable: false), child),
    DictionaryType(int16(), string(), ordered: true),
    ExtensionType(
      'example.uuid',
      FixedSizeBinaryType(16),
      metadata: 'version=1',
    ),
    ExtensionType('example.labels', DictionaryType(int8(), string())),
  ];
  for (final type in types) {
    test('IPC schema preserves $type', () {
      final schema = Schema(
        [
          field('value', type, metadata: {'source': 'test'}),
        ],
        metadata: {'table': 'example'},
      );
      final stream = ipc.openStream(ipc.newStream(schema).close());
      expect(stream.schema.equals(schema, checkMetadata: true), isTrue);
      expect(stream.readAll().numRows, 0);
      final file = ipc.openFile(ipc.newFile(schema).close());
      expect(file.schema.equals(schema, checkMetadata: true), isTrue);
      expect(file.numRecordBatches, 0);
    });
  }

  test('standard IPC preserves unnamed and duplicate fields', () {
    final schema = Schema([
      field('', string()),
      field('same', int32()),
      field('same', int64()),
    ]);
    expect(_readStreamSchema(schema), schema);
  });

  test('binding-only int128 is never mislabeled as standard IPC', () {
    for (final type in [bindingInt128(), bindingUint128()]) {
      final schema = Schema([field('wide', ListType(field('item', type)))]);
      expect(() => ipc.newStream(schema), throwsUnsupportedError);
    }
  });
}
