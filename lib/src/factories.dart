part of 'core.dart';

Array array(
  Object values, {
  DataType? type,
  Iterable<bool>? mask,
  int? size,
  bool safe = true,
}) {
  try {
    if (values is Array) {
      // Existing arrays already own their validity and length. PyArrow ignores
      // construction-only mask/size options on this input path.
      return type == null || type == values.type
          ? values
          : values.cast(type, safe: safe);
    }
    if (values is ChunkedArray) {
      if (type != null && type != values.type) {
        throw ArrowInvalid(
          'Cannot append scalar of type ${values.type} to builder for type $type',
        );
      }
      final source = values.combineChunks();
      if (mask != null) {
        return array(
          source.scalars.toList(),
          type: source.type,
          mask: mask,
          safe: safe,
        );
      }
      return source;
    }
    if (values is! Iterable)
      throw ArrowTypeError('Expected iterable, Array, or ChunkedArray');
    if (size != null && size < 0) throw ArgumentError.value(size, 'size');
    final List<Object?> input = values is List
        ? values.cast<Object?>()
        : (size == null ? values : values.take(size)).cast<Object?>().toList();
    final flags = mask is List<bool> ? mask : mask?.toList();
    if (flags != null && flags.length != input.length)
      throw ArgumentError('Mask length must match values');
    Object? at(int i) => flags != null && flags[i] ? null : input[i];
    final dtype = type ?? _inferNativeType(Iterable.generate(input.length, at));
    if (dtype is DictionaryType) {
      final unique = <_Value?>[];
      final lookup = <_Value, int>{};
      final indices = <_Value?>[];
      for (var i = 0; i < input.length; i++) {
        final value = _nativeRaw(at(i), dtype.valueType, safe: safe);
        if (value == null) {
          indices.add(null);
          continue;
        }
        final index = lookup.putIfAbsent(value, () {
          unique.add(value);
          return unique.length - 1;
        });
        indices.add(_DictionaryIndexValue(index));
      }
      var indexType = dtype.indexType as IntegerType;
      while (BigInt.from(unique.length - 1) > indexType.maximum) {
        if (indexType.bitWidth >= 64)
          throw ArgumentError('Dictionary exceeds index capacity');
        indexType = IntegerType(
          indexType.bitWidth * 2,
          signed: indexType.signed,
        );
      }
      return Array._fromRaw(
        DictionaryType(indexType, dtype.valueType, ordered: dtype.ordered),
        indices,
        dictionary: Array._fromRaw(dtype.valueType, unique),
      );
    }
    if (dtype is NullType ||
        dtype is BooleanType ||
        dtype is IntegerType ||
        dtype is FloatingType ||
        (dtype is Utf8Type || dtype is BinaryType) && !_isView(dtype) ||
        dtype is DecimalType ||
        dtype is DateType ||
        dtype is TimeType ||
        dtype is TimestampType ||
        dtype is DurationType) {
      return _encodeNative(dtype, input.length, at, safe);
    }
    return Array._fromRaw(
      dtype,
      _NativeValues(input.length, (i) => _nativeRaw(at(i), dtype, safe: safe)),
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

Scalar scalar(Object? value, {DataType? type}) {
  if (value is Scalar && type != null && type != value.type) {
    throw ArrowInvalid(
      'Cannot append scalar of type ${value.type} to builder for type $type',
    );
  }
  if (value is Scalar) return value;
  try {
    final dtype = type ?? _inferNativeType([value]);
    if (dtype is ListType ||
        dtype is FixedSizeListType ||
        dtype is StructType ||
        dtype is MapType ||
        dtype is UnionType ||
        dtype is RunEndEncodedType ||
        dtype is DictionaryType ||
        dtype is ExtensionType) {
      // Nested/encoded scalars keep their child arrays and dictionary context.
      return array([value], type: dtype)[0];
    }
    return Scalar._fromRaw(dtype, _nativeRaw(value, dtype));
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

class _NativeValues extends ListBase<_Value?> {
  _NativeValues(this._length, this.read);
  final int _length;
  final _Value? Function(int) read;
  @override
  int get length => _length;
  @override
  set length(int value) => throw UnsupportedError('Read only');
  @override
  _Value? operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return read(index);
  }

  @override
  void operator []=(int index, _Value? value) =>
      throw UnsupportedError('Read only');
}

DataType _inferNativeType(Iterable<Object?> values) {
  final inference = _NativeTypeInference();
  DataType? scalarType;
  var onlyScalars = true;
  var sawScalar = false;
  for (final value in values) {
    if (value is Scalar) {
      sawScalar = true;
      if (scalarType != null && scalarType != value.type) onlyScalars = false;
      scalarType ??= value.type;
      inference.add(
        value is DictionaryScalar ? value.value.value : value.value,
      );
    } else {
      if (value != null) onlyScalars = false;
      inference.add(value);
    }
  }
  if (onlyScalars && sawScalar) return scalarType!;
  return inference.finish();
}

// Only type summaries survive the scan, including for nested child values.
class _NativeTypeInference {
  String? kind;
  _NativeTypeInference? child;
  final fields = <String, _NativeTypeInference>{};
  TemporalValue? temporal;
  int? scale;
  int? integerDigits;
  bool utc = false;
  bool dateTimeSeen = false;

  void add(Object? value) {
    if (value == null) return;
    final next = switch (value) {
      bool() => 'bool',
      int() || BigInt() => 'int',
      num() => 'float',
      String() => 'string',
      Uint8List() => 'binary',
      List() => 'list',
      Map() => 'struct',
      DateTime() => 'datetime',
      Duration() => 'duration',
      TemporalValue() => 'temporal',
      DecimalValue() => 'decimal',
      _ => throw ArgumentError('Cannot infer an Arrow datatype for $value'),
    };
    if (kind == null) {
      kind = next;
    } else if (kind != next) {
      if ((kind == 'int' || kind == 'float') &&
          (next == 'int' || next == 'float')) {
        kind = 'float';
      } else if ((kind == 'string' || kind == 'binary') &&
          (next == 'string' || next == 'binary')) {
        kind = 'binary';
      } else {
        throw ArgumentError('Cannot infer a common Arrow datatype');
      }
    }
    if (value is List && value is! Uint8List) {
      final item = child ??= _NativeTypeInference();
      for (final element in value) {
        item.add(element);
      }
    } else if (value is Map) {
      for (final entry in value.entries) {
        final name = entry.key;
        if (name is! String) throw ArgumentError('Struct keys must be strings');
        (fields[name] ??= _NativeTypeInference()).add(entry.value);
      }
    } else if (value is TemporalValue) {
      temporal ??= value;
    } else if (value is DateTime) {
      if (!dateTimeSeen) {
        utc = value.isUtc;
        dateTimeSeen = true;
      }
    } else if (value is DecimalValue) {
      if (scale == null || value.scale > scale!) scale = value.scale;
      final digits = value.unscaled.abs().toString().length - value.scale;
      if (integerDigits == null || digits > integerDigits!)
        integerDigits = digits;
    }
  }

  DataType finish() => switch (kind) {
    null => const NullType(),
    'bool' => const BooleanType(),
    'int' => int64(),
    'float' => float64(),
    'string' => const Utf8Type(),
    'binary' => const BinaryType(),
    'list' => ListType(Field('item', child!.finish())),
    'struct' => _structType(),
    'datetime' => TimestampType(
      TimeUnit.microsecond,
      timeZone: utc ? 'UTC' : null,
    ),
    'duration' => const DurationType(TimeUnit.microsecond),
    'temporal' => switch (temporal!.kind) {
      'date' => DateType(temporal!.dateUnit ?? DateUnit.day),
      'time' => TimeType(temporal!.unit),
      'duration' => DurationType(temporal!.unit),
      _ => TimestampType(temporal!.unit, timeZone: temporal!.timeZone),
    },
    'decimal' => () {
      final precision = integerDigits! + scale! < 1
          ? 1
          : integerDigits! + scale!;
      return DecimalType(
        precision,
        scale!,
        bitWidth: precision > 38 ? 256 : 128,
      );
    }(),
    _ => throw StateError('Unknown inference kind'),
  };

  StructType _structType() {
    final names = fields.keys;
    return StructType([
      for (final name in names) Field(name, fields[name]!.finish()),
    ]);
  }
}

Array _encodeNative(
  DataType type,
  int length,
  Object? Function(int) at,
  bool safe,
) {
  if (type is NullType) {
    for (var i = 0; i < length; i++) {
      _nativeRaw(at(i), type, safe: safe);
    }
    return Array._(type, length, 0, const [], const [], null);
  }
  final variable = type is Utf8Type || type is BinaryType;
  final width = variable
      ? _offsetSize(type)
      : type is BooleanType
      ? 0
      : _byteWidth(type);
  final data = Uint8List(
    variable
        ? (length + 1) * width
        : width == 0
        ? (length + 7) ~/ 8
        : length * width,
  );
  final bytes = ByteData.sublistView(data);
  final payload = variable ? BytesBuilder(copy: false) : null;
  final halfScratch = type is FloatingType && width == 2 ? ByteData(4) : null;
  final integer = type is IntegerType ? type : null;
  final integerMinimum = integer == null ? 0 : integer.minimum.toInt();
  final integerMaximum = integer == null ? 0 : integer.maximum.toInt();
  Uint8List? validity;
  for (var i = 0; i < length; i++) {
    final native = at(i);
    if (native == null) {
      if (validity == null) {
        validity = Uint8List((length + 7) ~/ 8);
        validity.fillRange(0, validity.length, 255);
      }
      validity[i >> 3] &= ~(1 << (i & 7));
    } else if (integer != null && width <= 8 && native is int) {
      if (native < integerMinimum || native > integerMaximum) {
        throw ArrowInvalid(
          'Integer $native outside ${integer.minimum}..${integer.maximum}',
        );
      }
      final start = i * width;
      switch (width) {
        case 1:
          bytes.setInt8(start, native);
        case 2:
          bytes.setInt16(start, native, Endian.little);
        case 4:
          bytes.setInt32(start, native, Endian.little);
        case 8:
          _setInt64(bytes, start, native);
      }
    } else if (type is BooleanType && native is bool) {
      if (native) data[i >> 3] |= 1 << (i & 7);
    } else if (type is FloatingType && native is double) {
      final start = i * width;
      switch (width) {
        case 2:
          bytes.setUint16(start, _half(native, halfScratch), Endian.little);
        case 4:
          bytes.setFloat32(start, native, Endian.little);
        case 8:
          bytes.setFloat64(start, native, Endian.little);
      }
    } else if (variable && native is String) {
      payload!.add(utf8.encode(native));
    } else if (type is BinaryType && native is Uint8List) {
      payload!.add(native);
    } else {
      final value = _nativeRaw(native, type, safe: safe);
      if (value == null) {
        if (validity == null) {
          validity = Uint8List((length + 7) ~/ 8);
          validity.fillRange(0, validity.length, 255);
        }
        validity[i >> 3] &= ~(1 << (i & 7));
      } else if (variable) {
        if (value is _StringValue) payload!.add(utf8.encode(value.value));
        if (value is _BinaryValue) payload!.add(value.bytes);
      } else if (value is _BooleanValue) {
        if (value.value) data[i >> 3] |= 1 << (i & 7);
      } else {
        final number = switch (value) {
          _IntegerValue() => value.value,
          _FloatingValue() => value.bits,
          _DecimalValue() => value.unscaled,
          _TemporalValue() => value.value,
          _ => throw StateError('Unexpected primitive value'),
        };
        _writeInteger(bytes, i * width, width, number);
      }
    }
    if (variable) {
      if (width == 4) {
        bytes.setInt32((i + 1) * width, payload!.length, Endian.little);
      } else {
        _setInt64(bytes, (i + 1) * width, payload!.length);
      }
    }
  }
  if (validity != null && length % 8 != 0) {
    validity[validity.length - 1] &= (1 << (length % 8)) - 1;
  }
  return Array._(
    type,
    length,
    0,
    List.unmodifiable([
      validity?.asUnmodifiableView(),
      data.asUnmodifiableView(),
      if (variable) payload!.toBytes().asUnmodifiableView(),
    ]),
    const [],
    null,
  );
}
