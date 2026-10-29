part of 'core.dart';

// A deliberately small FlatBuffers implementation covering exactly what the
// Arrow IPC metadata (Schema.fbs, Message.fbs, File.fbs) needs: tables with
// scalar/offset fields, strings, vectors of tables/strings and vectors of
// fixed-size structs. Unions are encoded as their (type, value) slot pair.
//
// The writer lays objects out front-to-back. FlatBuffers uoffsets must point
// forward, so every referenced object is written after its referrer.

// ---------------------------------------------------------------- builder --

enum _FbScalarKind {
  boolean(1),
  u8(1),
  i16(2),
  i32(4),
  i64(8);

  const _FbScalarKind(this.size);
  final int size;
}

sealed class _FbSlot {
  const _FbSlot();
  int get size;
}

final class _FbScalar extends _FbSlot {
  const _FbScalar(this.kind, this.value);
  final _FbScalarKind kind;
  final int value;
  @override
  int get size => kind.size;
}

final class _FbRef extends _FbSlot {
  const _FbRef(this.target);
  final _FbObject target;
  @override
  int get size => 4;
}

sealed class _FbObject {
  const _FbObject();
}

final class _FbTableObject extends _FbObject {
  const _FbTableObject(this.slots);
  final Map<int, _FbSlot> slots;
}

final class _FbString extends _FbObject {
  const _FbString(this.bytes);
  final List<int> bytes;
}

final class _FbOffsetVector extends _FbObject {
  const _FbOffsetVector(this.items);
  final List<_FbObject> items;
}

final class _FbStructVector extends _FbObject {
  const _FbStructVector(this.bytes, this.count);
  final Uint8List bytes;
  final int count;
}

_FbSlot _fbBool(bool value) => _FbScalar(_FbScalarKind.boolean, value ? 1 : 0);
_FbSlot _fbU8(int value) => _FbScalar(_FbScalarKind.u8, value);
_FbSlot _fbI16(int value) => _FbScalar(_FbScalarKind.i16, value);
_FbSlot _fbI32(int value) => _FbScalar(_FbScalarKind.i32, value);
_FbSlot _fbI64(int value) => _FbScalar(_FbScalarKind.i64, value);
_FbSlot _fbString(String value) => _FbRef(_FbString(utf8.encode(value)));
_FbSlot _fbBytes(List<int> value) => _FbRef(_FbString(value));
_FbSlot _fbTable(Map<int, _FbSlot> slots) => _FbRef(_FbTableObject(slots));
_FbSlot _fbVector(List<_FbObject> items) => _FbRef(_FbOffsetVector(items));
_FbSlot _fbStructs(Uint8List bytes, int count) =>
    _FbRef(_FbStructVector(bytes, count));

int _ipcAlignUp(int value, int alignment) =>
    (value + alignment - 1) ~/ alignment * alignment;

final class _FbWriter {
  Uint8List _buffer = Uint8List(512);
  late ByteData _data = ByteData.sublistView(_buffer);
  int _length = 0;

  static Uint8List encode(_FbTableObject root) {
    final writer = _FbWriter();
    writer._reserve(4);
    final rootPosition = writer._write(root);
    writer._data.setUint32(0, rootPosition, Endian.little);
    writer._align(8);
    return Uint8List.fromList(
      Uint8List.sublistView(writer._buffer, 0, writer._length),
    );
  }

  int _reserve(int count) {
    _grow(_length + count);
    final position = _length;
    _length += count;
    return position;
  }

  void _grow(int needed) {
    if (needed <= _buffer.length) return;
    var capacity = _buffer.length * 2;
    while (capacity < needed) {
      capacity *= 2;
    }
    _buffer = Uint8List(capacity)..setRange(0, _length, _buffer);
    _data = ByteData.sublistView(_buffer);
  }

  void _align(int alignment) => _reserve((-_length) % alignment);

  int _write(_FbObject object) => switch (object) {
    _FbTableObject() => _writeTable(object),
    _FbString() => _writeString(object),
    _FbOffsetVector() => _writeOffsets(object),
    _FbStructVector() => _writeStructs(object),
  };

  int _writeTable(_FbTableObject table) {
    final (offsets, tableSize) = _layout(table.slots);
    final slotCount = table.slots.isEmpty
        ? 0
        : table.slots.keys.reduce((a, b) => a > b ? a : b) + 1;
    _align(2);
    final vtable = _reserve(4 + 2 * slotCount);
    _align(8);
    final position = _reserve(tableSize);
    _data
      ..setUint16(vtable, 4 + 2 * slotCount, Endian.little)
      ..setUint16(vtable + 2, tableSize, Endian.little)
      ..setInt32(position, position - vtable, Endian.little);
    for (final MapEntry(:key, :value) in offsets.entries) {
      _data.setUint16(vtable + 4 + 2 * key, value, Endian.little);
      _writeSlot(position + value, table.slots[key]!);
    }
    return position;
  }

  static (Map<int, int>, int) _layout(Map<int, _FbSlot> slots) {
    final ids = slots.keys.toList()
      ..sort((a, b) => slots[b]!.size.compareTo(slots[a]!.size));
    final offsets = <int, int>{};
    var offset = 4;
    for (final id in ids) {
      final size = slots[id]!.size;
      offset = _ipcAlignUp(offset, size);
      offsets[id] = offset;
      offset += size;
    }
    return (offsets, _ipcAlignUp(offset, 4));
  }

  void _writeSlot(int position, _FbSlot slot) {
    switch (slot) {
      case _FbRef(:final target):
        final child = _write(target);
        _data.setUint32(position, child - position, Endian.little);
      case _FbScalar(:final kind, :final value):
        _writeScalar(position, kind, value);
    }
  }

  void _writeScalar(int position, _FbScalarKind kind, int value) {
    switch (kind) {
      case _FbScalarKind.boolean || _FbScalarKind.u8:
        _data.setUint8(position, value);
      case _FbScalarKind.i16:
        _data.setInt16(position, value, Endian.little);
      case _FbScalarKind.i32:
        _data.setInt32(position, value, Endian.little);
      case _FbScalarKind.i64:
        _ipcSetInt64(_data, position, value);
    }
  }

  int _writeString(_FbString string) {
    _align(4);
    final count = string.bytes.length;
    final position = _reserve(4 + count + 1);
    _data.setUint32(position, count, Endian.little);
    _buffer.setRange(position + 4, position + 4 + count, string.bytes);
    return position;
  }

  int _writeOffsets(_FbOffsetVector vector) {
    _align(4);
    final count = vector.items.length;
    final position = _reserve(4 + 4 * count);
    _data.setUint32(position, count, Endian.little);
    for (var i = 0; i < count; i++) {
      final child = _write(vector.items[i]);
      final slot = position + 4 + 4 * i;
      _data.setUint32(slot, child - slot, Endian.little);
    }
    return position;
  }

  int _writeStructs(_FbStructVector vector) {
    // Struct elements (all 8-byte aligned in Arrow) start right after the
    // 4-byte length prefix.
    _reserve((-(_length + 4)) % 8);
    final position = _reserve(4 + vector.bytes.length);
    _data.setUint32(position, vector.count, Endian.little);
    _buffer.setRange(
      position + 4,
      position + 4 + vector.bytes.length,
      vector.bytes,
    );
    return position;
  }
}

// ----------------------------------------------------------------- reader --

/// Bounds-checked view of a FlatBuffer. Every read validates its range so
/// malformed input surfaces as a [FormatException] rather than a crash.
final class _FbReader {
  _FbReader(this.data);
  final ByteData data;
  int get length => data.lengthInBytes;

  void check(int position, int size) {
    if (position < 0 || size < 0 || position > length - size) {
      throw FormatException(
        'FlatBuffer read of $size bytes at $position exceeds $length bytes',
      );
    }
  }

  int u8(int p) => (this..check(p, 1)).data.getUint8(p);
  int u16(int p) => (this..check(p, 2)).data.getUint16(p, Endian.little);
  int i16(int p) => (this..check(p, 2)).data.getInt16(p, Endian.little);
  int i32(int p) => (this..check(p, 4)).data.getInt32(p, Endian.little);
  int u32(int p) => (this..check(p, 4)).data.getUint32(p, Endian.little);
  int i64(int p) => _ipcGetInt64((this..check(p, 8)).data, p);

  _FbTableView root() => _FbTableView(this, u32(0));
}

final class _FbStructs {
  const _FbStructs(this.reader, this.start, this.count, this.elementSize);
  const _FbStructs.empty(this.reader, this.elementSize) : start = 0, count = 0;
  final _FbReader reader;
  final int start;
  final int count;
  final int elementSize;

  int i64(int index, int field) =>
      reader.i64(start + index * elementSize + field);
  int i32(int index, int field) =>
      reader.i32(start + index * elementSize + field);
}

final class _FbTableView {
  _FbTableView(this.reader, this.position) {
    reader.check(position, 4);
    _vtable = position - reader.i32(position);
    _vtableSize = reader.u16(_vtable);
    if (_vtableSize < 4 || _vtableSize.isOdd) {
      throw FormatException('Invalid FlatBuffer vtable size $_vtableSize');
    }
    reader.check(_vtable, _vtableSize);
    _tableSize = reader.u16(_vtable + 2);
    if (_tableSize < 4) {
      throw FormatException('Invalid FlatBuffer table size $_tableSize');
    }
    reader.check(position, _tableSize);
  }

  final _FbReader reader;
  final int position;
  late final int _vtable;
  late final int _vtableSize;
  late final int _tableSize;

  /// Absolute position of field [id] holding [size] bytes, or -1 if absent.
  int _field(int id, int size) {
    final entry = 4 + 2 * id;
    if (entry + 2 > _vtableSize) return -1;
    final offset = reader.u16(_vtable + entry);
    if (offset == 0) return -1;
    if (offset < 4 || offset + size > _tableSize) {
      throw FormatException('FlatBuffer field $id lies outside its table');
    }
    return position + offset;
  }

  int u8(int id, int fallback) {
    final p = _field(id, 1);
    return p < 0 ? fallback : reader.u8(p);
  }

  bool boolean(int id, bool fallback) {
    final p = _field(id, 1);
    return p < 0 ? fallback : reader.u8(p) != 0;
  }

  int i16(int id, int fallback) {
    final p = _field(id, 2);
    return p < 0 ? fallback : reader.i16(p);
  }

  int i32(int id, int fallback) {
    final p = _field(id, 4);
    return p < 0 ? fallback : reader.i32(p);
  }

  int i64(int id, int fallback) {
    final p = _field(id, 8);
    return p < 0 ? fallback : reader.i64(p);
  }

  int _indirect(int p) => p + reader.u32(p);

  _FbTableView? table(int id) {
    final p = _field(id, 4);
    return p < 0 ? null : _FbTableView(reader, _indirect(p));
  }

  /// Raw bytes of string field [id] (FlatBuffers strings are byte vectors).
  Uint8List? bytes(int id) {
    final p = _field(id, 4);
    if (p < 0) return null;
    final start = _indirect(p);
    final count = reader.u32(start);
    reader.check(start + 4, count);
    return Uint8List.sublistView(reader.data, start + 4, start + 4 + count);
  }

  /// UTF-8 string field [id]; invalid UTF-8 is a [FormatException].
  String? string(int id) {
    final value = bytes(id);
    return value == null ? null : utf8.decode(value);
  }

  Iterable<_FbTableView> tables(int id) sync* {
    final p = _field(id, 4);
    if (p < 0) return;
    final start = _indirect(p);
    final count = reader.u32(start);
    reader.check(start + 4, count * 4);
    for (var i = 0; i < count; i++) {
      yield _FbTableView(reader, _indirect(start + 4 + 4 * i));
    }
  }

  _FbStructs structs(int id, int elementSize) {
    final p = _field(id, 4);
    if (p < 0) return _FbStructs.empty(reader, elementSize);
    final start = _indirect(p);
    final count = reader.u32(start);
    reader.check(start + 4, count * elementSize);
    return _FbStructs(reader, start + 4, count, elementSize);
  }
}

// 64-bit helpers built from two 32-bit halves so they also work on the web,
// where ByteData.getInt64/setInt64 are unsupported. Values beyond the
// JavaScript safe-integer range are rejected rather than silently rounded.
const int _ipcMaxSafeInt = 9007199254740991;

void _ipcSetInt64(ByteData data, int position, int value) {
  if (value > _ipcMaxSafeInt || value < -_ipcMaxSafeInt) {
    throw ArgumentError.value(value, 'value', 'exceeds the safe integer range');
  }
  final low = value % 0x100000000;
  final high = (value - low) ~/ 0x100000000;
  data
    ..setUint32(position, low, Endian.little)
    ..setInt32(position + 4, high, Endian.little);
}

int _ipcGetInt64(ByteData data, int position) {
  final low = data.getUint32(position, Endian.little);
  final high = data.getInt32(position + 4, Endian.little);
  if (high > 0x1fffff || high < -0x200000) {
    throw const FormatException('64-bit metadata integer exceeds safe range');
  }
  return high * 0x100000000 + low;
}
