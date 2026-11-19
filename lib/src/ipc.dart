part of 'core.dart';

// Apache Arrow IPC (columnar format version V5) streams and files.
//
// Implements the encapsulated message format, the streaming format and the
// random-access file format with metadata from `Schema.fbs`, `Message.fbs`
// and `File.fbs`, produced and parsed by a small in-tree FlatBuffers codec.
// Uncompressed bodies are read as zero-copy views; LZ4_FRAME/ZSTD bodies are
// decoded with `libcompress` on the VM and an in-tree LZ4 frame decoder on
// the web (ZSTD is unsupported there). Writers emit uncompressed bodies.

/// Resource limits applied while decoding untrusted IPC input.
///
/// Defaults are conservative; trusted callers handling larger data should
/// pass raised limits explicitly. Every breach raises a [FormatException]
/// naming the `IpcLimits` field, its configured value and the offending
/// value.
///
/// The limits bound decoding work and allocations inside the reader. They
/// do not bound later materialization (`toDartList`, `asDart`,
/// `combineChunks`) of run-end encoded, dictionary or view columns that
/// share values, and they are not a substitute for process isolation.
final class IpcLimits {
  /// Creates limits; every bound is inclusive.
  const IpcLimits({
    this.maxDepth = 64,
    this.maxFields = 10000,
    this.maxRows = 1 << 20,
    this.maxValues = 4 << 20,
    this.maxBuffers = 1 << 16,
    this.maxMessageBytes = 64 << 20,
    this.maxDictionaries = 1024,
    this.maxBatches = 1 << 20,
    this.maxDecompressedBytes = 256 << 20,
  });

  /// Maximum type nesting depth.
  final int maxDepth;

  /// Maximum number of fields (including nested children) in a schema.
  final int maxFields;

  /// Maximum length of any single array node (and of a delta-merged
  /// dictionary).
  final int maxRows;

  /// Maximum total of all field node lengths decoded by one read (a stream
  /// reader, or one file `getBatch`/`readAll` call plus the file's
  /// dictionaries). Bounds decoding work and allocations inside the reader,
  /// including for layouts (such as Null or run-end encoded) whose wire size
  /// is independent of their logical length.
  final int maxValues;

  /// Maximum number of field nodes or buffers in one message.
  final int maxBuffers;

  /// Maximum size of a message's metadata, body, decompressed body or file
  /// footer; also bounds the bytes of metadata strings decoded from one
  /// message and the bytes referenced by one message's view columns.
  final int maxMessageBytes;

  /// Maximum number of dictionary batches.
  final int maxDictionaries;

  /// Maximum number of record batches.
  final int maxBatches;

  /// Maximum total size of decompressed buffers produced by one read (a
  /// stream reader, or one file `getBatch`/`readAll` call plus the file's
  /// dictionaries). Uncompressed bodies are zero-copy views and are not
  /// counted.
  final int maxDecompressedBytes;
}

/// A [FormatException] for [value] (described by [what]) breaching the
/// `IpcLimits` field [name] configured as [limit].
FormatException _ipcLimitError(
  String what,
  int value,
  String name,
  int limit,
) => FormatException(
  '$what $value exceeds IpcLimits.$name ($limit); pass larger IpcLimits '
  'to openStream/openFile for trusted input',
);

/// Opens an in-memory Arrow IPC stream, like PyArrow's `ipc.open_stream`.
///
/// The schema message is decoded immediately. Malformed input raises
/// [FormatException]; valid but unsupported input raises [UnsupportedError].
RecordBatchStreamReader openStream(
  Uint8List bytes, {
  IpcLimits limits = const IpcLimits(),
}) => _ipcGuard(() {
  final messages = _IpcMessageCursor(bytes, 0, limits);
  final first = messages.next();
  if (first == null || first.headerType != _ipcHeaderSchema) {
    throw const FormatException('IPC stream must begin with a Schema message');
  }
  return RecordBatchStreamReader._(
    _IpcReadState(_ipcReadSchema(first.header, limits), limits),
    messages,
  );
});

/// Opens an in-memory Arrow IPC file (`ARROW1` magic plus footer), like
/// PyArrow's `ipc.open_file`.
///
/// The footer, schema and all dictionary batches are decoded immediately;
/// record batches are decoded on demand by [RecordBatchFileReader.getBatch].
RecordBatchFileReader openFile(
  Uint8List bytes, {
  IpcLimits limits = const IpcLimits(),
}) => _ipcGuard(() {
  final (footer, dataLength) = _ipcReadFooter(bytes, limits);
  final data = Uint8List.sublistView(bytes, 0, dataLength);
  final schemaTable = footer.table(1);
  if (schemaTable == null) {
    throw const FormatException('IPC file footer has no schema');
  }
  final state = _IpcReadState(_ipcReadSchema(schemaTable, limits), limits);
  final budget = _IpcValueBudget(limits);
  final dictionaryBlocks = _ipcBlocks(
    footer,
    2,
    'maxDictionaries',
    limits.maxDictionaries,
  );
  final batchBlocks = _ipcBlocks(footer, 3, 'maxBatches', limits.maxBatches);
  _ipcCheckDisjointBlocks([...dictionaryBlocks, ...batchBlocks]);
  for (final block in dictionaryBlocks) {
    final message = _ipcReadBlock(data, block, limits);
    if (message.headerType != _ipcHeaderDictionaryBatch) {
      throw const FormatException('Dictionary block has wrong message type');
    }
    state.acceptDictionary(message, budget, allowReplacement: false);
  }
  return RecordBatchFileReader._(state, data, batchBlocks, budget);
});

/// Creates an Arrow IPC stream writer for [schema], like PyArrow's
/// `ipc.new_stream`. Bytes are collected in memory and returned by
/// [RecordBatchStreamWriter.close].
///
/// Throws [UnsupportedError] for types without a standard IPC encoding
/// (binding `int128`/`uint128`, stacked extensions, dictionary of extension
/// or dictionary values) and [ArgumentError] for field metadata that uses
/// the reserved `ARROW:extension:*` keys.
RecordBatchStreamWriter newStream(Schema schema) =>
    RecordBatchStreamWriter._(_IpcWriterCore(schema, file: false));

/// Creates an Arrow IPC file writer for [schema], like PyArrow's
/// `ipc.new_file`. See [newStream] for rejected schemas.
RecordBatchFileWriter newFile(Schema schema) =>
    RecordBatchFileWriter._(_IpcWriterCore(schema, file: true));

/// Sequential reader of an Arrow IPC stream.
///
/// Iterating yields the remaining record batches once (the reader is a
/// single-pass cursor). Dictionary replacements and deltas apply to the
/// batches that follow them.
final class RecordBatchStreamReader extends Iterable<RecordBatch> {
  RecordBatchStreamReader._(this._state, this._messages)
    : _budget = _IpcValueBudget(_state.limits);

  final _IpcReadState _state;
  final _IpcMessageCursor _messages;
  final _IpcValueBudget _budget;
  int _batches = 0;
  bool _done = false;

  /// The stream schema.
  Schema get schema => _state.schema;

  /// The limits applied while decoding.
  IpcLimits get limits => _state.limits;

  /// Decodes the next record batch, or returns null at end of stream.
  RecordBatch? readNextBatch() => _ipcGuard(() {
    while (!_done) {
      final message = _messages.next();
      if (message == null) {
        _done = true;
        break;
      }
      switch (message.headerType) {
        case _ipcHeaderDictionaryBatch:
          _state.acceptDictionary(message, _budget, allowReplacement: true);
        case _ipcHeaderRecordBatch:
          if (++_batches > limits.maxBatches) {
            throw _ipcLimitError(
              'Record batch count',
              _batches,
              'maxBatches',
              limits.maxBatches,
            );
          }
          return _state.decodeBatch(message, _budget);
        case _ipcHeaderSchema:
          throw const FormatException('Unexpected second Schema message');
        default:
          throw UnsupportedError(
            'Unsupported IPC message type ${message.headerType}',
          );
      }
    }
    return null;
  });

  /// Reads every remaining batch into a [Table] with [schema].
  Table readAll() =>
      Table.fromBatches(List<RecordBatch>.of(this), schema: schema);

  @override
  Iterator<RecordBatch> get iterator => _IpcStreamIterator(this);
}

final class _IpcStreamIterator implements Iterator<RecordBatch> {
  _IpcStreamIterator(this._reader);
  final RecordBatchStreamReader _reader;
  RecordBatch? _current;

  @override
  RecordBatch get current => _current ?? (throw StateError('No current batch'));

  @override
  bool moveNext() => (_current = _reader.readNextBatch()) != null;
}

/// Random-access reader of an Arrow IPC file.
final class RecordBatchFileReader {
  RecordBatchFileReader._(
    this._state,
    this._data,
    this._blocks,
    this._dictionaryBudget,
  );

  final _IpcReadState _state;
  final Uint8List _data;
  final List<_IpcBlock> _blocks;
  final _IpcValueBudget _dictionaryBudget;

  /// The file schema (from the footer).
  Schema get schema => _state.schema;

  /// The limits applied while decoding.
  IpcLimits get limits => _state.limits;

  /// Number of record batches listed in the footer.
  int get numRecordBatches => _blocks.length;

  /// Decodes record batch [index] (0-based).
  RecordBatch getBatch(int index) {
    RangeError.checkValidIndex(index, _blocks, 'index');
    return _ipcGuard(() => _read(index, _dictionaryBudget.copy()));
  }

  RecordBatch _read(int index, _IpcValueBudget budget) {
    final message = _ipcReadBlock(_data, _blocks[index], limits);
    if (message.headerType != _ipcHeaderRecordBatch) {
      throw const FormatException('Record batch block has wrong message type');
    }
    return _state.decodeBatch(message, budget);
  }

  /// Reads every record batch into a [Table] with [schema].
  Table readAll() => _ipcGuard(() {
    final budget = _dictionaryBudget.copy();
    return Table.fromBatches([
      for (var i = 0; i < _blocks.length; i++) _read(i, budget),
    ], schema: schema);
  });
}

/// In-memory Arrow IPC stream writer created by [newStream].
final class RecordBatchStreamWriter {
  RecordBatchStreamWriter._(this._core);
  final _IpcWriterCore _core;

  /// The schema every written batch must match.
  Schema get schema => _core.ipc.schema;

  /// Writes [batch], preceded by any new, replaced or delta dictionaries.
  /// If this throws, nothing is written and the writer state is unchanged.
  void writeBatch(RecordBatch batch) => _core.writeBatches([batch]);

  /// Writes the batches of [table], optionally split to [maxChunkSize] rows.
  /// All-or-nothing: if any chunk fails, no chunk is written.
  void writeTable(Table table, {int? maxChunkSize}) =>
      _ipcWriteTable(_core, table, maxChunkSize);

  /// Writes a [RecordBatch] or a [Table], atomically like [writeBatch] and
  /// [writeTable].
  void write(Object data) => _ipcWrite(_core, data);

  /// Appends the end-of-stream marker and returns the stream bytes. Further
  /// writes throw [StateError]; repeated calls return the same bytes.
  Uint8List close() => _core.close();
}

/// In-memory Arrow IPC file writer created by [newFile].
final class RecordBatchFileWriter {
  RecordBatchFileWriter._(this._core);
  final _IpcWriterCore _core;

  /// The schema every written batch must match.
  Schema get schema => _core.ipc.schema;

  /// Writes [batch], preceded by any new or delta dictionaries. Files cannot
  /// replace a dictionary; doing so throws [UnsupportedError]. If this
  /// throws, nothing is written and the writer state is unchanged.
  void writeBatch(RecordBatch batch) => _core.writeBatches([batch]);

  /// Writes the batches of [table], optionally split to [maxChunkSize] rows.
  /// All-or-nothing: if any chunk fails, no chunk is written.
  void writeTable(Table table, {int? maxChunkSize}) =>
      _ipcWriteTable(_core, table, maxChunkSize);

  /// Writes a [RecordBatch] or a [Table], atomically like [writeBatch] and
  /// [writeTable].
  void write(Object data) => _ipcWrite(_core, data);

  /// Appends the footer and returns the file bytes. Further writes throw
  /// [StateError]; repeated calls return the same bytes.
  Uint8List close() => _core.close();
}

void _ipcWriteTable(_IpcWriterCore core, Table table, int? maxChunkSize) {
  if (!table.schema.equals(core.ipc.schema)) {
    throw ArgumentError('Table schema does not match writer schema');
  }
  core.writeBatches(table.toBatches(maxChunkSize: maxChunkSize));
}

void _ipcWrite(_IpcWriterCore core, Object data) => switch (data) {
  RecordBatch() => core.writeBatches([data]),
  Table() => _ipcWriteTable(core, data, null),
  _ => throw ArgumentError.value(data, 'data', 'Expected RecordBatch or Table'),
};

/// Converts model validation errors raised while decoding into
/// [FormatException]s; [UnsupportedError]s propagate unchanged.
T _ipcGuard<T>(T Function() body) {
  try {
    return body();
  } on ArgumentError catch (error) {
    throw FormatException('Invalid Arrow IPC data: ${error.message}');
  } on StateError catch (error) {
    throw FormatException('Invalid Arrow IPC data: ${error.message}');
  }
}
