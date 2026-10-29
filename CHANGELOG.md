# Changelog

## Unreleased

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
  interface from dartaframes_polars, without changing supported behavior.
- Provide optional standard C Data and C Stream ABI declarations in arrow_c.dart.
- Move the package into its standalone `richardrh/dartarrow` repository with
  independent dependency locking, checks, documentation, and manual GitHub
  draft release validation. No workflow publishes to pub.dev.
- Report missing capabilities separately from failures in the fixture probe;
  add optional `--require-full` mode to reject missing inventory entries.
