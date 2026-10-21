part of 'core.dart';

/// An exact decimal: [unscaled] multiplied by ten to the negative [scale].
/// This value never passes through binary floating point.
final class DecimalValue {
  DecimalValue(Object unscaled, this.scale) : unscaled = _integer(unscaled);

  /// Parses a decimal literal, including exponent notation, without rounding.
  factory DecimalValue.parse(String source) {
    final match = RegExp(
      r'^([+-]?)(?:(\d+)(?:\.(\d*))?|\.(\d+))(?:[eE]([+-]?\d+))?$',
    ).firstMatch(source);
    if (match == null) throw FormatException('Invalid decimal literal', source);
    final fraction = match[3] ?? match[4] ?? '';
    final digits = '${match[2] ?? '0'}$fraction';
    final exponent = int.tryParse(match[5] ?? '0');
    if (exponent == null)
      throw FormatException('Decimal exponent out of range', source);
    final scale = BigInt.from(fraction.length) - BigInt.from(exponent);
    if (scale < _minInt || scale > _maxInt) {
      throw FormatException('Decimal scale out of range', source);
    }
    final unscaled = BigInt.parse('${match[1]}$digits');
    return DecimalValue(unscaled, scale.toInt());
  }
  final BigInt unscaled;
  final int scale;
  @override
  bool operator ==(Object other) =>
      other is DecimalValue &&
      unscaled == other.unscaled &&
      scale == other.scale;
  @override
  int get hashCode => Object.hash(unscaled, scale);
  @override
  String toString() => 'DecimalValue($unscaled, $scale)';
}

/// An exact Arrow temporal counter when Dart cannot preserve its precision,
/// range, or timezone annotation. [kind] distinguishes timestamp, date, time,
/// and duration; [dateUnit] retains the original date encoding when applicable.
final class TemporalValue {
  TemporalValue(
    Object counter,
    this.unit, {
    this.timeZone,
    this.kind,
    this.dateUnit,
  }) : counter = _integer(counter);
  final BigInt counter;
  final TimeUnit unit;
  final String? timeZone;
  final String? kind;
  final DateUnit? dateUnit;
  @override
  bool operator ==(Object other) =>
      other is TemporalValue &&
      counter == other.counter &&
      unit == other.unit &&
      timeZone == other.timeZone &&
      kind == other.kind &&
      dateUnit == other.dateUnit;
  @override
  int get hashCode => Object.hash(counter, unit, timeZone, kind, dateUnit);
  @override
  String toString() =>
      'TemporalValue($counter, ${unit.name}, kind: $kind, timeZone: $timeZone)';
}

/// A typed scalar; validity is independent of floating-point NaN values.
class Scalar {
  Scalar._(
    this.type,
    this._rawValue, [
    this._dictionary,
    this._source,
    this._index,
  ]);
  factory Scalar._fromRaw(
    DataType type,
    _Value? value, {
    Array? dictionary,
    Array? source,
    int? index,
  }) {
    if (type is DictionaryType) {
      if (dictionary == null) throw ArgumentError.notNull('dictionary');
      return DictionaryScalar._(type, value, dictionary);
    }
    return Scalar._(type, value, dictionary, source, index);
  }

  final DataType type;
  final _Value? _rawValue;
  final Array? _dictionary;
  final Array? _source;
  final int? _index;

  Scalar _child(
    DataType childType,
    _Value? raw,
    int childIndex, {
    bool struct = false,
  }) {
    final source = _source;
    if (source == null) {
      return Scalar._fromRaw(childType, raw, dictionary: _dictionary);
    }
    final physical = source.offset + _index!;
    if (struct) return source.children[childIndex][physical];
    final storage = _physicalType(type);
    final start = storage is FixedSizeListType
        ? physical * storage.size
        : source._offsetAt(physical);
    return source.children.single[start + childIndex];
  }

  bool equals(Scalar other) {
    if (type != other.type || isValid != other.isValid) return false;
    if (!isValid) return true;
    if (this is DictionaryScalar && other is DictionaryScalar) {
      final left = this as DictionaryScalar;
      return left.index.equals(other.index) &&
          left.dictionary.equals(other.dictionary);
    }
    final raw = _rawValue!;
    final right = other._rawValue!;
    if (type is ExtensionType &&
        raw is _ExtensionValue &&
        right is _ExtensionValue) {
      final storageType = (type as ExtensionType).storageType;
      return Scalar._fromRaw(
        storageType,
        raw.storage,
        dictionary: _dictionary,
        source: _source,
        index: _index,
      ).equals(
        Scalar._fromRaw(
          storageType,
          right.storage,
          dictionary: other._dictionary,
          source: other._source,
          index: other._index,
        ),
      );
    }
    if (raw is _ListValue && right is _ListValue) {
      if (raw.values.length != right.values.length) return false;
      final childType = type is ListType
          ? (type as ListType).field.type
          : (type as FixedSizeListType).field.type;
      for (var i = 0; i < raw.values.length; i++) {
        if (!_child(
          childType,
          raw.values[i],
          i,
        ).equals(other._child(childType, right.values[i], i)))
          return false;
      }
      return true;
    }
    if (type is StructType && raw is _StructValue && right is _StructValue) {
      final fields = (type as StructType).fields;
      for (var i = 0; i < fields.length; i++) {
        if (!_child(
          fields[i].type,
          raw.fields[i].value,
          i,
          struct: true,
        ).equals(
          other._child(fields[i].type, right.fields[i].value, i, struct: true),
        ))
          return false;
      }
      return true;
    }
    return _rawEquals(type, raw, right);
  }

  @override
  bool operator ==(Object other) => other is Scalar && equals(other);

  @override
  int get hashCode {
    if (!isValid) return Object.hash(type, null);
    if (this is DictionaryScalar) {
      final encoded = this as DictionaryScalar;
      return Object.hash(
        type,
        encoded.index.hashCode,
        Object.hashAll(encoded.dictionary.scalars.map(_logicalScalarHash)),
      );
    }
    return Object.hash(type, _logicalScalarHash(this));
  }

  Scalar cast(DataType targetType, {bool safe = true}) {
    if (type == targetType) return this;
    try {
      if (this is DictionaryScalar && targetType is! DictionaryType) {
        return (this as DictionaryScalar).value.cast(targetType, safe: safe);
      }
      final source = _source;
      if (source != null &&
          (type is ListType ||
              type is FixedSizeListType ||
              type is StructType ||
              type is ExtensionType ||
              targetType is DictionaryType)) {
        var view = source.slice(_index!, 1);
        final physical = _physicalType(type);
        if (physical is FixedSizeListType) {
          view = Array._(
            type,
            1,
            0,
            [_visibleValidity(view)],
            [
              source.children.single.slice(
                (source.offset + _index) * physical.size,
                physical.size,
              ),
            ],
            source.dictionary,
            source,
          );
        }
        return _castArray(view, targetType, safe: safe)[0];
      }
      final dictionary = this is DictionaryScalar
          ? (this as DictionaryScalar).dictionary
          : _dictionary;
      if (targetType is DictionaryType) {
        return _castArray(
          Array._fromRaw(type, [_rawValue], dictionary: dictionary),
          targetType,
          safe: safe,
        )[0];
      }
      return Scalar._fromRaw(
        targetType,
        _castRaw(_rawValue, type, targetType, safe, dictionary),
      );
    } on ArrowInvalid {
      rethrow;
    } on ArrowTypeError {
      rethrow;
    } on ArgumentError catch (error) {
      throw ArrowInvalid(error.message?.toString() ?? error.toString());
    } on FormatException catch (error) {
      throw ArrowInvalid(error.message);
    }
  }

  bool get isValid => _rawValue != null && type is! NullType;

  /// The exact IEEE encoding for a floating scalar, or null otherwise.
  BigInt? get rawBits => switch (_rawValue) {
    _FloatingValue(:final bits) => bits,
    _ => null,
  };

  /// Exact value representation. Temporal values expose their raw integer
  /// counter; [type] retains units/timezone and [asDart] performs host conversion.
  Object? get value {
    if (!isValid) return null;
    final raw = _rawValue!;
    if (raw is _TemporalValue) return _nativeInteger(raw.value);
    if (raw is _ListValue) {
      final childType = switch (type) {
        ListType(:final field) => field.type,
        FixedSizeListType(:final field) => field.type,
        _ => throw StateError('List value requires a list datatype'),
      };
      return List<Object?>.unmodifiable([
        for (var i = 0; i < raw.values.length; i++)
          _child(childType, raw.values[i], i).value,
      ]);
    }
    if (raw is _StructValue) {
      final fields = (type as StructType).fields;
      return Map<String, Object?>.unmodifiable({
        for (var i = 0; i < fields.length; i++)
          fields[i].name: _child(
            fields[i].type,
            raw.fields[i].value,
            i,
            struct: true,
          ).value,
      });
    }
    if (raw is _ExtensionValue) {
      return Scalar._fromRaw(
        (type as ExtensionType).storageType,
        raw.storage,
        dictionary: _dictionary,
        source: _source,
        index: _index,
      ).value;
    }
    return asDart();
  }

  Object? asDart() {
    if (!isValid) return null;
    final raw = _rawValue!;
    if (raw is _BooleanValue) return raw.value;
    if (raw is _IntegerValue) return _nativeInteger(raw.value);
    if (raw is _FloatingValue) return _floating(raw);
    if (raw is _StringValue) return raw.value;
    if (raw is _BinaryValue) return raw.bytes;
    if (raw is _DecimalValue) {
      return DecimalValue(raw.unscaled, (type as DecimalType).scale);
    }
    if (raw is _TemporalValue) return _temporal(type, raw.value);
    if (raw is _ListValue) {
      final childType = switch (type) {
        ListType(:final field) => field.type,
        FixedSizeListType(:final field) => field.type,
        _ => throw StateError('List value requires a list datatype'),
      };
      return List<Object?>.unmodifiable([
        for (var i = 0; i < raw.values.length; i++)
          _child(childType, raw.values[i], i).asDart(),
      ]);
    }
    if (raw is _StructValue) {
      final fields = (type as StructType).fields;
      return Map<String, Object?>.unmodifiable({
        for (var i = 0; i < fields.length; i++)
          fields[i].name: _child(
            fields[i].type,
            raw.fields[i].value,
            i,
            struct: true,
          ).asDart(),
      });
    }
    if (raw is _ExtensionValue) {
      return Scalar._fromRaw(
        (type as ExtensionType).storageType,
        raw.storage,
        dictionary: _dictionary,
        source: _source,
        index: _index,
      ).asDart();
    }
    throw StateError('Unsupported scalar encoding for $type');
  }
}

/// Dictionary encoding retains a typed index and decodes through [dictionary].
final class DictionaryScalar extends Scalar {
  DictionaryScalar._(DictionaryType type, _Value? raw, this.dictionary)
    : super._(type, raw) {
    if (dictionary.type != type.valueType) {
      throw ArgumentError('Dictionary value type does not match scalar type');
    }
  }
  final Array dictionary;
  Scalar get index => Scalar._fromRaw(
    (type as DictionaryType).indexType,
    _rawValue == null
        ? null
        : _IntegerValue((_rawValue as _DictionaryIndexValue).index),
  );
  Scalar get value {
    if (!isValid)
      return Scalar._fromRaw((type as DictionaryType).valueType, null);
    final position = (_rawValue as _DictionaryIndexValue).index;
    if (position.isNegative || position >= BigInt.from(dictionary.length)) {
      throw RangeError('Dictionary index $position is out of bounds');
    }
    return dictionary[position.toInt()];
  }

  @override
  Object? asDart() => value.asDart();
}

int _logicalScalarHash(Scalar scalar) {
  if (!scalar.isValid) return 0;
  if (scalar is DictionaryScalar) return _logicalScalarHash(scalar.value);
  final raw = scalar._rawValue!;
  if (raw is _FloatingValue) {
    final value = _floating(raw);
    return value.isNaN ? 0x7ff80000 : value.hashCode;
  }
  if (raw is _ListValue) {
    final type = scalar.type;
    final childType = type is ListType
        ? type.field.type
        : (type as FixedSizeListType).field.type;
    return Object.hashAll(
      Iterable.generate(
        raw.values.length,
        (i) => _logicalScalarHash(scalar._child(childType, raw.values[i], i)),
      ),
    );
  }
  if (raw is _StructValue) {
    final fields = (scalar.type as StructType).fields;
    return Object.hashAll(
      Iterable.generate(
        fields.length,
        (i) => _logicalScalarHash(
          scalar._child(fields[i].type, raw.fields[i].value, i, struct: true),
        ),
      ),
    );
  }
  if (raw is _ExtensionValue) {
    return _logicalScalarHash(
      Scalar._fromRaw(
        (scalar.type as ExtensionType).storageType,
        raw.storage,
        dictionary: scalar._dictionary,
        source: scalar._source,
        index: scalar._index,
      ),
    );
  }
  return raw.hashCode;
}

BigInt _integer(Object value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  throw ArgumentError.value(value, 'value', 'must be int or BigInt');
}

final _minInt = -(BigInt.one << 63);
final _maxInt = (BigInt.one << 63) - BigInt.one;
Object _nativeInteger(BigInt value) =>
    value >= _minInt && value <= _maxInt ? value.toInt() : value;

double _floating(_FloatingValue value) {
  if (value.bitWidth == 16) {
    final bits = value.bits.toInt();
    final negative = bits & 0x8000 != 0;
    final exponent = (bits >> 10) & 31;
    final fraction = bits & 1023;
    if (exponent == 31)
      return fraction == 0
          ? (negative ? double.negativeInfinity : double.infinity)
          : double.nan;
    final magnitude = exponent == 0
        ? fraction * math.pow(2, -24).toDouble()
        : (1024 + fraction) * math.pow(2, exponent - 25).toDouble();
    return negative ? -magnitude : magnitude;
  }
  final data = ByteData(value.bitWidth ~/ 8);
  if (value.bitWidth == 32) {
    data.setUint32(0, value.bits.toInt(), Endian.little);
    return data.getFloat32(0, Endian.little);
  }
  data.setUint32(
    0,
    (value.bits & BigInt.from(0xffffffff)).toInt(),
    Endian.little,
  );
  data.setUint32(4, (value.bits >> 32).toInt(), Endian.little);
  return data.getFloat64(0, Endian.little);
}

Object _temporal(DataType type, BigInt counter) {
  final unit = switch (type) {
    TimestampType(:final unit) => unit,
    DurationType(:final unit) => unit,
    TimeType(:final unit) => unit,
    DateType() => TimeUnit.millisecond,
    _ => throw StateError('Temporal value requires a temporal datatype'),
  };
  final kind = switch (type) {
    TimestampType() => 'timestamp',
    DurationType() => 'duration',
    TimeType() => 'time',
    _ => 'date',
  };
  final zone = type is TimestampType ? type.timeZone : null;
  final dateUnit = type is DateType ? type.unit : null;
  TemporalValue fallback() => TemporalValue(
    counter,
    unit,
    timeZone: zone,
    kind: kind,
    dateUnit: dateUnit,
  );
  if (zone != null && zone != 'UTC') return fallback();
  if (type is TimeType) return fallback();
  BigInt micros;
  if (type is DateType && type.unit == DateUnit.day) {
    micros = counter * BigInt.from(86400000000);
  } else if (unit == TimeUnit.nanosecond) {
    if (counter.remainder(BigInt.from(1000)) != BigInt.zero) return fallback();
    micros = counter ~/ BigInt.from(1000);
  } else {
    micros =
        counter *
        BigInt.from(switch (unit) {
          TimeUnit.second => 1000000,
          TimeUnit.millisecond => 1000,
          _ => 1,
        });
  }
  if (micros < _minInt || micros > _maxInt) return fallback();
  if (type is DurationType) {
    return Duration(microseconds: micros.toInt());
  }
  if (micros.abs() > BigInt.parse('8640000000000000000')) return fallback();
  return DateTime.fromMicrosecondsSinceEpoch(micros.toInt(), isUtc: true);
}
