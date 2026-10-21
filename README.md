# dartaframes_arrow

Buffer-backed Apache Arrow arrays, schemas, logical values, and owned JSON for
Dart. This standalone repository maintains package `dartaframes_arrow` version
0.1.0 independently of Polars.

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
import 'package:dartaframes_arrow/arrow.dart';

void main() {
  final type = ArrowIntegerType(32);
  final array = ArrowArray(type, [
    ArrowIntegerValue(10),
    null,
    ArrowIntegerValue(30),
  ]);
  final batch = RecordBatch(
    ArrowSchema([ArrowField('value', type)]),
    [array],
  );
  print(batch.slice(1).length);
}
```

The core library has no runtime dependencies, native library, Polars dependency,
or native build hook. See [the guide source](https://github.com/richardrh/dartarrow/blob/main/doc/site/index.html)
and the [executable example](https://github.com/richardrh/dartarrow/blob/main/example/arrow.dart).
The documentation deployment is built for
<https://richardrh.github.io/dartarrow/> with a generated API reference.

## Ownership and scope

Logical-value construction copies values into owned physical buffers.
`ArrowArray.fromBuffers` borrows existing buffers: keep their allocation alive
and do not mutate any aliases for the lifetime of the array or its slices.
Slices share backing buffers. Read-only views cannot protect against mutation
through the original borrowed allocation.

Supported families include null, booleans, integers, floating-point raw bits,
decimal128, UTF-8/binary with normal or large offsets, dates, times, timestamps,
durations, lists, fixed-size lists, structs, dictionaries, and extension storage.
`int128`/`uint128` are binding extensions, not Apache Arrow integer datatypes.
This is **not complete Arrow specification support**: maps, unions, intervals,
fixed-size binary, list/string/binary views, large lists, and run-end encoding
are unsupported. There is no Arrow IPC reader/writer or compute engine.
`OwnedBatchJsonCodec` is a logical JSON transport, not Arrow IPC; it rejects
nested dictionary encoding.

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
```

PyArrow is pinned to 26.0.0. Committed fixtures are deterministic independent
physical-layout and logical-value expectations. Legacy interval fixtures are
explicit Arrow-format literals, not claimed PyArrow output. The report keeps
`missing` distinct from `fail`: default mode fails actual assertion failures;
`--require-full` also fails missing capabilities. A green supported-scope test
run does not claim every Arrow datatype exists.

## Migration and release policy

Import `package:dartaframes_arrow/arrow.dart` explicitly instead of the removed
Polars Arrow entrypoint or transitive Polars exports. Import `arrow_c.dart`
explicitly for `CArrowArray`, `CArrowSchema`, and `CArrowArrayStream`. There are
no forwarding libraries or private cross-repository test dependencies.

Releases are manual and GitHub-first: validate an exact `main` commit with green
CI, create its matching annotated version tag, then dispatch the release
workflow with `tag: v0.1.0`. The workflow requires that existing tag and produces
a **draft** GitHub release with a validated package-source archive and SHA-256
checksums.
Review the CI evidence and archive before publishing that draft. The package
is pure Dart; no Rust binary distribution is needed. No workflow publishes to
pub.dev and no pub.dev publishing credentials are configured by this project.
A hosted release requires a separate explicit maintainer decision after review.

Primary references: [Arrow columnar format](https://arrow.apache.org/docs/format/Columnar.html),
[Arrow C Data interface](https://arrow.apache.org/docs/format/CDataInterface.html),
[Dart Git dependencies](https://dart.dev/tools/pub/dependencies#git-packages),
[Dart package validation](https://dart.dev/tools/pub/cmd/pub-lish), and
[GitHub draft releases](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

Licensed under [Apache-2.0](https://github.com/richardrh/dartarrow/blob/main/LICENSE).
