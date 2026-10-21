/// Standard Arrow C Data and C Stream ABI declarations.
///
/// This optional library requires dart:ffi; arrow.dart does not.
library dartaframes_arrow_c;

import 'dart:ffi';

/// ABI-exact Arrow C Data Interface array structure.
final class CArrowArray extends Struct {
  @Int64()
  external int length;
  @Int64()
  external int nullCount;
  @Int64()
  external int offset;
  @Int64()
  external int nBuffers;
  @Int64()
  external int nChildren;
  external Pointer<Pointer<Void>> buffers;
  external Pointer<Pointer<CArrowArray>> children;
  external Pointer<CArrowArray> dictionary;
  external Pointer<NativeFunction<Void Function(Pointer<CArrowArray>)>> release;
  external Pointer<Void> privateData;
}

/// ABI-exact Arrow C Data Interface schema structure.
final class CArrowSchema extends Struct {
  external Pointer<Char> format;
  external Pointer<Char> name;
  external Pointer<Char> metadata;
  @Int64()
  external int flags;
  @Int64()
  external int nChildren;
  external Pointer<Pointer<CArrowSchema>> children;
  external Pointer<CArrowSchema> dictionary;
  external Pointer<NativeFunction<Void Function(Pointer<CArrowSchema>)>>
  release;
  external Pointer<Void> privateData;
}

/// ABI-exact Arrow C Stream Interface structure.
final class CArrowArrayStream extends Struct {
  external Pointer<
    NativeFunction<
      Int32 Function(Pointer<CArrowArrayStream>, Pointer<CArrowSchema>)
    >
  >
  getSchema;
  external Pointer<
    NativeFunction<
      Int32 Function(Pointer<CArrowArrayStream>, Pointer<CArrowArray>)
    >
  >
  getNext;
  external Pointer<
    NativeFunction<Pointer<Char> Function(Pointer<CArrowArrayStream>)>
  >
  getLastError;
  external Pointer<NativeFunction<Void Function(Pointer<CArrowArrayStream>)>>
  release;
  external Pointer<Void> privateData;
}
