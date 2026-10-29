part of 'core.dart';

// Physical layouts beyond the original primitive/list/struct families:
// fixed-size binary, string/binary views, list views, maps, unions,
// intervals and run-end encoding. Large lists and decimal widths reuse the
// generic offset and fixed-width paths in array.dart.

bool _isView(DataType t) =>
    t is Utf8Type && t.offsetWidth == OffsetWidth.view ||
    t is BinaryType && t.offsetWidth == OffsetWidth.view;

/// Storage types whose layout is handled by this file.
bool _isExtendedStorage(DataType t) =>
    t is FixedSizeBinaryType ||
    _isView(t) ||
    t is ListType && t.view ||
    t is MapType ||
    t is UnionType ||
    t is IntervalType ||
    t is RunEndEncodedType;

/// Logical (not bitmap) validity: unions and run-end encoded arrays have no
/// validity bitmap, so a slot is null exactly when its selected child is.
bool _hasLogicalValidity(DataType t) =>
    t is UnionType || t is RunEndEncodedType;

int _intervalWidth(IntervalType t) => switch (t.unit) {
  IntervalUnit.yearMonth => 4,
  IntervalUnit.dayTime => 8,
  IntervalUnit.monthDayNano => 16,
};

/// The physical child fields of [t], in Arrow child order.
List<Field> _childFields(DataType t) => switch (t) {
  ListType(:final field) || FixedSizeListType(:final field) => [field],
  StructType(:final fields) || UnionType(:final fields) => fields,
  MapType map => [map.entriesField],
  RunEndEncodedType(:final runEndsField, :final valuesField) => [
    runEndsField,
    valuesField,
  ],
  _ => const [],
};

int _readSigned(ByteData data, int index, int width) => switch (width) {
  2 => data.getInt16(index * 2, Endian.little),
  4 => data.getInt32(index * 4, Endian.little),
  _ => _int64At(data, index * 8),
};

/// Reads an int64 through two 32-bit halves so dart2js can execute it for
/// values within the JavaScript safe-integer range.
int _int64At(ByteData data, int start) {
  final low = data.getUint32(start, Endian.little);
  final high = data.getInt32(start + 4, Endian.little);
  return high * 0x100000000 + low;
}

void _setInt64(ByteData data, int start, int value) {
  data.setUint32(start, value & 0xffffffff, Endian.little);
  data.setInt32(
    start + 4,
    (value - (value & 0xffffffff)) ~/ 0x100000000,
    Endian.little,
  );
}

int _runEndWidth(RunEndEncodedType t) =>
    (t.runEndsField.type as IntegerType).bitWidth ~/ 8;

int _runEndAt(Array runEnds, int k, int width) =>
    _readSigned(runEnds._data, runEnds.offset + k, width);

/// Index of the run containing logical [position] (parent offset applied).
int _runIndex(Array array, RunEndEncodedType t, int position) {
  final runEnds = array.children[0];
  final width = _runEndWidth(t);
  var low = 0;
  var high = runEnds.length - 1;
  while (low < high) {
    final middle = (low + high) >> 1;
    if (_runEndAt(runEnds, middle, width) > position) {
      high = middle;
    } else {
      low = middle + 1;
    }
  }
  return low;
}

/// Child index and child position selected by union slot [i].
(int, int) _unionSlot(Array array, UnionType t, int i) {
  final typeId = array._physicalBuffers[1]![i].toSigned(8);
  final child = t.childIndexForTypeId(typeId);
  if (child < 0) throw StateError('Undeclared union type id $typeId');
  final position = t.mode == UnionMode.sparse
      ? i
      : ByteData.sublistView(array._physicalBuffers[2]!)
            .getInt32(i * 4, Endian.little);
  return (child, position);
}

bool _logicalValid(Array array, DataType t, int i) {
  if (t is UnionType) {
    final (child, position) = _unionSlot(array, t, i);
    return array.children[child]._isValid(position);
  }
  final ree = t as RunEndEncodedType;
  return array.children[1]._isValid(_runIndex(array, ree, i));
}

int _sizeAt(Array array, int index) {
  final data = ByteData.sublistView(array._physicalBuffers[2]!);
  return (array._storage as ListType).offsetWidth == OffsetWidth.large
      ? _int64At(data, index * 8)
      : data.getInt32(index * 4, Endian.little);
}

/// Child start and length of list-like slot [i] (lists, views and maps).
(int, int) _listRange(Array array, int i) {
  final t = array._storage;
  final start = array._offsetAt(i);
  if (t is ListType && t.view) return (start, _sizeAt(array, i));
  return (start, array._offsetAt(i + 1) - start);
}

Uint8List _viewBytes(Array array, int i) {
  final views = ByteData.sublistView(array._physicalBuffers[1]!);
  final length = views.getInt32(i * 16, Endian.little);
  if (length <= 12) {
    return Uint8List.sublistView(
      array._physicalBuffers[1]!,
      i * 16 + 4,
      i * 16 + 4 + length,
    );
  }
  final buffer = views.getInt32(i * 16 + 8, Endian.little);
  final start = views.getInt32(i * 16 + 12, Endian.little);
  return Uint8List.sublistView(
    array._physicalBuffers[2 + buffer]!,
    start,
    start + length,
  );
}

/// Decodes physical slot [i] of an extended storage type [t].
_Value _decodeExtended(Array array, DataType t, int i) {
  switch (t) {
    case FixedSizeBinaryType(:final byteWidth):
      return _BinaryValue(
        Uint8List.sublistView(
          array._physicalBuffers[1]!,
          i * byteWidth,
          (i + 1) * byteWidth,
        ),
      );
    case Utf8Type():
      return _StringValue(utf8.decode(_viewBytes(array, i)));
    case BinaryType():
      return _BinaryValue(_viewBytes(array, i));
    case ListType():
      final (start, size) = _listRange(array, i);
      return _ListValue(array.children[0].slice(start, size)._rawValues);
    case MapType():
      final (start, size) = _listRange(array, i);
      final entries = array.children[0];
      return _MapValue([
        for (var j = start; j < start + size; j++)
          _MapEntry(
            entries.children[0]._rawValue(entries.offset + j) ??
                (throw StateError('Map keys cannot be null')),
            entries.children[1]._rawValue(entries.offset + j),
          ),
      ]);
    case UnionType():
      final (child, position) = _unionSlot(array, t, i);
      return _UnionValue(
        t.typeIds[child],
        array.children[child]._rawValue(position),
      );
    case IntervalType(:final unit):
      final data = array._data;
      return _IntervalValue(switch (unit) {
        IntervalUnit.yearMonth => IntervalValue.yearMonth(
          data.getInt32(i * 4, Endian.little),
        ),
        IntervalUnit.dayTime => IntervalValue.dayTime(
          data.getInt32(i * 8, Endian.little),
          data.getInt32(i * 8 + 4, Endian.little),
        ),
        IntervalUnit.monthDayNano => IntervalValue.monthDayNano(
          data.getInt32(i * 16, Endian.little),
          data.getInt32(i * 16 + 4, Endian.little),
          _readInteger(data, i * 16 + 8, 8, true),
        ),
      });
    case RunEndEncodedType():
      return array.children[1]._rawValue(_runIndex(array, t, i))!;
    default:
      throw StateError('Not an extended layout: $t');
  }
}

/// Validates extended layouts for logical slots `offset..end`.
void _validateExtended(Array array, DataType t, int end) {
  final buffers = array._physicalBuffers;
  final offset = array.offset;
  void requireBytes(int slot, int bytes) {
    if (buffers[slot] == null || buffers[slot]!.length < bytes) {
      throw ArgumentError('Truncated buffer $slot');
    }
  }

  switch (t) {
    case FixedSizeBinaryType(:final byteWidth):
      requireBytes(1, end * byteWidth);
    case IntervalType():
      requireBytes(1, end * _intervalWidth(t));
    case Utf8Type() || BinaryType():
      requireBytes(1, end * 16);
      for (var slot = 2; slot < buffers.length; slot++) {
        if (buffers[slot] == null) {
          throw ArgumentError('View data buffer $slot is missing');
        }
      }
      final views = ByteData.sublistView(buffers[1]!);
      for (var i = offset; i < end; i++) {
        if (!array._isValid(i - offset)) continue;
        final length = views.getInt32(i * 16, Endian.little);
        if (length < 0) throw ArgumentError('Negative view length');
        if (length <= 12) continue;
        final buffer = views.getInt32(i * 16 + 8, Endian.little);
        final start = views.getInt32(i * 16 + 12, Endian.little);
        if (buffer < 0 ||
            2 + buffer >= buffers.length ||
            start < 0 ||
            start + length > buffers[2 + buffer]!.length) {
          throw ArgumentError('View $i references bytes out of bounds');
        }
      }
    case ListType():
      final width = t.offsetWidth == OffsetWidth.large ? 8 : 4;
      requireBytes(1, end * width);
      requireBytes(2, end * width);
      final limit = array.children[0].length;
      for (var i = offset; i < end; i++) {
        final start = array._offsetAt(i);
        final size = _sizeAt(array, i);
        if (start < 0 || size < 0 || start + size > limit) {
          throw ArgumentError('List view $i is out of bounds');
        }
      }
    case MapType():
      requireBytes(1, (end + 1) * 4);
      final limit = array.children[0].length;
      var previous = array._offsetAt(offset);
      if (previous < 0) throw ArgumentError('Negative offset');
      for (var i = offset + 1; i <= end; i++) {
        final next = array._offsetAt(i);
        if (next < previous || next > limit) {
          throw ArgumentError('Invalid offsets');
        }
        previous = next;
      }
      if (previous > limit) throw ArgumentError('Offset exceeds storage');
      final entries = array.children[0];
      final start = array._offsetAt(offset);
      if (entries._physicalBuffers[0] != null) {
        for (var j = start; j < previous; j++) {
          if (!entries._isValid(j)) throw ArgumentError('Null map entry');
        }
      }
      final keys = entries.children[0];
      for (var j = start; j < previous; j++) {
        if (!keys._isValid(entries.offset + j)) {
          throw ArgumentError('Null map key');
        }
      }
    case UnionType():
      if (buffers[0] != null) {
        throw ArgumentError('Union arrays have no validity bitmap');
      }
      requireBytes(1, end);
      if (t.mode == UnionMode.dense) requireBytes(2, end * 4);
      for (var i = offset; i < end; i++) {
        final typeId = buffers[1]![i].toSigned(8);
        final child = t.childIndexForTypeId(typeId);
        if (child < 0) {
          throw ArgumentError('Undeclared union type id $typeId at $i');
        }
        final (_, position) = _unionSlot(array, t, i);
        if (position < 0 || position >= array.children[child].length) {
          throw ArgumentError('Union child position out of bounds at $i');
        }
      }
    case RunEndEncodedType():
      if (buffers[0] != null) {
        throw ArgumentError('Run-end encoded arrays have no validity bitmap');
      }
      final runEnds = array.children[0];
      final values = array.children[1];
      if (runEnds.nullCount != 0) throw ArgumentError('Null run end');
      if (values.length < runEnds.length) {
        throw ArgumentError('Run-end values are shorter than run ends');
      }
      final width = _runEndWidth(t);
      var previous = 0;
      for (var k = 0; k < runEnds.length; k++) {
        final next = _runEndAt(runEnds, k, width);
        if (next <= previous) {
          throw ArgumentError('Run ends must be strictly increasing');
        }
        previous = next;
      }
      if (end > 0 && previous < end) {
        throw ArgumentError('Run ends do not cover the array length');
      }
    default:
      throw StateError('Not an extended layout: $t');
  }
}

Uint8List? _validityBits(List<_Value?> input) {
  if (!input.contains(null)) return null;
  final validity = Uint8List((input.length + 7) ~/ 8);
  for (var i = 0; i < input.length; i++) {
    if (input[i] != null) validity[i >> 3] |= 1 << (i & 7);
  }
  return validity;
}

Array _owned(
  DataType type,
  int length,
  List<Uint8List?> buffers, [
  List<Array> children = const [],
]) => Array._(
  type,
  length,
  0,
  List.unmodifiable(buffers.map((b) => b?.asUnmodifiableView())),
  List.unmodifiable(children),
  null,
);

Uint8List _offsetsBytes(List<int> offsets, int width) {
  final bytes = Uint8List(offsets.length * width);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < offsets.length; i++) {
    if (width == 4) {
      if (offsets[i] > 0x7fffffff) {
        throw ArgumentError('Offset exceeds 32-bit capacity');
      }
      data.setInt32(i * 4, offsets[i], Endian.little);
    } else {
      _setInt64(data, i * 8, offsets[i]);
    }
  }
  return bytes;
}

/// Encodes validated logical values of an extended storage [type].
Array _encodeExtended(DataType type, List<_Value?> input) {
  final n = input.length;
  switch (type) {
    case FixedSizeBinaryType(:final byteWidth):
      final data = Uint8List(n * byteWidth);
      for (var i = 0; i < n; i++) {
        final v = input[i] as _BinaryValue?;
        if (v != null)
          data.setRange(i * byteWidth, (i + 1) * byteWidth, v.bytes);
      }
      return _owned(type, n, [_validityBits(input), data]);
    case IntervalType():
      final width = _intervalWidth(type);
      final bytes = Uint8List(n * width);
      final data = ByteData.sublistView(bytes);
      for (var i = 0; i < n; i++) {
        final v = (input[i] as _IntervalValue?)?.value;
        if (v == null) continue;
        switch (type.unit) {
          case IntervalUnit.yearMonth:
            data.setInt32(i * 4, v.months, Endian.little);
          case IntervalUnit.dayTime:
            data.setInt32(i * 8, v.days, Endian.little);
            data.setInt32(i * 8 + 4, v.milliseconds, Endian.little);
          case IntervalUnit.monthDayNano:
            data.setInt32(i * 16, v.months, Endian.little);
            data.setInt32(i * 16 + 4, v.days, Endian.little);
            _writeInteger(data, i * 16 + 8, 8, v.nanoseconds);
        }
      }
      return _owned(type, n, [_validityBits(input), bytes]);
    case Utf8Type() || BinaryType():
      final views = Uint8List(n * 16);
      final viewData = ByteData.sublistView(views);
      final payload = BytesBuilder(copy: false);
      for (var i = 0; i < n; i++) {
        final v = input[i];
        if (v == null) continue;
        final bytes = v is _StringValue
            ? utf8.encode(v.value)
            : (v as _BinaryValue).bytes;
        viewData.setInt32(i * 16, bytes.length, Endian.little);
        if (bytes.length <= 12) {
          views.setRange(i * 16 + 4, i * 16 + 4 + bytes.length, bytes);
        } else {
          views.setRange(i * 16 + 4, i * 16 + 8, bytes);
          viewData.setInt32(i * 16 + 8, 0, Endian.little);
          viewData.setInt32(i * 16 + 12, payload.length, Endian.little);
          payload.add(bytes);
        }
      }
      return _owned(type, n, [
        _validityBits(input),
        views,
        payload.takeBytes(),
      ]);
    case ListType():
      final width = type.offsetWidth == OffsetWidth.large ? 8 : 4;
      final childValues = <_Value?>[];
      final starts = <int>[];
      final sizes = <int>[];
      for (final v in input) {
        final list = v as _ListValue?;
        starts.add(childValues.length);
        sizes.add(list?.values.length ?? 0);
        if (list != null) childValues.addAll(list.values);
      }
      return _owned(
        type,
        n,
        [
          _validityBits(input),
          _offsetsBytes(starts, width),
          _offsetsBytes(sizes, width),
        ],
        [Array._fromRaw(type.field.type, childValues)],
      );
    case MapType():
      final entries = <_Value?>[];
      final offsets = <int>[0];
      for (final v in input) {
        final map = v as _MapValue?;
        if (map != null) {
          for (final entry in map.entries) {
            entries.add(
              _StructValue([
                _StructEntry(type.keyField.name, entry.key),
                _StructEntry(type.valueField.name, entry.value),
              ]),
            );
          }
        }
        offsets.add(entries.length);
      }
      return _owned(
        type,
        n,
        [_validityBits(input), _offsetsBytes(offsets, 4)],
        [Array._fromRaw(type.entriesField.type, entries)],
      );
    case UnionType():
      final typeIds = Uint8List(n);
      final childValues = [for (final _ in type.fields) <_Value?>[]];
      final offsets = type.mode == UnionMode.dense ? <int>[] : null;
      for (var i = 0; i < n; i++) {
        final v = input[i] as _UnionValue?;
        final typeId = v?.typeId ?? type.typeIds.first;
        final child = type.childIndexForTypeId(typeId);
        typeIds[i] = typeId;
        if (offsets == null) {
          for (var c = 0; c < childValues.length; c++) {
            childValues[c].add(c == child ? v?.value : null);
          }
        } else {
          offsets.add(childValues[child].length);
          childValues[child].add(v?.value);
        }
      }
      return _owned(
        type,
        n,
        [null, typeIds, if (offsets != null) _offsetsBytes(offsets, 4)],
        [
          for (var c = 0; c < type.fields.length; c++)
            Array._fromRaw(type.fields[c].type, childValues[c]),
        ],
      );
    case RunEndEncodedType():
      final ends = <_Value?>[];
      final values = <_Value?>[];
      for (var i = 0; i < n; i++) {
        if (values.isNotEmpty && values.last == input[i]) {
          ends[ends.length - 1] = _IntegerValue(i + 1);
        } else {
          ends.add(_IntegerValue(i + 1));
          values.add(input[i]);
        }
      }
      return _owned(
        type,
        n,
        [null],
        [
          Array._fromRaw(type.runEndsField.type, ends),
          Array._fromRaw(type.valuesField.type, values),
        ],
      );
    default:
      throw StateError('Not an extended layout: $type');
  }
}

/// Validates a logical value of an extended datatype.
void _validateExtendedValue(
  DataType type,
  _Value value,
  String path,
  Never Function() mismatch,
) {
  switch (type) {
    case FixedSizeBinaryType(:final byteWidth):
      if (value is! _BinaryValue) mismatch();
      if (value.bytes.length != byteWidth) {
        throw ArgumentError(
          '$path has ${value.bytes.length} bytes; expected $byteWidth',
        );
      }
    case MapType map:
      if (value is! _MapValue) mismatch();
      for (var i = 0; i < value.entries.length; i++) {
        final entry = value.entries[i];
        _validateRawValue(map.keyField.type, entry.key, path: '$path[$i].key');
        if (entry.value != null) {
          _validateRawValue(
            map.valueField.type,
            entry.value!,
            path: '$path[$i].value',
          );
        }
      }
    case UnionType union:
      if (value is! _UnionValue) mismatch();
      final child = union.childIndexForTypeId(value.typeId);
      if (child < 0) {
        throw ArgumentError(
          '$path has undeclared union type id ${value.typeId}',
        );
      }
      if (value.value != null) {
        _validateRawValue(
          union.fields[child].type,
          value.value!,
          path: '$path.${union.fields[child].name}',
        );
      }
    case IntervalType interval:
      if (value is! _IntervalValue || value.value.unit != interval.unit) {
        mismatch();
      }
    case RunEndEncodedType ree:
      _validateRawValue(ree.valuesField.type, value, path: path);
    default:
      mismatch();
  }
}

/// Concatenates extended layouts by re-encoding child storage where needed.
Array _concatExtended(List<Array> arrays, DataType type, int length) {
  if (type is FixedSizeBinaryType || type is IntervalType) {
    return _concatLeaf(arrays, type, length);
  }
  if (type is UnionType) {
    final typeIds = Uint8List(length);
    var row = 0;
    for (final a in arrays) {
      typeIds.setRange(row, row + a.length, a._physicalBuffers[1]!, a.offset);
      row += a.length;
    }
    if (type.mode == UnionMode.sparse) {
      return _owned(
        type,
        length,
        [null, typeIds],
        [
          for (var c = 0; c < type.fields.length; c++)
            concatArrays([
              for (final a in arrays) a.children[c].slice(a.offset, a.length),
            ]),
        ],
      );
    }
    final offsets = <int>[];
    final bases = List.filled(type.fields.length, 0);
    for (final a in arrays) {
      for (var i = 0; i < a.length; i++) {
        final (child, position) = _unionSlot(a, type, a.offset + i);
        offsets.add(bases[child] + position);
      }
      for (var c = 0; c < bases.length; c++) {
        bases[c] += a.children[c].length;
      }
    }
    return _owned(
      type,
      length,
      [null, typeIds, _offsetsBytes(offsets, 4)],
      [
        for (var c = 0; c < type.fields.length; c++)
          concatArrays([for (final a in arrays) a.children[c]]),
      ],
    );
  }
  if (type is RunEndEncodedType) {
    final ends = <_Value?>[];
    final values = <Array>[];
    var base = 0;
    for (final a in arrays) {
      if (a.length == 0) continue;
      final first = _runIndex(a, type, a.offset);
      final last = _runIndex(a, type, a.offset + a.length - 1);
      final width = _runEndWidth(type);
      for (var k = first; k <= last; k++) {
        final end = k == last
            ? a.offset + a.length
            : _runEndAt(a.children[0], k, width);
        ends.add(_IntegerValue(base + end - a.offset));
      }
      values.add(a.children[1].slice(first, last - first + 1));
      base += a.length;
    }
    return _owned(
      type,
      length,
      [null],
      [
        Array._fromRaw(type.runEndsField.type, ends),
        values.isEmpty
            ? arrays.first.children[1].slice(0, 0)
            : concatArrays(values),
      ],
    );
  }
  // Views, list views and maps: gather each row's child range.
  final validity = Uint8List((length + 7) ~/ 8);
  var nulls = 0;
  var row = 0;
  for (final a in arrays) {
    for (var i = 0; i < a.length; i++, row++) {
      if (a._isValid(i)) {
        validity[row >> 3] |= 1 << (row & 7);
      } else {
        nulls++;
      }
    }
  }
  if (_isView(type)) {
    return Array._fromRaw(type, [for (final a in arrays) ...a._rawValues]);
  }
  final valid = nulls == 0 ? null : validity;
  if (type is MapType) {
    final offsets = <int>[0];
    final segments = <Array>[];
    for (final a in arrays) {
      final start = a._offsetAt(a.offset);
      final end = a._offsetAt(a.offset + a.length);
      segments.add(a.children.single.slice(start, end - start));
      for (var i = 1; i <= a.length; i++) {
        offsets.add(
          offsets.last +
              a._offsetAt(a.offset + i) -
              a._offsetAt(a.offset + i - 1),
        );
      }
    }
    return _owned(
      type,
      length,
      [valid, _offsetsBytes(offsets, 4)],
      [concatArrays(segments)],
    );
  }
  final segments = <Array>[];
  final starts = <int>[];
  final sizes = <int>[];
  var childLength = 0;
  for (final a in arrays) {
    for (var i = 0; i < a.length; i++) {
      final (start, size) = _listRange(a, a.offset + i);
      starts.add(childLength);
      sizes.add(size);
      segments.add(a.children.single.slice(start, size));
      childLength += size;
    }
  }
  final child = segments.isEmpty
      ? arrays.first.children.single.slice(0, 0)
      : concatArrays(segments);
  final width = (type as ListType).offsetWidth == OffsetWidth.large ? 8 : 4;
  return _owned(
    type,
    length,
    [valid, _offsetsBytes(starts, width), _offsetsBytes(sizes, width)],
    [child],
  );
}

Uint8List _packedBytes(Array array, IntegerType expected, String name) {
  if (array.type != expected || array.nullCount != 0) {
    throw ArgumentError('$name must be a non-null $expected array');
  }
  final width = expected.bitWidth ~/ 8;
  return Uint8List.sublistView(
    array._physicalBuffers[1]!,
    array.offset * width,
    (array.offset + array.length) * width,
  );
}

Array _unionFromArrays(
  UnionMode mode,
  Array typeIds,
  Array? valueOffsets,
  List<Array> children,
  List<String>? fieldNames,
  List<int>? typeCodes,
) {
  if (fieldNames != null && fieldNames.length != children.length) {
    throw ArgumentError('fieldNames length must match children');
  }
  final type = UnionType(
    [
      for (var i = 0; i < children.length; i++)
        Field(fieldNames?[i] ?? '$i', children[i].type),
    ],
    mode: mode,
    typeIds: typeCodes,
  );
  final ids = _packedBytes(typeIds, IntegerType(8), 'typeIds');
  return Array.fromBuffers(type, typeIds.length, [
    null,
    Buffer(ids),
    if (valueOffsets != null)
      Buffer(_packedBytes(valueOffsets, IntegerType(32), 'valueOffsets')),
  ], children: children);
}
