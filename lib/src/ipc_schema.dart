part of 'core.dart';

// Mapping between [Schema] and the Arrow `Schema.fbs` FlatBuffers tables.
// Field slots, type union ids and enum values follow the Arrow format
// specification; they are not a private wire format.

const String _ipcExtensionName = 'ARROW:extension:name';
const String _ipcExtensionMetadata = 'ARROW:extension:metadata';

/// A schema field plus the IPC dictionary id of its dictionary encoding (if
/// any) and its IPC children (the children of the storage value type).
final class _IpcField {
  const _IpcField(this.field, this.children, this.dictionaryId);
  final Field field;
  final List<_IpcField> children;
  final int? dictionaryId;
}

/// Decoded or encodable schema plus its per-field IPC descriptors.
final class _IpcSchema {
  const _IpcSchema(this.schema, this.fields);
  final Schema schema;
  final List<_IpcField> fields;
}

/// [type] with extension and dictionary wrappers removed.
DataType _ipcStorage(DataType type) {
  var depth = 0;
  while (type is ExtensionType || type is DictionaryType) {
    if (++depth > 64) throw UnsupportedError('IPC wrapper nesting exceeds 64');
    type = switch (type) {
      ExtensionType(:final storageType) => storageType,
      DictionaryType(:final valueType) => valueType,
      _ => type,
    };
  }
  return type;
}

/// The dictionary encoding of [type] beneath extension wrappers, if any.
DictionaryType? _ipcDictionary(DataType type) {
  var depth = 0;
  while (type is ExtensionType) {
    if (++depth > 64) throw UnsupportedError('IPC wrapper nesting exceeds 64');
    type = type.storageType;
  }
  return type is DictionaryType ? type : null;
}

/// IPC child fields of [type]'s storage value type.
List<Field> _ipcChildFields(DataType input) {
  final type = _ipcStorage(input);
  return switch (type) {
    ListType(:final field) => [field],
    FixedSizeListType(:final field) => [field],
    StructType(:final fields) => fields,
    MapType() => [type.entriesField],
    UnionType(:final fields) => fields,
    RunEndEncodedType(:final runEndsField, :final valuesField) => [
      runEndsField,
      valuesField,
    ],
    _ => const [],
  };
}

/// Assigns dictionary ids in depth-first pre-order and validates that every
/// type has a standard IPC representation.
_IpcSchema _ipcDescribe(Schema schema) {
  var nextId = 0;
  _IpcField visit(Field value, int depth) {
    if (depth > 64) throw ArgumentError('IPC schema nesting exceeds 64');
    _ipcValidateWrappers(value.type);
    final dictionary = _ipcDictionary(value.type);
    final id = dictionary == null ? null : nextId++;
    if (dictionary != null && _ipcDictionary(dictionary.valueType) != null) {
      throw UnsupportedError(
        'Dictionary-of-dictionary IPC fields are unsupported',
      );
    }
    return _IpcField(value, [
      for (final child in _ipcChildFields(value.type)) visit(child, depth + 1),
    ], id);
  }

  return _IpcSchema(schema, [for (final f in schema.fields) visit(f, 0)]);
}

void _ipcValidateWrappers(DataType type) {
  // A field carries a single extension annotation, and a dictionary of
  // extension values cannot preserve its wrapper order in that annotation.
  if (type is ExtensionType) {
    if (type.storageType is ExtensionType) {
      throw UnsupportedError('IPC cannot preserve stacked extension types');
    }
    _ipcValidateWrappers(type.storageType);
  } else if (type is DictionaryType && type.valueType is ExtensionType) {
    throw UnsupportedError(
      'Use extension-over-dictionary for standard Arrow IPC',
    );
  }
}

// ---------------------------------------------------------------- writing --

_FbSlot _ipcMetadataVector(Iterable<MapEntry<List<int>, List<int>>> entries) =>
    _fbVector([
      for (final entry in entries)
        _FbTableObject({0: _fbBytes(entry.key), 1: _fbBytes(entry.value)}),
    ]);

_FbTableObject _ipcSchemaTable(_IpcSchema schema) {
  final metadata = schema.schema.metadata;
  return _FbTableObject({
    0: _fbI16(0), // Endianness.Little
    1: _fbVector([for (final field in schema.fields) _ipcFieldTable(field)]),
    if (metadata != null && metadata.isNotEmpty)
      2: _ipcMetadataVector(metadata.entries),
  });
}

_FbTableObject _ipcFieldTable(_IpcField descriptor) {
  final field = descriptor.field;
  final metadata = <MapEntry<List<int>, List<int>>>[
    ...?field.metadata?.entries,
  ];
  if (field.metadata?[_ipcExtensionName] != null ||
      field.metadata?[_ipcExtensionMetadata] != null) {
    throw ArgumentError(
      'Use ExtensionType instead of reserved extension metadata keys',
    );
  }
  var type = field.type;
  if (type is ExtensionType) {
    metadata
      ..add(MapEntry(utf8.encode(_ipcExtensionName), utf8.encode(type.name)))
      ..addAll([
        if (type.metadata != null)
          MapEntry(
            utf8.encode(_ipcExtensionMetadata),
            utf8.encode(type.metadata!),
          ),
      ]);
  }
  final dictionary = _ipcDictionary(type);
  type = _ipcStorage(type);
  final (id, table) = _ipcTypeTable(type);
  return _FbTableObject({
    0: _fbString(field.name),
    1: _fbBool(field.nullable),
    2: _fbU8(id),
    3: _FbRef(table),
    if (dictionary != null)
      4: _fbTable({
        0: _fbI64(descriptor.dictionaryId!),
        1: _FbRef(_ipcIntegerTable(dictionary.indexType as IntegerType)),
        2: _fbBool(dictionary.ordered),
      }),
    if (descriptor.children.isNotEmpty)
      5: _fbVector([
        for (final child in descriptor.children) _ipcFieldTable(child),
      ]),
    if (metadata.isNotEmpty) 6: _ipcMetadataVector(metadata),
  });
}

void _ipcRejectBindingInteger(IntegerType type) {
  if (type.bitWidth > 64) {
    throw UnsupportedError(
      'int128/uint128 are binding extensions, not Arrow IPC integer types',
    );
  }
}

_FbTableObject _ipcIntegerTable(IntegerType type) {
  _ipcRejectBindingInteger(type);
  return _FbTableObject({0: _fbI32(type.bitWidth), 1: _fbBool(type.signed)});
}

int _ipcTimeIndex(TimeUnit unit) => switch (unit) {
  TimeUnit.second => 0,
  TimeUnit.millisecond => 1,
  TimeUnit.microsecond => 2,
  TimeUnit.nanosecond => 3,
};

const List<TimeUnit> _ipcTimeUnits = [
  TimeUnit.second,
  TimeUnit.millisecond,
  TimeUnit.microsecond,
  TimeUnit.nanosecond,
];

(int, _FbTableObject) _ipcTypeTable(DataType type) {
  const empty = _FbTableObject({});
  int offsetType(OffsetWidth width, int normal, int large, int view) =>
      switch (width) {
        OffsetWidth.normal => normal,
        OffsetWidth.large => large,
        OffsetWidth.view => view,
      };
  return switch (type) {
    NullType() => (1, empty),
    IntegerType() => (2, _ipcIntegerTable(type)),
    FloatingType(:final bitWidth) => (
      3,
      _FbTableObject({
        0: _fbI16(const [16, 32, 64].indexOf(bitWidth)),
      }),
    ),
    BinaryType(:final offsetWidth) => (
      offsetType(offsetWidth, 4, 19, 23),
      empty,
    ),
    Utf8Type(:final offsetWidth) => (offsetType(offsetWidth, 5, 20, 24), empty),
    BooleanType() => (6, empty),
    DecimalType(:final precision, :final scale, :final bitWidth) => (
      7,
      _FbTableObject({
        0: _fbI32(precision),
        1: _fbI32(scale),
        2: _fbI32(bitWidth),
      }),
    ),
    DateType(:final unit) => (
      8,
      _FbTableObject({0: _fbI16(unit == DateUnit.day ? 0 : 1)}),
    ),
    TimeType(:final unit) => (
      9,
      _FbTableObject({
        0: _fbI16(_ipcTimeIndex(unit)),
        1: _fbI32(_ipcTimeIndex(unit) < 2 ? 32 : 64),
      }),
    ),
    TimestampType(:final unit, :final timeZone) => (
      10,
      _FbTableObject({
        0: _fbI16(_ipcTimeIndex(unit)),
        if (timeZone != null) 1: _fbString(timeZone),
      }),
    ),
    IntervalType(:final unit) => (11, _FbTableObject({0: _fbI16(unit.index)})),
    ListType(:final offsetWidth, :final view) => (
      view
          ? (offsetWidth == OffsetWidth.large ? 26 : 25)
          : (offsetWidth == OffsetWidth.large ? 21 : 12),
      empty,
    ),
    StructType() => (13, empty),
    UnionType(:final mode, :final typeIds) => (
      14,
      _FbTableObject({0: _fbI16(mode.index), 1: _ipcInt32Vector(typeIds)}),
    ),
    FixedSizeBinaryType(:final byteWidth) => (
      15,
      _FbTableObject({0: _fbI32(byteWidth)}),
    ),
    FixedSizeListType(:final size) => (16, _FbTableObject({0: _fbI32(size)})),
    MapType(:final keysSorted) => (
      17,
      _FbTableObject({0: _fbBool(keysSorted)}),
    ),
    DurationType(:final unit) => (
      18,
      _FbTableObject({0: _fbI16(_ipcTimeIndex(unit))}),
    ),
    RunEndEncodedType() => (22, empty),
    DictionaryType() || ExtensionType() => throw StateError(
      'IPC wrappers must be removed before encoding $type',
    ),
  };
}

_FbSlot _ipcInt32Vector(List<int> values) {
  final bytes = Uint8List(4 * values.length);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < values.length; i++) {
    data.setInt32(4 * i, values[i], Endian.little);
  }
  return _fbStructs(bytes, values.length);
}

// ---------------------------------------------------------------- reading --

/// Reads a KeyValue vector as raw byte pairs, rejecting duplicate keys.
List<MapEntry<Uint8List, Uint8List>> _ipcReadMetadata(
  _FbTableView table,
  int slot,
) {
  final result = <MapEntry<Uint8List, Uint8List>>[];
  final seen = <String>{};
  for (final item in table.tables(slot)) {
    final key = item.bytes(0);
    if (key == null || !seen.add(base64Encode(key))) {
      throw const FormatException('Invalid or duplicate IPC metadata key');
    }
    result.add(MapEntry(key, item.bytes(1) ?? Uint8List(0)));
  }
  return result;
}

Map<Object, Object>? _ipcMetadataMap(
  List<MapEntry<Uint8List, Uint8List>> entries,
) => entries.isEmpty ? null : Map<Object, Object>.fromEntries(entries);

bool _ipcIsKey(Uint8List key, String name) {
  final expected = utf8.encode(name);
  if (key.length != expected.length) return false;
  for (var i = 0; i < key.length; i++) {
    if (key[i] != expected[i]) return false;
  }
  return true;
}

_IpcSchema _ipcReadSchema(_FbTableView table, IpcLimits limits) {
  if (table.i16(0, 0) != 0) {
    throw UnsupportedError('Big-endian Arrow IPC is unsupported');
  }
  var count = 0;
  final dictionaries = <int, DictionaryType>{};
  _IpcField visit(_FbTableView table, int depth) {
    if (depth > limits.maxDepth || ++count > limits.maxFields) {
      throw const FormatException(
        'IPC schema nesting or field count limit exceeded',
      );
    }
    final children = [
      for (final child in table.tables(5)) visit(child, depth + 1),
    ];
    final payload = table.table(3);
    if (payload == null) throw const FormatException('Missing IPC field type');
    var type = _ipcReadType(table.u8(2, 0), payload, [
      for (final child in children) child.field,
    ]);
    final encoding = table.table(4);
    int? dictionaryId;
    if (encoding != null) {
      dictionaryId = encoding.i64(0, 0);
      if (encoding.i16(3, 0) != 0) {
        throw const FormatException('Invalid IPC dictionary encoding kind');
      }
      final index = encoding.table(1);
      final dictionary = DictionaryType(
        index == null ? IntegerType(32) : _ipcReadInteger(index),
        type,
        ordered: encoding.boolean(2, false),
      );
      final existing = dictionaries[dictionaryId];
      if (existing != null && existing.valueType != dictionary.valueType) {
        throw const FormatException('Conflicting shared IPC dictionary types');
      }
      dictionaries[dictionaryId] = dictionary;
      type = dictionary;
    }
    final metadata = _ipcReadMetadata(table, 6);
    Uint8List? take(String name) {
      final at = metadata.indexWhere((e) => _ipcIsKey(e.key, name));
      return at < 0 ? null : metadata.removeAt(at).value;
    }

    final extension = take(_ipcExtensionName);
    final extensionMetadata = take(_ipcExtensionMetadata);
    if (extension != null) {
      type = ExtensionType(
        utf8.decode(extension),
        type,
        metadata: extensionMetadata == null
            ? null
            : utf8.decode(extensionMetadata),
      );
    } else if (extensionMetadata != null) {
      // Without a name the metadata is ordinary field metadata.
      metadata.add(
        MapEntry(utf8.encode(_ipcExtensionMetadata), extensionMetadata),
      );
    }
    return _IpcField(
      Field(
        table.string(0) ?? '',
        type,
        nullable: table.boolean(1, false),
        metadata: _ipcMetadataMap(metadata),
      ),
      children,
      dictionaryId,
    );
  }

  final fields = [for (final item in table.tables(1)) visit(item, 0)];
  return _IpcSchema(
    Schema([
      for (final item in fields) item.field,
    ], metadata: _ipcMetadataMap(_ipcReadMetadata(table, 2))),
    fields,
  );
}

IntegerType _ipcReadInteger(_FbTableView table) {
  final width = table.i32(0, 0);
  if (width != 8 && width != 16 && width != 32 && width != 64) {
    throw FormatException('Invalid standard integer width $width');
  }
  return IntegerType(width, signed: table.boolean(1, false));
}

T _ipcEnum<T>(List<T> values, int index, String name) {
  if (index < 0 || index >= values.length) {
    throw FormatException('Unknown IPC $name enum $index');
  }
  return values[index];
}

const Set<int> _ipcNestedTypeIds = {12, 13, 14, 16, 17, 21, 22, 25, 26};

DataType _ipcReadType(int id, _FbTableView table, List<Field> children) {
  if (!_ipcNestedTypeIds.contains(id) && children.isNotEmpty) {
    throw const FormatException('Primitive IPC field cannot have children');
  }
  return switch (id) {
    1 => const NullType(),
    2 => _ipcReadInteger(table),
    3 => FloatingType(
      _ipcEnum(const [16, 32, 64], table.i16(0, 0), 'precision'),
    ),
    4 => const BinaryType(),
    5 => const Utf8Type(),
    6 => const BooleanType(),
    7 => DecimalType(
      table.i32(0, 0),
      table.i32(1, 0),
      bitWidth: table.i32(2, 128),
    ),
    8 => DateType(_ipcEnum(DateUnit.values, table.i16(0, 1), 'date unit')),
    9 => _ipcReadTime(table),
    10 => TimestampType(
      _ipcEnum(_ipcTimeUnits, table.i16(0, 0), 'timestamp unit'),
      timeZone: table.string(1),
    ),
    11 => IntervalType(
      _ipcEnum(IntervalUnit.values, table.i16(0, 0), 'interval unit'),
    ),
    15 => FixedSizeBinaryType(table.i32(0, 0)),
    18 => DurationType(
      _ipcEnum(_ipcTimeUnits, table.i16(0, 1), 'duration unit'),
    ),
    19 => const BinaryType(OffsetWidth.large),
    20 => const Utf8Type(OffsetWidth.large),
    23 => const BinaryType(OffsetWidth.view),
    24 => const Utf8Type(OffsetWidth.view),
    _ => _ipcReadNestedType(id, table, children),
  };
}

DataType _ipcReadTime(_FbTableView table) {
  final unit = _ipcEnum(_ipcTimeUnits, table.i16(0, 1), 'time unit');
  if (table.i32(1, 32) != (_ipcTimeIndex(unit) < 2 ? 32 : 64)) {
    throw const FormatException('Time unit and bit width disagree');
  }
  return TimeType(unit);
}

DataType _ipcReadNestedType(int id, _FbTableView table, List<Field> children) {
  Field single() {
    if (children.length != 1) {
      throw const FormatException('IPC list/map needs exactly one child');
    }
    return children.single;
  }

  switch (id) {
    case 12:
      return ListType(single());
    case 13:
      return StructType(children);
    case 14:
      final ids = table.structs(1, 4);
      if (ids.count != 0 && ids.count != children.length) {
        throw const FormatException('Union type ids do not match children');
      }
      return UnionType(
        children,
        typeIds: ids.count == 0
            ? null
            : [for (var i = 0; i < ids.count; i++) ids.i32(i, 0)],
        mode: _ipcEnum(UnionMode.values, table.i16(0, 0), 'union mode'),
      );
    case 16:
      return FixedSizeListType(single(), table.i32(0, 0));
    case 17:
      final entries = single();
      final struct = entries.type;
      if (entries.nullable ||
          struct is! StructType ||
          struct.fields.length != 2) {
        throw const FormatException('Invalid IPC map entry layout');
      }
      return MapType(
        struct.fields[0],
        struct.fields[1],
        keysSorted: table.boolean(0, false),
        entriesName: entries.name,
        entriesMetadata: entries.metadata,
      );
    case 21:
      return ListType(single(), offsetWidth: OffsetWidth.large);
    case 22:
      if (children.length != 2) {
        throw const FormatException(
          'Run-end encoded IPC requires two children',
        );
      }
      return RunEndEncodedType(children[0], children[1]);
    case 25:
      return ListType(single(), view: true);
    case 26:
      return ListType(single(), offsetWidth: OffsetWidth.large, view: true);
    default:
      throw UnsupportedError('Unknown Arrow IPC type ID $id');
  }
}
