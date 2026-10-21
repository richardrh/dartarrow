part of 'core.dart';

/// Arrow physical storage. Imported _physicalBuffers are borrowed: callers must keep
/// their backing allocation alive and must not mutate any aliases while used.
final class Array {
  /// A lazy scalar view; separate from [cast] because Dart's Iterable.cast
  /// has an incompatible generic signature.
  Iterable<Scalar> get scalars sync* {
    for (var i = 0; i < length; i++) yield this[i];
  }

  factory Array._fromRaw(
    DataType type,
    List<_Value?> values, {
    List<bool>? validity,
    Array? dictionary,
  }) {
    if (validity != null) {
      if (validity.length != values.length)
        throw ArgumentError('Validity length mismatch');
      for (var i = 0; i < values.length; i++) {
        if (validity[i] != (values[i] != null))
          throw ArgumentError('Validity and values disagree at $i');
      }
    }
    final dt = _dictionaryType(type);
    if (dt == null
        ? dictionary != null
        : dictionary == null || dictionary.type != dt.valueType) {
      throw ArgumentError('Dictionary datatype mismatch');
    }
    for (final value in values) {
      if (value == null) continue;
      _validateRawValue(type, value);
      if (dt != null) {
        var storage = value;
        while (storage is _ExtensionValue) {
          storage = storage.storage;
        }
        final index = (storage as _DictionaryIndexValue).index;
        if (index.isNegative || index >= BigInt.from(dictionary!.length)) {
          throw RangeError('Dictionary index out of bounds');
        }
      }
    }
    return _encode(type, values, dictionary);
  }

  factory Array.fromDictionary(
    Array indices,
    Array dictionary, {
    bool ordered = false,
  }) {
    if (indices.type is! IntegerType ||
        (indices.type as IntegerType).bitWidth > 64) {
      throw ArgumentError('Dictionary indices must be standard integer arrays');
    }
    return Array._fromRaw(
      DictionaryType(indices.type, dictionary.type, ordered: ordered),
      [
        for (final value in indices._rawValues)
          value == null
              ? null
              : _DictionaryIndexValue((value as _IntegerValue).value),
      ],
      dictionary: dictionary,
    );
  }

  Array._(
    this.type,
    this.length,
    this.offset,
    this._physicalBuffers,
    this.children,
    this.dictionary, [
    this._owner,
  ]);

  /// Imports little-endian Arrow _physicalBuffers without copying. Buffer zero is the
  /// optional LSB-first validity bitmap; remaining slots follow Arrow layout.
  /// All _physicalBuffers are borrowed and externally read-only. Keep the original
  /// storage alive and immutable through every alias while any view is used.
  /// Required data _physicalBuffers must be supplied even when empty. Null validity
  /// means all valid; nullCount -1 means unknown. Children use logical indices:
  /// list offsets are relative to child index zero, including sliced children.
  factory Array.fromBuffers(
    DataType type,
    int length,
    List<Buffer?> buffers, {
    int offset = 0,
    List<Array> children = const [],
    Array? dictionary,
    int nullCount = -1,
  }) {
    final array = Array._(
      type,
      length,
      offset,
      List.unmodifiable(buffers.map((b) => b?.bytes)),
      List.unmodifiable(children),
      dictionary,
      List<Buffer?>.unmodifiable(buffers),
    );
    array._validate();
    if (nullCount < -1 || nullCount >= 0 && nullCount != array.nullCount) {
      throw ArgumentError('nullCount disagrees with validity bitmap');
    }
    return array;
  }

  final DataType type;
  final int length;
  final int offset;
  final List<Uint8List?> _physicalBuffers;
  final Object? _owner;
  final List<Array> children;
  late final ByteData _data = ByteData.sublistView(_physicalBuffers[1]!);
  final Array? dictionary;
  late final List<_Value?> _rawValues = _ArrayValues(this);
  late final List<bool> _validity = _ArrayValidity(this);
  late final int nullCount = _countNulls();
  int _countNulls() {
    if (_storage is NullType) return length;
    if (_physicalBuffers[0] == null) return 0;
    var count = 0;
    for (var i = 0; i < length; i++) {
      if (!_isValid(i)) count++;
    }
    return count;
  }

  bool _isValid(int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    if (_storage is NullType) return false;
    final bits = _physicalBuffers[0];
    final i = offset + index;
    return bits == null || bits[i >> 3] & (1 << (i & 7)) != 0;
  }

  /// A non-null BooleanArray mask. Dictionary values are decoded for masks.
  Array isValid() {
    final physical = _storage;
    if (physical is! NullType && physical is! DictionaryType) {
      final validity = _physicalBuffers.first;
      if (validity != null) {
        return Array._(
          const BooleanType(),
          length,
          offset,
          [null, validity],
          const [],
          null,
          this,
        );
      }
    }
    final data = Uint8List((length + 7) ~/ 8);
    _writeNullBits(data, 0);
    for (var i = 0; i < data.length; i++) {
      data[i] ^= 255;
    }
    if (length % 8 != 0) data[data.length - 1] &= (1 << (length % 8)) - 1;
    return Array._(
      const BooleanType(),
      length,
      0,
      [null, data.asUnmodifiableView()],
      const [],
      null,
      this,
    );
  }

  /// A non-null BooleanArray mask, optionally treating floating NaN as null.
  Array isNull({bool nanIsNull = false}) {
    final data = Uint8List((length + 7) ~/ 8);
    _writeNullBits(data, 0, nanIsNull: nanIsNull);
    return Array._(
      const BooleanType(),
      length,
      0,
      [null, data.asUnmodifiableView()],
      const [],
      null,
      this,
    );
  }

  void _writeNullBits(
    Uint8List output,
    int outputOffset, {
    bool nanIsNull = false,
  }) {
    final physical = _storage;
    final encoded = physical is DictionaryType;
    final dictionaryMask = encoded
        ? dictionary!.isNull(nanIsNull: nanIsNull)._physicalBuffers[1]!
        : null;
    final indexType = encoded ? physical.indexType as IntegerType : null;
    final width = encoded
        ? indexType!.bitWidth ~/ 8
        : physical is FloatingType
        ? physical.bitWidth ~/ 8
        : 0;
    final data = encoded || nanIsNull && physical is FloatingType
        ? _data
        : null;
    for (var i = 0; i < length; i++) {
      var missing = !_isValid(i);
      if (!missing && encoded) {
        final start = (offset + i) * width;
        final index = switch (width) {
          1 => indexType!.signed ? data!.getInt8(start) : data!.getUint8(start),
          2 =>
            indexType!.signed
                ? data!.getInt16(start, Endian.little)
                : data!.getUint16(start, Endian.little),
          4 =>
            indexType!.signed
                ? data!.getInt32(start, Endian.little)
                : data!.getUint32(start, Endian.little),
          8 =>
            indexType!.signed
                ? data!.getInt64(start, Endian.little)
                : data!.getUint64(start, Endian.little),
          _ => throw StateError('Invalid dictionary index width'),
        };
        missing = dictionaryMask![index >> 3] & (1 << (index & 7)) != 0;
      } else if (!missing && nanIsNull && physical is FloatingType) {
        final start = (offset + i) * width;
        missing = switch (width) {
          2 => (data!.getUint16(start, Endian.little) & 0x7fff) > 0x7c00,
          4 =>
            (data!.getUint32(start, Endian.little) & 0x7fffffff) > 0x7f800000,
          8 =>
            (data!.getUint64(start, Endian.little) & 0x7fffffffffffffff) >
                0x7ff0000000000000,
          _ => false,
        };
      }
      if (missing) {
        final position = outputOffset + i;
        output[position >> 3] |= 1 << (position & 7);
      }
    }
  }

  /// Constant-time view; shares _physicalBuffers, children and dictionary without scans.
  Array slice([int offset = 0, int? length]) {
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (length != null && length < 0)
      throw ArgumentError.value(length, 'length');
    if (offset > this.length) offset = this.length;
    final available = this.length - offset;
    final size = length == null || length > available ? available : length;
    return Array._(
      type,
      size,
      this.offset + offset,
      _physicalBuffers,
      children,
      dictionary,
      _owner ?? this,
    );
  }

  Scalar operator [](int index) {
    if (index < 0) index += length;
    RangeError.checkValidIndex(index, this, 'index', length);
    return Scalar._fromRaw(
      type,
      _rawValue(index),
      dictionary: dictionary,
      source: this,
      index: index,
    );
  }

  List<Object?> toDartList() => [
    for (var i = 0; i < length; i++) this[i].asDart(),
  ];

  List<Buffer?> buffers() => [
    if (_storage is NullType) null,
    for (final bytes in _physicalBuffers)
      bytes == null ? null : Buffer._borrowed(bytes, this),
    for (final child in children) ...child.buffers(),
  ];

  void validate({bool full = false}) {
    _validate();
    if (full) {
      for (final child in children) child.validate(full: true);
      dictionary?.validate(full: true);
    }
  }

  Array cast(DataType targetType, {bool safe = true}) =>
      _castArray(this, targetType, safe: safe);

  bool equals(Array other) {
    if (type != other.type || length != other.length) return false;
    final dictionaries = _hasDictionaryStorage(this)
        ? <Array, Map<Array, bool>>{}
        : null;
    for (var i = 0; i < length; i++) {
      if (!_elementEquals(this, i, other, i, dictionaries)) return false;
    }
    return true;
  }

  DataType get _storage => _physicalType(type);
  int _offsetAt(int index) {
    final data = _data;
    return _offsetSize(_storage) == 4
        ? data.getInt32(index * 4, Endian.little)
        : data.getInt64(index * 8, Endian.little);
  }

  _Value? _rawValue(int index) {
    if (!_isValid(index)) return null;
    final i = offset + index;
    _Value decode(DataType t) {
      if (t is ExtensionType) return _ExtensionValue(decode(t.storageType));
      if (t is DictionaryType)
        return _DictionaryIndexValue(
          _readInteger(
            _data,
            i * _byteWidth(t),
            _byteWidth(t),
            (t.indexType as IntegerType).signed,
          ),
        );
      if (t is BooleanType)
        return _BooleanValue(
          _physicalBuffers[1]![i >> 3] & (1 << (i & 7)) != 0,
        );
      if (t is IntegerType)
        return _IntegerValue(
          _readInteger(_data, i * (t.bitWidth ~/ 8), t.bitWidth ~/ 8, t.signed),
        );
      if (t is FloatingType)
        return _FloatingValue(
          t.bitWidth,
          _readInteger(_data, i * (t.bitWidth ~/ 8), t.bitWidth ~/ 8, false),
        );
      if (t is DecimalType)
        return _DecimalValue(_readInteger(_data, i * 16, 16, true));
      if (t is Utf8Type || t is BinaryType) {
        final bytes = Uint8List.sublistView(
          _physicalBuffers[2]!,
          _offsetAt(i),
          _offsetAt(i + 1),
        );
        return t is Utf8Type
            ? _StringValue(utf8.decode(bytes))
            : _BinaryValue(bytes);
      }
      if (t is ListType)
        return _ListValue(
          children[0]
              .slice(_offsetAt(i), _offsetAt(i + 1) - _offsetAt(i))
              ._rawValues,
        );
      if (t is FixedSizeListType)
        return _ListValue(children[0].slice(i * t.size, t.size)._rawValues);
      if (t is StructType)
        return _StructValue([
          for (var c = 0; c < children.length; c++)
            _StructEntry(t.fields[c].name, children[c]._rawValue(i)),
        ]);
      return _TemporalValue(
        _readInteger(_data, i * _byteWidth(t), _byteWidth(t), true),
      );
    }

    return decode(type);
  }

  void _validate() {
    if (length < 0 || offset < 0)
      throw ArgumentError('Negative length or offset');
    final t = _storage;
    final end = offset + length;
    if (end < offset) throw ArgumentError('Array offset plus length overflows');
    final bitmapBytes = end ~/ 8 + (end % 8 == 0 ? 0 : 1);
    final slots = t is NullType
        ? 0
        : t is Utf8Type || t is BinaryType
        ? 3
        : t is StructType || t is FixedSizeListType
        ? 1
        : 2;
    if (_physicalBuffers.length != slots)
      throw ArgumentError('Expected $slots _physicalBuffers for $type');
    if (slots > 0 &&
        _physicalBuffers[0] != null &&
        _physicalBuffers[0]!.length < bitmapBytes)
      throw ArgumentError('Truncated validity bitmap');
    void requireBuffer(int slot, int count, [int width = 1]) {
      if (_physicalBuffers[slot] == null ||
          _physicalBuffers[slot]!.length ~/ width < count)
        throw ArgumentError('Truncated buffer $slot');
    }

    final fields = t is ListType
        ? [t.field]
        : t is FixedSizeListType
        ? [t.field]
        : t is StructType
        ? t.fields
        : <Field>[];
    if (children.length != fields.length)
      throw ArgumentError('Incorrect child count');
    for (var c = 0; c < fields.length; c++) {
      if (children[c].type != fields[c].type)
        throw ArgumentError('Child datatype mismatch');
    }
    if (t is ListType || t is Utf8Type || t is BinaryType) {
      requireBuffer(1, 0);
      if (end >= _physicalBuffers[1]!.length ~/ _offsetSize(t)) {
        throw ArgumentError('Truncated offsets buffer');
      }
      if (t is! ListType) requireBuffer(2, 0);
      final limit = t is ListType
          ? children[0].length
          : _physicalBuffers[2]!.length;
      var previous = _offsetAt(offset);
      if (previous < 0) throw ArgumentError('Negative offset');
      for (var i = offset + 1; i <= end; i++) {
        final next = _offsetAt(i);
        if (next < previous || next > limit)
          throw ArgumentError('Invalid offsets');
        previous = next;
      }
      if (previous > limit) throw ArgumentError('Offset exceeds storage');
    } else if (t is BooleanType) {
      requireBuffer(1, bitmapBytes);
    } else if (t is FixedSizeListType) {
      if (t.size != 0 && children[0].length ~/ t.size < end)
        throw ArgumentError('Truncated list child');
    } else if (t is StructType) {
      if (children.any((c) => c.length < end))
        throw ArgumentError('Truncated struct child');
    } else if (t is! NullType) {
      requireBuffer(1, end, _byteWidth(t));
    }
    final dt = _dictionaryType(type);
    if (dt == null && dictionary != null)
      throw ArgumentError('Unexpected dictionary');
    if (dt != null && (dictionary == null || dictionary!.type != dt.valueType))
      throw ArgumentError('Dictionary datatype mismatch');
    if (t is FixedSizeListType && t.size == 0) return;
    // Semantic invariants not expressible by buffer sizes alone.
    if (dt == null && t is! Utf8Type && t is! TimeType && t is! DecimalType)
      return;
    for (var i = 0; i < length; i++) {
      if (!_isValid(i)) continue;
      if (dt != null) {
        final index = _readInteger(
          _data,
          (offset + i) * _byteWidth(t),
          _byteWidth(t),
          (dt.indexType as IntegerType).signed,
        );
        if (index.isNegative || index >= BigInt.from(dictionary!.length))
          throw RangeError('Dictionary index out of bounds');
      }
      if (t is Utf8Type || t is TimeType || t is DecimalType)
        _validateRawValue(type, _rawValue(i)!);
    }
  }
}

final class _ArrayValues extends ListBase<_Value?> {
  _ArrayValues(this.array);
  final Array array;
  @override
  int get length => array.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only view');
  @override
  _Value? operator [](int index) => array._rawValue(index);
  @override
  void operator []=(int index, _Value? value) =>
      throw UnsupportedError('Read-only view');
}

final class _ArrayValidity extends ListBase<bool> {
  _ArrayValidity(this.array);
  final Array array;
  @override
  int get length => array.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only view');
  @override
  bool operator [](int index) => array._isValid(index);
  @override
  void operator []=(int index, bool value) =>
      throw UnsupportedError('Read-only view');
}

DataType _physicalType(DataType t) =>
    t is ExtensionType ? _physicalType(t.storageType) : t;
DictionaryType? _dictionaryType(DataType t) =>
    _physicalType(t) is DictionaryType
    ? _physicalType(t) as DictionaryType
    : null;
int _offsetSize(DataType t) =>
    (t is Utf8Type && t.offsetWidth == OffsetWidth.large ||
        t is BinaryType && t.offsetWidth == OffsetWidth.large)
    ? 8
    : 4;
int _byteWidth(DataType t) {
  if (t is DictionaryType) return (t.indexType as IntegerType).bitWidth ~/ 8;
  if (t is IntegerType) return t.bitWidth ~/ 8;
  if (t is FloatingType) return t.bitWidth ~/ 8;
  if (t is DecimalType) return 16;
  if (t is DateType) return t.unit == DateUnit.day ? 4 : 8;
  if (t is TimeType)
    return t.unit == TimeUnit.second || t.unit == TimeUnit.millisecond ? 4 : 8;
  return 8;
}

BigInt _readInteger(ByteData data, int start, int width, bool signed) {
  if (width <= 8) {
    final value = switch (width) {
      1 => signed ? data.getInt8(start) : data.getUint8(start),
      2 =>
        signed
            ? data.getInt16(start, Endian.little)
            : data.getUint16(start, Endian.little),
      4 =>
        signed
            ? data.getInt32(start, Endian.little)
            : data.getUint32(start, Endian.little),
      _ => data.getInt64(start, Endian.little),
    };
    return !signed && value < 0
        ? BigInt.from(value) + (BigInt.one << 64)
        : BigInt.from(value);
  }
  var value = BigInt.zero;
  for (var j = width - 1; j >= 0; j--) {
    value = (value << 8) | BigInt.from(data.getUint8(start + j));
  }
  return signed && data.getUint8(start + width - 1) & 128 != 0
      ? value - (BigInt.one << (width * 8))
      : value;
}

void _writeInteger(ByteData data, int start, int width, BigInt value) {
  if (width <= 8) {
    final raw = value.toSigned(width * 8).toInt();
    switch (width) {
      case 1:
        data.setInt8(start, raw);
      case 2:
        data.setInt16(start, raw, Endian.little);
      case 4:
        data.setInt32(start, raw, Endian.little);
      case 8:
        data.setInt64(start, raw, Endian.little);
    }
    return;
  }
  for (var j = 0; j < width; j++) {
    data.setUint8(start + j, (value & BigInt.from(255)).toInt());
    value >>= 8;
  }
}

Array _encode(DataType type, List<_Value?> input, Array? dictionary) {
  if (type is ExtensionType) {
    final storage = _encode(
      type.storageType,
      input
          .map((v) => v == null ? null : (v as _ExtensionValue).storage)
          .toList(),
      dictionary,
    );
    return Array._(
      type,
      storage.length,
      0,
      storage._physicalBuffers,
      storage.children,
      storage.dictionary,
    );
  }
  final n = input.length;
  if (type is NullType) return Array._(type, n, 0, const [], const [], null);
  Uint8List? validity;
  if (input.contains(null)) {
    validity = Uint8List((n + 7) ~/ 8);
    for (var i = 0; i < n; i++) {
      if (input[i] != null) validity[i >> 3] |= 1 << (i & 7);
    }
  }
  final _physicalBuffers = <Uint8List?>[validity];
  final children = <Array>[];
  if (type is ListType || type is FixedSizeListType) {
    final field = type is ListType
        ? type.field
        : (type as FixedSizeListType).field;
    final childValues = <_Value?>[];
    final offsets = type is ListType ? Uint8List((n + 1) * 4) : null;
    final offsetData = offsets == null ? null : ByteData.sublistView(offsets);
    for (var i = 0; i < n; i++) {
      final v = input[i] as _ListValue?;
      if (v != null) childValues.addAll(v.values);
      if (v == null && type is FixedSizeListType)
        childValues.addAll(List.filled(type.size, null));
      offsetData?.setInt32((i + 1) * 4, childValues.length, Endian.little);
    }
    if (type is ListType) _physicalBuffers.add(offsets);
    children.add(Array._fromRaw(field.type, childValues));
  } else if (type is StructType) {
    for (var c = 0; c < type.fields.length; c++) {
      children.add(
        Array._fromRaw(type.fields[c].type, [
          for (final v in input)
            v == null ? null : (v as _StructValue).fields[c].value,
        ]),
      );
    }
  } else if (type is Utf8Type || type is BinaryType) {
    final width = _offsetSize(type);
    final offsets = Uint8List((n + 1) * width);
    final offsetData = ByteData.sublistView(offsets);
    final data = BytesBuilder(copy: false);
    for (var i = 0; i < n; i++) {
      final v = input[i];
      if (v is _StringValue) data.add(utf8.encode(v.value));
      if (v is _BinaryValue) data.add(v.bytes);
      if (width == 4) {
        offsetData.setInt32((i + 1) * width, data.length, Endian.little);
      } else {
        offsetData.setInt64((i + 1) * width, data.length, Endian.little);
      }
    }
    _physicalBuffers.addAll([offsets, data.takeBytes()]);
  } else if (type is BooleanType) {
    final data = Uint8List((n + 7) ~/ 8);
    for (var i = 0; i < n; i++) {
      if ((input[i] as _BooleanValue?)?.value == true)
        data[i >> 3] |= 1 << (i & 7);
    }
    _physicalBuffers.add(data);
  } else {
    final width = _byteWidth(type);
    final data = Uint8List(n * width);
    final byteData = ByteData.sublistView(data);
    for (var i = 0; i < n; i++) {
      final v = input[i];
      final value = switch (v) {
        _IntegerValue() => v.value,
        _FloatingValue() => v.bits,
        _DecimalValue() => v.unscaled,
        _TemporalValue() => v.value,
        _DictionaryIndexValue() => v.index,
        _ => BigInt.zero,
      };
      _writeInteger(byteData, i * width, width, value);
    }
    _physicalBuffers.add(data);
  }
  return Array._(
    type,
    n,
    0,
    List.unmodifiable(_physicalBuffers.map((b) => b?.asUnmodifiableView())),
    List.unmodifiable(children),
    dictionary,
  );
}

void _validateRawValue(DataType type, _Value value, {String path = 'value'}) {
  Never mismatch() =>
      throw ArgumentError('$path is ${value.runtimeType}, not valid for $type');
  switch (type) {
    case NullType():
      mismatch();
    case BooleanType():
      if (value is! _BooleanValue) mismatch();
    case final IntegerType integer:
      if (value is! _IntegerValue) mismatch();
      if (value.value < integer.minimum || value.value > integer.maximum) {
        throw RangeError(
          '$path integer ${value.value} is outside ${integer.minimum}..${integer.maximum}',
        );
      }
    case final FloatingType floating:
      if (value is! _FloatingValue || value.bitWidth != floating.bitWidth)
        mismatch();
    case final DecimalType decimal:
      if (value is! _DecimalValue) mismatch();
      final digits = value.unscaled.abs().toString().length;
      if (digits > decimal.precision) {
        throw RangeError(
          '$path unscaled decimal has $digits digits; precision is ${decimal.precision}',
        );
      }
    case Utf8Type():
      if (value is! _StringValue) mismatch();
    case BinaryType():
      if (value is! _BinaryValue) mismatch();
    case final DateType date:
      if (value is! _TemporalValue) mismatch();
      final width = date.unit == DateUnit.day ? 32 : 64;
      final minimum = -(BigInt.one << (width - 1));
      final maximum = (BigInt.one << (width - 1)) - BigInt.one;
      if (value.value < minimum || value.value > maximum) {
        throw RangeError('$path date counter does not fit int$width');
      }
    case TimestampType() || DurationType():
      if (value is! _TemporalValue) mismatch();
      if (!_fitsSigned64(value.value)) {
        throw RangeError('$path temporal counter does not fit int64');
      }
    case final TimeType time:
      if (value is! _TemporalValue) mismatch();
      final unitsPerSecond = switch (time.unit) {
        TimeUnit.second => BigInt.one,
        TimeUnit.millisecond => BigInt.from(1000),
        TimeUnit.microsecond => BigInt.from(1000000),
        TimeUnit.nanosecond => BigInt.from(1000000000),
      };
      final endOfDay = BigInt.from(86400) * unitsPerSecond;
      if (value.value.isNegative || value.value >= endOfDay) {
        throw RangeError('$path time counter must fall within one day');
      }
      if ((time.unit == TimeUnit.second || time.unit == TimeUnit.millisecond) &&
          value.value > BigInt.from(0x7fffffff)) {
        throw RangeError('$path time counter does not fit int32');
      }
    case final ListType list:
      if (value is! _ListValue) mismatch();
      _validateChildren(list.field, value.values, path);
    case final FixedSizeListType list:
      if (value is! _ListValue) mismatch();
      if (value.values.length != list.size) {
        throw ArgumentError(
          '$path has ${value.values.length} children; expected ${list.size}',
        );
      }
      _validateChildren(list.field, value.values, path);
    case final StructType struct:
      if (value is! _StructValue) mismatch();
      if (value.fields.length != struct.fields.length) {
        throw ArgumentError(
          '$path has ${value.fields.length} fields; expected ${struct.fields.length}',
        );
      }
      for (var i = 0; i < struct.fields.length; i++) {
        final expected = struct.fields[i];
        final actual = value.fields[i];
        if (actual.name != expected.name) {
          throw ArgumentError(
            '$path field $i is ${actual.name}; expected ${expected.name}',
          );
        }
        if (actual.value != null) {
          _validateRawValue(
            expected.type,
            actual.value!,
            path: '$path.${expected.name}',
          );
        }
      }
    case final DictionaryType dictionary:
      if (value is! _DictionaryIndexValue) mismatch();
      _validateRawValue(
        dictionary.indexType,
        _IntegerValue(value.index),
        path: path,
      );
    case final ExtensionType extension:
      if (value is! _ExtensionValue) mismatch();
      _validateRawValue(
        extension.storageType,
        value.storage,
        path: '$path.storage',
      );
  }
}

bool _fitsSigned64(BigInt value) =>
    value >= -(BigInt.one << 63) && value <= (BigInt.one << 63) - BigInt.one;

void _validateChildren(Field field, List<_Value?> values, String path) {
  for (var i = 0; i < values.length; i++) {
    final child = values[i];
    if (child != null) {
      _validateRawValue(field.type, child, path: '$path[$i]');
    }
  }
}

/// Concatenates exact Arrow storage without host-value conversion.
Array concatArrays(List<Array> arrays) {
  if (arrays.isEmpty) throw ArgumentError('At least one array is required');
  if (arrays.length == 1) return arrays.single;
  final type = arrays.first.type;
  if (arrays.any((a) => a.type != type))
    throw ArgumentError('Array types must match');
  var length = 0;
  for (final array in arrays) {
    length = _checkedLengthAdd(length, array.length);
  }
  if (type is ExtensionType) {
    final storage = concatArrays([
      for (final a in arrays)
        Array._(
          type.storageType,
          a.length,
          a.offset,
          a._physicalBuffers,
          a.children,
          a.dictionary,
        ),
    ]);
    return Array._(
      type,
      length,
      0,
      storage._physicalBuffers,
      storage.children,
      storage.dictionary,
    );
  }
  if (type is DictionaryType) {
    final entries = <Array>[];
    final remaps = <List<int>>[];
    for (final a in arrays) {
      final source = a.dictionary!;
      final remap = <int>[];
      for (var i = 0; i < source.length; i++) {
        final value = source.slice(i, 1);
        var found = entries.indexWhere((entry) => entry.equals(value));
        if (found < 0) {
          found = entries.length;
          entries.add(value);
        }
        remap.add(found);
      }
      remaps.add(remap);
    }
    final dictionary = entries.isEmpty
        ? arrays.first.dictionary!.slice(0, 0)
        : concatArrays(entries);
    return Array._fromRaw(type, [
      for (var c = 0; c < arrays.length; c++)
        for (final value in arrays[c]._rawValues)
          value == null
              ? null
              : _DictionaryIndexValue(
                  remaps[c][(value as _DictionaryIndexValue).index.toInt()],
                ),
    ], dictionary: dictionary);
  }
  if (type is ListType || type is FixedSizeListType || type is StructType) {
    final validity = Uint8List((length + 7) ~/ 8);
    var index = 0;
    var nulls = 0;
    for (final a in arrays) {
      for (var i = 0; i < a.length; i++, index++) {
        if (a._isValid(i)) {
          validity[index >> 3] |= 1 << (index & 7);
        } else {
          nulls++;
        }
      }
    }
    final children = <Array>[];
    final buffers = <Uint8List?>[nulls == 0 ? null : validity];
    if (type is StructType) {
      for (var c = 0; c < type.fields.length; c++) {
        children.add(
          concatArrays([
            for (final a in arrays) a.children[c].slice(a.offset, a.length),
          ]),
        );
      }
    } else if (type is FixedSizeListType) {
      children.add(
        concatArrays([
          for (final a in arrays)
            a.children.single.slice(a.offset * type.size, a.length * type.size),
        ]),
      );
    } else {
      final offsets = Uint8List((length + 1) * 4);
      final data = ByteData.sublistView(offsets);
      final segments = <Array>[];
      var childLength = 0;
      var row = 0;
      for (final a in arrays) {
        final start = a._offsetAt(a.offset);
        final end = a._offsetAt(a.offset + a.length);
        segments.add(a.children.single.slice(start, end - start));
        for (var i = 1; i <= a.length; i++) {
          data.setInt32(
            ++row * 4,
            childLength + a._offsetAt(a.offset + i) - start,
            Endian.little,
          );
        }
        childLength += end - start;
      }
      buffers.add(offsets);
      children.add(concatArrays(segments));
    }
    return Array._(
      type,
      length,
      0,
      List.unmodifiable(buffers.map((b) => b?.asUnmodifiableView())),
      List.unmodifiable(children),
      null,
    );
  }
  return _concatLeaf(arrays, type, length);
}

Array _concatLeaf(List<Array> arrays, DataType type, int length) {
  if (type is NullType)
    return Array._(type, length, 0, const [], const [], null);
  Uint8List? validity;
  if (arrays.any((a) => a.nullCount != 0)) {
    validity = Uint8List((length + 7) ~/ 8);
    var row = 0;
    for (final a in arrays) {
      for (var i = 0; i < a.length; i++, row++) {
        if (a._isValid(i)) validity[row >> 3] |= 1 << (row & 7);
      }
    }
  }
  final buffers = <Uint8List?>[validity];
  if (type is Utf8Type || type is BinaryType) {
    final width = _offsetSize(type);
    final offsets = Uint8List((length + 1) * width);
    final offsetData = ByteData.sublistView(offsets);
    var byteLength = 0;
    for (final a in arrays) {
      byteLength += a._offsetAt(a.offset + a.length) - a._offsetAt(a.offset);
    }
    final bytes = Uint8List(byteLength);
    var bytePosition = 0;
    var row = 0;
    for (final a in arrays) {
      final start = a._offsetAt(a.offset);
      final end = a._offsetAt(a.offset + a.length);
      bytes.setRange(
        bytePosition,
        bytePosition + end - start,
        a._physicalBuffers[2]!,
        start,
      );
      for (var i = 1; i <= a.length; i++) {
        final position = bytePosition + a._offsetAt(a.offset + i) - start;
        row++;
        if (width == 4) {
          offsetData.setInt32(row * width, position, Endian.little);
        } else {
          offsetData.setInt64(row * width, position, Endian.little);
        }
      }
      bytePosition += end - start;
    }
    buffers.addAll([offsets, bytes]);
  } else if (type is BooleanType) {
    final bytes = Uint8List((length + 7) ~/ 8);
    var row = 0;
    for (final a in arrays) {
      for (var i = 0; i < a.length; i++, row++) {
        final source = a.offset + i;
        if (a._physicalBuffers[1]![source >> 3] & (1 << (source & 7)) != 0) {
          bytes[row >> 3] |= 1 << (row & 7);
        }
      }
    }
    buffers.add(bytes);
  } else {
    final width = _byteWidth(type);
    final bytes = Uint8List(length * width);
    var position = 0;
    for (final a in arrays) {
      final size = a.length * width;
      bytes.setRange(
        position,
        position + size,
        a._physicalBuffers[1]!,
        a.offset * width,
      );
      position += size;
    }
    buffers.add(bytes);
  }
  return Array._(
    type,
    length,
    0,
    List.unmodifiable(buffers.map((b) => b?.asUnmodifiableView())),
    const [],
    null,
  );
}

bool _hasDictionaryStorage(Array array) =>
    array.dictionary != null || array.children.any(_hasDictionaryStorage);

bool _elementEquals(
  Array left,
  int li,
  Array right,
  int ri, [
  Map<Array, Map<Array, bool>>? dictionaries,
]) {
  final type = _physicalType(left.type);
  if (type is DictionaryType) {
    final leftDictionary = left.dictionary!;
    final rightDictionary = right.dictionary!;
    var equal = dictionaries?[leftDictionary]?[rightDictionary];
    if (equal == null) {
      equal = leftDictionary.equals(rightDictionary);
      if (dictionaries != null) {
        final comparisons = dictionaries[leftDictionary] ??= <Array, bool>{};
        comparisons[rightDictionary] = equal;
      }
    }
    if (!equal) return false;
  }
  if (!left._isValid(li) || !right._isValid(ri)) {
    return left._isValid(li) == right._isValid(ri);
  }
  if (type is DictionaryType) {
    return _rawEquals(left.type, left._rawValue(li), right._rawValue(ri));
  }
  if (type is StructType) {
    for (var c = 0; c < type.fields.length; c++) {
      if (!_elementEquals(
        left.children[c],
        left.offset + li,
        right.children[c],
        right.offset + ri,
        dictionaries,
      ))
        return false;
    }
    return true;
  }
  if (type is ListType || type is FixedSizeListType) {
    final ls = type is ListType
        ? left._offsetAt(left.offset + li)
        : (left.offset + li) * (type as FixedSizeListType).size;
    final rs = type is ListType
        ? right._offsetAt(right.offset + ri)
        : (right.offset + ri) * (type as FixedSizeListType).size;
    final ln = type is ListType
        ? left._offsetAt(left.offset + li + 1) - ls
        : (type as FixedSizeListType).size;
    final rn = type is ListType
        ? right._offsetAt(right.offset + ri + 1) - rs
        : (type as FixedSizeListType).size;
    if (ln != rn) return false;
    for (var i = 0; i < ln; i++) {
      if (!_elementEquals(
        left.children.single,
        ls + i,
        right.children.single,
        rs + i,
        dictionaries,
      ))
        return false;
    }
    return true;
  }
  return _rawEquals(left.type, left._rawValue(li), right._rawValue(ri));
}

bool _rawEquals(DataType type, _Value? left, _Value? right) {
  if (left == null || right == null) return left == right;
  if (left is _FloatingValue && right is _FloatingValue) {
    return _floating(left) == _floating(right);
  }
  if (type is ExtensionType &&
      left is _ExtensionValue &&
      right is _ExtensionValue) {
    return _rawEquals(type.storageType, left.storage, right.storage);
  }
  if (left is _ListValue && right is _ListValue) {
    if (left.values.length != right.values.length) return false;
    final childType = type is ListType
        ? type.field.type
        : (type as FixedSizeListType).field.type;
    for (var i = 0; i < left.values.length; i++) {
      if (!_rawEquals(childType, left.values[i], right.values[i])) return false;
    }
    return true;
  }
  if (type is StructType && left is _StructValue && right is _StructValue) {
    for (var i = 0; i < type.fields.length; i++) {
      if (!_rawEquals(
        type.fields[i].type,
        left.fields[i].value,
        right.fields[i].value,
      ))
        return false;
    }
    return true;
  }
  return left == right;
}
