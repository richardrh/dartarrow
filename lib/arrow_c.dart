/// Standard Arrow C Data and C Stream ABI declarations.
///
/// This optional library requires dart:ffi; arrow.dart does not. On web
/// targets, where dart:ffi is unavailable, it exports nothing.
library dartarrow_c;

export 'src/arrow_c_ffi.dart'
    if (dart.library.js_interop) 'src/arrow_c_unsupported.dart';
