//! Native library behind the `wxscan` Flutter package (the crate keeps its
//! `wxscan_core` name: it depends on the upstream `wxscan` crate, and cargo
//! will not resolve a package against a dependency sharing its own name).
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

// The system image decoder, lent to wxscan-ffi so that scanImage reads what
// the platform reads rather than only png, jpeg and gif. This is the layer
// that can know about frameworks; wxscan-ffi deliberately cannot.
#[cfg(any(target_os = "ios", target_os = "macos"))]
mod apple_decoder;

/// Lend this library the platform's own image decoder, if there is one.
///
/// Calling this is what makes `scanImage` read HEIC and everything else the
/// system displays; without it the built-in png, jpeg and gif are all there is.
/// It changes nothing about how those three are read — the platform is asked
/// only once they have declined.
///
/// Idempotent, and safe to call from anywhere: registering twice replaces the
/// registration with an identical one. Platforms with nothing to lend do
/// nothing at all, so a caller never has to ask which platform it is on.
#[no_mangle]
pub extern "C" fn wxscan_install_platform_image_decoder() {
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    {
        let decoder = apple_decoder::decoder();
        // SAFETY: the pointers are to functions in this library, which outlive
        // any registration of them.
        unsafe { wxscan_ffi::wxscan_set_image_decoder(&decoder) };
    }
}
