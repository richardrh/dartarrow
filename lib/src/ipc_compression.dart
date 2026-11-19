part of 'core.dart';

// Message.fbs BodyCompression: every compressed buffer starts with its
// little-endian int64 uncompressed length; -1 marks an uncompressed payload.

/// Decodes one compressed IPC buffer. [reserve] is called with the output
/// size before anything is allocated; `copied` is false for an uncompressed
/// payload, which is returned as a view of [encoded].
Uint8List _ipcDecompress(
  Uint8List encoded,
  int codec,
  void Function(int size, bool copied) reserve,
) {
  if (codec != 0 && codec != 1) {
    throw UnsupportedError('Unknown Arrow IPC compression codec $codec');
  }
  if (encoded.isEmpty) return encoded;
  if (encoded.length < 8) {
    throw const FormatException('Compressed IPC buffer lacks its size prefix');
  }
  final declared = _ipcGetInt64(ByteData.sublistView(encoded), 0);
  final payload = Uint8List.sublistView(encoded, 8);
  if (declared == -1) {
    reserve(payload.length, false);
    return payload;
  }
  if (declared < 0) {
    throw FormatException('Invalid IPC decompressed size $declared');
  }
  reserve(declared, true);
  // A declared length of 0 is an empty buffer, as in Arrow C++'s
  // DecompressBuffer; writers emit it for empty buffers.
  if (declared == 0) return Uint8List(0);
  final Uint8List result;
  try {
    result = ipc_compression.decompressIpcBuffer(codec, payload, declared);
  } on UnsupportedError {
    rethrow;
  } on FormatException {
    rethrow;
  } on Exception catch (error) {
    throw FormatException('Invalid compressed IPC buffer: $error');
  } on RangeError catch (error) {
    throw FormatException('Invalid compressed IPC buffer bounds: $error');
  }
  if (result.length != declared) {
    throw const FormatException('IPC decompressed length differs from prefix');
  }
  return result;
}
