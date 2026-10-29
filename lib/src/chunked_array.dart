part of 'core.dart';

final class ChunkedArray {
  factory ChunkedArray(Iterable<Object?> chunks, {DataType? type}) {
    final result = <Array>[];
    for (final chunk in chunks) {
      final Array value;
      if (chunk is Array) {
        value = chunk;
      } else if (chunk is Iterable) {
        value = array(chunk, type: type);
      } else {
        throw ArgumentError.value(
          chunk,
          'chunks',
          'Expected Array or Iterable',
        );
      }
      type ??= value.type;
      if (value.type != type)
        throw ArrowTypeError('All chunks must have the same type');
      result.add(value);
    }
    if (type == null)
      throw ArrowInvalid('An empty chunk collection requires a type');
    return ChunkedArray._(List.unmodifiable(result), type);
  }
  ChunkedArray._(this.chunks, this.type) {
    var total = 0;
    _chunkEnds = List<int>.generate(chunks.length, (index) {
      total = _checkedLengthAdd(total, chunks[index].length);
      return total;
    }, growable: false);
    _length = total;
  }
  final List<Array> chunks;
  final DataType type;
  int get numChunks => chunks.length;
  late final List<int> _chunkEnds;
  late final int _length;
  int get length => _length;
  late final int _nullCount = chunks.fold(0, (n, c) => n + c.nullCount);
  int get nullCount => _nullCount;

  ChunkedArray isValid() => ChunkedArray([
    for (final chunk in chunks)
      if (chunk.length != 0) chunk.isValid(),
  ], type: const BooleanType());

  ChunkedArray isNull({bool nanIsNull = false}) {
    if (length == 0) return ChunkedArray(const [], type: const BooleanType());
    final data = Uint8List((length + 7) ~/ 8);
    var offset = 0;
    for (final chunk in chunks) {
      chunk._writeNullBits(data, offset, nanIsNull: nanIsNull);
      offset += chunk.length;
    }
    final mask = Array._(
      const BooleanType(),
      length,
      0,
      [null, data.asUnmodifiableView()],
      const [],
      null,
    );
    return ChunkedArray([mask], type: const BooleanType());
  }

  Array chunk(int index) {
    RangeError.checkValidIndex(index, chunks);
    return chunks[index];
  }

  Scalar operator [](int index) {
    final count = length;
    final position = index < 0 ? count + index : index;
    RangeError.checkValueInInterval(position, 0, count - 1, 'index');
    var low = 0;
    var high = _chunkEnds.length;
    while (low < high) {
      final middle = low + ((high - low) >> 1);
      if (_chunkEnds[middle] <= position) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    final start = low == 0 ? 0 : _chunkEnds[low - 1];
    return chunks[low][position - start];
  }

  ChunkedArray slice([int offset = 0, int? length]) {
    if (offset < 0) throw RangeError.value(offset, 'offset');
    if (length != null && length < 0)
      throw ArgumentError.value(length, 'length');
    var skip = offset;
    var remaining = length ?? this.length;
    final result = <Array>[];
    for (final chunk in chunks) {
      if (skip >= chunk.length &&
          (chunk.length != 0 || skip != 0 || result.isEmpty)) {
        skip -= chunk.length;
        continue;
      }
      final take = remaining < chunk.length - skip
          ? remaining
          : chunk.length - skip;
      result.add(chunk.slice(skip, take));
      remaining -= take;
      skip = 0;
      if (remaining == 0) break;
    }
    if (result.isEmpty && chunks.isNotEmpty)
      result.add(chunks.last.slice(chunks.last.length, 0));
    return ChunkedArray._(List.unmodifiable(result), type);
  }

  Iterable<Scalar> get scalars sync* {
    for (final chunk in chunks) {
      yield* chunk.scalars;
    }
  }

  List<Object?> toDartList() => [
    for (final chunk in chunks) ...chunk.toDartList(),
  ];
  Array combineChunks() =>
      chunks.isEmpty ? array(const [], type: type) : concatArrays(chunks);
  ChunkedArray cast(DataType type, {bool safe = true}) =>
      ChunkedArray(chunks.map((c) => c.cast(type, safe: safe)), type: type);
  bool equals(ChunkedArray other) {
    if (type != other.type || length != other.length) return false;
    var a = 0;
    var b = 0;
    var ai = 0;
    var bi = 0;
    while (a < chunks.length && b < other.chunks.length) {
      final left = chunks[a];
      final right = other.chunks[b];
      final size = left.length - ai < right.length - bi
          ? left.length - ai
          : right.length - bi;
      if (size > 0 && !left.slice(ai, size).equals(right.slice(bi, size)))
        return false;
      ai += size;
      bi += size;
      if (ai == left.length) {
        a++;
        ai = 0;
      }
      if (bi == right.length) {
        b++;
        bi = 0;
      }
    }
    return true;
  }
}

ChunkedArray chunkedArray(Iterable<Object?> chunks, {DataType? type}) =>
    ChunkedArray(chunks, type: type);

/// Signed 64-bit maximum, parsed at runtime because the literal cannot be
/// represented on dart2js (where it rounds to 2^63, still a sound bound).
final int _int64Max = int.parse('9223372036854775807');

int _checkedLengthAdd(int total, int length) {
  if (length > _int64Max - total) {
    throw ArrowInvalid('Logical length exceeds signed 64-bit capacity');
  }
  return total + length;
}
