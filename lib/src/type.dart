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

enum OffsetWidth { normal, large }

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
        return DecimalType(integer('precision'), integer('scale'));
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
        throw FormatException('Unknown Arrow datatype kind: $kind');
    }
  }

  bool equals(DataType other, {bool checkMetadata = false}) {
    if (this is ListType && other is ListType) {
      return (this as ListType).field.equals(
        other.field,
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
    ListType type => Object.hash(ListType, type.field),
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
  DecimalType(this.precision, this.scale) {
    if (precision < 1 || precision > 38) {
      throw RangeError.range(precision, 1, 38, 'precision');
    }
    if (scale < -2147483648 || scale > 2147483647) {
      throw RangeError.range(scale, -2147483648, 2147483647, 'scale');
    }
  }
  final int precision;
  final int scale;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'decimal',
    'precision': precision,
    'scale': scale,
  };
}

final class Utf8Type extends DataType {
  const Utf8Type([this.offsetWidth = OffsetWidth.normal]);
  final OffsetWidth offsetWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': offsetWidth == OffsetWidth.large ? 'largeString' : 'string',
  };
}

final class BinaryType extends DataType {
  const BinaryType([this.offsetWidth = OffsetWidth.normal]);
  final OffsetWidth offsetWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': offsetWidth == OffsetWidth.large ? 'largeBinary' : 'binary',
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

final class ListType extends DataType {
  ListType(this.field);
  final Field field;
  @override
  Map<String, Object?> toJson() => {'kind': 'list', 'field': field.toJson()};
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
