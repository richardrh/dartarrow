part of 'core.dart';

Array _castArray(Array source, DataType target, {bool safe = true}) {
  try {
    if (source.type == target) return source;
    final from = source.type;
    if (from is ExtensionType) {
      final storage = Array._(
        from.storageType,
        source.length,
        source.offset,
        source._physicalBuffers,
        source.children,
        source.dictionary,
        source,
      );
      final converted = _castArray(
        storage,
        target is ExtensionType ? target.storageType : target,
        safe: safe,
      );
      return target is ExtensionType
          ? Array._(
              target,
              converted.length,
              converted.offset,
              converted._physicalBuffers,
              converted.children,
              converted.dictionary,
              converted,
            )
          : converted;
    }
    if (target is ExtensionType) {
      final converted = _castArray(source, target.storageType, safe: safe);
      return Array._(
        target,
        converted.length,
        converted.offset,
        converted._physicalBuffers,
        converted.children,
        converted.dictionary,
        converted,
      );
    }
    if (from is ListType && target is ListType && !from.view && !target.view) {
      final start = source._offsetAt(source.offset);
      final end = source._offsetAt(source.offset + source.length);
      final child = _castArray(
        source.children.single.slice(start, end - start),
        target.field.type,
        safe: safe,
      );
      final width = _offsetSize(target);
      final offsets = Uint8List((source.length + 1) * width);
      final bytes = ByteData.sublistView(offsets);
      for (var i = 0; i <= source.length; i++) {
        final offset = source._offsetAt(source.offset + i) - start;
        if (width == 4) {
          if (offset > 0x7fffffff)
            throw ArrowInvalid('List offset exceeds 32-bit capacity');
          bytes.setInt32(i * width, offset, Endian.little);
        } else {
          _setInt64(bytes, i * width, offset);
        }
      }
      return Array._(
        target,
        source.length,
        0,
        [_visibleValidity(source), offsets.asUnmodifiableView()],
        [child],
        null,
        source,
      );
    }
    if (from is FixedSizeListType &&
        target is FixedSizeListType &&
        from.size == target.size) {
      final toField = target.field;
      final child = _castArray(
        source.children.single,
        toField.type,
        safe: safe,
      );
      final result = Array._(
        target,
        source.length,
        source.offset,
        source._physicalBuffers,
        [child],
        null,
        source,
      );
      result._validate();
      return result;
    }
    if (from is StructType && target is StructType) {
      final children = <Array>[];
      for (final field in target.fields) {
        final index = from.fields.indexWhere(
          (candidate) => candidate.name == field.name,
        );
        if (index < 0)
          throw UnsupportedError(
            'Struct cast cannot introduce field ${field.name}',
          );
        children.add(
          _castArray(
            source.children[index].slice(source.offset, source.length),
            field.type,
            safe: safe,
          ),
        );
      }
      final result = Array._(
        target,
        source.length,
        0,
        [_visibleValidity(source)],
        children,
        null,
        source,
      );
      result._validate();
      return result;
    }
    // Dictionary construction consumes decoded values, never physical indices.
    if (target is DictionaryType) {
      final decoded = <_Value?>[];
      final indices = <_Value?>[];
      final lookup = <_Value, int>{};
      for (var i = 0; i < source.length; i++) {
        final value = _castRaw(
          source._rawValue(i),
          source.type,
          target.valueType,
          safe,
          source.dictionary,
        );
        if (value == null) {
          indices.add(null);
          continue;
        }
        final index = lookup.putIfAbsent(value, () {
          decoded.add(value);
          return decoded.length - 1;
        });
        indices.add(_DictionaryIndexValue(index));
      }
      var indexType = target.indexType as IntegerType;
      while (BigInt.from(decoded.length - 1) > indexType.maximum) {
        if (indexType.bitWidth >= 64)
          throw ArgumentError('Dictionary exceeds index capacity');
        indexType = IntegerType(
          indexType.bitWidth * 2,
          signed: indexType.signed,
        );
      }
      return Array._fromRaw(
        DictionaryType(indexType, target.valueType, ordered: target.ordered),
        indices,
        dictionary: Array._fromRaw(target.valueType, decoded),
      );
    }
    final values = <_Value?>[];
    for (var i = 0; i < source.length; i++) {
      values.add(
        _castRaw(
          source._rawValue(i),
          source.type,
          target,
          safe,
          source.dictionary,
        ),
      );
    }
    return Array._fromRaw(target, values);
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

Uint8List? _visibleValidity(Array source) {
  if (source._physicalBuffers.isEmpty || source._physicalBuffers.first == null)
    return null;
  final validity = Uint8List((source.length + 7) ~/ 8);
  for (var i = 0; i < source.length; i++) {
    if (source._isValid(i)) validity[i >> 3] |= 1 << (i & 7);
  }
  return validity.asUnmodifiableView();
}

_Value? _castRaw(
  _Value? raw,
  DataType source,
  DataType target,
  bool safe,
  Array? dictionary,
) {
  if (raw == null) return null;
  if (source == target) return raw;
  if (source is DictionaryType && raw is _DictionaryIndexValue) {
    if (dictionary == null) throw ArgumentError('Missing dictionary');
    return _castRaw(
      dictionary._rawValue(raw.index.toInt()),
      source.valueType,
      target,
      safe,
      dictionary.dictionary,
    );
  }
  if (source is ExtensionType && raw is _ExtensionValue) {
    final destination = target is ExtensionType ? target.storageType : target;
    final result = _castRaw(
      raw.storage,
      source.storageType,
      destination,
      safe,
      dictionary,
    );
    return target is ExtensionType && result != null
        ? _ExtensionValue(result)
        : result;
  }
  if (target is ExtensionType) {
    final result = _castRaw(raw, source, target.storageType, safe, dictionary);
    return result == null ? null : _ExtensionValue(result);
  }
  if (raw is _TemporalValue) {
    if (target is IntegerType)
      return _nativeRaw(raw.value, target, safe: safe, casting: true);
    final temporal = switch (source) {
      DateType t => TemporalValue(
        raw.value,
        TimeUnit.millisecond,
        kind: 'date',
        dateUnit: t.unit,
      ),
      TimestampType t => TemporalValue(
        raw.value,
        t.unit,
        kind: 'timestamp',
        timeZone: t.timeZone,
      ),
      TimeType t => TemporalValue(raw.value, t.unit, kind: 'time'),
      DurationType t => TemporalValue(raw.value, t.unit, kind: 'duration'),
      _ => throw UnsupportedError('Invalid temporal source $source'),
    };
    return _nativeRaw(temporal, target, safe: safe, casting: true);
  }
  if (raw is _DecimalValue && source is DecimalType) {
    return _nativeRaw(
      DecimalValue(raw.unscaled, source.scale),
      target,
      safe: safe,
      casting: true,
    );
  }
  if (raw is _ListValue &&
      (source is ListType || source is FixedSizeListType) &&
      (target is ListType || target is FixedSizeListType)) {
    final from = source is ListType
        ? source.field
        : (source as FixedSizeListType).field;
    final to = target is ListType
        ? target.field
        : (target as FixedSizeListType).field;
    if (target is FixedSizeListType && raw.values.length != target.size)
      throw ArgumentError('Fixed-size list length mismatch');
    return _ListValue([
      for (final child in raw.values)
        _castRaw(child, from.type, to.type, safe, dictionary),
    ]);
  }
  if (raw is _MapValue && source is MapType && target is MapType) {
    return _MapValue([
      for (final entry in raw.entries)
        _MapEntry(
          _castRaw(
                entry.key,
                source.keyField.type,
                target.keyField.type,
                safe,
                dictionary,
              ) ??
              (throw ArgumentError('Map keys cannot be null')),
          _castRaw(
            entry.value,
            source.valueField.type,
            target.valueField.type,
            safe,
            dictionary,
          ),
        ),
    ]);
  }
  if (source is RunEndEncodedType) {
    return _castRaw(raw, source.valuesField.type, target, safe, dictionary);
  }
  if (target is RunEndEncodedType) {
    return _castRaw(raw, source, target.valuesField.type, safe, dictionary);
  }
  if (raw is _StructValue && source is StructType && target is StructType) {
    final result = <_StructEntry>[];
    for (final field in target.fields) {
      final index = source.fields.indexWhere((f) => f.name == field.name);
      if (index < 0)
        throw UnsupportedError(
          'Struct cast cannot introduce field ${field.name}',
        );
      result.add(
        _StructEntry(
          field.name,
          _castRaw(
            raw.fields[index].value,
            source.fields[index].type,
            field.type,
            safe,
            dictionary,
          ),
        ),
      );
    }
    return _StructValue(result);
  }
  return _nativeRaw(
    Scalar._fromRaw(source, raw, dictionary: dictionary).asDart(),
    target,
    safe: safe,
    casting: true,
  );
}

BigInt _conversionInteger(Object value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  throw ArgumentError('Expected integer, got $value');
}

BigInt _rescale(BigInt value, int from, int to, bool safe) {
  final difference = to - from;
  if (difference == 0) return value;
  if (difference.abs() > 10000)
    throw ArgumentError('Scale difference exceeds supported value range');
  final factor = BigInt.from(10).pow(difference.abs());
  if (difference > 0) return value * factor;
  if (safe && value.remainder(factor) != BigInt.zero)
    throw ArgumentError('Conversion would lose precision');
  return value ~/ factor;
}

int _unitScale(TimeUnit unit) => switch (unit) {
  TimeUnit.second => 0,
  TimeUnit.millisecond => 3,
  TimeUnit.microsecond => 6,
  TimeUnit.nanosecond => 9,
};

_Value? _nativeRaw(
  Object? value,
  DataType type, {
  bool safe = true,
  bool casting = false,
}) {
  if (value == null) return null;
  if (value is Scalar) {
    if (!value.isValid) return null;
    return _castRaw(
      value._rawValue,
      value.type,
      type,
      safe,
      value is DictionaryScalar ? value.dictionary : value._dictionary,
    );
  }
  if (type is NullType) throw ArgumentError('Non-null value for null datatype');
  if (type is BooleanType) {
    if (value is bool) return _BooleanValue(value);
    if (casting && (value is num || value is BigInt))
      return _BooleanValue(value != 0 && value != BigInt.zero);
  }
  if (type is IntegerType) {
    BigInt n;
    if (value is int || value is BigInt) {
      n = _conversionInteger(value);
    } else if (value is double) {
      if (!value.isFinite || (safe && value.truncateToDouble() != value))
        throw ArgumentError('Float cannot be represented as integer');
      n = BigInt.from(value);
    } else if (casting && value is bool) {
      n = value ? BigInt.one : BigInt.zero;
    } else if (casting && value is String) {
      n = BigInt.parse(value);
    } else if (casting && value is DecimalValue) {
      n = _rescale(value.unscaled, value.scale, 0, safe);
    } else if (casting && value is TemporalValue) {
      n = value.counter;
    } else {
      throw ArgumentError('Cannot convert $value to integer');
    }
    if (n < type.minimum || n > type.maximum) {
      if (!casting || safe)
        throw ArgumentError(
          'Integer $n outside ${type.minimum}..${type.maximum}',
        );
      final modulus = BigInt.one << type.bitWidth;
      n = n % modulus;
      if (type.signed && n > type.maximum) n -= modulus;
    }
    return _IntegerValue(n);
  }
  if (type is FloatingType) {
    double n;
    if (value is num) {
      n = value.toDouble();
    } else if (value is BigInt) {
      n = value.toDouble();
    } else if (casting && value is String) {
      n = double.parse(value);
    } else if (casting && value is bool) {
      n = value ? 1 : 0;
    } else if (casting && value is DecimalValue) {
      n = value.unscaled.toDouble() / _pow10(value.scale);
    } else {
      throw ArgumentError('Cannot convert $value to float');
    }
    if ((safe || !casting) &&
        (value is int || value is BigInt) &&
        (!n.isFinite || BigInt.from(n) != _conversionInteger(value)))
      throw ArgumentError('Integer is not exactly representable as float');
    if ((safe || !casting) && (value is int || value is BigInt)) {
      final significantBits = type.bitWidth == 64
          ? 53
          : type.bitWidth == 32
          ? 24
          : 11;
      final bound = BigInt.one << significantBits;
      if (_conversionInteger(value).abs() > bound)
        throw ArgumentError(
          'Integer outside exactly representable floating range',
        );
    }
    if (type.bitWidth == 64) return _FloatingValue.float64(n);
    if (type.bitWidth == 32) return _FloatingValue.float32(n);
    return _FloatingValue.float16(_half(n));
  }
  if (type is Utf8Type) {
    if (value is String) return _StringValue(value);
    if (casting && value is Uint8List) return _StringValue(utf8.decode(value));
    if (casting &&
        (value is num ||
            value is BigInt ||
            value is bool ||
            value is DecimalValue))
      return _StringValue(value.toString());
  }
  if (type is BinaryType || type is FixedSizeBinaryType) {
    final bytes = value is List<int>
        ? value
        : value is String
        ? utf8.encode(value)
        : null;
    if (bytes != null) {
      if (type is FixedSizeBinaryType && bytes.length != type.byteWidth) {
        throw ArgumentError(
          'Expected ${type.byteWidth} bytes, got ${bytes.length}',
        );
      }
      return _BinaryValue(bytes);
    }
  }
  if (type is MapType) {
    final Iterable<(Object?, Object?)> pairs = switch (value) {
      Map() => value.entries.map((e) => (e.key, e.value)),
      List() => value.map(
        (entry) => switch (entry) {
          (Object? key, Object? item) => (key, item),
          MapEntry(:final key, :final value) => (key, value),
          List(length: 2) => (entry[0], entry[1]),
          _ => throw ArgumentError(
            'Map entries must be (key, value) records, MapEntry, or pairs',
          ),
        },
      ),
      _ => throw ArgumentError('Expected map or list of entries'),
    };
    return _MapValue([
      for (final (key, item) in pairs)
        _MapEntry(
          _nativeRaw(key, type.keyField.type, safe: safe, casting: casting) ??
              (throw ArgumentError('Map keys cannot be null')),
          _nativeRaw(item, type.valueField.type, safe: safe, casting: casting),
        ),
    ]);
  }
  if (type is IntervalType) {
    if (value is IntervalValue && value.unit == type.unit) {
      return _IntervalValue(value);
    }
    if (type.unit == IntervalUnit.monthDayNano) {
      if (value case (int months, int days, Object nanoseconds)) {
        return _IntervalValue(
          IntervalValue.monthDayNano(months, days, nanoseconds),
        );
      }
      if (value case [int months, int days, Object nanoseconds]) {
        return _IntervalValue(
          IntervalValue.monthDayNano(months, days, nanoseconds),
        );
      }
    }
    throw ArgumentError('Cannot convert $value to $type');
  }
  if (type is RunEndEncodedType) {
    return _nativeRaw(
      value,
      type.valuesField.type,
      safe: safe,
      casting: casting,
    );
  }
  if (type is UnionType) {
    throw UnsupportedError(
      'Union arrays cannot be built from native values; use Array.fromBuffers',
    );
  }
  if (type is DecimalType) {
    BigInt unscaled;
    if (value is DecimalValue) {
      unscaled = _rescale(value.unscaled, value.scale, type.scale, safe);
    } else if (value is int || value is BigInt) {
      unscaled = _rescale(_conversionInteger(value), 0, type.scale, safe);
    } else if (casting && (value is String || value is double)) {
      final text = value.toString();
      final match = RegExp(r'^([+-]?)(\d+)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$')
          .firstMatch(text);
      if (match == null) throw ArgumentError('Invalid decimal $text');
      final fraction = match.group(3) ?? '';
      final coefficient = BigInt.parse(
        '${match.group(1)}${match.group(2)}$fraction',
      );
      unscaled = _rescale(
        coefficient,
        fraction.length - int.parse(match.group(4) ?? '0'),
        type.scale,
        safe,
      );
    } else {
      throw ArgumentError('Expected exact decimal or integer');
    }
    if (unscaled.abs().toString().length > type.precision)
      throw ArgumentError('Decimal exceeds precision ${type.precision}');
    return _DecimalValue(unscaled);
  }
  if (type is DateType ||
      type is TimeType ||
      type is TimestampType ||
      type is DurationType) {
    final unit = switch (type) {
      DateType t => t.unit == DateUnit.day ? null : TimeUnit.millisecond,
      TimeType t => t.unit,
      TimestampType t => t.unit,
      DurationType t => t.unit,
      _ => null,
    };
    BigInt n;
    if (value is int || value is BigInt) {
      n = _conversionInteger(value);
    } else {
      BigInt counter;
      int scale;
      if (value is TemporalValue) {
        counter = value.counter;
        if (value.kind == 'date' && value.dateUnit == DateUnit.day) {
          counter *= BigInt.from(86400);
          scale = 0;
        } else {
          scale = _unitScale(value.unit);
        }
      } else if (value is DateTime &&
          (type is DateType || type is TimestampType)) {
        counter = BigInt.from(value.microsecondsSinceEpoch);
        scale = 6;
      } else if (value is Duration && type is DurationType) {
        counter = BigInt.from(value.inMicroseconds);
        scale = 6;
      } else {
        throw ArgumentError('Cannot convert $value to temporal datatype');
      }
      if (unit == null) {
        final micros = _rescale(counter, scale, 6, safe);
        final day = BigInt.from(86400000000);
        if (safe && micros.remainder(day) != BigInt.zero)
          throw ArgumentError('Date conversion loses time of day');
        n = micros ~/ day;
      } else {
        n = _rescale(counter, scale, _unitScale(unit), safe);
      }
    }
    final width =
        type is DateType && type.unit == DateUnit.day ||
            type is TimeType &&
                (type.unit == TimeUnit.second ||
                    type.unit == TimeUnit.millisecond)
        ? 32
        : 64;
    final checked = _nativeRaw(
      n,
      IntegerType(width),
      safe: safe,
      casting: casting,
    ) as _IntegerValue;
    if (type is TimeType) {
      final endOfDay =
          BigInt.from(86400) * BigInt.from(10).pow(_unitScale(type.unit));
      if (checked.value.isNegative || checked.value >= endOfDay) {
        throw RangeError('Time counter must fall within one day');
      }
    }
    return _TemporalValue(checked.value);
  }
  if (type is ListType || type is FixedSizeListType) {
    if (value is! List) throw ArgumentError('Expected list');
    final field = type is ListType
        ? type.field
        : (type as FixedSizeListType).field;
    if (type is FixedSizeListType && value.length != type.size)
      throw ArgumentError('Fixed-size list length mismatch');
    return _ListValue([
      for (final child in value)
        _nativeRaw(child, field.type, safe: safe, casting: casting),
    ]);
  }
  if (type is StructType) {
    if (value is! Map) throw ArgumentError('Expected struct map');
    return _StructValue([
      for (final field in type.fields)
        _StructEntry(
          field.name,
          _nativeRaw(
            value[field.name],
            field.type,
            safe: safe,
            casting: casting,
          ),
        ),
    ]);
  }
  if (type is ExtensionType) {
    final storage = _nativeRaw(
      value,
      type.storageType,
      safe: safe,
      casting: casting,
    );
    return storage == null ? null : _ExtensionValue(storage);
  }
  throw UnsupportedError(
    'Conversion of ${value.runtimeType} to $type is unsupported',
  );
}

double _pow10(int exponent) {
  var result = 1.0;
  for (var i = 0; i < exponent.abs(); i++) {
    result *= 10;
  }
  return exponent < 0 ? 1 / result : result;
}

int _half(double value, [ByteData? scratch]) {
  final data = scratch ?? ByteData(4);
  data.setFloat32(0, value, Endian.little);
  final bits = data.getUint32(0, Endian.little);
  final sign = (bits >> 16) & 0x8000;
  final exponent = ((bits >> 23) & 255) - 127;
  final fraction = bits & 0x7fffff;
  if (exponent == 128) return sign | 0x7c00 | (fraction == 0 ? 0 : 0x200);
  if (exponent > 15) return sign | 0x7c00;
  if (exponent < -25) return sign;
  final significand = fraction | 0x800000;
  final shift = exponent < -14 ? -exponent - 1 : 13;
  var rounded = significand >> shift;
  final remainder = significand & ((1 << shift) - 1);
  final halfway = 1 << (shift - 1);
  if (remainder > halfway || remainder == halfway && rounded.isOdd) rounded++;
  return sign | (exponent < -14 ? rounded : ((exponent + 14) << 10) + rounded);
}
