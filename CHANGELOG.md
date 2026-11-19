# Changelog

## 0.3.0

First release on pub.dev.

- **Breaking:** rename the package from `dartaframes_arrow` to `dartarrow`.
  Update dependencies and imports to `package:dartarrow/...`.
- Add the remaining standard Arrow logical types with PyArrow-style factories:
  fixed-size binary (`binary(n)`), `stringView`/`binaryView`, `largeList`,
  `listView`/`largeListView`, `decimal32`/`decimal64`/`decimal256` (any signed
  32-bit scale), `mapType`, `sparseUnion`/`denseUnion`/`union`, intervals
  (`IntervalType`, `monthDayNanoInterval`, exact `IntervalValue`), and
  `runEndEncoded`. All are buffer-backed: `Array.fromBuffers` validation,
  scalars, zero-copy slices, concatenation, equality, owned JSON, casts and
  native construction where PyArrow supports it. New `Array.fromRunEnds`,
  `Array.fromSparseUnion` and `Array.fromDenseUnion` build encoded arrays from
  child arrays. Decimal inference widens to `decimal256` beyond 38 digits.
- Add standard Arrow IPC V5 streams and files in the separate `ipc.dart` import,
  shaped like `pyarrow.ipc` (`openStream`, `openFile`, `newStream`, `newFile`,
  `RecordBatchStream/FileReader/Writer`, `IpcLimits`): zero-copy reads of
  uncompressed bodies, writes directly from physical buffers (slices rebased),
  LZ4_FRAME/ZSTD decompression on the VM via pure Dart `libcompress` and LZ4_FRAME
  on the web, nested and extension dictionaries, stream dictionary replacement
  and deltas, schema/field/custom metadata as bytes, bounded decoding, and
  PyArrow 26 fixtures verified in both directions. Core 64-bit buffer access is
  now dart2js-safe.
- Owned JSON decoding now requires canonical decimal-integer strings and
  exact-width `floatBits`, bounding hostile input before parsing.
- Every physical PyArrow 26 fixture family is now supported; CI runs the
  conformance probe with `--require-full`.
- **Breaking:** casts follow PyArrow. Decimal to string yields Arrow decimal
  text (`1.23`, `5E+2`) instead of `DecimalValue(...)`; float to string yields
  Arrow's shortest form (`1`, `nan`, `1e+16`); timestamp to date32/date64 floors
  to the day (also before 1970 and with `safe: true`) and uses the zone-local
  date for UTC and fixed `±HH:MM` zones, raising `ArrowInvalid` for malformed
  offsets and `UnsupportedError` for zone names that need a time zone
  database; time/duration/timestamp reinterpretation casts throw
  `UnsupportedError`; string to number accepts only Arrow's spellings; a
  dictionary cast keeps the requested index type or raises `ArrowInvalid`.
- **Breaking:** a `DateTime` given to `date32`/`date64` stores its own calendar
  date regardless of the machine's time zone, and date64 values are whole days.
  A host value of the wrong kind for an explicit type raises the same
  `ArrowInvalid` or `ArrowTypeError` as PyArrow instead of `UnsupportedError`.
- **Breaking:** `Array.fromSparseUnion` requires children as long as `typeIds`,
  and `fromBuffers`/`validate` reject sparse unions whose children do not cover
  `offset + length`; such arrays previously misaligned rows in `concatArrays`.
- Fix large list-view validation accepting overflowing `offset + size`, 32-bit
  offset overflow when building or concatenating string/binary data beyond
  2 GiB, and `fromBuffers` rejecting the `[null]` that `buffers()` returns for
  the null type.
- `concatArrays` and `ChunkedArray.combineChunks` unify dictionaries in linear
  rather than quadratic time, by value representation: NaN entries unify and
  `-0.0` no longer merges into `0.0`. A dictionary shared by every input is
  reused.
- `ByteMetadata.containsKey`/`containsValue` compare by content, like
  `operator []`; they previously always returned false.
- Owned JSON decoding rejects null fixed-size list/binary slots whose declared
  width would expand past the codec limits instead of exhausting memory.
- IPC writers are atomic: a `writeBatch`/`writeTable` call that throws writes
  nothing and leaves dictionary state unchanged, so a later `close()` still
  produces a valid file.
- IPC readers raise `UnsupportedError` (not `FormatException`) for metadata
  versions before V5, accept compressed buffers declaring length 0, and name
  the exceeded `IpcLimits` field in limit errors.
- Harden IPC readers against small inputs that expand: decoded metadata
  strings and the data referenced by `string_view`/`binary_view` columns count
  against `IpcLimits.maxMessageBytes` even when offsets alias one value, file
  footers whose blocks repeat or overlap are rejected, and the new
  `IpcLimits.maxDecompressedBytes` (default 256 MiB) bounds decompressed
  buffers per read. The limits bound decoding, not later materialization of
  columns that share values, and do not replace process isolation.
- Upgrade `libcompress` to 2.x, which decodes ZSTD bodies that 1.x rejected or
  could exhaust memory on.
- On dart2js, integers and temporal counters beyond 2^53 are returned as
  `BigInt` instead of being rounded; infinities, `-0.0` and whole numbers
  outside the 64-bit integer range infer float64. CI now runs the whole test
  suite under dart2js and dart2wasm.
- `arrow_c.dart` exports its `dart:ffi` structs only where `dart:ffi` exists,
  so the package analyses as web and WASM compatible.
- Pushing a `v<version>` tag publishes to pub.dev and creates the GitHub
  release.

## 0.2.0

- Breaking clean cutover to a PyArrow-shaped Dart interface: `DataType`, `Array`,
  `Scalar`, `Buffer`, `Field`, `Schema`, `RecordBatch`, `ChunkedArray`, and `Table`.
  Removed Arrow-prefixed public classes and wrapper-value construction; no aliases.
- Add native-value factories, typed null scalar indexing, explicit native
  conversion, safe casts, byte-preserving metadata, and ordered duplicate fields.
- Add real chunked columns, cross-chunk slicing, aligned record batches,
  lossless chunk combination, and zero-column height preservation.
- Add typed scalar equality/hashing and casts, encoding-aware dictionary equality,
  and visible-span list/struct casts. Nullability remains a schema declaration:
  nested physical nulls are accepted and fully validated as in PyArrow.
- Preserve parent struct nulls in `RecordBatch.fromStructArray`, intersecting
  validity with each visible child while sharing exact value/dictionary storage.
- Encode ordinary native primitives directly into owned buffers, retain exact
  typed-scalar IEEE payloads, and reject overflowing chunk-length accumulation.
- Keep the core independent of native libraries. Owned JSON is available through
  the separate `json.dart` import; it remains a custom transport, not Arrow IPC.
- The existing 0.1.0 tag/draft is unchanged; this is a new breaking main revision,
  not a claim of pub.dev publication or full PyArrow support.

## 0.1.0

- Extract the existing pure Dart Arrow arrays, schemas, values, and owned JSON
  interface from the Polars bindings, without changing supported behavior.
- Provide optional standard C Data and C Stream ABI declarations in arrow_c.dart.
- Move the package into its standalone `richardrh/dartarrow` repository with
  independent dependency locking, checks, documentation, and manual GitHub
  draft release validation. No workflow publishes to pub.dev.
- Report missing capabilities separately from failures in the fixture probe;
  add optional `--require-full` mode to reject missing inventory entries.
