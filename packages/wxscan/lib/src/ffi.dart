import 'dart:ffi' as ffi;

import 'bindings.dart';

/// `wxscan_scanner_release` as a native function pointer, for
/// [ffi.NativeFinalizer].
///
/// The bindings are native-asset bound, so there is no library handle to look a
/// symbol up in; the address comes from the generated declaration itself.
///
/// A finalizer hands its token over as a `void*`, while this takes a handle —
/// one machine word either way, in the same register, so the two agree at the
/// ABI even though the types do not. Nothing dereferences the token: the
/// library looks the handle up in its own table.
final ffi.Pointer<ffi.NativeFinalizerFunction> scannerFinalizer =
    ffi.Native.addressOf<ffi.NativeFunction<ffi.Void Function(WxScanScannerId)>>(
      wxscan_scanner_release,
    ).cast();
