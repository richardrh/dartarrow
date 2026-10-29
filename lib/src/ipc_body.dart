part of 'core.dart';

// RecordBatch/DictionaryBatch bodies (https://arrow.apache.org/docs/format/
// Columnar.html). Each array contributes one FieldNode plus the buffers its
// layout prescribes, in depth-first pre-order. Reading builds zero-copy
// [Array.fromBuffers] views over uncompressed bodies; writing emits the
// arrays' physical buffers, rebasing sliced arrays so every written array
// starts at offset zero.

final class _IpcNode {
  const _IpcNode(this.length, this.nullCount);
  final int length;
  final int nullCount;
}

final class _IpcBufferRef {
  const _IpcBufferRef(this.offset, this.length);
  final int offset;
  final int length;
}

/// Fixed byte width of [type]'s values buffer, or null when [type] has a
/// different layout. [type] must not carry extension wrappers.
int? _ipcFixedWidth(DataType type) => switch (type) {
  IntegerType(:final bitWidth) ||
  FloatingType(:final bitWidth) ||
  DecimalType(:final bitWidth) => bitWidth ~/ 8,
  FixedSizeBinaryType(:final byteWidth) => byteWidth,
  DateType(:final unit) => unit == DateUnit.day ? 4 : 8,
  TimeType(:final unit) => _ipcTimeIndex(unit) < 2 ? 4 : 8,
  TimestampType() || DurationType() => 8,
  IntervalType(:final unit) => switch (unit) {
    IntervalUnit.yearMonth => 4,
    IntervalUnit.dayTime => 8,
    IntervalUnit.monthDayNano => 16,
  },
  DictionaryType(:final indexType) => (indexType as IntegerType).bitWidth ~/ 8,
  _ => null,
};

/// [type] without extension wrappers (dictionary encodings are kept).
DataType _ipcUnwrapExtensions(DataType type) {
  var depth = 0;
  while (type is ExtensionType) {
    if (++depth > 64) throw UnsupportedError('IPC wrapper nesting exceeds 64');
    type = type.storageType;
  }
  return type;
}

/// Offset entry size of a variable-length binary/string/list layout.
int _ipcOffsetWidth(DataType type) => switch (type) {
  Utf8Type(offsetWidth: OffsetWidth.large) ||
  BinaryType(offsetWidth: OffsetWidth.large) ||
  ListType(offsetWidth: OffsetWidth.large) => 8,
  _ => 4,
};

bool _ipcIsView(DataType type) => switch (type) {
  Utf8Type(offsetWidth: OffsetWidth.view) ||
  BinaryType(offsetWidth: OffsetWidth.view) => true,
  ListType(:final view) => view,
  _ => false,
};

int _ipcReadOffset(ByteData data, int index, int width) => width == 4
    ? data.getInt32(index * 4, Endian.little)
    : _ipcGetInt64(data, index * 8);

// ----------------------------------------------------------------- reader --

/// Running total of decoded field node lengths, shared across one read.
final class _IpcValueBudget {
  _IpcValueBudget(this.limit, [this.used = 0]);
  final int limit;
  int used;

  void charge(int count) {
    used += count;
    if (used > limit) {
      throw FormatException(
        'Decoded value count exceeds IpcLimits.maxValues ($limit)',
      );
    }
  }
}

final class _IpcBodyReader {
  _IpcBodyReader(
    this.body,
    this.nodes,
    this.buffers,
    this.variadicCounts,
    this.codec,
    this.limits,
    this.budget,
    this.dictionary,
  );

  final Uint8List body;
  final List<_IpcNode> nodes;
  final List<_IpcBufferRef> buffers;
  final List<int> variadicCounts;

  /// BodyCompression codec (0 = LZ4_FRAME, 1 = ZSTD) or null if uncompressed.
  final int? codec;
  final IpcLimits limits;
  final _IpcValueBudget budget;

  /// Resolves an IPC dictionary id to the current dictionary snapshot.
  final Array Function(int id) dictionary;

  int _node = 0;
  int _buffer = 0;
  int _variadic = 0;
  int _decompressed = 0;
  int depth = 0;

  _IpcNode node() {
    if (_node >= nodes.length) {
      throw const FormatException('RecordBatch has too few field nodes');
    }
    final n = nodes[_node++];
    if (n.length < 0 || n.length > limits.maxRows) {
      throw FormatException('Field node length ${n.length} exceeds limits');
    }
    if (n.nullCount < 0 || n.nullCount > n.length) {
      throw FormatException('Invalid null count ${n.nullCount}');
    }
    budget.charge(n.length);
    return n;
  }

  Uint8List buffer() {
    if (_buffer >= buffers.length) {
      throw const FormatException('RecordBatch has too few buffers');
    }
    final ref = buffers[_buffer++];
    if (ref.offset < 0 ||
        ref.length < 0 ||
        ref.offset > body.length - ref.length) {
      throw FormatException(
        'Buffer [${ref.offset}, +${ref.length}) exceeds body of '
        '${body.length} bytes',
      );
    }
    final raw = Uint8List.sublistView(
      body,
      ref.offset,
      ref.offset + ref.length,
    );
    final codec = this.codec;
    if (codec == null || raw.isEmpty) return raw;
    final decoded = _ipcDecompress(
      raw,
      codec,
      limits.maxMessageBytes - _decompressed,
    );
    _decompressed += decoded.length;
    if (_decompressed > limits.maxMessageBytes) {
      throw const FormatException('Decompressed body exceeds maxMessageBytes');
    }
    return decoded;
  }

  /// The validity bitmap of [n], or null when every slot is valid.
  Buffer? validity(_IpcNode n) {
    final bitmap = buffer();
    if (bitmap.isEmpty) {
      if (n.nullCount != 0) {
        throw const FormatException(
          'Missing validity bitmap for node with nulls',
        );
      }
      return null;
    }
    return Buffer(bitmap);
  }

  /// An offsets buffer of [n]; empty arrays may omit it entirely.
  Buffer offsets(_IpcNode n, int width) {
    final bytes = buffer();
    if (n.length == 0 && bytes.isEmpty) return Buffer(Uint8List(width));
    return Buffer(bytes);
  }

  int variadicCount() {
    if (_variadic >= variadicCounts.length) {
      throw const FormatException('Missing variadic buffer count');
    }
    return variadicCounts[_variadic++];
  }

  void finish() {
    if (_node != nodes.length ||
        _buffer != buffers.length ||
        _variadic != variadicCounts.length) {
      throw const FormatException(
        'RecordBatch has unconsumed nodes, buffers or variadic counts',
      );
    }
  }
}

/// Reads one array of [type] whose IPC field descriptor is [field]. For a
/// dictionary batch [type] is the dictionary value type while [field] is the
/// dictionary-encoded field, whose children describe the value type.
Array _ipcReadArray(_IpcBodyReader r, DataType type, _IpcField field) {
  if (++r.depth > r.limits.maxDepth) {
    throw const FormatException('Arrow nesting exceeds maximum depth');
  }
  try {
    return _ipcReadArrayAt(r, type, field);
  } finally {
    r.depth--;
  }
}

Array _ipcReadArrayAt(_IpcBodyReader r, DataType type, _IpcField field) {
  final storage = _ipcUnwrapExtensions(type);
  if (storage is IntegerType) _ipcRejectBindingInteger(storage);
  List<Array> readChildren(List<Field> fields) {
    if (fields.length != field.children.length) {
      throw const FormatException('IPC field children do not match type');
    }
    return [
      for (var i = 0; i < fields.length; i++)
        _ipcReadArray(r, fields[i].type, field.children[i]),
    ];
  }

  final n = r.node();
  switch (storage) {
    case NullType():
      return Array.fromBuffers(type, n.length, const []);
    case DictionaryType():
      final id = field.dictionaryId;
      if (id == null) {
        throw const FormatException('Dictionary field lacks a dictionary id');
      }
      final validity = r.validity(n);
      final indices = Buffer(r.buffer());
      return Array.fromBuffers(
        type,
        n.length,
        [validity, indices],
        dictionary: r.dictionary(id),
        nullCount: n.nullCount,
      );
    case UnionType(:final mode, :final fields):
      if (n.nullCount != 0) {
        throw const FormatException('Union cannot have a top-level null count');
      }
      final typeIds = Buffer(r.buffer());
      final offsets = mode == UnionMode.dense ? Buffer(r.buffer()) : null;
      return Array.fromBuffers(type, n.length, [
        null,
        typeIds,
        ?offsets,
      ], children: readChildren(fields));
    case RunEndEncodedType(:final runEndsField, :final valuesField):
      if (n.nullCount != 0) {
        throw const FormatException(
          'Run-end encoded parent null count must be zero',
        );
      }
      return Array.fromBuffers(type, n.length, const [
        null,
      ], children: readChildren([runEndsField, valuesField]));
    default:
  }
  final validity = r.validity(n);
  final List<Buffer?> buffers;
  var children = const <Array>[];
  switch (storage) {
    case BooleanType():
      buffers = [validity, Buffer(r.buffer())];
    case Utf8Type() || BinaryType() when _ipcIsView(storage):
      final views = Buffer(r.buffer());
      final count = r.variadicCount();
      if (count < 0 || count > r.limits.maxBuffers) {
        throw const FormatException('Invalid variadic buffer count');
      }
      buffers = [
        validity,
        views,
        for (var i = 0; i < count; i++) Buffer(r.buffer()),
      ];
    case Utf8Type() || BinaryType():
      final offsets = r.offsets(n, _ipcOffsetWidth(storage));
      buffers = [validity, offsets, Buffer(r.buffer())];
    case ListType(:final field, :final view):
      final offsets = r.offsets(n, _ipcOffsetWidth(storage));
      buffers = [validity, offsets, if (view) Buffer(r.buffer())];
      children = readChildren([field]);
    case MapType():
      buffers = [validity, r.offsets(n, 4)];
      children = readChildren([storage.entriesField]);
    case FixedSizeListType(:final field):
      buffers = [validity];
      children = readChildren([field]);
    case StructType(:final fields):
      buffers = [validity];
      children = readChildren(fields);
    default:
      if (_ipcFixedWidth(storage) == null) {
        throw UnsupportedError('No standard Arrow IPC layout for $type');
      }
      buffers = [validity, Buffer(r.buffer())];
  }
  return Array.fromBuffers(
    type,
    n.length,
    buffers,
    children: children,
    nullCount: n.nullCount,
  );
}

// ----------------------------------------------------------------- writer --

final class _IpcBodyWriter {
  final List<_IpcNode> nodes = [];
  final List<_IpcBufferRef> buffers = [];
  final List<int> variadicCounts = [];
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int _length = 0;

  Uint8List takeBytes() => _bytes.takeBytes();

  void node(int length, int nullCount) =>
      nodes.add(_IpcNode(length, nullCount));

  /// Appends [bytes] as the next buffer, padding the body to 8 bytes.
  void buffer(Uint8List bytes) {
    buffers.add(_IpcBufferRef(_length, bytes.length));
    _bytes.add(bytes);
    final padding = (-bytes.length) % 8;
    if (padding > 0) _bytes.add(Uint8List(padding));
    _length += bytes.length + padding;
  }
}

/// [length] bits of [bits] starting at bit [offset], re-based to bit zero.
/// A null bitmap means all bits are set.
Uint8List _ipcBitmap(Uint8List? bits, int offset, int length) {
  final count = (length + 7) >> 3;
  if (bits == null) {
    final out = Uint8List(count)..fillRange(0, count, 0xff);
    if (length % 8 != 0) out[count - 1] = (1 << (length % 8)) - 1;
    return out;
  }
  if (offset % 8 == 0) {
    return Uint8List.sublistView(bits, offset >> 3, (offset >> 3) + count);
  }
  final out = Uint8List(count);
  for (var i = 0; i < length; i++) {
    final j = offset + i;
    if (bits[j >> 3] & (1 << (j & 7)) != 0) out[i >> 3] |= 1 << (i & 7);
  }
  return out;
}

Uint8List _ipcSlice(Uint8List? bytes, int start, int end) =>
    bytes == null ? Uint8List(0) : Uint8List.sublistView(bytes, start, end);

/// Offsets `[offset, offset + length]` of [bytes] re-based to start at zero,
/// plus the original first and last offsets.
(Uint8List, int, int) _ipcRebasedOffsets(
  Uint8List bytes,
  int width,
  int offset,
  int length,
) {
  final data = ByteData.sublistView(bytes);
  final first = _ipcReadOffset(data, offset, width);
  final last = _ipcReadOffset(data, offset + length, width);
  if (first == 0) {
    return (
      Uint8List.sublistView(
        bytes,
        offset * width,
        (offset + length + 1) * width,
      ),
      first,
      last,
    );
  }
  final out = Uint8List((length + 1) * width);
  final target = ByteData.sublistView(out);
  for (var i = 0; i <= length; i++) {
    final value = _ipcReadOffset(data, offset + i, width) - first;
    if (width == 4) {
      target.setInt32(i * 4, value, Endian.little);
    } else {
      _ipcSetInt64(target, i * 8, value);
    }
  }
  return (out, first, last);
}

void _ipcWriteArray(_IpcBodyWriter w, Array array) {
  final type = _ipcUnwrapExtensions(array.type);
  final offset = array.offset;
  final length = array.length;
  final buffers = array._physicalBuffers;
  if (type is IntegerType) _ipcRejectBindingInteger(type);
  switch (type) {
    case NullType():
      w.node(length, length);
      return;
    case UnionType(:final mode):
      w.node(length, 0);
      w.buffer(_ipcSlice(buffers[1], offset, offset + length));
      if (mode == UnionMode.dense) {
        w.buffer(_ipcSlice(buffers[2], offset * 4, (offset + length) * 4));
        for (final child in array.children) {
          _ipcWriteArray(w, child);
        }
      } else {
        for (final child in array.children) {
          _ipcWriteArray(w, child.slice(offset, length));
        }
      }
      return;
    case RunEndEncodedType():
      w.node(length, 0);
      _ipcWriteRunEnds(w, array);
      return;
    default:
  }
  final nulls = array.nullCount;
  w.node(length, nulls);
  w.buffer(nulls == 0 ? Uint8List(0) : _ipcBitmap(buffers[0], offset, length));
  switch (type) {
    case BooleanType():
      w.buffer(_ipcBitmap(buffers[1], offset, length));
    case Utf8Type() || BinaryType() when _ipcIsView(type):
      w.buffer(_ipcSlice(buffers[1], offset * 16, (offset + length) * 16));
      w.variadicCounts.add(buffers.length - 2);
      for (var i = 2; i < buffers.length; i++) {
        w.buffer(buffers[i] ?? Uint8List(0));
      }
    case Utf8Type() || BinaryType():
      final width = _ipcOffsetWidth(type);
      final (offsets, first, last) = _ipcRebasedOffsets(
        buffers[1]!,
        width,
        offset,
        length,
      );
      w.buffer(offsets);
      w.buffer(_ipcSlice(buffers[2], first, last));
    case ListType(:final view) when view:
      final width = _ipcOffsetWidth(type);
      w.buffer(
        _ipcSlice(buffers[1], offset * width, (offset + length) * width),
      );
      w.buffer(
        _ipcSlice(buffers[2], offset * width, (offset + length) * width),
      );
      _ipcWriteArray(w, array.children[0]);
    case ListType() || MapType():
      final (offsets, first, last) = _ipcRebasedOffsets(
        buffers[1]!,
        _ipcOffsetWidth(type),
        offset,
        length,
      );
      w.buffer(offsets);
      _ipcWriteArray(w, array.children[0].slice(first, last - first));
    case FixedSizeListType(:final size):
      _ipcWriteArray(w, array.children[0].slice(offset * size, length * size));
    case StructType():
      for (final child in array.children) {
        _ipcWriteArray(w, child.slice(offset, length));
      }
    default:
      final width = _ipcFixedWidth(type);
      if (width == null) {
        throw UnsupportedError('No standard Arrow IPC layout for $type');
      }
      w.buffer(
        _ipcSlice(buffers[1], offset * width, (offset + length) * width),
      );
  }
}

/// Writes the run ends and values children of a run-end encoded [array],
/// keeping only the runs that overlap its logical window.
void _ipcWriteRunEnds(_IpcBodyWriter w, Array array) {
  final ends = array.children[0];
  final values = array.children[1];
  final width = (ends.type as IntegerType).bitWidth ~/ 8;
  final data = ByteData.sublistView(ends._physicalBuffers[1]!);
  int end(int i) => switch (width) {
    2 => data.getInt16((ends.offset + i) * 2, Endian.little),
    4 => data.getInt32((ends.offset + i) * 4, Endian.little),
    _ => _ipcGetInt64(data, (ends.offset + i) * 8),
  };
  final start = array.offset;
  final stop = start + array.length;
  var first = 0;
  var last = -1;
  if (array.length > 0) {
    while (first < ends.length && end(first) <= start) {
      first++;
    }
    last = first;
    while (last < ends.length && end(last) < stop) {
      last++;
    }
    if (last >= ends.length) {
      throw StateError('Run ends do not cover the array length');
    }
  }
  final runs = last - first + 1;
  final out = Uint8List(runs * width);
  final target = ByteData.sublistView(out);
  for (var i = 0; i < runs; i++) {
    final value = math.min(end(first + i) - start, array.length);
    switch (width) {
      case 2:
        target.setInt16(i * 2, value, Endian.little);
      case 4:
        target.setInt32(i * 4, value, Endian.little);
      default:
        _ipcSetInt64(target, i * 8, value);
    }
  }
  w.node(runs, 0);
  w.buffer(Uint8List(0));
  w.buffer(out);
  _ipcWriteArray(w, values.slice(first, runs));
}
