// Dart half of the PyArrow interoperability loop.
//
// Reads every committed PyArrow fixture in test/conformance/fixtures/arrow_ipc with the
// public dartaframes_arrow IPC readers (PyArrow -> Dart), then re-encodes the
// decoded table with the public writers into an output directory mirroring
// `<family>/<name>.arrow|.arrows`. `tool/conformance/arrow_ipc_interop.py verify` then reads
// those files with PyArrow and compares them to the PyArrow expectations
// (Dart -> PyArrow), so a pass means real interoperability rather than a Dart
// self-round-trip.
//
// Usage:
//   dart run tool/conformance/arrow_ipc_interop.dart --out build/arrow_ipc_dart [--only family]
//   .venv/bin/python tool/conformance/arrow_ipc_interop.py verify \
//        --output build/arrow_ipc_dart
//
// Fixtures the Dart codec rejects (UnsupportedError/FormatException) are
// reported as UNSUPPORTED/READ-FAIL and simply not written; the Python
// verifier then lists them as MISSING. Exit code is 1 only for unexpected
// errors (anything other than an explicit UnsupportedError), or for any
// failure when `--strict` is given.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartaframes_arrow/arrow.dart';
import 'package:dartaframes_arrow/ipc.dart' as ipc;

const _extensions = {'file': '.arrow', 'stream': '.arrows'};

/// Fixtures that are expected to be rejected (see _knownGaps in
/// test/ipc_interop_test.dart); they are reported but do not fail the run.
const _knownGaps = {'extension/binary_metadata'};

Future<void> main(List<String> args) async {
  var out = 'build/arrow_ipc_dart';
  var fixtures = 'test/conformance/fixtures/arrow_ipc';
  var strict = false;
  final only = <String>{};
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--out':
        out = args[++i];
      case '--fixtures':
        fixtures = args[++i];
      case '--only':
        only.add(args[++i]);
      case '--strict':
        strict = true;
      case '-h' || '--help':
        stdout.writeln(
          'dart run tool/conformance/arrow_ipc_interop.dart [--out DIR] [--fixtures DIR] '
          '[--only FAMILY]... [--strict]',
        );
        return;
      default:
        stderr.writeln('unknown argument: ${args[i]}');
        exitCode = 64;
        return;
    }
  }

  final manifest = jsonDecode(
    File('$fixtures/manifest.json').readAsStringSync(),
  ) as Map<String, Object?>;
  var written = 0;
  var unsupported = 0;
  var failed = 0;
  for (final entry in (manifest['fixtures']! as List).cast<Map>()) {
    final family = entry['family'] as String;
    final name = entry['name'] as String;
    if (only.isNotEmpty && !only.contains(family)) continue;
    for (final format in (entry['formats'] as List).cast<String>()) {
      final rel = '$family/$name${_extensions[format]}';
      final input = File('$fixtures/$rel').readAsBytesSync();
      String status;
      try {
        // Batch boundaries (including empty batches) are written one by one.
        final Schema schema;
        final List<RecordBatch> batches;
        if (format == 'file') {
          final reader = ipc.openFile(input);
          schema = reader.schema;
          batches = [
            for (var i = 0; i < reader.numRecordBatches; i++)
              reader.getBatch(i),
          ];
        } else {
          final reader = ipc.openStream(input);
          schema = reader.schema;
          batches = reader.toList();
        }
        final Uint8List bytes;
        if (format == 'file') {
          final writer = ipc.newFile(schema);
          batches.forEach(writer.writeBatch);
          bytes = writer.close();
        } else {
          final writer = ipc.newStream(schema);
          batches.forEach(writer.writeBatch);
          bytes = writer.close();
        }
        final table = Table.fromBatches(batches, schema: schema);
        final target = File('$out/$rel');
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(bytes);
        written++;
        status = 'WROTE      $rel (${table.numRows} rows)';
      } on UnsupportedError catch (e) {
        unsupported++;
        status = 'UNSUPPORTED $rel: ${e.message}';
      } on FormatException catch (e) {
        if (_knownGaps.contains('$family/$name')) {
          unsupported++;
          stdout.writeln('KNOWN-GAP  $rel: ${e.message}');
          continue;
        }
        failed++;
        status = 'READ-FAIL  $rel: ${e.message}';
      } catch (e) {
        failed++;
        status = 'ERROR      $rel: $e';
      }
      stdout.writeln(status);
    }
  }
  stdout.writeln(
    '$written written, $unsupported unsupported, $failed failed -> $out',
  );
  if (failed > 0 || (strict && unsupported > 0)) exitCode = 1;
}
