import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'type.dart';
import 'value.dart';
import 'schema.dart';

/// Arrow physical storage. Imported buffers are borrowed: callers must keep
/// their backing allocation alive and must not mutate any aliases while used.
final class ArrowArray {
  factory ArrowArray(
    ArrowDataType type,
    List<ArrowValue?> values, {
    List<bool>? validity,
    ArrowArray? dictionary,
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
      validateArrowValue(type, value);
      if (dt != null) {
        var storage = value;
        while (storage is ArrowExtensionValue) {
          storage = storage.storage;
        }
        final index = (storage as ArrowDictionaryIndexValue).index;
        if (index.isNegative || index >= BigInt.from(dictionary!.length)) {
          throw RangeError('Dictionary index out of bounds');
        }
      }
    }
    return _encode(type, values, dictionary);
  }

  ArrowArray._(
    this.type,
    this.length,
    this.offset,
    this.buffers,
    this.children,
    this.dictionary,
  );

  /// Imports little-endian Arrow buffers without copying. Buffer zero is the
  /// optional LSB-first validity bitmap; remaining slots follow Arrow layout.
  /// All buffers are borrowed and externally read-only. Keep the original
  /// storage alive and immutable through every alias while any view is used.
  /// Required data buffers must be supplied even when empty. Null validity
  /// means all valid; nullCount -1 means unknown. Children use logical indices:
  /// list offsets are relative to child index zero, including sliced children.
  factory ArrowArray.fromBuffers(
    ArrowDataType type, {
    required int length,
    int offset = 0,
    required List<Uint8List?> buffers,
    List<ArrowArray> children = const [],
    ArrowArray? dictionary,
    int? nullCount,
  }) {
    final array = ArrowArray._(
      type,
      length,
      offset,
      List.unmodifiable(buffers.map((b) => b?.asUnmodifiableView())),
      List.unmodifiable(children),
      dictionary,
    );
    array._validate();
    if (nullCount != null &&
        (nullCount < -1 || nullCount >= 0 && nullCount != array.nullCount)) {
      throw ArgumentError('nullCount disagrees with validity bitmap');
    }
    return array;
  }

  final ArrowDataType type;
  final int length;
  final int offset;
  final List<Uint8List?> buffers;
  final List<ArrowArray> children;
  late final ByteData _data = ByteData.sublistView(buffers[1]!);
  final ArrowArray? dictionary;
  late final List<ArrowValue?> values = _ArrayValues(this);
  late final List<bool> validity = _ArrayValidity(this);
  late final int nullCount = _countNulls();
  int _countNulls() {
    if (_storage is ArrowNullType) return length;
    if (buffers[0] == null) return 0;
    var count = 0;
    for (var i = 0; i < length; i++) {
      if (!isValid(i)) count++;
    }
    return count;
  }

  bool isValid(int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    if (_storage is ArrowNullType) return false;
    final bits = buffers[0];
    final i = offset + index;
    return bits == null || bits[i >> 3] & (1 << (i & 7)) != 0;
  }

  /// Constant-time view; shares buffers, children and dictionary without scans.
  ArrowArray slice(int start, [int? count]) {
    RangeError.checkValidRange(
      start,
      start + (count ?? length - start),
      length,
    );
    return ArrowArray._(
      type,
      count ?? length - start,
      offset + start,
      buffers,
      children,
      dictionary,
    );
  }

  ArrowDataType get _storage => _physicalType(type);
  int _offsetAt(int index) {
    final data = _data;
    return _offsetSize(_storage) == 4
        ? data.getInt32(index * 4, Endian.little)
        : data.getInt64(index * 8, Endian.little);
  }

  ArrowValue? operator [](int index) {
    if (!isValid(index)) return null;
    final i = offset + index;
    ArrowValue decode(ArrowDataType t) {
      if (t is ArrowExtensionType)
        return ArrowExtensionValue(decode(t.storageType));
      if (t is ArrowDictionaryType)
        return ArrowDictionaryIndexValue(
          _readInteger(
            _data,
            i * _byteWidth(t),
            _byteWidth(t),
            (t.indexType as ArrowIntegerType).signed,
          ),
        );
      if (t is ArrowBooleanType)
        return ArrowBooleanValue(buffers[1]![i >> 3] & (1 << (i & 7)) != 0);
      if (t is ArrowIntegerType)
        return ArrowIntegerValue(
          _readInteger(_data, i * (t.bitWidth ~/ 8), t.bitWidth ~/ 8, t.signed),
        );
      if (t is ArrowFloatingType)
        return ArrowFloatingValue(
          t.bitWidth,
          _readInteger(_data, i * (t.bitWidth ~/ 8), t.bitWidth ~/ 8, false),
        );
      if (t is ArrowDecimalType)
        return ArrowDecimalValue(_readInteger(_data, i * 16, 16, true));
      if (t is ArrowUtf8Type || t is ArrowBinaryType) {
        final bytes = Uint8List.sublistView(
          buffers[2]!,
          _offsetAt(i),
          _offsetAt(i + 1),
        );
        return t is ArrowUtf8Type
            ? ArrowStringValue(utf8.decode(bytes))
            : ArrowBinaryValue(bytes);
      }
      if (t is ArrowListType)
        return ArrowListValue(
          children[0]
              .slice(_offsetAt(i), _offsetAt(i + 1) - _offsetAt(i))
              .values,
        );
      if (t is ArrowFixedSizeListType)
        return ArrowListValue(children[0].slice(i * t.size, t.size).values);
      if (t is ArrowStructType)
        return ArrowStructValue([
          for (var c = 0; c < children.length; c++)
            ArrowStructEntry(t.fields[c].name, children[c][i]),
        ]);
      return ArrowTemporalValue(
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
    final slots = t is ArrowNullType
        ? 0
        : t is ArrowUtf8Type || t is ArrowBinaryType
        ? 3
        : t is ArrowStructType || t is ArrowFixedSizeListType
        ? 1
        : 2;
    if (buffers.length != slots)
      throw ArgumentError('Expected $slots buffers for $type');
    if (slots > 0 && buffers[0] != null && buffers[0]!.length < bitmapBytes)
      throw ArgumentError('Truncated validity bitmap');
    void requireBuffer(int slot, int count, [int width = 1]) {
      if (buffers[slot] == null || buffers[slot]!.length ~/ width < count)
        throw ArgumentError('Truncated buffer $slot');
    }

    final fields = t is ArrowListType
        ? [t.field]
        : t is ArrowFixedSizeListType
        ? [t.field]
        : t is ArrowStructType
        ? t.fields
        : <ArrowField>[];
    if (children.length != fields.length)
      throw ArgumentError('Incorrect child count');
    for (var c = 0; c < fields.length; c++) {
      if (children[c].type != fields[c].type)
        throw ArgumentError('Child datatype mismatch');
    }
    if (t is ArrowListType || t is ArrowUtf8Type || t is ArrowBinaryType) {
      requireBuffer(1, 0);
      if (end >= buffers[1]!.length ~/ _offsetSize(t)) {
        throw ArgumentError('Truncated offsets buffer');
      }
      if (t is! ArrowListType) requireBuffer(2, 0);
      final limit = t is ArrowListType
          ? children[0].length
          : buffers[2]!.length;
      var previous = _offsetAt(offset);
      if (previous < 0) throw ArgumentError('Negative offset');
      for (var i = offset + 1; i <= end; i++) {
        final next = _offsetAt(i);
        if (next < previous || next > limit)
          throw ArgumentError('Invalid offsets');
        previous = next;
      }
      if (previous > limit) throw ArgumentError('Offset exceeds storage');
    } else if (t is ArrowBooleanType) {
      requireBuffer(1, bitmapBytes);
    } else if (t is ArrowFixedSizeListType) {
      if (t.size != 0 && children[0].length ~/ t.size < end)
        throw ArgumentError('Truncated list child');
    } else if (t is ArrowStructType) {
      if (children.any((c) => c.length < end))
        throw ArgumentError('Truncated struct child');
    } else if (t is! ArrowNullType) {
      requireBuffer(1, end, _byteWidth(t));
    }
    final dt = _dictionaryType(type);
    if (dt == null && dictionary != null)
      throw ArgumentError('Unexpected dictionary');
    if (dt != null && (dictionary == null || dictionary!.type != dt.valueType))
      throw ArgumentError('Dictionary datatype mismatch');
    if (t is ArrowFixedSizeListType && t.size == 0) return;
    // Semantic invariants not expressible by buffer sizes alone.
    if (dt == null &&
        t is! ArrowUtf8Type &&
        t is! ArrowTimeType &&
        t is! ArrowDecimalType &&
        !fields.any((f) => !f.nullable))
      return;
    for (var i = 0; i < length; i++) {
      if (!isValid(i)) continue;
      if (dt != null) {
        final index = _readInteger(
          _data,
          (offset + i) * _byteWidth(t),
          _byteWidth(t),
          (dt.indexType as ArrowIntegerType).signed,
        );
        if (index.isNegative || index >= BigInt.from(dictionary!.length))
          throw RangeError('Dictionary index out of bounds');
      }
      if (t is ArrowUtf8Type || t is ArrowTimeType || t is ArrowDecimalType)
        validateArrowValue(type, this[i]!);
      if (t is ArrowListType ||
          t is ArrowFixedSizeListType ||
          t is ArrowStructType) {
        for (var c = 0; c < fields.length; c++) {
          if (fields[c].nullable) continue;
          final start = t is ArrowListType
              ? _offsetAt(offset + i)
              : t is ArrowFixedSizeListType
              ? (offset + i) * t.size
              : offset + i;
          final stop = t is ArrowListType
              ? _offsetAt(offset + i + 1)
              : t is ArrowFixedSizeListType
              ? start + t.size
              : start + 1;
          for (var j = start; j < stop; j++) {
            if (!children[c].isValid(j))
              throw ArgumentError('Null in non-nullable child');
          }
        }
      }
    }
  }
}

final class _ArrayValues extends ListBase<ArrowValue?> {
  _ArrayValues(this.array);
  final ArrowArray array;
  @override
  int get length => array.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only view');
  @override
  ArrowValue? operator [](int index) => array[index];
  @override
  void operator []=(int index, ArrowValue? value) =>
      throw UnsupportedError('Read-only view');
}

final class _ArrayValidity extends ListBase<bool> {
  _ArrayValidity(this.array);
  final ArrowArray array;
  @override
  int get length => array.length;
  @override
  set length(int value) => throw UnsupportedError('Read-only view');
  @override
  bool operator [](int index) => array.isValid(index);
  @override
  void operator []=(int index, bool value) =>
      throw UnsupportedError('Read-only view');
}

ArrowDataType _physicalType(ArrowDataType t) =>
    t is ArrowExtensionType ? _physicalType(t.storageType) : t;
ArrowDictionaryType? _dictionaryType(ArrowDataType t) =>
    _physicalType(t) is ArrowDictionaryType
    ? _physicalType(t) as ArrowDictionaryType
    : null;
int _offsetSize(ArrowDataType t) =>
    (t is ArrowUtf8Type && t.offsetWidth == ArrowOffsetWidth.large ||
        t is ArrowBinaryType && t.offsetWidth == ArrowOffsetWidth.large)
    ? 8
    : 4;
int _byteWidth(ArrowDataType t) {
  if (t is ArrowDictionaryType)
    return (t.indexType as ArrowIntegerType).bitWidth ~/ 8;
  if (t is ArrowIntegerType) return t.bitWidth ~/ 8;
  if (t is ArrowFloatingType) return t.bitWidth ~/ 8;
  if (t is ArrowDecimalType) return 16;
  if (t is ArrowDateType) return t.unit == ArrowDateUnit.day ? 4 : 8;
  if (t is ArrowTimeType)
    return t.unit == ArrowTimeUnit.second || t.unit == ArrowTimeUnit.millisecond
        ? 4
        : 8;
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

ArrowArray _encode(
  ArrowDataType type,
  List<ArrowValue?> input,
  ArrowArray? dictionary,
) {
  if (type is ArrowExtensionType) {
    final storage = _encode(
      type.storageType,
      input
          .map((v) => v == null ? null : (v as ArrowExtensionValue).storage)
          .toList(),
      dictionary,
    );
    return ArrowArray._(
      type,
      storage.length,
      0,
      storage.buffers,
      storage.children,
      storage.dictionary,
    );
  }
  final n = input.length;
  if (type is ArrowNullType)
    return ArrowArray._(type, n, 0, const [], const [], null);
  Uint8List? validity;
  if (input.contains(null)) {
    validity = Uint8List((n + 7) ~/ 8);
    for (var i = 0; i < n; i++) {
      if (input[i] != null) validity[i >> 3] |= 1 << (i & 7);
    }
  }
  final buffers = <Uint8List?>[validity];
  final children = <ArrowArray>[];
  if (type is ArrowListType || type is ArrowFixedSizeListType) {
    final field = type is ArrowListType
        ? type.field
        : (type as ArrowFixedSizeListType).field;
    final childValues = <ArrowValue?>[];
    final offsets = type is ArrowListType ? Uint8List((n + 1) * 4) : null;
    final offsetData = offsets == null ? null : ByteData.sublistView(offsets);
    for (var i = 0; i < n; i++) {
      final v = input[i] as ArrowListValue?;
      if (v != null) childValues.addAll(v.values);
      if (v == null && type is ArrowFixedSizeListType)
        childValues.addAll(List.filled(type.size, null));
      offsetData?.setInt32((i + 1) * 4, childValues.length, Endian.little);
    }
    if (type is ArrowListType) buffers.add(offsets);
    children.add(ArrowArray(field.type, childValues));
  } else if (type is ArrowStructType) {
    for (var c = 0; c < type.fields.length; c++) {
      children.add(
        ArrowArray(type.fields[c].type, [
          for (final v in input)
            v == null ? null : (v as ArrowStructValue).fields[c].value,
        ]),
      );
    }
  } else if (type is ArrowUtf8Type || type is ArrowBinaryType) {
    final width = _offsetSize(type);
    final offsets = Uint8List((n + 1) * width);
    final offsetData = ByteData.sublistView(offsets);
    final data = BytesBuilder(copy: false);
    for (var i = 0; i < n; i++) {
      final v = input[i];
      if (v is ArrowStringValue) data.add(utf8.encode(v.value));
      if (v is ArrowBinaryValue) data.add(v.bytes);
      if (width == 4) {
        offsetData.setInt32((i + 1) * width, data.length, Endian.little);
      } else {
        offsetData.setInt64((i + 1) * width, data.length, Endian.little);
      }
    }
    buffers.addAll([offsets, data.takeBytes()]);
  } else if (type is ArrowBooleanType) {
    final data = Uint8List((n + 7) ~/ 8);
    for (var i = 0; i < n; i++) {
      if ((input[i] as ArrowBooleanValue?)?.value == true)
        data[i >> 3] |= 1 << (i & 7);
    }
    buffers.add(data);
  } else {
    final width = _byteWidth(type);
    final data = Uint8List(n * width);
    final byteData = ByteData.sublistView(data);
    for (var i = 0; i < n; i++) {
      final v = input[i];
      final value = switch (v) {
        ArrowIntegerValue() => v.value,
        ArrowFloatingValue() => v.bits,
        ArrowDecimalValue() => v.unscaled,
        ArrowTemporalValue() => v.value,
        ArrowDictionaryIndexValue() => v.index,
        _ => BigInt.zero,
      };
      _writeInteger(byteData, i * width, width, value);
    }
    buffers.add(data);
  }
  return ArrowArray._(
    type,
    n,
    0,
    List.unmodifiable(buffers.map((b) => b?.asUnmodifiableView())),
    List.unmodifiable(children),
    dictionary,
  );
}

final class ArrowArrayBuilder {
  ArrowArrayBuilder(this.type, {this.dictionary});
  final ArrowDataType type;
  final ArrowArray? dictionary;
  final List<ArrowValue?> _values = [];
  bool _built = false;
  int _length = 0;

  int get length => _length;
  void append(ArrowValue? value) {
    if (_built) throw StateError('Builder has already been built');
    if (value != null) validateArrowValue(type, value, path: 'value');
    _values.add(value);
    _length++;
  }

  void appendNull() => append(null);
  ArrowArray build() {
    if (_built) throw StateError('Builder has already been built');
    _built = true;
    final array = ArrowArray(type, _values, dictionary: dictionary);
    _values.clear();
    return array;
  }
}

void validateArrowValue(
  ArrowDataType type,
  ArrowValue value, {
  String path = 'value',
}) {
  Never mismatch() =>
      throw ArgumentError('$path is ${value.runtimeType}, not valid for $type');
  switch (type) {
    case ArrowNullType():
      mismatch();
    case ArrowBooleanType():
      if (value is! ArrowBooleanValue) mismatch();
    case final ArrowIntegerType integer:
      if (value is! ArrowIntegerValue) mismatch();
      if (value.value < integer.minimum || value.value > integer.maximum) {
        throw RangeError(
          '$path integer ${value.value} is outside ${integer.minimum}..${integer.maximum}',
        );
      }
    case final ArrowFloatingType floating:
      if (value is! ArrowFloatingValue || value.bitWidth != floating.bitWidth)
        mismatch();
    case final ArrowDecimalType decimal:
      if (value is! ArrowDecimalValue) mismatch();
      final digits = value.unscaled.abs().toString().length;
      if (digits > decimal.precision) {
        throw RangeError(
          '$path unscaled decimal has $digits digits; precision is ${decimal.precision}',
        );
      }
    case ArrowUtf8Type():
      if (value is! ArrowStringValue) mismatch();
    case ArrowBinaryType():
      if (value is! ArrowBinaryValue) mismatch();
    case final ArrowDateType date:
      if (value is! ArrowTemporalValue) mismatch();
      final width = date.unit == ArrowDateUnit.day ? 32 : 64;
      final minimum = -(BigInt.one << (width - 1));
      final maximum = (BigInt.one << (width - 1)) - BigInt.one;
      if (value.value < minimum || value.value > maximum) {
        throw RangeError('$path date counter does not fit int$width');
      }
    case ArrowTimestampType() || ArrowDurationType():
      if (value is! ArrowTemporalValue) mismatch();
      if (!_fitsSigned64(value.value)) {
        throw RangeError('$path temporal counter does not fit int64');
      }
    case final ArrowTimeType time:
      if (value is! ArrowTemporalValue) mismatch();
      final unitsPerSecond = switch (time.unit) {
        ArrowTimeUnit.second => BigInt.one,
        ArrowTimeUnit.millisecond => BigInt.from(1000),
        ArrowTimeUnit.microsecond => BigInt.from(1000000),
        ArrowTimeUnit.nanosecond => BigInt.from(1000000000),
      };
      final endOfDay = BigInt.from(86400) * unitsPerSecond;
      if (value.value.isNegative || value.value >= endOfDay) {
        throw RangeError('$path time counter must fall within one day');
      }
      if ((time.unit == ArrowTimeUnit.second ||
              time.unit == ArrowTimeUnit.millisecond) &&
          value.value > BigInt.from(0x7fffffff)) {
        throw RangeError('$path time counter does not fit int32');
      }
    case final ArrowListType list:
      if (value is! ArrowListValue) mismatch();
      _validateChildren(list.field, value.values, path);
    case final ArrowFixedSizeListType list:
      if (value is! ArrowListValue) mismatch();
      if (value.values.length != list.size) {
        throw ArgumentError(
          '$path has ${value.values.length} children; expected ${list.size}',
        );
      }
      _validateChildren(list.field, value.values, path);
    case final ArrowStructType struct:
      if (value is! ArrowStructValue) mismatch();
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
        if (actual.value == null) {
          if (!expected.nullable)
            throw ArgumentError('$path.${expected.name} is not nullable');
        } else {
          validateArrowValue(
            expected.type,
            actual.value!,
            path: '$path.${expected.name}',
          );
        }
      }
    case final ArrowDictionaryType dictionary:
      if (value is! ArrowDictionaryIndexValue) mismatch();
      validateArrowValue(
        dictionary.indexType,
        ArrowIntegerValue(value.index),
        path: path,
      );
    case final ArrowExtensionType extension:
      if (value is! ArrowExtensionValue) mismatch();
      validateArrowValue(
        extension.storageType,
        value.storage,
        path: '$path.storage',
      );
  }
}

bool _fitsSigned64(BigInt value) =>
    value >= -(BigInt.one << 63) && value <= (BigInt.one << 63) - BigInt.one;

void _validateChildren(
  ArrowField field,
  List<ArrowValue?> values,
  String path,
) {
  for (var i = 0; i < values.length; i++) {
    final child = values[i];
    if (child == null) {
      if (!field.nullable) throw ArgumentError('$path[$i] is not nullable');
    } else {
      validateArrowValue(field.type, child, path: '$path[$i]');
    }
  }
}
