import 'dart:ffi' as ffi;

import 'bindings.dart';

/// `wxscan_scanner_free` as a native function pointer, for [ffi.NativeFinalizer].
///
/// The bindings are native-asset bound, so there is no library handle to look a
/// symbol up in; the address comes from the generated declaration itself.
final ffi.Pointer<ffi.NativeFinalizerFunction> scannerFinalizer =
    ffi.Native.addressOf<
      ffi.NativeFunction<ffi.Void Function(ffi.Pointer<WxScanScanner>)>
    >(wxscan_scanner_free).cast();
