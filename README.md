# dartaframes_arrow

Pure Dart Arrow arrays, typed scalars, schemas, record batches, and chunked tables.
This standalone repository develops package `dartaframes_arrow` version 0.2.0
independently of Polars. The interface follows PyArrow's core object model,
with Dart spelling and explicit precision-preserving native conversions.

## Install and use

The initial delivery is GitHub-first. Until a maintainer explicitly publishes a
hosted version, use a Git dependency; pin `ref` to a reviewed full commit for
reproducible applications. This development example follows `main`:

```yaml
dependencies:
  dartaframes_arrow:
    git:
      url: https://github.com/richardrh/dartarrow.git
      ref: main
```

```dart
import 'package:dartaframes_arrow/arrow.dart' as pa;

void main() {
  final values = pa.array([10, null, 30], type: pa.int32());
  print(values[1].isValid); // false: still a typed int32 Scalar
  print(values[0].asDart()); // 10
  print(values.slice(1, 2).toDartList()); // [null, 30]
  final batch = pa.recordBatch({'value': values});
  final table = pa.table({
    'value': pa.chunkedArray([values.slice(0, 1), values.slice(1)]),
  });
  print(batch.column('value') is pa.Array); // true
  print(table.column('value') is pa.ChunkedArray); // true
  print(table.toBatches(maxChunkSize: 2).map((b) => b.numRows));
}
```

The core library has no runtime dependencies, native library, Polars dependency,
or native build hook. See [the guide source](https://github.com/richardrh/dartarrow/blob/main/doc/site/index.html)
and the [executable example](https://github.com/richardrh/dartarrow/blob/main/example/arrow.dart).
The documentation deployment is built for
<https://richardrh.github.io/dartarrow/> with a generated API reference.

## Ownership and scope

Logical-value construction copies values into owned physical buffers.
`Array.fromBuffers(type, length, buffers, ...)` borrows `Buffer` objects: keep
their allocations alive and do not mutate aliases while arrays or slices exist.
Slices share backing buffers. Read-only views cannot protect against mutation
through the original borrowed allocation.

Supported families include null, booleans, integers, floating-point raw bits,
decimal128, UTF-8/binary with normal or large offsets, dates, times, timestamps,
durations, lists, fixed-size lists, structs, dictionaries, and extension storage.
`bindingInt128()`/`bindingUint128()` are binding extensions, not Apache Arrow integer datatypes.
This is **not complete Arrow specification support**: maps, unions, intervals,
fixed-size binary, list/string/binary views, large lists, and run-end encoding
are unsupported. There is no Arrow IPC reader/writer or compute engine.
Import `package:dartaframes_arrow/json.dart` for `OwnedBatchJsonCodec`, a custom
logical JSON transport, not Arrow IPC; nested dictionary encoding is rejected.

Optional `package:dartaframes_arrow/arrow_c.dart` exposes standard Arrow C Data
and C Stream ABI structs using `dart:ffi`. It does not allocate or release
foreign buffers and does not supply Polars-owned handles or a runtime.

## Independent development

Use Dart 3.13.0 (pinned in `mise.toml`), then:

```sh
dart pub get --enforce-lockfile
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test --coverage=coverage
dart run example/arrow.dart
mkdir -p build
dart compile exe example/arrow.dart -o build/arrow-example
./build/arrow-example
python3 tool/build_docs.py
dart pub publish --dry-run
```

The tests require no native library or source from the Polars repository. CI
runs these package checks and retains coverage/conformance evidence. Changes to
Arrow support must preserve explicit unsupported cases, not convert rejection
into a claimed passing capability.

### Independent PyArrow oracle

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tool/conformance/requirements.txt
.venv/bin/python tool/conformance/generate_fixtures.py
git diff --exit-code -- test/conformance/fixtures/pyarrow.json
mkdir -p build
dart run test/conformance/dart_probe.dart --output build/conformance.json
# Optional strict inventory check: currently missing families make this fail.
dart run test/conformance/dart_probe.dart --require-full
# Independently regenerate the public behavior oracle and compare exactly.
.venv/bin/python tool/conformance/generate_api_fixtures.py --output /tmp/api_pyarrow.json
cmp test/conformance/fixtures/api_pyarrow.json /tmp/api_pyarrow.json
dart run test/conformance/api_probe.dart --output build/api-conformance.json
dart test test/conformance/api_conformance_test.dart
```

PyArrow is pinned to 26.0.0. Committed fixtures are deterministic independent
physical-layout and logical-value expectations. Legacy interval fixtures are
explicit Arrow-format literals, not claimed PyArrow output. The report keeps
`missing` distinct from `fail`: default mode fails actual assertion failures;
`--require-full` also fails missing capabilities. A green supported-scope test
run does not claim every Arrow datatype exists.

The public API oracle separately checks construction, scalar conversion, casts,
metadata, masks, errors, and chunk/tabular behavior against PyArrow. It is not
the physical type/layout support matrix: its probe requires every declared
behavior case to pass, while the physical report separately inventories missing
families. The API acceptance test also rejects deliberately corrupted expected
data, ensuring the independent oracle is actually consulted.

## Migration and release policy

### From 0.1.0 / Polars

This is a breaking cutover, not an alias layer. Import
`package:dartaframes_arrow/arrow.dart` as `pa`. Replace Arrow-prefixed classes
with `DataType`, `Field`, `Schema`, `Array`, `Scalar`, and `Buffer`; construct
ordinary values with `pa.array([...], type: pa.int32())` rather than public
logical-value wrappers. Replace schema-first batch construction with
`pa.RecordBatch.fromArrays(arrays, schema: schema)` or `pa.recordBatch(map)`.
Use `.numRows`/`.numColumns`, `.column(indexOrName)`, and `.slice(offset, length)`.
Indexing always returns a typed `Scalar`, including null: use `.isValid` and
`.asDart()`, or materialize an entire array with `.toDartList()`.
Scalars provide typed value equality (`.equals` and `==`, with consistent hashes)
and checked `.cast(type, safe: true)`. NaN is unequal to itself; signed zeros
compare equal. Dictionary equality retains mapping/index identity rather than
discarding encoding differences with identical decoded values.
For arrays and chunked arrays, `.isValid()` and `.isNull(nanIsNull: false)`
return non-null Boolean masks. For individual elements, use `values[i].isValid`.
Dictionary masks include decoded dictionary nulls; scalar validity retains the
encoded index's validity, matching PyArrow's distinction.

Use the single lowerCamelCase factory spelling: `pa.field`, `pa.schema`,
`pa.recordBatch`, `pa.table`, `pa.chunkedArray`, `pa.scalar`, `pa.int32()`,
`pa.string()`, `pa.boolType()`, `pa.nullType()`, and `pa.listType(...)`.
There are no snake_case aliases or obsolete class re-exports. When importing
Polars too, prefix Arrow imports with `pa`: Arrow's `pa.Scalar` is not the
Polars expression/value class of the same name.

Table columns are always `ChunkedArray`, not a `RecordBatch` typedef. Chunk
boundaries remain intact until `.combineChunks()` is requested.
`Field` and `Schema` preserve ordered, duplicate, and empty field names.
Metadata accepts String or `Uint8List` keys/values and exposes immutable
byte-keyed content lookup; absent metadata remains distinct from explicit
empty metadata. `.equals(checkMetadata: true)` includes metadata; the default
ignores it. Ambiguous name lookup fails instead of selecting the first field.

Use the separate `json.dart` import for owned JSON, and `arrow_c.dart` for
`CArrowArray`, `CArrowSchema`, and `CArrowArrayStream`. Neither is required by
the native-independent core. No forwarding Polars entrypoint remains.

**Dart adaptation:** `Array` and `ChunkedArray` do not implement `Iterable`,
because its generic `cast<R>()` conflicts with Arrow's dtype-based `.cast(type)`.
Iterate typed scalars lazily with `for (final scalar in values.scalars)`;
use `.toDartList()` for native values. There is no native `.toList()` alias.

### Precision and native conversion

Native conversion is deliberately not Python's host-type conversion:
wide integer values use `BigInt` where needed rather than lossy doubles.
`DecimalValue` preserves an unscaled `BigInt` and scale; decimals never become
doubles. Temporal `Scalar.value` exposes the exact raw `int`/`BigInt` counter;
`Scalar.type` retains units and timezone.
`.asDart()` returns UTC `DateTime` for exactly representable dates/timestamps and
`Duration` for exactly representable durations. Time-of-day, nanosecond remainders,
IANA-zone timestamps, and out-of-host-range values remain `TemporalValue`.
Binary values remain bytes; floating-point NaN remains valid, not null.

Releases are manual and GitHub-first: validate an exact `main` commit with green
CI, create its matching annotated version tag, then dispatch the release
workflow with the new revision's matching tag (for this version, `v0.2.0`).
The workflow requires that existing tag and produces a **draft** GitHub release
with a validated package-source archive and SHA-256 checksums.
Review the CI evidence and archive before publishing that draft. The package
is pure Dart; no Rust binary distribution is needed. No workflow publishes to
pub.dev and no pub.dev publishing credentials are configured by this project.
A hosted release requires a separate explicit maintainer decision after review.
The existing `v0.1.0` tag and draft are immutable historical artifacts; do not
retag or overwrite them for this interface change.

Primary references: [Arrow columnar format](https://arrow.apache.org/docs/format/Columnar.html),
[Arrow C Data interface](https://arrow.apache.org/docs/format/CDataInterface.html),
[Dart Git dependencies](https://dart.dev/tools/pub/dependencies#git-packages),
[Dart package validation](https://dart.dev/tools/pub/cmd/pub-lish), and
[GitHub draft releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

Licensed under [Apache-2.0](https://github.com/richardrh/dartarrow/blob/main/LICENSE).
