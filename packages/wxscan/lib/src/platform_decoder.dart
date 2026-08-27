/// Lending the scanner the platform's own image decoder.
///
/// `scanImage` decodes png, jpeg and gif in Rust, which is what a photo picker
/// writes. Everything else a caller might be handed — HEIC above all, which is
/// most of an Apple photo library — would mean linking a decoder measured in
/// megabytes and encumbered by patents.
///
/// The platform already has one, and this hands it over. It is consulted only
/// once the built-in decoders have declined, so it cannot change how the three
/// they cover are read; where the platform has nothing to lend, the call does
/// nothing and `scanImage` behaves exactly as before.
///
/// Declared here rather than in `bindings.dart` because the symbol belongs to
/// this package's own Rust crate rather than to `wxscan-ffi`, and that file is
/// generated from `wxscan-ffi`'s header.
///
/// The asset is the one the generated bindings use: one library, one code
/// asset, and this symbol is in it alongside the rest.
@ffi.DefaultAsset('package:wxscan/src/bindings.dart')
library;

import 'dart:ffi' as ffi;

@ffi.Native<ffi.Void Function()>(
  symbol: 'wxscan_install_platform_image_decoder',
)
external void _install();

var _installed = false;

/// Installs the platform decoder once per process.
///
/// The native side is idempotent, so the flag is only to keep the lock it takes
/// off the path of every scanner that gets created.
void installPlatformImageDecoder() {
  if (_installed) return;
  _install();
  _installed = true;
}
