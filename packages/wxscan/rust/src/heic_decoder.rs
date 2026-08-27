//! HEIC, decoded in Rust.
//!
//! `wxscan-ffi` carries png, jpeg and gif. What is missing is HEIC, which is
//! most of a modern photo library — and on Apple platforms ImageIO supplies it
//! at no cost, being in the process already. Android has no such free lunch:
//!
//! * `AImageDecoder`, the NDK's decoder, is API 30. This package supports API
//!   24, so a quarter of the fleet would silently keep the old behaviour — and
//!   it does not apply the orientation a photograph records, which the other
//!   two paths do, so pictures would come back a quarter turn out on this
//!   platform alone.
//! * The Java `ImageDecoder` does apply it and goes back to API 28, but it is
//!   reached through JNI, and the decoder is called from whatever thread
//!   scanned — no `JNIEnv` in hand, and no `JavaVM` cached, because nothing
//!   here is entered from Java on this path.
//!
//! So the decoder is compiled in instead. It costs binary size where the
//! system decoders cost none, and buys back the two things above: every
//! supported API level, and the same upright picture as everywhere else.

use std::ffi::c_void;

use wxscan_ffi::WxScanImageDecoder;

extern "C" {
    fn calloc(count: usize, size: usize) -> *mut c_void;
    fn free(p: *mut c_void);
}

/// Bytes past which this is not a photograph anyone took.
///
/// These can come from anywhere — a file shared into the application, a
/// download — and a container header is a handful of integers a decoder is
/// otherwise willing to believe. Checked before decoding rather than after,
/// which is the only point at which it costs nothing.
const MAX_INPUT_BYTES: usize = 64 * 1024 * 1024;

/// Past this the decode is a denial of service rather than a picture. Several
/// times any phone camera, and a fraction of what the container can claim.
const MAX_PIXELS: usize = 100_000_000;

/// Decodes `data` to upright RGBA, C-allocated for the caller to release.
///
/// The orientation is the decoder's business and it does apply it: a picture
/// stored 460x320 with the tag that says to turn it comes back 320x460, as it
/// does on every other path.
fn decode_rgba(data: &[u8]) -> Option<(*const u8, usize, usize)> {
    if data.len() > MAX_INPUT_BYTES {
        return None;
    }
    let image = heif_oxide::decode_bytes(data).ok()?;

    let width = image.width as usize;
    let height = image.height as usize;
    if width == 0 || height == 0 || width.checked_mul(height)? > MAX_PIXELS {
        return None;
    }

    let rgba = image.to_rgba8();
    let len = width.checked_mul(height)?.checked_mul(4)?;
    if rgba.len() < len {
        return None;
    }

    // Into a C buffer, because it crosses into wxscan-ffi and comes back here
    // to be freed with nothing in between knowing its size.
    let pixels = unsafe { calloc(len, 1) };
    if pixels.is_null() {
        return None;
    }
    unsafe { std::ptr::copy_nonoverlapping(rgba.as_ptr(), pixels as *mut u8, len) };
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
        wxscan_set_image_decoder, WxScanStatus,
    };

    fn fixture(name: &str) -> Vec<u8> {
        std::fs::read(format!("{}/tests/data/{name}", env!("CARGO_MANIFEST_DIR"))).unwrap()
    }

    /// A picture stored a quarter turn from upright comes back upright, with
    /// the symbol in it.
    ///
    /// This is the whole of what Android gains, and the half that cannot be
    /// checked on a phone from here — so it is checked with the same decoder,
    /// compiled for this machine. What a phone adds is only the registration.
    ///
    /// 460x320 in the file, 320x460 out: the decoder applies the orientation,
    /// as ImageIO and `image` do on the other two paths. Were it not to, the
    /// picture would still decode and only the coordinates would be wrong,
    /// which nothing at run time would notice.
    #[test]
    fn a_rotated_heic_comes_back_upright_and_decodes() {
        let _serial = crate::exclusively();
        unsafe {
            let decoder = super::decoder();
            wxscan_set_image_decoder(&decoder);

            let scanner = wxscan_scanner_new(std::ptr::null(), 0, std::ptr::null(), 0);
            assert!(!scanner.is_null());
            let data = fixture("rot90.heic");
            let mut status = WxScanStatus::BadArgument;
            let out = wxscan_scan_bytes(scanner, data.as_ptr(), data.len(), &mut status);

            assert_eq!(status, WxScanStatus::Ok);
            assert!(!out.is_null());
            assert_eq!(
                ((*out).width, (*out).height),
                (320, 460),
                "stored 460x320; the orientation should have been applied"
            );
            assert_eq!((*out).results_len, 1, "the symbol survived the decode");

            wxscan_results_free(out);
            wxscan_scanner_free(scanner);
            wxscan_set_image_decoder(std::ptr::null());
        }
    }

    /// AVIF is the same container with AV1 inside instead of HEVC, and this
    /// decoder carries only HEVC — so it declines, and on Android an AVIF is
    /// still unreadable. Recorded because the container makes the two look
    /// alike, and because Apple reads both.
    #[test]
    fn avif_is_not_covered() {
        let _serial = crate::exclusively();
        assert!(
            super::decode_rgba(&fixture("upright.avif")).is_none(),
            "an AVIF is HEVC's container with AV1 inside; decoding one would \
             mean this crate had grown an AV1 decoder, which is worth noticing"
        );
    }

    /// It is asked about everything the built-in decoders declined, so it has
    /// to say no politely to what is not a HEIC at all.
    #[test]
    fn what_is_not_a_heic_is_declined_rather_than_mangled() {
        let _serial = crate::exclusively();
        assert!(super::decode_rgba(b"not a picture").is_none());
        assert!(super::decode_rgba(&[]).is_none());
        assert!(super::decode_rgba(&fixture("upright.heic")).is_some());
    }
}
