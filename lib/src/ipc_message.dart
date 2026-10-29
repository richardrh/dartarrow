part of 'core.dart';

// Encapsulated messages (Message.fbs), the stream framing and the file
// footer (File.fbs).

const int _ipcMetadataV5 = 4; // MetadataVersion.V5
const int _ipcHeaderSchema = 1;
const int _ipcHeaderDictionaryBatch = 2;
const int _ipcHeaderRecordBatch = 3;
final Uint8List _ipcFileMagic = Uint8List.fromList(ascii.encode('ARROW1'));

Uint8List _ipcInt32Bytes(int value) =>
    Uint8List(4)..buffer.asByteData().setInt32(0, value, Endian.little);

final class _IpcMessage {
  const _IpcMessage(this.headerType, this.header, this.body);
  final int headerType;
  final _FbTableView header;
  final Uint8List body;
}

/// A file Block (File.fbs struct): offset, metaDataLength, bodyLength.
final class _IpcBlock {
  const _IpcBlock(this.offset, this.metadataLength, this.bodyLength);
  final int offset;
  final int metadataLength;
  final int bodyLength;
}

// ------------------------------------------------------------ decoding ----

_IpcMessage _ipcParseMessage(Uint8List metadata, Uint8List body) {
  final message = _FbReader(ByteData.sublistView(metadata)).root();
  final version = message.i16(0, 0);
  if (version != _ipcMetadataV5) {
    throw FormatException(
      'Unsupported IPC metadata version $version (need V5)',
    );
  }
  final headerType = message.u8(1, 0);
  final header = message.table(2);
  if (header == null) throw const FormatException('IPC message has no header');
  final bodyLength = message.i64(3, 0);
  if (bodyLength < 0 || bodyLength > body.length) {
    throw FormatException(
      'IPC body length $bodyLength exceeds available bytes',
    );
  }
  return _IpcMessage(
    headerType,
    header,
    Uint8List.sublistView(body, 0, bodyLength),
  );
}

/// Walks encapsulated messages: `0xFFFFFFFF`, int32 length, metadata, body.
final class _IpcMessageCursor {
  _IpcMessageCursor(this.bytes, this.position, this.limits);
  final Uint8List bytes;
  int position;
  final IpcLimits limits;
  late final ByteData _data = ByteData.sublistView(bytes);

  int _int32() {
    if (position > bytes.length - 4) {
      throw const FormatException('Truncated IPC message prefix');
    }
    final value = _data.getInt32(position, Endian.little);
    position += 4;
    return value;
  }

  /// Returns the next message, or null at end-of-stream / end of input.
  _IpcMessage? next() {
    if (position == bytes.length) return null;
    var length = _int32();
    // Pre-0.15 streams omit the continuation token.
    if (length == -1) length = _int32();
    if (length == 0) return null;
    if (length < 0 ||
        length > limits.maxMessageBytes ||
        length > bytes.length - position) {
      throw FormatException('Invalid IPC metadata length $length');
    }
    final metadata = Uint8List.sublistView(bytes, position, position + length);
    position += length;
    final message = _ipcParseMessage(
      metadata,
      Uint8List.sublistView(bytes, position),
    );
    if (message.body.length > limits.maxMessageBytes) {
      throw const FormatException('IPC body exceeds maxMessageBytes');
    }
    position += message.body.length;
    return message;
  }
}

bool _ipcHasMagic(Uint8List bytes, int at) {
  for (var i = 0; i < _ipcFileMagic.length; i++) {
    if (bytes[at + i] != _ipcFileMagic[i]) return false;
  }
  return true;
}

/// The footer table and the length of the data preceding the footer.
(_FbTableView, int) _ipcReadFooter(Uint8List bytes, IpcLimits limits) {
  const trailer = 10; // int32 footer length + 'ARROW1'
  if (bytes.length < 8 + trailer ||
      !_ipcHasMagic(bytes, 0) ||
      !_ipcHasMagic(bytes, bytes.length - 6)) {
    throw const FormatException('Not an Arrow IPC file (missing ARROW1 magic)');
  }
  final data = ByteData.sublistView(bytes);
  final length = data.getInt32(bytes.length - trailer, Endian.little);
  final start = bytes.length - trailer - length;
  if (length <= 0 || start < 8) {
    throw FormatException('Invalid IPC file footer length $length');
  }
  if (length > limits.maxMessageBytes) {
    throw const FormatException('IPC footer exceeds maxMessageBytes');
  }
  final footer = _FbReader(
    ByteData.sublistView(bytes, start, bytes.length - trailer),
  ).root();
  final version = footer.i16(0, 0);
  if (version != _ipcMetadataV5) {
    throw FormatException('Unsupported IPC file version $version (need V5)');
  }
  return (footer, start);
}

List<_IpcBlock> _ipcBlocks(_FbTableView footer, int slot, int max) {
  final structs = footer.structs(slot, 24);
  if (structs.count > max) {
    throw FormatException(
      'IPC file has ${structs.count} blocks; limit is $max',
    );
  }
  return [
    for (var i = 0; i < structs.count; i++)
      _IpcBlock(structs.i64(i, 0), structs.i32(i, 8), structs.i64(i, 16)),
  ];
}

_IpcMessage _ipcReadBlock(Uint8List bytes, _IpcBlock block, IpcLimits limits) {
  final end = block.offset + block.metadataLength + block.bodyLength;
  if (block.offset < 8 ||
      block.metadataLength < 8 ||
      block.bodyLength < 0 ||
      block.bodyLength > limits.maxMessageBytes ||
      end > bytes.length) {
    throw const FormatException('IPC file block lies outside the file');
  }
  final cursor = _IpcMessageCursor(
    Uint8List.sublistView(bytes, 0, end),
    block.offset,
    limits,
  );
  final message = cursor.next();
  if (message == null) throw const FormatException('Empty IPC file block');
  if (cursor.position != end || message.body.length != block.bodyLength) {
    throw const FormatException('IPC file block lengths disagree with message');
  }
  return message;
}

/// Dictionary and record batch decoding state shared by both readers.
final class _IpcReadState {
  _IpcReadState(this.ipc, this.limits) {
    void visit(_IpcField field) {
      final id = field.dictionaryId;
      if (id != null) {
        final previous = _slots[id];
        if (previous != null &&
            _ipcDictionary(previous.field.type)!.valueType !=
                _ipcDictionary(field.field.type)!.valueType) {
          throw FormatException('Incompatible value types for dictionary $id');
        }
        _slots.putIfAbsent(id, () => field);
      }
      field.children.forEach(visit);
    }

    ipc.fields.forEach(visit);
  }

  final _IpcSchema ipc;
  final IpcLimits limits;
  final Map<int, _IpcField> _slots = {};
  final Map<int, Array> _dictionaries = {};
  int _dictionaryCount = 0;

  Schema get schema => ipc.schema;

  Array _dictionary(int id) {
    final dictionary = _dictionaries[id];
    if (dictionary == null) {
      throw FormatException('Batch references missing dictionary $id');
    }
    return dictionary;
  }

  void acceptDictionary(
    _IpcMessage message,
    _IpcValueBudget budget, {
    required bool allowReplacement,
  }) {
    if (++_dictionaryCount > limits.maxDictionaries) {
      throw const FormatException('Too many dictionary batches');
    }
    final id = message.header.i64(0, 0);
    final slot = _slots[id];
    if (slot == null) throw FormatException('Unknown dictionary id $id');
    final data = message.header.table(1);
    if (data == null) {
      throw const FormatException('DictionaryBatch has no data');
    }
    final valueType = _ipcDictionary(slot.field.type)!.valueType;
    final values = _ipcDecodeColumns(data, message.body, [
      (valueType, slot),
    ], budget).single;
    final isDelta = message.header.boolean(2, false);
    final existing = _dictionaries[id];
    if (isDelta && existing == null) {
      throw FormatException('Dictionary delta $id has no base dictionary');
    }
    if (existing != null && !isDelta && !allowReplacement) {
      throw const FormatException('IPC files may not replace dictionaries');
    }
    if (isDelta && existing!.length + values.length > limits.maxRows) {
      throw const FormatException('Dictionary delta exceeds row limit');
    }
    _dictionaries[id] = isDelta ? concatArrays([existing!, values]) : values;
  }

  RecordBatch decodeBatch(_IpcMessage message, _IpcValueBudget budget) {
    final fields = ipc.fields;
    final columns = _ipcDecodeColumns(message.header, message.body, [
      for (final field in fields) (field.field.type, field),
    ], budget);
    return RecordBatch._(schema, columns, message.header.i64(0, 0));
  }

  /// Decodes a RecordBatch table body into one array per column.
  List<Array> _ipcDecodeColumns(
    _FbTableView batch,
    Uint8List body,
    List<(DataType, _IpcField)> columns,
    _IpcValueBudget budget,
  ) {
    final length = batch.i64(0, 0);
    if (length < 0 || length > limits.maxRows) {
      throw FormatException('Batch length $length exceeds limits');
    }
    final reader = _IpcBodyReader(
      body,
      [
        for (final (a, b) in _ipcPairs(batch.structs(1, 16), 'field nodes'))
          _IpcNode(a, b),
      ],
      [
        for (final (a, b) in _ipcPairs(batch.structs(2, 16), 'buffers'))
          _IpcBufferRef(a, b),
      ],
      _ipcVariadicCounts(batch),
      _ipcCompressionCodec(batch),
      limits,
      budget,
      _dictionary,
    );
    final arrays = [
      for (final (type, field) in columns) _ipcReadArray(reader, type, field),
    ];
    reader.finish();
    for (final array in arrays) {
      if (array.length != length) {
        throw FormatException(
          'Column length ${array.length} != batch length $length',
        );
      }
    }
    return arrays;
  }

  List<(int, int)> _ipcPairs(_FbStructs structs, String name) {
    if (structs.count > limits.maxBuffers) {
      throw FormatException('Too many $name');
    }
    return [
      for (var i = 0; i < structs.count; i++)
        (structs.i64(i, 0), structs.i64(i, 8)),
    ];
  }

  List<int> _ipcVariadicCounts(_FbTableView batch) {
    final structs = batch.structs(4, 8);
    if (structs.count > limits.maxBuffers) {
      throw const FormatException('Too many variadic buffer counts');
    }
    return [for (var i = 0; i < structs.count; i++) structs.i64(i, 0)];
  }
}

/// Reads RecordBatch.compression (BodyCompression), returning the codec id
/// or null when the body is uncompressed.
int? _ipcCompressionCodec(_FbTableView batch) {
  final compression = batch.table(3);
  if (compression == null) return null;
  final codec = compression.u8(0, 0);
  if (codec > 1) throw FormatException('Unknown compression codec $codec');
  if (compression.u8(1, 0) != 0) {
    throw const FormatException('Only BUFFER body compression is defined');
  }
  return codec;
}

// ------------------------------------------------------------ encoding ----

final class _IpcMessageSink {
  final BytesBuilder _out = BytesBuilder(copy: false);
  int get length => _out.length;
  void raw(Uint8List bytes) => _out.add(bytes);
  Uint8List takeBytes() => _out.takeBytes();

  /// Writes one encapsulated message and returns its file [_IpcBlock].
  _IpcBlock message(int headerType, _FbTableObject header, Uint8List body) {
    final metadata = _FbWriter.encode(
      _FbTableObject({
        0: _fbI16(_ipcMetadataV5),
        1: _fbU8(headerType),
        2: _FbRef(header),
        3: _fbI64(body.length),
      }),
    );
    final padded = _ipcAlignUp(metadata.length, 8);
    final offset = length;
    raw(_ipcInt32Bytes(-1));
    raw(_ipcInt32Bytes(padded));
    raw(metadata);
    raw(Uint8List(padded - metadata.length));
    raw(body);
    return _IpcBlock(offset, 8 + padded, body.length);
  }

  void endOfStream() {
    raw(_ipcInt32Bytes(-1));
    raw(_ipcInt32Bytes(0));
  }
}

/// Encodes [arrays] as one RecordBatch table and its body.
(_FbTableObject, Uint8List) _ipcEncodeBody(int length, List<Array> arrays) {
  final w = _IpcBodyWriter();
  for (final array in arrays) {
    _ipcWriteArray(w, array);
  }
  final body = w.takeBytes();
  final nodes = ByteData(16 * w.nodes.length);
  for (var i = 0; i < w.nodes.length; i++) {
    _ipcSetInt64(nodes, i * 16, w.nodes[i].length);
    _ipcSetInt64(nodes, i * 16 + 8, w.nodes[i].nullCount);
  }
  final buffers = ByteData(16 * w.buffers.length);
  for (var i = 0; i < w.buffers.length; i++) {
    _ipcSetInt64(buffers, i * 16, w.buffers[i].offset);
    _ipcSetInt64(buffers, i * 16 + 8, w.buffers[i].length);
  }
  final variadic = ByteData(8 * w.variadicCounts.length);
  for (var i = 0; i < w.variadicCounts.length; i++) {
    _ipcSetInt64(variadic, i * 8, w.variadicCounts[i]);
  }
  return (
    _FbTableObject({
      0: _fbI64(length),
      1: _fbStructs(nodes.buffer.asUint8List(), w.nodes.length),
      2: _fbStructs(buffers.buffer.asUint8List(), w.buffers.length),
      if (w.variadicCounts.isNotEmpty)
        4: _fbStructs(variadic.buffer.asUint8List(), w.variadicCounts.length),
    }),
    body,
  );
}

/// Shared stream/file writer state: framing, dictionary tracking, blocks.
final class _IpcWriterCore {
  _IpcWriterCore(Schema schema, {required this.file})
    : ipc = _ipcDescribe(schema) {
    schemaTable = _ipcSchemaTable(ipc);
    if (file) sink.raw(Uint8List.fromList([..._ipcFileMagic, 0, 0]));
    sink.message(_ipcHeaderSchema, schemaTable, Uint8List(0));
  }

  final bool file;
  final _IpcSchema ipc;
  late final _FbTableObject schemaTable;
  final _IpcMessageSink sink = _IpcMessageSink();
  final Map<int, Array> _written = {};
  final List<_IpcBlock> dictionaryBlocks = [];
  final List<_IpcBlock> batchBlocks = [];
  Uint8List? _closed;

  void writeBatch(RecordBatch batch) {
    if (_closed != null) throw StateError('IPC writer is closed');
    if (!batch.schema.equals(ipc.schema)) {
      throw ArgumentError('Record batch schema does not match writer schema');
    }
    final dictionaries = <(int, Array)>[];
    void visit(Array array, _IpcField field) {
      final id = field.dictionaryId;
      final source = id == null ? array : array.dictionary!;
      if (id != null) dictionaries.add((id, source));
      for (var i = 0; i < field.children.length; i++) {
        visit(source.children[i], field.children[i]);
      }
    }

    for (var c = 0; c < batch.columns.length; c++) {
      visit(batch.columns[c], ipc.fields[c]);
    }
    // Nested dictionaries must precede dictionaries whose values use them.
    final pending = <(int, Array, bool)>[];
    for (final (id, dictionary) in dictionaries.reversed) {
      final previous = _written[id];
      if (previous != null &&
          (identical(previous, dictionary) || previous.equals(dictionary))) {
        continue;
      }
      if (previous != null &&
          previous.length < dictionary.length &&
          previous.equals(dictionary.slice(0, previous.length))) {
        pending.add((id, dictionary.slice(previous.length), true));
      } else if (previous != null && file) {
        throw UnsupportedError(
          'IPC files cannot replace a dictionary between batches',
        );
      } else {
        pending.add((id, dictionary, false));
      }
      _written[id] = dictionary;
    }
    for (final (id, values, isDelta) in pending) {
      final (data, body) = _ipcEncodeBody(values.length, [values]);
      dictionaryBlocks.add(
        sink.message(
          _ipcHeaderDictionaryBatch,
          _FbTableObject({0: _fbI64(id), 1: _FbRef(data), 2: _fbBool(isDelta)}),
          body,
        ),
      );
    }
    final (header, body) = _ipcEncodeBody(batch.numRows, batch.columns);
    batchBlocks.add(sink.message(_ipcHeaderRecordBatch, header, body));
  }

  Uint8List close() {
    final closed = _closed;
    if (closed != null) return closed;
    sink.endOfStream();
    if (file) {
      final footer = _FbWriter.encode(
        _FbTableObject({
          0: _fbI16(_ipcMetadataV5),
          1: _FbRef(schemaTable),
          2: _fbStructs(
            _ipcBlockBytes(dictionaryBlocks),
            dictionaryBlocks.length,
          ),
          3: _fbStructs(_ipcBlockBytes(batchBlocks), batchBlocks.length),
        }),
      );
      sink
        ..raw(footer)
        ..raw(_ipcInt32Bytes(footer.length))
        ..raw(_ipcFileMagic);
    }
    return _closed = sink.takeBytes();
  }
}

Uint8List _ipcBlockBytes(List<_IpcBlock> blocks) {
  final data = ByteData(24 * blocks.length);
  for (var i = 0; i < blocks.length; i++) {
    _ipcSetInt64(data, i * 24, blocks[i].offset);
    data.setInt32(i * 24 + 8, blocks[i].metadataLength, Endian.little);
    _ipcSetInt64(data, i * 24 + 16, blocks[i].bodyLength);
  }
  return data.buffer.asUint8List();
}
