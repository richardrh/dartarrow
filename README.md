# dartarrow

A PyArrow-style API for [Apache Arrow](https://arrow.apache.org/) in pure Dart.

If you know `pyarrow`, the core will feel familiar: `pa.array`, `pa.schema`,
`pa.table`, `ipc.openStream`. Same object model, Dart spelling. No native
library, no runtime dependencies beyond a pure Dart compression package.

It covers PyArrow's in-memory data model and Arrow IPC. It is not a port of
all of PyArrow: see [Scope](#scope).

[Guide](https://richardrh.github.io/dartarrow/) ·
[API reference](https://richardrh.github.io/dartarrow/api/) ·
[PyArrow parity](doc/pyarrow-api-parity.md) ·
[Changelog](CHANGELOG.md)

## Install

```sh
dart pub add dartarrow
```

## Usage
The API looks like PyArrow but in Dart.

```dart
import 'package:dartarrow/arrow.dart' as pa;
import 'package:dartarrow/ipc.dart' as ipc;

void main() {
  final values = pa.array([10, null, 30], type: pa.int32());
  print(values[1].isValid);            // false: a typed int32 null Scalar
  print(values.slice(1, 2).toDartList()); // [null, 30]

  final table = pa.table({
    'id': pa.chunkedArray([values.slice(0, 1), values.slice(1)]),
  });

  // Arrow IPC round trip (format V5, in memory)
  final bytes = (ipc.newStream(table.schema)..writeTable(table)).close();
  print(ipc.openStream(bytes).readAll().numRows); // 3
}
```

More in [`example/`](example/).

## Features

| Area | Support |
| --- | --- |
| Types | All standard Arrow logical types: primitives, decimals 32–256, UTF-8/binary (incl. views), temporal, intervals, lists, structs, maps, unions, run-end, dictionaries, extensions |
| Objects | `Array`, `Scalar`, `Schema`, `Field`, `RecordBatch`, `ChunkedArray`, `Table` |
| IPC | Arrow IPC V5 streams and files over in-memory bytes, zero-copy reads, LZ4_FRAME and ZSTD decompression; writes are uncompressed |
| C ABI | `CArrowSchema`, `CArrowArray`, `CArrowArrayStream` struct layouts via `dart:ffi` (`arrow_c.dart`) |
| Platforms | Dart VM, dart2js and dart2wasm (ZSTD decompression and `arrow_c.dart` are VM-only) |

Verified against PyArrow 26.0.0 fixtures, including IPC interop in both
directions.

## Scope

dartarrow is the Arrow data model plus IPC. PyArrow features that are **not**
here:

- Compute: no `take`, `filter`, `sort`, aggregation, `group_by` or joins. Only
  `cast`, `isNull`/`isValid`, `equals`, slicing and concatenation.
- Column editing on tables and batches (`append_column`, `drop_columns`, ...);
  `select`, `renameColumns` and `slice` are available.
- File formats and services: Parquet, CSV, Arrow JSON, ORC, datasets,
  filesystems, Flight.
- Streaming I/O: readers and writers work on a complete `Uint8List`; file and
  socket access is left to the caller. IPC compression on write, write options
  and custom footer metadata are not available.
- C Data Interface import/export: `arrow_c.dart` only declares the structs.
- Pretty-printing: `print(table)` shows `Instance of 'Table'`; use
  `toDartMap()` or `toDartList()`.

[PyArrow parity](doc/pyarrow-api-parity.md) lists the implemented surface and
the known behavioural differences.

## Dart-specific behaviour

- Wide integers use `BigInt`; decimals keep an unscaled `BigInt` and scale, never a `double`.
- `Array` does not implement `Iterable` (its `cast<R>()` clashes with Arrow's `cast(type)`). Use `values.scalars` or `values.toDartList()`.
- `Array.fromBuffers` borrows memory. Keep buffers alive and unmutated while arrays or slices exist.
- IPC readers enforce `IpcLimits`. The defaults (about one million rows per
  array and four million values per reader) reject larger inputs with a
  `FormatException` that names the limit; pass `limits:` for bigger trusted data.
- Under dart2js, integers beyond 2^53 are returned as `BigInt`, and
  whole-number doubles such as `1.0` are indistinguishable from integers, so
  `pa.array([1.0])` infers `int64` there. Pass an explicit type when it matters.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the PyArrow conformance workflow.

## License

[Apache-2.0](LICENSE)
