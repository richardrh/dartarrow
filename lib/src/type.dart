part of 'core.dart';

enum TimeUnit {
  second('seconds'),
  millisecond('milliseconds'),
  microsecond('microseconds'),
  nanosecond('nanoseconds');

  const TimeUnit(this.jsonName);
  final String jsonName;

  String get shortName => switch (this) {
    TimeUnit.second => 's',
    TimeUnit.millisecond => 'ms',
    TimeUnit.microsecond => 'us',
    TimeUnit.nanosecond => 'ns',
  };

  static TimeUnit parse(String value) => values.firstWhere(
    (unit) =>
        unit.jsonName == value || unit.name == value || unit.shortName == value,
    orElse: () => throw FormatException('Unknown time unit: $value'),
  );
}

enum DateUnit { day, millisecond }

/// Offset layout of variable-length strings and binaries. [view] selects the
/// Arrow `Utf8View`/`BinaryView` layouts (16-byte views plus data buffers).
enum OffsetWidth { normal, large, view }

/// Physical layout of a union: sparse (children as long as the union) or
/// dense (an int32 offsets buffer indexes into each child).
enum UnionMode { sparse, dense }

/// Calendar interval units of the Arrow `Interval` type.
enum IntervalUnit { yearMonth, dayTime, monthDayNano }

sealed class DataType {
  const DataType();

  Map<String, Object?> toJson();

  static DataType fromJson(Map<String, Object?> json) {
    try {
      return _fromJson(json);
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('Invalid Arrow datatype: $error');
    } on TypeError catch (error) {
      throw FormatException('Invalid Arrow datatype shape: $error');
    }
  }

  static DataType _fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    if (kind is! String)
      throw const FormatException('dtype.kind must be a string');
    int integer(String name) {
      final value = json[name];
      if (value is! int)
        throw FormatException('dtype.$name must be an integer');
      return value;
    }

    String string(String name) {
      final value = json[name];
      if (value is! String)
        throw FormatException('dtype.$name must be a string');
      return value;
    }

    Map<String, Object?> object(String name) {
      final value = json[name];
      if (value is! Map) throw FormatException('dtype.$name must be an object');
      return _stringObjectMap(value, 'dtype.$name');
    }

    bool boolean(String name, bool defaultValue) {
      final value = json[name];
      if (value == null && !json.containsKey(name)) return defaultValue;
      if (value is! bool) {
        throw FormatException('dtype.$name must be a boolean');
      }
      return value;
    }

    String? optionalString(String name) {
      final value = json[name];
      if (value == null && !json.containsKey(name)) return null;
      if (value is! String) {
        throw FormatException('dtype.$name must be a string');
      }
      return value;
    }

    switch (kind) {
      case 'null':
        return const NullType();
      case 'boolean':
        return const BooleanType();
      case 'int8':
        return IntegerType(8);
      case 'int16':
        return IntegerType(16);
      case 'int32':
        return IntegerType(32);
      case 'int64':
        return IntegerType(64);
      case 'int128':
        return IntegerType(128);
      case 'uint8':
        return IntegerType(8, signed: false);
      case 'uint16':
        return IntegerType(16, signed: false);
      case 'uint32':
        return IntegerType(32, signed: false);
      case 'uint64':
        return IntegerType(64, signed: false);
      case 'uint128':
        return IntegerType(128, signed: false);
      case 'float16':
        return FloatingType(16);
      case 'float32':
        return FloatingType(32);
      case 'float64':
        return FloatingType(64);
      case 'decimal':
        final bitWidth = json['bitWidth'];
        if (bitWidth != null && bitWidth is! int) {
          throw const FormatException('dtype.bitWidth must be an integer');
        }
        return DecimalType(
          integer('precision'),
          integer('scale'),
          bitWidth: (bitWidth as int?) ?? 128,
        );
      case 'string':
      case 'utf8':
        return const Utf8Type();
      case 'largeString':
      case 'largeUtf8':
        return const Utf8Type(OffsetWidth.large);
      case 'binary':
        return const BinaryType();
      case 'largeBinary':
        return const BinaryType(OffsetWidth.large);
      case 'date':
        return switch (string('unit')) {
          'days' => const DateType(),
          'milliseconds' => const DateType(DateUnit.millisecond),
          final unit => throw FormatException('Unknown date unit: $unit'),
        };
      case 'datetime':
      case 'timestamp':
        return TimestampType(
          TimeUnit.parse(string('unit')),
          timeZone: optionalString('timeZone'),
        );
      case 'duration':
        return DurationType(TimeUnit.parse(string('unit')));
      case 'time':
        return TimeType(TimeUnit.parse(string('unit')));
      case 'list':
        return ListType(Field.fromJson(object('field')));
      case 'fixedSizeList':
      case 'array':
        return FixedSizeListType(
          Field.fromJson(object('field')),
          integer('size'),
        );
      case 'struct':
        final fields = json['fields'];
        if (fields is! List)
          throw const FormatException('dtype.fields must be a list');
        return StructType(
          fields.indexed
              .map(
                (e) => Field.fromJson(
                  _stringObjectMap(e.$2, 'dtype.fields[${e.$1}]'),
                ),
              )
              .toList(),
        );
      case 'dictionary':
        return DictionaryType(
          DataType.fromJson(object('indexType')),
          DataType.fromJson(object('valueType')),
          ordered: boolean('ordered', false),
        );
      case 'extension':
        return ExtensionType(
          string('name'),
          DataType.fromJson(object('storageType')),
          metadata: optionalString('metadata'),
        );
      default:
        return _extendedFromJson(kind, json, integer, string, object, boolean);
    }
  }

  static DataType _extendedFromJson(
    String kind,
    Map<String, Object?> json,
    int Function(String) integer,
    String Function(String) string,
    Map<String, Object?> Function(String) object,
    bool Function(String, bool) boolean,
  ) {
    Field field(String name) => Field.fromJson(object(name));
    switch (kind) {
      case 'largeList':
        return ListType(field('field'), offsetWidth: OffsetWidth.large);
      case 'listView':
        return ListType(field('field'), view: true);
      case 'largeListView':
        return ListType(
          field('field'),
          offsetWidth: OffsetWidth.large,
          view: true,
        );
      case 'stringView':
      case 'utf8View':
        return const Utf8Type(OffsetWidth.view);
      case 'binaryView':
        return const BinaryType(OffsetWidth.view);
      case 'fixedSizeBinary':
        return FixedSizeBinaryType(integer('byteWidth'));
      case 'map':
        return MapType(
          field('key'),
          // `item` is PyArrow's spelling of the value field.
          field(json.containsKey('item') ? 'item' : 'value'),
          keysSorted: boolean('keysSorted', false),
          entriesName: json.containsKey('entriesName')
              ? string('entriesName')
              : 'entries',
          entriesMetadata: ByteMetadata.fromJson(json['entriesMetadata']),
        );
      case 'union' || 'sparseUnion' || 'denseUnion':
        final fields = json['fields'];
        // `typeCodes` is PyArrow's spelling of the child type ids.
        final ids = json['typeIds'] ?? json['typeCodes'];
        if (fields is! List) {
          throw const FormatException('dtype.fields must be a list');
        }
        if (ids is! List || ids.any((id) => id is! int)) {
          throw const FormatException('dtype.typeIds must be integers');
        }
        return UnionType(
          [
            for (final (i, f) in fields.indexed)
              Field.fromJson(_stringObjectMap(f, 'dtype.fields[$i]')),
          ],
          mode: switch (kind == 'union' ? string('mode') : kind) {
            'sparseUnion' => UnionMode.sparse,
            'denseUnion' => UnionMode.dense,
            'sparse' => UnionMode.sparse,
            'dense' => UnionMode.dense,
            final mode => throw FormatException('Unknown union mode: $mode'),
          },
          typeIds: ids.cast<int>(),
        );
      case 'interval':
        final unit = string('unit');
        return IntervalType(
          IntervalUnit.values.firstWhere(
            (u) => u.name == unit,
            orElse: () => throw FormatException('Unknown interval unit: $unit'),
          ),
        );
      case 'yearMonthInterval':
        return const IntervalType(IntervalUnit.yearMonth);
      case 'dayTimeInterval':
        return const IntervalType(IntervalUnit.dayTime);
      case 'monthDayNanoInterval':
        return const IntervalType(IntervalUnit.monthDayNano);
      case 'runEndEncoded':
        if (json.containsKey('runEndType')) {
          // PyArrow-style descriptor with the conventional child names.
          return RunEndEncodedType(
            Field(
              'run_ends',
              DataType.fromJson(object('runEndType')),
              nullable: false,
            ),
            Field('values', DataType.fromJson(object('valueType'))),
          );
        }
        return RunEndEncodedType(field('runEnds'), field('values'));
      default:
        throw FormatException('Unknown Arrow datatype kind: $kind');
    }
  }

  bool equals(DataType other, {bool checkMetadata = false}) {
    if (this is ListType && other is ListType) {
      final self = this as ListType;
      return self.offsetWidth == other.offsetWidth &&
          self.view == other.view &&
          self.field.equals(other.field, checkMetadata: checkMetadata);
    }
    if (this is MapType && other is MapType) {
      final self = this as MapType;
      return self.keysSorted == other.keysSorted &&
          self.entriesName == other.entriesName &&
          (!checkMetadata ||
              _metadataEquals(self.entriesMetadata, other.entriesMetadata)) &&
          self.keyField.equals(other.keyField, checkMetadata: checkMetadata) &&
          self.valueField.equals(
            other.valueField,
            checkMetadata: checkMetadata,
          );
    }
    if (this is UnionType && other is UnionType) {
      final self = this as UnionType;
      if (self.mode != other.mode ||
          !_listEquals(self.typeIds, other.typeIds) ||
          self.fields.length != other.fields.length) {
        return false;
      }
      for (var i = 0; i < self.fields.length; i++) {
        if (!self.fields[i].equals(
          other.fields[i],
          checkMetadata: checkMetadata,
        )) {
          return false;
        }
      }
      return true;
    }
    if (this is RunEndEncodedType && other is RunEndEncodedType) {
      final self = this as RunEndEncodedType;
      return self.runEndsField.equals(
            other.runEndsField,
            checkMetadata: checkMetadata,
          ) &&
          self.valuesField.equals(
            other.valuesField,
            checkMetadata: checkMetadata,
          );
    }
    if (this is FixedSizeListType && other is FixedSizeListType) {
      final self = this as FixedSizeListType;
      return self.size == other.size &&
          self.field.equals(other.field, checkMetadata: checkMetadata);
    }
    if (this is StructType && other is StructType) {
      final fields = (this as StructType).fields;
      if (fields.length != other.fields.length) return false;
      for (var i = 0; i < fields.length; i++) {
        if (!fields[i].equals(other.fields[i], checkMetadata: checkMetadata)) {
          return false;
        }
      }
      return true;
    }
    if (this is DictionaryType && other is DictionaryType) {
      final self = this as DictionaryType;
      return self.ordered == other.ordered &&
          self.indexType.equals(
            other.indexType,
            checkMetadata: checkMetadata,
          ) &&
          self.valueType.equals(other.valueType, checkMetadata: checkMetadata);
    }
    if (this is ExtensionType && other is ExtensionType) {
      final self = this as ExtensionType;
      return self.name == other.name &&
          self.metadata == other.metadata &&
          self.storageType.equals(
            other.storageType,
            checkMetadata: checkMetadata,
          );
    }
    return _deepEquals(toJson(), other.toJson());
  }

  @override
  bool operator ==(Object other) => other is DataType && equals(other);

  @override
  int get hashCode => switch (this) {
    ListType type => Object.hash(
      ListType,
      type.offsetWidth,
      type.view,
      type.field,
    ),
    MapType type => Object.hash(
      MapType,
      type.keyField,
      type.valueField,
      type.keysSorted,
      type.entriesName,
    ),
    UnionType type => Object.hash(
      UnionType,
      type.mode,
      Object.hashAll(type.typeIds),
      Object.hashAll(type.fields),
    ),
    RunEndEncodedType type => Object.hash(
      RunEndEncodedType,
      type.runEndsField,
      type.valuesField,
    ),
    FixedSizeListType type => Object.hash(
      FixedSizeListType,
      type.size,
      type.field,
    ),
    StructType type => Object.hash(StructType, Object.hashAll(type.fields)),
    DictionaryType type => Object.hash(
      DictionaryType,
      type.indexType,
      type.valueType,
      type.ordered,
    ),
    ExtensionType type => Object.hash(
      ExtensionType,
      type.name,
      type.storageType,
      type.metadata,
    ),
    _ => _deepHash(toJson()),
  };

  @override
  String toString() => toJson().toString();
}

final class NullType extends DataType {
  const NullType();
  @override
  Map<String, Object?> toJson() => const {'kind': 'null'};
}

final class BooleanType extends DataType {
  const BooleanType();
  @override
  Map<String, Object?> toJson() => const {'kind': 'boolean'};
}

final class IntegerType extends DataType {
  IntegerType(this.bitWidth, {this.signed = true}) {
    if (bitWidth != 8 &&
        bitWidth != 16 &&
        bitWidth != 32 &&
        bitWidth != 64 &&
        bitWidth != 128) {
      throw ArgumentError.value(
        bitWidth,
        'bitWidth',
        'must be 8, 16, 32, 64, or 128',
      );
    }
  }
  final int bitWidth;
  final bool signed;
  BigInt get minimum => signed ? -(BigInt.one << (bitWidth - 1)) : BigInt.zero;
  BigInt get maximum => signed
      ? (BigInt.one << (bitWidth - 1)) - BigInt.one
      : (BigInt.one << bitWidth) - BigInt.one;
  @override
  Map<String, Object?> toJson() => {'kind': '${signed ? '' : 'u'}int$bitWidth'};
}

final class FloatingType extends DataType {
  FloatingType(this.bitWidth) {
    if (bitWidth != 16 && bitWidth != 32 && bitWidth != 64) {
      throw ArgumentError.value(bitWidth, 'bitWidth', 'must be 16, 32, or 64');
    }
  }
  final int bitWidth;
  @override
  Map<String, Object?> toJson() => {'kind': 'float$bitWidth'};
}

final class DecimalType extends DataType {
  /// A decimal stored in [bitWidth] 32, 64, 128 (default), or 256 bits.
  ///
  /// Maximum precision is 9, 18, 38, or 76 respectively. [scale] may be any
  /// signed 32-bit integer, including negative scales and scales above
  /// [precision], as Arrow permits (value = unscaled * 10^-scale).
  DecimalType(this.precision, this.scale, {this.bitWidth = 128}) {
    final maxPrecision = switch (bitWidth) {
      32 => 9,
      64 => 18,
      128 => 38,
      256 => 76,
      _ => throw ArgumentError.value(
        bitWidth,
        'bitWidth',
        'must be 32, 64, 128, or 256',
      ),
    };
    if (precision < 1 || precision > maxPrecision) {
      throw RangeError.range(precision, 1, maxPrecision, 'precision');
    }
    if (scale < -2147483648 || scale > 2147483647) {
      throw RangeError.range(scale, -2147483648, 2147483647, 'scale');
    }
  }
  final int precision;
  final int scale;

  /// Storage width in bits.
  final int bitWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'decimal',
    'precision': precision,
    'scale': scale,
    if (bitWidth != 128) 'bitWidth': bitWidth,
  };
}

final class Utf8Type extends DataType {
  const Utf8Type([this.offsetWidth = OffsetWidth.normal]);
  final OffsetWidth offsetWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': switch (offsetWidth) {
      OffsetWidth.normal => 'string',
      OffsetWidth.large => 'largeString',
      OffsetWidth.view => 'stringView',
    },
  };
}

final class BinaryType extends DataType {
  const BinaryType([this.offsetWidth = OffsetWidth.normal]);
  final OffsetWidth offsetWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': switch (offsetWidth) {
      OffsetWidth.normal => 'binary',
      OffsetWidth.large => 'largeBinary',
      OffsetWidth.view => 'binaryView',
    },
  };
}

/// Fixed-width binary: every value has exactly [byteWidth] bytes.
final class FixedSizeBinaryType extends DataType {
  FixedSizeBinaryType(this.byteWidth) {
    if (byteWidth < 0) {
      throw RangeError.value(byteWidth, 'byteWidth', 'must be non-negative');
    }
  }
  final int byteWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'fixedSizeBinary',
    'byteWidth': byteWidth,
  };
}

final class DateType extends DataType {
  const DateType([this.unit = DateUnit.day]);
  final DateUnit unit;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'date',
    'unit': unit == DateUnit.day ? 'days' : 'milliseconds',
  };
}

final class TimestampType extends DataType {
  const TimestampType(this.unit, {this.timeZone});
  final TimeUnit unit;
  final String? timeZone;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'datetime',
    'unit': unit.jsonName,
    if (timeZone != null) 'timeZone': timeZone,
  };
}

final class DurationType extends DataType {
  const DurationType(this.unit);
  final TimeUnit unit;
  @override
  Map<String, Object?> toJson() => {'kind': 'duration', 'unit': unit.jsonName};
}

final class TimeType extends DataType {
  const TimeType(this.unit);
  final TimeUnit unit;
  @override
  Map<String, Object?> toJson() => {'kind': 'time', 'unit': unit.jsonName};
}

/// Variable-length list. [offsetWidth] selects `List` (normal) or `LargeList`
/// (large); [view] selects the `ListView`/`LargeListView` layouts.
final class ListType extends DataType {
  ListType(
    this.field, {
    this.offsetWidth = OffsetWidth.normal,
    this.view = false,
  }) {
    if (offsetWidth == OffsetWidth.view) {
      throw ArgumentError.value(
        offsetWidth,
        'offsetWidth',
        'use view: true for list views',
      );
    }
  }
  final Field field;
  final OffsetWidth offsetWidth;
  final bool view;
  @override
  Map<String, Object?> toJson() => {
    'kind': switch ((offsetWidth == OffsetWidth.large, view)) {
      (false, false) => 'list',
      (true, false) => 'largeList',
      (false, true) => 'listView',
      (true, true) => 'largeListView',
    },
    'field': field.toJson(),
  };
}

final class FixedSizeListType extends DataType {
  FixedSizeListType(this.field, this.size) {
    if (size < 0) throw RangeError.value(size, 'size', 'must be non-negative');
  }
  final Field field;
  final int size;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'fixedSizeList',
    'field': field.toJson(),
    'size': size,
  };
}

final class StructType extends DataType {
  StructType(List<Field> fields) : fields = List.unmodifiable(fields);
  final List<Field> fields;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'struct',
    'fields': fields.map((f) => f.toJson()).toList(),
  };
}

final class DictionaryType extends DataType {
  DictionaryType(this.indexType, this.valueType, {this.ordered = false}) {
    if (indexType is! IntegerType) {
      throw ArgumentError.value(
        indexType,
        'indexType',
        'must be an integer type',
      );
    }
  }
  final DataType indexType;
  final DataType valueType;
  final bool ordered;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'dictionary',
    'indexType': indexType.toJson(),
    'valueType': valueType.toJson(),
    'ordered': ordered,
  };
}

final class ExtensionType extends DataType {
  ExtensionType(this.name, this.storageType, {this.metadata}) {
    if (name.isEmpty)
      throw ArgumentError.value(name, 'name', 'must not be empty');
  }
  final String name;
  final DataType storageType;
  final String? metadata;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'extension',
    'name': name,
    'storageType': storageType.toJson(),
    if (metadata != null) 'metadata': metadata,
  };
}

/// Arrow `Map`: a list of non-null `entries` structs of `<key, value>`.
///
/// The key field must be non-nullable. Entry order and duplicate keys are
/// preserved; [keysSorted] only records the producer's claim.
final class MapType extends DataType {
  MapType(
    this.keyField,
    this.valueField, {
    this.keysSorted = false,
    this.entriesName = 'entries',
    Map<Object, Object>? entriesMetadata,
  }) : entriesMetadata = entriesMetadata == null
           ? null
           : entriesMetadata is ByteMetadata
           ? entriesMetadata
           : ByteMetadata(entriesMetadata) {
    if (keyField.nullable) {
      throw ArgumentError.value(keyField, 'keyField', 'must be non-nullable');
    }
  }
  final Field keyField;
  final Field valueField;
  final bool keysSorted;
  final String entriesName;

  /// Metadata of the physical entries child field, preserved for fidelity.
  final ByteMetadata? entriesMetadata;

  /// The physical child field: a non-null struct of key and value.
  Field get entriesField => Field(
    entriesName,
    StructType([keyField, valueField]),
    nullable: false,
    metadata: entriesMetadata,
  );

  /// The key datatype, as PyArrow's `MapType.key_type`.
  DataType get keyType => keyField.type;

  /// The item datatype, as PyArrow's `MapType.item_type`.
  DataType get itemType => valueField.type;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'map',
    'key': keyField.toJson(),
    'value': valueField.toJson(),
    'keysSorted': keysSorted,
    if (entriesName != 'entries') 'entriesName': entriesName,
    if (entriesMetadata != null) 'entriesMetadata': entriesMetadata!.toJson(),
  };
}

/// Arrow sparse or dense union. Each child has a type id (default its index).
final class UnionType extends DataType {
  UnionType(
    List<Field> fields, {
    this.mode = UnionMode.sparse,
    List<int>? typeIds,
  }) : fields = List.unmodifiable(fields),
       typeIds = List.unmodifiable(
         typeIds ?? List.generate(fields.length, (i) => i),
       ) {
    if (this.typeIds.length != fields.length) {
      throw ArgumentError('Union typeIds length must match field count');
    }
    final seen = <int>{};
    for (final id in this.typeIds) {
      if (id < 0 || id > 127) throw RangeError.range(id, 0, 127, 'typeId');
      if (!seen.add(id)) throw ArgumentError('Duplicate union type id: $id');
    }
  }
  final List<Field> fields;
  final UnionMode mode;
  final List<int> typeIds;

  /// Child index for [typeId], or -1 when undeclared.
  int childIndexForTypeId(int typeId) => typeIds.indexOf(typeId);
  @override
  Map<String, Object?> toJson() => {
    'kind': 'union',
    'mode': mode.name,
    'typeIds': typeIds,
    'fields': fields.map((f) => f.toJson()).toList(),
  };
}

/// Calendar interval in the given [unit].
final class IntervalType extends DataType {
  const IntervalType(this.unit);
  final IntervalUnit unit;
  @override
  Map<String, Object?> toJson() => {'kind': 'interval', 'unit': unit.name};
}

/// Run-end encoded data. [runEndsField] must be a non-nullable int16, int32,
/// or int64 field.
final class RunEndEncodedType extends DataType {
  RunEndEncodedType(this.runEndsField, this.valuesField) {
    final type = runEndsField.type;
    if (type is! IntegerType ||
        !type.signed ||
        type.bitWidth < 16 ||
        type.bitWidth > 64 ||
        runEndsField.nullable) {
      throw ArgumentError.value(
        runEndsField,
        'runEndsField',
        'must be a non-nullable int16, int32, or int64 field',
      );
    }
  }
  final Field runEndsField;
  final Field valuesField;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'runEndEncoded',
    'runEnds': runEndsField.toJson(),
    'values': valuesField.toJson(),
  };
}

bool _deepEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((k) => b.containsKey(k) && _deepEquals(a[k], b[k]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _deepEquals(a[i], b[i]));
  }
  return a == b;
}

int _deepHash(Object? value) {
  if (value is Map)
    return Object.hashAllUnordered(
      value.entries.map((e) => Object.hash(e.key, _deepHash(e.value))),
    );
  if (value is List) return Object.hashAll(value.map(_deepHash));
  return value.hashCode;
}

Map<String, Object?> _stringObjectMap(Object? value, String path) {
  if (value is! Map) throw FormatException('$path must be an object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$path keys must be strings');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}
