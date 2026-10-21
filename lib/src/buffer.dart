part of 'core.dart';

/// An immutable view of borrowed bytes. The owner must not mutate its storage
/// while consumers require a stable snapshot; [toBytes] creates an owned copy.
final class Buffer {
  Buffer(Uint8List bytes, {Object? owner})
    : _bytes = bytes.asUnmodifiableView(),
      _owner = owner ?? bytes;

  Buffer._borrowed(this._bytes, this._owner);

  final Uint8List _bytes;
  // Retains foreign/native allocation owners for the lifetime of every view.
  final Object _owner;

  int get size => _bytes.length;
  bool get isMutable => false;

  /// Read-only storage for array buffer decoding; this does not copy.
  Uint8List get bytes => _bytes;

  /// A borrowed view starting at [offset]; explicit lengths must fit.
  Buffer slice([int offset = 0, int? length]) {
    RangeError.checkValueInInterval(offset, 0, size, 'offset');
    if (length != null && length < 0) {
      throw RangeError.value(length, 'length', 'must be non-negative');
    }
    final available = size - offset;
    if (length != null && length > available) {
      throw RangeError.value(length, 'length', 'slice exceeds buffer length');
    }
    final count = length ?? available;
    return Buffer(
      Uint8List.sublistView(_bytes, offset, offset + count),
      owner: _owner,
    );
  }

  /// Returns a mutable, independent copy of this view.
  Uint8List toBytes() => Uint8List.fromList(_bytes);
}
