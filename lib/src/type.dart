import 'schema.dart';

enum ArrowTimeUnit {
  second('seconds'),
  millisecond('milliseconds'),
  microsecond('microseconds'),
  nanosecond('nanoseconds');

  const ArrowTimeUnit(this.jsonName);
  final String jsonName;

  static ArrowTimeUnit parse(String value) => values.firstWhere(
    (unit) => unit.jsonName == value || unit.name == value,
    orElse: () => throw FormatException('Unknown time unit: $value'),
  );
}

enum ArrowDateUnit { day, millisecond }

enum ArrowOffsetWidth { normal, large }

sealed class ArrowDataType {
  const ArrowDataType();

  Map<String, Object?> toJson();

  static ArrowDataType fromJson(Map<String, Object?> json) {
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

  static ArrowDataType _fromJson(Map<String, Object?> json) {
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
        return const ArrowNullType();
      case 'boolean':
        return const ArrowBooleanType();
      case 'int8':
        return ArrowIntegerType(8);
      case 'int16':
        return ArrowIntegerType(16);
      case 'int32':
        return ArrowIntegerType(32);
      case 'int64':
        return ArrowIntegerType(64);
      case 'int128':
        return ArrowIntegerType(128);
      case 'uint8':
        return ArrowIntegerType(8, signed: false);
      case 'uint16':
        return ArrowIntegerType(16, signed: false);
      case 'uint32':
        return ArrowIntegerType(32, signed: false);
      case 'uint64':
        return ArrowIntegerType(64, signed: false);
      case 'uint128':
        return ArrowIntegerType(128, signed: false);
      case 'float16':
        return ArrowFloatingType(16);
      case 'float32':
        return ArrowFloatingType(32);
      case 'float64':
        return ArrowFloatingType(64);
      case 'decimal':
        return ArrowDecimalType(integer('precision'), integer('scale'));
      case 'string':
      case 'utf8':
        return const ArrowUtf8Type();
      case 'largeString':
      case 'largeUtf8':
        return const ArrowUtf8Type(ArrowOffsetWidth.large);
      case 'binary':
        return const ArrowBinaryType();
      case 'largeBinary':
        return const ArrowBinaryType(ArrowOffsetWidth.large);
      case 'date':
        return switch (string('unit')) {
          'days' => const ArrowDateType(),
          'milliseconds' => const ArrowDateType(ArrowDateUnit.millisecond),
          final unit => throw FormatException('Unknown date unit: $unit'),
        };
      case 'datetime':
      case 'timestamp':
        return ArrowTimestampType(
          ArrowTimeUnit.parse(string('unit')),
          timeZone: optionalString('timeZone'),
        );
      case 'duration':
        return ArrowDurationType(ArrowTimeUnit.parse(string('unit')));
      case 'time':
        return ArrowTimeType(ArrowTimeUnit.parse(string('unit')));
      case 'list':
        return ArrowListType(ArrowField.fromJson(object('field')));
      case 'fixedSizeList':
      case 'array':
        return ArrowFixedSizeListType(
          ArrowField.fromJson(object('field')),
          integer('size'),
        );
      case 'struct':
        final fields = json['fields'];
        if (fields is! List)
          throw const FormatException('dtype.fields must be a list');
        return ArrowStructType(
          fields.indexed
              .map(
                (e) => ArrowField.fromJson(
                  _stringObjectMap(e.$2, 'dtype.fields[${e.$1}]'),
                ),
              )
              .toList(),
        );
      case 'dictionary':
        return ArrowDictionaryType(
          ArrowDataType.fromJson(object('indexType')),
          ArrowDataType.fromJson(object('valueType')),
          ordered: boolean('ordered', false),
        );
      case 'extension':
        return ArrowExtensionType(
          string('name'),
          ArrowDataType.fromJson(object('storageType')),
          metadata: optionalString('metadata'),
        );
      default:
        throw FormatException('Unknown Arrow datatype kind: $kind');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is ArrowDataType && _deepEquals(toJson(), other.toJson());

  @override
  int get hashCode => _deepHash(toJson());

  @override
  String toString() => toJson().toString();
}

final class ArrowNullType extends ArrowDataType {
  const ArrowNullType();
  @override
  Map<String, Object?> toJson() => const {'kind': 'null'};
}

final class ArrowBooleanType extends ArrowDataType {
  const ArrowBooleanType();
  @override
  Map<String, Object?> toJson() => const {'kind': 'boolean'};
}

final class ArrowIntegerType extends ArrowDataType {
  ArrowIntegerType(this.bitWidth, {this.signed = true}) {
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

final class ArrowFloatingType extends ArrowDataType {
  ArrowFloatingType(this.bitWidth) {
    if (bitWidth != 16 && bitWidth != 32 && bitWidth != 64) {
      throw ArgumentError.value(bitWidth, 'bitWidth', 'must be 16, 32, or 64');
    }
  }
  final int bitWidth;
  @override
  Map<String, Object?> toJson() => {'kind': 'float$bitWidth'};
}

final class ArrowDecimalType extends ArrowDataType {
  ArrowDecimalType(this.precision, this.scale) {
    if (precision < 1 || precision > 38) {
      throw RangeError.range(precision, 1, 38, 'precision');
    }
    if (scale < 0 || scale > precision) {
      throw RangeError.range(scale, 0, precision, 'scale');
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

final class ArrowUtf8Type extends ArrowDataType {
  const ArrowUtf8Type([this.offsetWidth = ArrowOffsetWidth.normal]);
  final ArrowOffsetWidth offsetWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': offsetWidth == ArrowOffsetWidth.large ? 'largeString' : 'string',
  };
}

final class ArrowBinaryType extends ArrowDataType {
  const ArrowBinaryType([this.offsetWidth = ArrowOffsetWidth.normal]);
  final ArrowOffsetWidth offsetWidth;
  @override
  Map<String, Object?> toJson() => {
    'kind': offsetWidth == ArrowOffsetWidth.large ? 'largeBinary' : 'binary',
  };
}

final class ArrowDateType extends ArrowDataType {
  const ArrowDateType([this.unit = ArrowDateUnit.day]);
  final ArrowDateUnit unit;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'date',
    'unit': unit == ArrowDateUnit.day ? 'days' : 'milliseconds',
  };
}

final class ArrowTimestampType extends ArrowDataType {
  const ArrowTimestampType(this.unit, {this.timeZone});
  final ArrowTimeUnit unit;
  final String? timeZone;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'datetime',
    'unit': unit.jsonName,
    if (timeZone != null) 'timeZone': timeZone,
  };
}

final class ArrowDurationType extends ArrowDataType {
  const ArrowDurationType(this.unit);
  final ArrowTimeUnit unit;
  @override
  Map<String, Object?> toJson() => {'kind': 'duration', 'unit': unit.jsonName};
}

final class ArrowTimeType extends ArrowDataType {
  const ArrowTimeType(this.unit);
  final ArrowTimeUnit unit;
  @override
  Map<String, Object?> toJson() => {'kind': 'time', 'unit': unit.jsonName};
}

final class ArrowListType extends ArrowDataType {
  ArrowListType(this.field);
  final ArrowField field;
  @override
  Map<String, Object?> toJson() => {'kind': 'list', 'field': field.toJson()};
}

final class ArrowFixedSizeListType extends ArrowDataType {
  ArrowFixedSizeListType(this.field, this.size) {
    if (size < 0) throw RangeError.value(size, 'size', 'must be non-negative');
  }
  final ArrowField field;
  final int size;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'fixedSizeList',
    'field': field.toJson(),
    'size': size,
  };
}

final class ArrowStructType extends ArrowDataType {
  ArrowStructType(List<ArrowField> fields)
    : fields = List.unmodifiable(fields) {
    final names = <String>{};
    for (final field in fields) {
      if (!names.add(field.name))
        throw ArgumentError('Duplicate struct field: ${field.name}');
    }
  }
  final List<ArrowField> fields;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'struct',
    'fields': fields.map((f) => f.toJson()).toList(),
  };
}

final class ArrowDictionaryType extends ArrowDataType {
  ArrowDictionaryType(this.indexType, this.valueType, {this.ordered = false}) {
    if (indexType is! ArrowIntegerType) {
      throw ArgumentError.value(
        indexType,
        'indexType',
        'must be an integer type',
      );
    }
  }
  final ArrowDataType indexType;
  final ArrowDataType valueType;
  final bool ordered;
  @override
  Map<String, Object?> toJson() => {
    'kind': 'dictionary',
    'indexType': indexType.toJson(),
    'valueType': valueType.toJson(),
    'ordered': ordered,
  };
}

final class ArrowExtensionType extends ArrowDataType {
  ArrowExtensionType(this.name, this.storageType, {this.metadata}) {
    if (name.isEmpty)
      throw ArgumentError.value(name, 'name', 'must not be empty');
  }
  final String name;
  final ArrowDataType storageType;
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
