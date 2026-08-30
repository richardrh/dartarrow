import 'dart:typed_data';

sealed class ArrowValue {
  const ArrowValue();
}

final class ArrowBooleanValue extends ArrowValue {
  const ArrowBooleanValue(this.value);
  final bool value;
  @override
  bool operator ==(Object other) =>
      other is ArrowBooleanValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class ArrowIntegerValue extends ArrowValue {
  ArrowIntegerValue(Object value) : value = _bigInt(value);
  final BigInt value;
  @override
  bool operator ==(Object other) =>
      other is ArrowIntegerValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

/// An IEEE floating-point bit pattern. This preserves NaN payloads and signed zero.
final class ArrowFloatingValue extends ArrowValue {
  ArrowFloatingValue(this.bitWidth, Object bits) : bits = _bigInt(bits) {
    if (bitWidth != 16 && bitWidth != 32 && bitWidth != 64) {
      throw ArgumentError.value(bitWidth, 'bitWidth');
    }
    if (this.bits.isNegative || this.bits >= (BigInt.one << bitWidth)) {
      throw ArgumentError.value(bits, 'bits', 'does not fit in $bitWidth bits');
    }
  }
  factory ArrowFloatingValue.float16(int rawBits) =>
      ArrowFloatingValue(16, rawBits);
  factory ArrowFloatingValue.float32(double value) {
    final data = ByteData(4)..setFloat32(0, value, Endian.little);
    return ArrowFloatingValue(32, data.getUint32(0, Endian.little));
  }
  factory ArrowFloatingValue.float64(double value) {
    final data = ByteData(8)..setFloat64(0, value, Endian.little);
    return ArrowFloatingValue(64, data.getUint64(0, Endian.little));
  }
  final int bitWidth;
  final BigInt bits;
  String get hexadecimalBits =>
      bits.toRadixString(16).padLeft(bitWidth ~/ 4, '0');
  @override
  bool operator ==(Object other) =>
      other is ArrowFloatingValue &&
      bitWidth == other.bitWidth &&
      bits == other.bits;
  @override
  int get hashCode => Object.hash(bitWidth, bits);
}

final class ArrowDecimalValue extends ArrowValue {
  ArrowDecimalValue(Object unscaled) : unscaled = _bigInt(unscaled);
  final BigInt unscaled;
  @override
  bool operator ==(Object other) =>
      other is ArrowDecimalValue && unscaled == other.unscaled;
  @override
  int get hashCode => unscaled.hashCode;
}

final class ArrowStringValue extends ArrowValue {
  const ArrowStringValue(this.value);
  final String value;
  @override
  bool operator ==(Object other) =>
      other is ArrowStringValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class ArrowBinaryValue extends ArrowValue {
  ArrowBinaryValue(List<int> bytes)
    : bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final Uint8List bytes;
  @override
  bool operator ==(Object other) =>
      other is ArrowBinaryValue && _listEquals(bytes, other.bytes);
  @override
  int get hashCode => Object.hashAll(bytes);
}

/// A raw date/time/timestamp/duration counter in the datatype's declared unit.
final class ArrowTemporalValue extends ArrowValue {
  ArrowTemporalValue(Object value) : value = _bigInt(value);
  final BigInt value;
  @override
  bool operator ==(Object other) =>
      other is ArrowTemporalValue && value == other.value;
  @override
  int get hashCode => value.hashCode;
}

final class ArrowListValue extends ArrowValue {
  ArrowListValue(List<ArrowValue?> values) : values = List.unmodifiable(values);
  final List<ArrowValue?> values;
  @override
  bool operator ==(Object other) =>
      other is ArrowListValue && _listEquals(values, other.values);
  @override
  int get hashCode => Object.hashAll(values);
}

final class ArrowStructEntry {
  const ArrowStructEntry(this.name, this.value);
  final String name;
  final ArrowValue? value;
  @override
  bool operator ==(Object other) =>
      other is ArrowStructEntry && name == other.name && value == other.value;
  @override
  int get hashCode => Object.hash(name, value);
}

/// Ordered struct members. Names are retained to detect field-order mistakes.
final class ArrowStructValue extends ArrowValue {
  ArrowStructValue(List<ArrowStructEntry> fields)
    : fields = List.unmodifiable(fields);
  final List<ArrowStructEntry> fields;
  @override
  bool operator ==(Object other) =>
      other is ArrowStructValue && _listEquals(fields, other.fields);
  @override
  int get hashCode => Object.hashAll(fields);
}

final class ArrowDictionaryIndexValue extends ArrowValue {
  ArrowDictionaryIndexValue(Object index) : index = _bigInt(index);
  final BigInt index;
  @override
  bool operator ==(Object other) =>
      other is ArrowDictionaryIndexValue && index == other.index;
  @override
  int get hashCode => index.hashCode;
}

final class ArrowExtensionValue extends ArrowValue {
  const ArrowExtensionValue(this.storage);
  final ArrowValue storage;
  @override
  bool operator ==(Object other) =>
      other is ArrowExtensionValue && storage == other.storage;
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
