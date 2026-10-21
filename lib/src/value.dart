part of 'core.dart';

sealed class _Value {
  const _Value();
}

final class _BooleanValue extends _Value {
  const _BooleanValue(this.value);
  final bool value;
  @override
  bool operator ==(Object other) =>
      other is _BooleanValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class _IntegerValue extends _Value {
  _IntegerValue(Object value) : value = _bigInt(value);
  final BigInt value;
  @override
  bool operator ==(Object other) =>
      other is _IntegerValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

/// An IEEE floating-point bit pattern. This preserves NaN payloads and signed zero.
final class _FloatingValue extends _Value {
  _FloatingValue(this.bitWidth, Object bits) : bits = _bigInt(bits) {
    if (bitWidth != 16 && bitWidth != 32 && bitWidth != 64) {
      throw ArgumentError.value(bitWidth, 'bitWidth');
    }
    if (this.bits.isNegative || this.bits >= (BigInt.one << bitWidth)) {
      throw ArgumentError.value(bits, 'bits', 'does not fit in $bitWidth bits');
    }
  }
  factory _FloatingValue.float16(int rawBits) =>
      _FloatingValue(16, rawBits & 0xffff);
  factory _FloatingValue.float32(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return _FloatingValue(32, data.getUint32(0, Endian.little));
  }
  factory _FloatingValue.float64(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    final rawBits = data.getInt64(0, Endian.little);
    return _FloatingValue(
      64,
      rawBits < 0 ? BigInt.from(rawBits) + (BigInt.one << 64) : rawBits,
    );
  }
  final int bitWidth;
  final BigInt bits;
  String get hexadecimalBits =>
      bits.toRadixString(16).padLeft(bitWidth ~/ 4, '0');
  @override
  bool operator ==(Object other) =>
      other is _FloatingValue &&
      bitWidth == other.bitWidth &&
      bits == other.bits;
  @override
  int get hashCode => Object.hash(bitWidth, bits);
}

final class _DecimalValue extends _Value {
  _DecimalValue(Object unscaled) : unscaled = _bigInt(unscaled);
  final BigInt unscaled;
  @override
  bool operator ==(Object other) =>
      other is _DecimalValue && unscaled == other.unscaled;
  @override
  int get hashCode => unscaled.hashCode;
}

final class _StringValue extends _Value {
  const _StringValue(this.value);
  final String value;
  @override
  bool operator ==(Object other) =>
      other is _StringValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class _BinaryValue extends _Value {
  _BinaryValue(List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final Uint8List bytes;
  @override
  bool operator ==(Object other) =>
      other is _BinaryValue && _listEquals(bytes, other.bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
}

/// A raw date/time/timestamp/duration counter in the datatype's declared unit.
final class _TemporalValue extends _Value {
  _TemporalValue(Object value) : value = _bigInt(value);
  final BigInt value;
  @override
  bool operator ==(Object other) =>
      other is _TemporalValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class _ListValue extends _Value {
  _ListValue(List<_Value?> values) : values = List.unmodifiable(values);
  final List<_Value?> values;
  @override
  bool operator ==(Object other) =>
      other is _ListValue && _listEquals(values, other.values);
  @override
  int get hashCode => Object.hashAll(values);
}

final class _StructEntry {
  const _StructEntry(this.name, this.value);
  final String name;
  final _Value? value;
  @override
  bool operator ==(Object other) =>
      other is _StructEntry && name == other.name && value == other.value;
  @override
  int get hashCode => Object.hash(name, value);
}

/// Ordered struct members. Names are retained to detect field-order mistakes.
final class _StructValue extends _Value {
  _StructValue(List<_StructEntry> fields) : fields = List.unmodifiable(fields);
  final List<_StructEntry> fields;
  @override
  bool operator ==(Object other) =>
      other is _StructValue && _listEquals(fields, other.fields);
  @override
  int get hashCode => Object.hashAll(fields);
}

final class _DictionaryIndexValue extends _Value {
  _DictionaryIndexValue(Object index) : index = _bigInt(index);
  final BigInt index;
  @override
  bool operator ==(Object other) =>
      other is _DictionaryIndexValue && index == other.index;
  @override
  int get hashCode => index.hashCode;
}

final class _ExtensionValue extends _Value {
  const _ExtensionValue(this.storage);
  final _Value storage;
  @override
  bool operator ==(Object other) =>
      other is _ExtensionValue && storage == other.storage;
  @override
  int get hashCode => storage.hashCode;
}

BigInt _bigInt(Object value) {
  if (value is BigInt) return value;
  if (value is int) return BigInt.from(value);
  if (value is String) return BigInt.parse(value);
  throw ArgumentError.value(
    value,
    'value',
    'must be an int, BigInt, or integer string',
  );
}

bool _listEquals<T>(List<T> a, List<T> b) =>
    a.length == b.length &&
    List.generate(a.length, (i) => i).every((i) => a[i] == b[i]);
