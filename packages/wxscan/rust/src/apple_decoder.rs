//! The system's image decoder, on Apple platforms.
//!
//! `wxscan-ffi` carries png, jpeg and gif; ImageIO reads everything the system
//! can display, HEIC included, which is what a photo library is mostly made of.
//! It is already in the process — every application links it — so this costs a
//! few hundred bytes of glue and no framework that was not there.
//!
//! # Why the thumbnail API decodes the full image
//!
//! `CGImageSourceCreateImageAtIndex` returns the pixels as stored, ignoring the
//! orientation tag beside them, so a photograph taken sideways would come back
//! sideways — and the built-in path applies that tag, so the two would disagree
//! depending on the format.
//!
//! `CGImageSourceCreateThumbnailAtIndex` applies it, given
//! `kCGImageSourceCreateThumbnailWithTransform`. With
//! `kCGImageSourceCreateThumbnailFromImageAlways` it decodes the real image
//! rather than an embedded preview, and with `kCGImageSourceThumbnailMaxPixelSize`
//! set to the longer side it does not scale anything down. "Thumbnail" is the
//! name of the API, not of what comes out of it.

use std::ffi::c_void;

use wxscan_ffi::WxScanImageDecoder;

type CFTypeRef = *const c_void;
type CFStringRef = CFTypeRef;
type CFDataRef = CFTypeRef;
type CFDictionaryRef = CFTypeRef;
type CFMutableDictionaryRef = *mut c_void;
type CFNumberRef = CFTypeRef;
type CFAllocatorRef = CFTypeRef;
type CGImageSourceRef = CFTypeRef;
type CGImageRef = CFTypeRef;
type CGColorSpaceRef = *mut c_void;
type CGContextRef = *mut c_void;

const K_CF_NUMBER_INT: i32 = 9; // kCFNumberIntType
const K_CG_IMAGE_ALPHA_NONE_SKIP_LAST: u32 = 5; // kCGImageAlphaNoneSkipLast

// The pixel buffer crosses back into wxscan-ffi and returns here to be freed,
// with nothing in between knowing how large it is. Rust's allocator needs that
// size to deallocate, so the buffer is C's: calloc and free need only the
// pointer. (Zeroed rather than raw because a decoded image need not cover the
// whole rectangle, and reading uninitialised memory is not worth the microsecond.)
extern "C" {
    fn calloc(count: usize, size: usize) -> *mut c_void;
    fn free(p: *mut c_void);
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFDataCreate(allocator: CFAllocatorRef, bytes: *const u8, length: isize) -> CFDataRef;
    fn CFRelease(cf: CFTypeRef);
    fn CFDictionaryCreateMutable(
        allocator: CFAllocatorRef,
        capacity: isize,
        key_callbacks: *const c_void,
        value_callbacks: *const c_void,
    ) -> CFMutableDictionaryRef;
    fn CFDictionarySetValue(dict: CFMutableDictionaryRef, key: *const c_void, value: *const c_void);
    fn CFDictionaryGetValue(dict: CFDictionaryRef, key: *const c_void) -> *const c_void;
    fn CFNumberCreate(allocator: CFAllocatorRef, the_type: i32, value_ptr: *const c_void)
        -> CFNumberRef;
    fn CFNumberGetValue(number: CFNumberRef, the_type: i32, value_ptr: *mut c_void) -> bool;

    static kCFAllocatorDefault: CFAllocatorRef;
    static kCFTypeDictionaryKeyCallBacks: c_void;
    static kCFTypeDictionaryValueCallBacks: c_void;
    static kCFBooleanTrue: CFTypeRef;
}

#[link(name = "ImageIO", kind = "framework")]
extern "C" {
    fn CGImageSourceCreateWithData(data: CFDataRef, options: CFDictionaryRef) -> CGImageSourceRef;
    fn CGImageSourceCopyPropertiesAtIndex(
        isrc: CGImageSourceRef,
        index: usize,
        options: CFDictionaryRef,
    ) -> CFDictionaryRef;
    fn CGImageSourceCreateThumbnailAtIndex(
        isrc: CGImageSourceRef,
        index: usize,
        options: CFDictionaryRef,
    ) -> CGImageRef;

    static kCGImagePropertyPixelWidth: CFStringRef;
    static kCGImagePropertyPixelHeight: CFStringRef;
    static kCGImageSourceCreateThumbnailFromImageAlways: CFStringRef;
    static kCGImageSourceCreateThumbnailWithTransform: CFStringRef;
    static kCGImageSourceThumbnailMaxPixelSize: CFStringRef;
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGImageGetWidth(image: CGImageRef) -> usize;
    fn CGImageGetHeight(image: CGImageRef) -> usize;
    fn CGImageRelease(image: CGImageRef);
    fn CGColorSpaceCreateDeviceRGB() -> CGColorSpaceRef;
    fn CGColorSpaceRelease(space: CGColorSpaceRef);
    fn CGBitmapContextCreate(
        data: *mut c_void,
        width: usize,
        height: usize,
        bits_per_component: usize,
        bytes_per_row: usize,
        space: CGColorSpaceRef,
        bitmap_info: u32,
    ) -> CGContextRef;
    fn CGContextRelease(c: CGContextRef);
    fn CGContextDrawImage(c: CGContextRef, rect: CGRect, image: CGImageRef);
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CGPoint {
    x: f64,
    y: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct CGSize {
    width: f64,
    height: f64,
}
#[repr(C)]
#[derive(Clone, Copy)]
struct CGRect {
    origin: CGPoint,
    size: CGSize,
}

/// Releases a CoreFoundation object on the way out of a scope, so that the
/// early returns below do not each have to remember.
struct Owned(CFTypeRef);
impl Drop for Owned {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0) }
        }
    }
}

/// Reads one integer property out of an image's metadata.
unsafe fn int_property(properties: CFDictionaryRef, key: CFStringRef) -> Option<usize> {
    let value = CFDictionaryGetValue(properties, key as *const c_void);
    if value.is_null() {
        return None;
    }
    let mut out: i32 = 0;
    if !CFNumberGetValue(value, K_CF_NUMBER_INT, &mut out as *mut i32 as *mut c_void) {
        return None;
    }
    (out > 0).then_some(out as usize)
}

/// Decodes `data` to RGBA with ImageIO, returning the buffer and its shape.
///
/// The buffer is C-allocated and belongs to the caller until it comes back to
/// [`release`].
unsafe fn decode_rgba(data: &[u8]) -> Option<(*const u8, usize, usize)> {
    let cf_data = Owned(CFDataCreate(
        kCFAllocatorDefault,
        data.as_ptr(),
        data.len() as isize,
    ));
    if cf_data.0.is_null() {
        return None;
    }
    let source = Owned(CGImageSourceCreateWithData(cf_data.0, std::ptr::null()));
    if source.0.is_null() {
        return None;
    }

    // The stored size, only to keep the "thumbnail" from being smaller than the
    // image. The size that matters is the one the decoded image reports, which
    // is the stored size after the orientation has been applied.
    let properties = Owned(CGImageSourceCopyPropertiesAtIndex(
        source.0,
        0,
        std::ptr::null(),
    ));
    if properties.0.is_null() {
        return None;
    }
    let stored_width = int_property(properties.0, kCGImagePropertyPixelWidth)?;
    let stored_height = int_property(properties.0, kCGImagePropertyPixelHeight)?;
    let longest = stored_width.max(stored_height) as i32;

    let options = CFDictionaryCreateMutable(
        kCFAllocatorDefault,
        0,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    );
    if options.is_null() {
        return None;
    }
    let options = Owned(options as CFTypeRef);
    CFDictionarySetValue(
        options.0 as CFMutableDictionaryRef,
        kCGImageSourceCreateThumbnailFromImageAlways as *const c_void,
        kCFBooleanTrue as *const c_void,
    );
    CFDictionarySetValue(
        options.0 as CFMutableDictionaryRef,
        kCGImageSourceCreateThumbnailWithTransform as *const c_void,
        kCFBooleanTrue as *const c_void,
    );
    let max_size = Owned(CFNumberCreate(
        kCFAllocatorDefault,
        K_CF_NUMBER_INT,
        &longest as *const i32 as *const c_void,
    ));
    if max_size.0.is_null() {
        return None;
    }
    CFDictionarySetValue(
        options.0 as CFMutableDictionaryRef,
        kCGImageSourceThumbnailMaxPixelSize as *const c_void,
        max_size.0 as *const c_void,
    );

    let image = CGImageSourceCreateThumbnailAtIndex(source.0, 0, options.0);
    if image.is_null() {
        return None;
    }
    let width = CGImageGetWidth(image);
    let height = CGImageGetHeight(image);
    if width == 0 || height == 0 {
        CGImageRelease(image);
        return None;
    }

    let len = width.checked_mul(height).and_then(|n| n.checked_mul(4));
    let Some(len) = len else {
        CGImageRelease(image);
        return None;
    };
    let pixels = calloc(len, 1);
    if pixels.is_null() {
        CGImageRelease(image);
        return None;
    }

    let space = CGColorSpaceCreateDeviceRGB();
    let context = CGBitmapContextCreate(
        pixels,
        width,
        height,
        8,
        width * 4,
        space,
        K_CG_IMAGE_ALPHA_NONE_SKIP_LAST,
    );
    CGColorSpaceRelease(space);
    if context.is_null() {
        free(pixels);
        CGImageRelease(image);
        return None;
    }

    CGContextDrawImage(
        context,
        CGRect {
            origin: CGPoint { x: 0.0, y: 0.0 },
            size: CGSize {
                width: width as f64,
                height: height as f64,
            },
        },
        image,
    );
    CGContextRelease(context);
    CGImageRelease(image);

    Some((pixels as *const u8, width, height))
}

unsafe extern "C" fn decode(
    data: *const u8,
    len: usize,
    out_pixels: *mut *const u8,
    out_width: *mut u32,
    out_height: *mut u32,
    out_format: *mut i32,
    _ctx: *mut c_void,
) -> i32 {
    if data.is_null() {
        return 0;
    }
    let bytes = std::slice::from_raw_parts(data, len);
    let Some((pixels, width, height)) = decode_rgba(bytes) else {
        return 0;
    };
    *out_pixels = pixels;
    *out_width = width as u32;
    *out_height = height as u32;
    *out_format = 2; // WxScanPixelFormat::Rgba
    1
}

unsafe extern "C" fn release(pixels: *const u8, _ctx: *mut c_void) {
    if !pixels.is_null() {
        free(pixels as *mut c_void);
    }
}

/// The decoder to lend to `wxscan-ffi`.
pub(crate) fn decoder() -> WxScanImageDecoder {
    WxScanImageDecoder {
        decode: Some(decode),
        release: Some(release),
        ctx: std::ptr::null_mut(),
    }
}

#[cfg(test)]
mod tests {
    use wxscan_ffi::{
        wxscan_results_free, wxscan_scan_bytes, wxscan_scanner_free, wxscan_scanner_new,
        WxScanStatus,
    };

    /// The whole point of the arrangement, in one test: a HEIC that the
    /// built-in decoders cannot read at all decodes once the platform is
    /// asked. HEIC is what a photo library is mostly made of, and carrying a
    /// decoder for it would mean carrying an HEVC decoder.
    ///
    /// Both halves are one test because installing the decoder is
    /// process-wide: as two, `cargo test` would run them in either order and
    /// the "before" half would see whatever the other had done.
    #[test]
    fn the_platform_reads_a_heic_the_built_in_decoders_cannot() {
        let data = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/data/upright.heic"
        ))
        .unwrap();

        unsafe {
            let scanner = wxscan_scanner_new(std::ptr::null(), 0, std::ptr::null(), 0);
            assert!(!scanner.is_null());

            // Before: not a picture this build knows, which is where every
            // earlier version stood.
            let mut status = WxScanStatus::Ok;
            let out = wxscan_scan_bytes(scanner, data.as_ptr(), data.len(), &mut status);
            assert!(out.is_null());
            assert_eq!(status, WxScanStatus::UnsupportedFormat);

            crate::wxscan_install_platform_image_decoder();

            // After: the same bytes decode, and the symbol comes out. The
            // dimensions are those of the png this was converted from, so the
            // orientation is applied here as it is there.
            let mut status = WxScanStatus::BadArgument;
            let out = wxscan_scan_bytes(scanner, data.as_ptr(), data.len(), &mut status);
            assert_eq!(status, WxScanStatus::Ok);
            assert!(!out.is_null());
            assert_eq!(((*out).width, (*out).height), (320, 460));
            assert_eq!((*out).results_len, 1, "the symbol survived the round trip");

            wxscan_results_free(out);
            wxscan_scanner_free(scanner);
        }
    }
}
