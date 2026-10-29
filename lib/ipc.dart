/// Apache Arrow IPC (columnar format V5) streams and files, shaped like
/// PyArrow's `pyarrow.ipc` module. Import with a prefix:
///
/// ```dart
/// import 'package:dartaframes_arrow/ipc.dart' as ipc;
///
/// final writer = ipc.newStream(table.schema)..writeTable(table);
/// final bytes = writer.close();
/// final roundTrip = ipc.openStream(bytes).readAll();
/// ```
///
/// Readers and writers work on in-memory bytes. Readers return zero-copy
/// views over uncompressed bodies, decode LZ4_FRAME and ZSTD compressed
/// bodies (LZ4 only on the web), support dictionary replacement and delta
/// batches in streams, and are bounded by [IpcLimits]. Writers emit
/// uncompressed little-endian V5 output.
///
/// Errors: malformed input raises [FormatException]; valid input using an
/// unsupported feature (big-endian data, unknown types or codecs) raises
/// [UnsupportedError]. Writers raise [UnsupportedError] for types without a
/// standard IPC encoding (binding `int128`/`uint128`) and [ArgumentError] for
/// invalid input such as a mismatched batch schema.
library dartaframes_arrow_ipc;

export 'src/core.dart'
    show
        IpcLimits,
        RecordBatchFileReader,
        RecordBatchFileWriter,
        RecordBatchStreamReader,
        RecordBatchStreamWriter,
        newFile,
        newStream,
        openFile,
        openStream;
