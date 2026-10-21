part of 'core.dart';

/// Immutable byte-keyed metadata. Keys are compared by content, not identity.
final class ByteMetadata extends MapBase<Uint8List, Uint8List> {
  ByteMetadata(Map<Object, Object> values) {
    for (final entry in values.entries) {
      final key = _bytes(entry.key);
      _entries[base64Encode(key)] = MapEntry(key, _bytes(entry.value));
    }
  }
  final Map<String, MapEntry<Uint8List, Uint8List>> _entries = {};
  static Uint8List _bytes(Object value) {
    final List<int> bytes;
    if (value is String) {
      bytes = utf8.encode(value);
    } else if (value is Uint8List) {
      bytes = value;
    } else {
      throw ArgumentError.value(
        value,
        'metadata',
        'Expected String or Uint8List',
      );
    }
    return Uint8List.fromList(bytes).asUnmodifiableView();
  }

  @override
  Uint8List? operator [](Object? key) {
    if (key is String) return _entries[base64Encode(utf8.encode(key))]?.value;
    if (key is Uint8List) return _entries[base64Encode(key)]?.value;
    return null;
  }

  @override
  Iterable<Uint8List> get keys => _entries.values.map((e) => e.key);
  @override
  void operator []=(Uint8List key, Uint8List value) =>
      throw UnsupportedError('Immutable metadata');
  @override
  void clear() => throw UnsupportedError('Immutable metadata');
  @override
  Uint8List? remove(Object? key) =>
      throw UnsupportedError('Immutable metadata');
  bool equals(ByteMetadata? other) =>
      other != null &&
      length == other.length &&
      _entries.entries.every(
        (e) => _same(e.value.value, other._entries[e.key]?.value),
      );
  static bool _same(Uint8List a, Uint8List? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Object toJson() => {
    'encoding': 'base64',
    'entries': _entries.values
        .map((e) => [base64Encode(e.key), base64Encode(e.value)])
        .toList(),
  };
  static ByteMetadata? fromJson(Object? value) {
    if (value == null) return null;
    if (value is! Map)
      throw const FormatException('metadata must be an object');
    if (value['encoding'] == 'base64' && value['entries'] is List) {
      final result = <Object, Object>{};
      for (final entry in value['entries'] as List) {
        if (entry is! List ||
            entry.length != 2 ||
            entry[0] is! String ||
            entry[1] is! String)
          throw const FormatException('Invalid binary metadata entry');
        result[base64Decode(entry[0] as String)] = base64Decode(
          entry[1] as String,
        );
      }
      return ByteMetadata(result);
    }
    final result = <Object, Object>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! String)
        throw const FormatException('Legacy metadata must contain strings');
      result[entry.key as String] = entry.value as String;
    }
    return ByteMetadata(result);
  }
}
