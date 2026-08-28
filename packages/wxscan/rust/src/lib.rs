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

// Everywhere Apple's ImageIO is not: Android, Windows and Linux all have to
// carry this one. Built for the tests on Apple too — it is pure Rust, and a
// decoder that could only be exercised on a phone would not be exercised.
#[cfg(any(not(any(target_os = "ios", target_os = "macos")), test))]
mod heic_decoder;

/// Give this library a decoder for the formats it does not carry.
///
/// Calling this is what makes `scanImage` read HEIC. On Apple that is ImageIO,
/// which brings everything else the system displays with it — AVIF, RAW, the
/// lot — for nothing, since every application links it already. Everywhere else
/// it is a decoder compiled in, because there is nothing to borrow: Android's
/// is API 30 and ignores the orientation tag, Linux has none, and Windows has
/// one only if the user installed it.
///
/// Either way it is asked second, so it changes nothing about how the built-in
/// png, jpeg and gif are read.
///
/// Idempotent, and safe to call from anywhere: registering twice replaces the
/// registration with an identical one.
#[no_mangle]
pub extern "C" fn wxscan_install_platform_image_decoder() {
    #[cfg(any(target_os = "ios", target_os = "macos"))]
    let decoder = apple_decoder::decoder();
    #[cfg(not(any(target_os = "ios", target_os = "macos")))]
    let decoder = heic_decoder::decoder();

    // SAFETY: the pointers are to functions in this library, which outlive any
    // registration of them.
    unsafe { wxscan_ffi::wxscan_set_image_decoder(&decoder) };
}

/// Serialising the tests that install an image decoder.
///
/// The registration is one global slot in wxscan-ffi, and `cargo test` runs
/// tests in parallel, so two modules installing their own decoder would each
/// see the other's. Every such test takes this first, and starts from nothing
/// installed whatever the test before it did.
#[cfg(test)]
pub(crate) fn exclusively() -> std::sync::MutexGuard<'static, ()> {
    static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    // A failing test poisons the lock; that is no reason for the rest to fail
    // too, so the poison is stepped over.
    let guard = LOCK.lock().unwrap_or_else(|e| e.into_inner());
    // SAFETY: clearing the registration is always sound.
    unsafe { wxscan_ffi::wxscan_set_image_decoder(std::ptr::null()) };
    guard
}
