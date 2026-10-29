library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'ipc_compression_vm.dart'
    if (dart.library.js_interop) 'ipc_compression_web.dart'
    as ipc_compression;

part 'array.dart';
part 'array_extended.dart';
part 'batch.dart';
part 'buffer.dart';
part 'chunked_array.dart';
part 'codec.dart';
part 'conversion.dart';
part 'factories.dart';
part 'ipc.dart';
part 'ipc_body.dart';
part 'ipc_compression.dart';
part 'ipc_flatbuffers.dart';
part 'ipc_message.dart';
part 'ipc_schema.dart';
part 'error.dart';
part 'metadata.dart';
part 'scalar.dart';
part 'schema.dart';
part 'table.dart';
part 'type.dart';
part 'type_factories.dart';
part 'value.dart';
