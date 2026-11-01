# dartarrow

A PyArrow-style API for [Apache Arrow](https://arrow.apache.org/) in pure Dart.

If you know `pyarrow`, you already know this: `pa.array`, `pa.schema`,
`pa.table`, `ipc.openStream`. Same object model, Dart spelling. No native
library, no runtime dependencies beyond a pure Dart compression package.

[Guide](https://richardrh.github.io/dartarrow/) ·
[API reference](https://richardrh.github.io/dartarrow/api/) ·
[PyArrow parity](doc/pyarrow-api-parity.md) ·
[Changelog](CHANGELOG.md)

## Install

```yaml
dependencies:
  dartarrow:
    git:
      url: https://github.com/richardrh/dartarrow.git
      ref: main # pin a full commit SHA for reproducible builds
```

Not yet published to pub.dev.

## Usage

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
| IPC | Arrow IPC V5 streams and files, zero-copy reads, LZ4_FRAME and ZSTD decompression |
| C ABI | `CArrowSchema`, `CArrowArray`, `CArrowArrayStream` struct layouts via `dart:ffi` (`arrow_c.dart`) |
| Platforms | Dart VM and web (ZSTD is VM-only) |

Not included: compute kernels, datasets, Parquet/CSV.

Verified against PyArrow 26.0.0 fixtures, including IPC interop in both
directions.

## Dart-specific behaviour

- Wide integers use `BigInt`; decimals keep an unscaled `BigInt` and scale, never a `double`.
- `Array` does not implement `Iterable` (its `cast<R>()` clashes with Arrow's `cast(type)`). Use `values.scalars` or `values.toDartList()`.
- `Array.fromBuffers` borrows memory. Keep buffers alive and unmutated while arrays or slices exist.

## Development

```sh
mise run check   # format, analyze, test, example, publish dry-run
mise run docs    # build the guide and API reference into build/site
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the PyArrow conformance workflow.

## License

[Apache-2.0](LICENSE)
