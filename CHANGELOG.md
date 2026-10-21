# Changelog

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
