//! JNI entry points for `com.wilinz.wxscanlive.core.NativeScanner`.
//!
//! Camera frames on Android reach the scanner from Kotlin without passing
//! through Dart. A caller on this path either creates its own scanner here or
//! is handed the handle of one the Dart side already holds — the handles are
//! the same numbers on both paths, since they name entries in one table inside
//! the library rather than anything belonging to either binding.
//!
//! Results are returned as a JSON document because that is the cheapest way to
//! move a small variable-length structure across JNI and then a method channel.
//! Serialization therefore lives here, in the binding layer, rather than in the
//! C ABI.

use jni::objects::{JByteArray, JClass};
use jni::sys::{jboolean, jint, jlong, jstring};
use jni::JNIEnv;

use wxscan::frame::upright_gray;
use wxscan_ffi::WxScanScannerId;

/// A `jlong` as a handle, or 0 if it cannot be one.
///
/// `usize` is 32 bits on armeabi-v7a, so a plain `as` cast would truncate —
/// and truncation is worse than rejection here: `0x1_0000_0001` would come
/// down to `1` and hit a live scanner that the caller never named. Anything
/// that does not fit names nothing, which is what 0 means.
fn handle_of(v: jlong) -> WxScanScannerId {
    WxScanScannerId::try_from(v).unwrap_or(0)
}

/// Drops a Java exception this side has decided to handle itself.
///
/// jni-rs leaves a throwable pending when it reports `JavaException`, and every
/// entry point here answers with an empty result rather than propagating one.
/// Leaving it pending would be undefined behaviour at the next JNI call and an
/// abort under CheckJNI, and it would surface at some unrelated boundary later.
fn clear_pending(env: &mut JNIEnv) {
    if env.exception_check().unwrap_or(false) {
        let _ = env.exception_clear();
    }
}

/// Create a scanner from model buffers, returning an opaque handle, or 0 if a
/// model fails to load. Passing empty arrays selects the mode without models,
/// which still decodes but detects small or distant symbols less reliably.
///
/// The handle must be released with [`Java_com_wilinz_wxscanlive_core_NativeScanner_nativeRelease`].
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscanlive_core_NativeScanner_nativeCreate(
    mut env: JNIEnv,
    _class: JClass,
    detect: JByteArray,
    sr: JByteArray,
) -> jlong {
    // A copy that fails leaves a Java exception pending, and this side answers
    // with the mode without models rather than propagating one — so the
    // throwable has to go, or it surfaces at some unrelated JNI call later.
    let mut read = |env: &mut JNIEnv, a: &JByteArray| -> Vec<u8> {
        match env.convert_byte_array(a) {
            Ok(v) => v,
            Err(_) => {
                clear_pending(env);
                Vec::new()
            }
        }
    };
    let d = read(&mut env, &detect);
    let s = read(&mut env, &sr);
    let id = unsafe {
        wxscan_ffi::wxscan_scanner_new(
            if d.is_empty() { std::ptr::null() } else { d.as_ptr() },
            d.len(),
            if s.is_empty() { std::ptr::null() } else { s.as_ptr() },
            s.len(),
        )
    };
    id as jlong
}

/// Take a reference to a scanner the caller did not create, returning the same
/// handle, or 0 if it names no scanner.
///
/// This is how a camera binding borrows the scanner a Dart application already
/// holds: one scanner, one set of weights in memory, and it stays alive
/// whichever side lets go of it first. Match it with
/// [`Java_com_wilinz_wxscanlive_core_NativeScanner_nativeRelease`].
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscanlive_core_NativeScanner_nativeRetain(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) -> jlong {
    wxscan_ffi::wxscan_scanner_retain(handle_of(handle)) as jlong
}

/// Whether the scanner a handle names has its detector network loaded.
///
/// A borrowed scanner was built by whoever lent it, so this side cannot know
/// from the weights it was passed — it was passed none. Rather than guess, it
/// asks. Returns false for a handle that names no scanner.
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscanlive_core_NativeScanner_nativeHasDetector(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) -> jboolean {
    u8::from(wxscan_ffi::wxscan_scanner_has_detector(handle_of(handle)) != 0)
}

/// Give up a reference. The scanner goes when its last holder does.
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscanlive_core_NativeScanner_nativeRelease(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    if handle != 0 {
        wxscan_ffi::wxscan_scanner_release(handle_of(handle));
    }
}

/// Scan one camera frame.
///
/// * `handle` comes from [`Java_com_wilinz_wxscanlive_core_NativeScanner_nativeCreate`].
/// * `y_plane` is the Y plane of the frame, `row_stride` bytes per row.
/// * `rotation` is the clockwise angle in degrees needed to bring the frame upright.
/// * `mirror` mirrors the returned x coordinates without mirroring the frame.
///
/// Returns the JSON described in [`scan_json`]. Invalid input yields the empty
/// document rather than an exception.
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscanlive_core_NativeScanner_nativeScanFrame(
    mut env: JNIEnv,
    _class: JClass,
    handle: jlong,
    y_plane: JByteArray,
    width: jint,
    height: jint,
    row_stride: jint,
    rotation: jint,
    mirror: jboolean,
) -> jstring {
    let json = match env.convert_byte_array(&y_plane) {
        Ok(bytes) => scan_json(
            handle_of(handle),
            &bytes,
            width,
            height,
            row_stride,
            rotation,
            mirror != 0,
        ),
        Err(_) => {
            // The copy failed, which for jni-rs means a Java exception is
            // pending — an OutOfMemoryError, most likely. Calling any further
            // JNI function with one pending is undefined behaviour, and
            // Android's CheckJNI aborts the process for it. `new_string`
            // below is exactly such a call.
            clear_pending(&mut env);
            empty_json()
        }
    };
    env.new_string(json)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

/// Confirm the library is loaded, called once after `System.loadLibrary`.
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscanlive_core_NativeScanner_nativePing(
    env: JNIEnv,
    _class: JClass,
) -> jstring {
    env.new_string("wxscan")
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

/// Scan a frame and serialize the outcome.
///
/// ```text
/// {"w":720,"h":1280,
///  "results":[{"text":"...","charset":"UTF-8","version":3,"ecLevel":"L",
///              "charsetMode":"BYTE","binaryMethod":0,
///              "points":[x0,y0,x1,y1,x2,y2,x3,y3]}],
///  "candidates":[[x0,y0,x1,y1,x2,y2,x3,y3]]}
/// ```
///
/// A non-empty `candidates` with an empty `results` means a symbol was located
/// but not decoded, which the caller can use to zoom in.
///
/// A handle that names no scanner yields the empty document, as does a frame
/// whose dimensions do not match its buffer.
fn scan_json(
    handle: WxScanScannerId,
    bytes: &[u8],
    width: jint,
    height: jint,
    row_stride: jint,
    rotation: jint,
    mirror: bool,
) -> String {
    if width <= 0 || height <= 0 || row_stride < width {
        return empty_json();
    }
    // A handle that names nothing — released, or never valid — is an empty
    // document, not a dereference.
    let Some(scanner) = wxscan_ffi::lookup_scanner(handle) else {
        return empty_json();
    };
    let (w, h, stride) = (width as usize, height as usize, row_stride as usize);
    // Checked, because `usize` is 32 bits on armeabi-v7a: `stride * h` for a
    // frame claiming 65536 rows of 65536 bytes wraps to zero there, the length
    // check passes, and `upright_gray` reads past the end of a short array.
    // This is the only bounds check standing between Java and that slice.
    let Some(needed) = stride.checked_mul(h) else {
        return empty_json();
    };
    if bytes.len() < needed {
        return empty_json();
    }

    let (gray, ow, oh) = upright_gray(bytes, w, h, stride, rotation);
    let (results, candidates) = scanner.scan_upright(&gray, ow, oh);

    let flip = |x: f32| if mirror { ow as f32 - x } else { x };
    let quad = |pts: &[(f32, f32); 4]| {
        pts.iter()
            .map(|(x, y)| format!("{:.2},{:.2}", flip(*x), y))
            .collect::<Vec<_>>()
            .join(",")
    };

    let items: Vec<String> = results
        .iter()
        .map(|r| {
            format!(
                concat!(
                    "{{\"text\":\"{}\",\"charset\":\"{}\",\"version\":{},\"ecLevel\":\"{}\",",
                    "\"charsetMode\":\"{}\",\"binaryMethod\":{},\"points\":[{}]}}"
                ),
                escape(&decode_text(&r.bytes, &r.charset)),
                escape(&r.charset),
                r.qrcode_version,
                escape(&r.ec_level),
                escape(&r.charset_mode),
                r.binary_method,
                quad(&r.points),
            )
        })
        .collect();
    let cands: Vec<String> = candidates.iter().map(|q| format!("[{}]", quad(q))).collect();

    format!(
        "{{\"w\":{ow},\"h\":{oh},\"results\":[{}],\"candidates\":[{}]}}",
        items.join(","),
        cands.join(",")
    )
}

/// The document for a frame with nothing in it, also used on invalid input.
fn empty_json() -> String {
    "{\"w\":0,\"h\":0,\"results\":[],\"candidates\":[]}".to_string()
}

/// Interpret payload bytes according to the reported charset. The decoder
/// reports the encoding without converting, so GB2312 is decoded here; GBK is a
/// superset of it and tolerates a few out-of-range bytes.
fn decode_text(bytes: &[u8], charset: &str) -> String {
    if charset.eq_ignore_ascii_case("GB2312") {
        let (cow, _, _) = encoding_rs::GBK.decode(bytes);
        return cow.into_owned();
    }
    String::from_utf8_lossy(bytes).into_owned()
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}
