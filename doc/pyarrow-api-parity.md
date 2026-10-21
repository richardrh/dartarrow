# PyArrow-shaped Dart interface: implemented scope

Status: **approved breaking 0.2.0 interface; scoped independent API acceptance
passed**, researched against Apache Arrow/PyArrow **26.0.0**. The 176 executable
API cases pass; this establishes the tested scope, not complete PyArrow parity.
This is not full PyArrow, complete Arrow type coverage, or IPC interoperability.
The historical 0.1.0 tag/draft is unchanged.

## Current public interface

Import `package:dartaframes_arrow/arrow.dart` as `pa`. Its canonical public model
is `DataType`, `Field`, `Schema`, `Scalar`, `Array`, `Buffer`, `RecordBatch`,
`ChunkedArray`, and `Table`. The implementation is one native-independent Dart
library assembled from source parts; source files are not separate import APIs.
There are no obsolete Arrow-prefixed public classes or compatibility aliases.

```dart
import 'package:dartaframes_arrow/arrow.dart' as pa;

final a = pa.array([1, null, 3], type: pa.int32());
final valid = a[0].asDart(); // 1
final invalid = a[1].isValid; // false; type is still int32
final values = a.slice(1, 2).toDartList(); // [null, 3]
final batch = pa.recordBatch({'values': a});
final table = pa.table({'values': pa.chunkedArray([a.slice(0, 1), a.slice(1)])});
// batch.column('values') is Array; table.column('values') is ChunkedArray.
```

| PyArrow surface | Implemented Dart spelling | Contract |
| --- | --- | --- |
| `array`, `scalar` | `array`, `scalar` | Native-value inference or explicit dtype; typed null scalars. |
| dtype factories | `int32()`, `int64()`, `float64()`, `string()`, etc. | Parameterized types retain units, timezone and child fields. |
| keyword-conflicting factories | `boolType()`, `nullType()`, `listType(...)` | Single Dart spelling; no snake_case aliases. |
| `field`, `schema` | `field`, `schema` | Field objects or `(String, DataType)` records; ordered duplicate names. |
| scalar indexing / conversion | `a[i]`, `.asDart()`, `.toDartList()` | Indexing returns Scalar, including invalid typed values. |
| buffer import / access | `Array.fromBuffers(type, length, buffers, ...)`, `.buffers()` | Buffer objects, logical offset, children and dictionary. |
| tabular factories | `recordBatch`, `table`, named `fromArrays`, `fromDartMap`, `fromDartList` | Equal column lengths; explicit schema determines output. |
| chunked construction | `chunkedArray(chunks, {type})` | Homogeneous chunks; an empty collection requires type. |
| tabular properties | `.schema`, `.columns`, `.columnNames`, `.numRows`, `.numColumns`, `.length` | Table columns are always ChunkedArray; batch columns are Array. |
| column access | `.column(indexOrName)`, `operator []` | Ambiguous duplicate-name access fails; positional access preserves duplicates. |
| slicing / projection | `.slice([offset, length])`, `.select(...)` | Slices share storage; zero-column projection retains row count. |
| conversion | `.toDartMap()`, `.toDartList()` | Column-oriented map versus row maps; duplicate map names use last column. |
| chunk access | `.chunks`, `.numChunks`, `.chunk(i)`, `.combineChunks()` | No automatic flattening; combining can allocate. |
| batch/table conversion | `Table.fromBatches`, `.toBatches({maxChunkSize})` | Align existing unequal chunk boundaries without copying values. |
| casts / comparison | `.cast(..., safe: true)`, `.equals(...)` | Checked conversion, not physical reinterpretation. |
| schema metadata | `.withMetadata`, `.removeMetadata`, `.replaceSchemaMetadata` | Immutable byte-preserving metadata; default schema/field equality ignores metadata. |
| buffer conversion | `.size`, `.isMutable`, `.slice`, `.toBytes()` | Byte units; slices share storage and byte conversion copies. |

**Dart adaptation:** Array and ChunkedArray expose a lazy `.scalars`
`Iterable<Scalar>` rather than implementing Iterable themselves: Dart's generic
`Iterable.cast<R>()` conflicts with Arrow's `.cast(DataType, safe: ...)`.
Use `for (final scalar in values.scalars)` for typed iteration, and
`.toDartList()` for native values. No native `.toList()` alias is provided.

## Important implemented semantics

- Empty/all-null native sequences infer null type; ordinary integers infer int64,
  integer/float mixtures float64, booleans bool, strings UTF-8, and bytes binary.
  Explicit types preserve typed empty/all-null arrays. NaN is valid, not null.
- Names and schema are mutually exclusive. Metadata cannot accompany an explicit
  schema. Explicit mapping schemas ignore extra keys and reject missing named
  columns. Physical nulls are permitted under a nonnullable schema at construction,
  matching the PyArrow constructors rather than imposing a stronger contract.
- Field/schema names preserve duplicates and empty strings. `getFieldIndex` returns
  -1 for missing or ambiguous names; `getAllFieldIndices` returns every position.
  Name-based field/column lookup rejects ambiguity. Renaming drops schema metadata.
- Metadata accepts String or `Uint8List` keys/values and exposes immutable byte
  content lookup, not typed-list identity lookup. Null metadata and explicit empty
  metadata remain distinguishable as properties; equality treats them alike.
  `.equals(checkMetadata: true)` recursively checks field metadata as well.
- Scalar indexing supports negative indices. Slice offset and length must be
  nonnegative; oversized slices clamp to the available logical range.
- Tables retain independent chunk boundaries. Batch iteration can expose empty
  interior chunks; `maxChunkSize` is a positive upper bound, not a request to merge
  boundaries. Zero-column positive-row batches are representable through
  `RecordBatch.fromStructArray` and remain intact through slicing/projection.
- Dictionary scalars expose logical values rather than raw indices. Chunk
  combination preserves physical precision and unifies dictionary mappings;
  it does not concatenate through lossy native conversion.

## Dart precision contract

Python host types are not Dart host types. Native integer conversion returns
`int` where representable, otherwise `BigInt`. `DecimalValue` retains an unscaled
`BigInt` and scale and never becomes a double implicitly. Temporal `Scalar.value`
returns the exact raw counter as `int` or `BigInt` (null when invalid), while
`Scalar.type` retains its unit and timezone. `.asDart()` produces UTC
`DateTime` for exactly representable dates/timestamps and `Duration` for exactly
representable durations. Time-of-day, nanosecond remainders, IANA-zone timestamps,
and out-of-host-range values remain `TemporalValue`. `Scalar.rawBits` provides
exact floating-point IEEE bits; materializing a host double is a distinct operation.

## Migration and deliberate exclusions

Use `pa` to distinguish Arrow `pa.Scalar` from a Polars class with the same name.
Replace wrapper-value construction with native inputs to `pa.array`/`pa.scalar`,
schema-first batch construction with `RecordBatch.fromArrays(..., schema: ...)`,
and row/column count properties with `numRows`/`numColumns`. See the README's
migration guide. `OwnedBatchJsonCodec` and exact scalar JSON helpers live in the
optional `json.dart` import. Owned JSON is custom transport, **not Arrow IPC**;
binary metadata has explicit base64 encoding and legacy string metadata decodes.
The separate `arrow_c.dart` import supplies ABI declarations, not a native runtime.

No IPC reader/writer, dataset layer, or compute engine is implemented. Missing
families include maps, unions, intervals, fixed-size binary, view types, large
lists, and run-end encoding. `int128`/`uint128` are binding extensions, not standard
Arrow integer datatypes. Do not infer support from a familiar factory name or a
successful supported-scope fixture run. Unsupported capabilities stay explicit.

## Evidence and sources

Public tests exercise the array/scalar/schema/table seams. The independent oracle
pins PyArrow 26.0.0 and keeps missing inventory separate from failures. Human-readable
pretty-print output is not the contract. Physical layouts, native conversion,
metadata, errors, chunk boundaries, and shared-storage slicing are separate checks.

Observed final acceptance: `build/api-conformance.json` reports **176 passed,
0 failed**. The throwaway corrupted-oracle CLI exits 1 and
`build/api-negative.json` reports **175 passed, 1 failed**, specifically the
corrupted `infer.empty` expectation. The separate physical pipeline reports
**238 passed, 18 explicitly missing, 0 failed**, versus the prior 237/19
inventory: only `decimal128.negativeScale` was promoted after its full
foreign/slice/owned/JSON checks passed. API regeneration twice produced
byte-identical fixtures. These counts do not turn explicitly missing types
into supported capabilities.
The final QA owner additionally reports **234 package tests passed**, with
formatting and analysis clean. Scalar equality/casts and encoded array/chunk
dictionary equality are included in the independent API inventory; NaN,
signed zero, typed null, nested types and remapped dictionaries are compared
without assuming decoded-equal dictionaries are encoded-equal.

Public `Array.isValid()` and `isNull({nanIsNull: false})` return Boolean Arrays;
ChunkedArray counterparts return ChunkedArrays, not per-index booleans.
Use `a[i].isValid` for scalar/index validity. NaN remains valid unless explicitly
included by `nanIsNull`. PyArrow's dictionary mask operations treat null
dictionary values as null, independently of the encoded index's validity.
The tested chunked mask operations drop empty input chunks. Nested nonnullable
field annotations do not reject existing child nulls, including during full
validation, matching the separately pinned PyArrow constructor cases.

### Independent API acceptance format and observed cases

`tool/conformance/generate_api_fixtures.py` runs real pinned PyArrow 26.0.0
and writes deterministic `test/conformance/fixtures/api_pyarrow.json`.
Each record has `id`, recursive `input` expression, and `expected`, containing
either `ok` with a normalized public result or `error` with a meaningful
argument/range/type/conversion category. No Dart source participates in oracle
generation. Native input tags distinguish bytes (`$bytes`), arbitrary-width
integers (`$int`), decimal (`$decimal`), datetime (`$datetime`), exact temporal
counters (`$temporal`), and floating bits (`$float`). These are explicit
host-language adaptations, not claims that Python containers map unchanged.

The Dart runner checks type structure, scalar validity and native conversion,
dictionary indices and decoded values, column return kinds, metadata bytes,
chunk boundaries, and row counts. It checks `.scalars` against typed indexing,
while both are compared to independent scalar expectations. Physical fixtures
remain a separate pipeline. Corrupting API expected output must make the
differential comparison fail.

Type comparison explicitly normalizes semantic descriptor spellings:
UTF-8 `string`/`utf8`, timestamp `datetime`/`timestamp`, and field
`dtype`/`type` denote the same type. Widths, units, timezones, child fields,
nullability and dictionary ordering remain compared. Nested descriptor
metadata absence becomes an empty map for that descriptor convention;
public Field/Schema properties separately distinguish null from empty.
Native NaN materialization is compared as valid NaN; independent `rawBits`
checks retain exact payloads, including half NaN `0x7e01`. Error categories
depend only on actual Dart exception types, not IDs, operations or messages.

Observed with PyArrow 26.0.0, not inferred from old Dart defaults:

- `array(['bad', 2], mask=[True, False])` infers int64 `[null, 2]`;
  masked inputs are excluded from inference and conversion. `size=1` is a hint
  for list `[1,2,3]`, but truncates an iterator to `[1]`.
- Empty/all-null input infers null. Mixed int/float infers double; mixed
  bool/int fails conversion. Struct field order follows first key encounter,
  not sorted names; missing keys become null. Mixed bytes/strings infer binary
  with strings encoded as UTF-8, in either order.
- `safe=False` construction still rejects int8 overflow and inexact integer
  conversion to floating point. Unsafe casts wrap int8 `128` to `-128`
  and truncate `1.5` to integer `1`.
- Negative array indices wrap, but out-of-range indices fail. Array slices
  clamp oversized offsets/lengths; negative offset is a range error, negative
  length an argument error. Buffer slices do not clamp excessive length.
- Typed empty chunk vectors have zero chunks; untyped empty vectors fail.
  An interior empty chunk remains observable in a slice crossing it.
  Unaligned table chunk boundaries affect batches; `maxChunkSize` must be
  positive. Zero-column projection retains positive row count.
- A nonnullable schema does not cause array/table construction to reject
  existing nulls. Duplicate empty names remain positional; ambiguous name
  lookup fails, `getFieldIndex` is -1, and `getAllFieldIndices` returns all positions.
- Absent metadata is null and explicit empty metadata is an empty map.
  Default Field/Schema equality ignores metadata; metadata-aware equality
  treats absent/empty alike but distinguishes nonempty maps. Arbitrary
  bytes, including NUL and invalid UTF-8, are preserved.
- `array(existingArray)` preserves type and ignores mask and size options;
  an explicit different type casts. `array(existingChunkedArray)` returns
  an Array, flattening chunks, ignores size but applies mask. With observed
  int16 input and explicit int32, PyArrow rejects scalar append conversion
  rather than casting. These paths have separate cases. Typed scalar/null
  sequences retain their type; `scalar(existingScalar)` preserves its type.
  Raw half-NaN scalar inputs preserve exact bits through reconstruction
  without passing through host doubles.

Factory and object contracts are documented in the primary references below.
Supplemental pinned sources cover inference and precision details:
[official inference implementation](https://github.com/apache/arrow/blob/apache-arrow-26.0.0/python/pyarrow/src/arrow/python/inference.cc),
[official conversion tests](https://github.com/apache/arrow/blob/apache-arrow-26.0.0/python/pyarrow/tests/test_convert_builtin.py),
[CastOptions](https://arrow.apache.org/docs/python/generated/pyarrow.compute.CastOptions.html),
[DictionaryScalar](https://arrow.apache.org/docs/python/generated/pyarrow.DictionaryScalar.html).


- [PyArrow array](https://arrow.apache.org/docs/python/generated/pyarrow.array.html)
- [Scalar](https://arrow.apache.org/docs/python/generated/pyarrow.Scalar.html)
- [Field](https://arrow.apache.org/docs/python/generated/pyarrow.Field.html)
- [Schema](https://arrow.apache.org/docs/python/generated/pyarrow.Schema.html)
- [RecordBatch](https://arrow.apache.org/docs/python/generated/pyarrow.RecordBatch.html)
- [Table](https://arrow.apache.org/docs/python/generated/pyarrow.Table.html)
- [ChunkedArray](https://arrow.apache.org/docs/python/generated/pyarrow.ChunkedArray.html)
- [Buffer](https://arrow.apache.org/docs/python/generated/pyarrow.Buffer.html)
- [Arrow columnar format](https://arrow.apache.org/docs/format/Columnar.html)
