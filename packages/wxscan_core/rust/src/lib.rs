//! Native library behind the `wxscan_core` Flutter package.
//!
//! Two entry points share one scanner instance:
//!
//! * Dart opens this library and calls the C ABI of `wxscan-ffi` directly. The
//!   re-export below keeps those symbols in the produced cdylib and staticlib.
//! * On Android the camera plugin sends frames from Kotlin through [`jni_shim`],
//!   so they never cross into Dart. It receives the scanner as a handle
//!   produced by the C ABI on the Dart side.

pub use wxscan_ffi::*;

#[cfg(target_os = "android")]
mod jni_shim;
