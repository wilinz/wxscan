//! JNI entry points for `com.wilinz.wxscan.core.NativeScanner`.
//!
//! Camera frames on Android reach the scanner from Kotlin without passing
//! through Dart. A caller on this path owns its own scanner, created and
//! destroyed here, and never touches the Dart bindings of this package; the two
//! entry points share the library, not an instance.
//!
//! Results are returned as a JSON document because that is the cheapest way to
//! move a small variable-length structure across JNI and then a method channel.
//! Serialization therefore lives here, in the binding layer, rather than in the
//! C ABI.

use jni::objects::{JByteArray, JClass};
use jni::sys::{jboolean, jint, jlong, jstring};
use jni::JNIEnv;

use wxscan::frame::upright_gray;
use wxscan_ffi::WxScanScanner;

/// Create a scanner from model buffers, returning an opaque handle, or 0 if a
/// model fails to load. Passing empty arrays selects the mode without models,
/// which still decodes but detects small or distant symbols less reliably.
///
/// The handle must be released with [`Java_com_wilinz_wxscan_core_NativeScanner_nativeDestroy`].
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscan_core_NativeScanner_nativeCreate(
    env: JNIEnv,
    _class: JClass,
    detect: JByteArray,
    sr: JByteArray,
) -> jlong {
    let read = |a: &JByteArray| -> Vec<u8> { env.convert_byte_array(a).unwrap_or_default() };
    let (d, s) = (read(&detect), read(&sr));
    let ptr = unsafe {
        wxscan_ffi::wxscan_scanner_new(
            if d.is_empty() { std::ptr::null() } else { d.as_ptr() },
            d.len(),
            if s.is_empty() { std::ptr::null() } else { s.as_ptr() },
            s.len(),
        )
    };
    ptr as jlong
}

/// Destroy a scanner. A handle of 0 is ignored.
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscan_core_NativeScanner_nativeDestroy(
    _env: JNIEnv,
    _class: JClass,
    handle: jlong,
) {
    if handle != 0 {
        unsafe { wxscan_ffi::wxscan_scanner_free(handle as *mut WxScanScanner) };
    }
}

/// Scan one camera frame.
///
/// * `handle` comes from [`Java_com_wilinz_wxscan_core_NativeScanner_nativeCreate`].
/// * `y_plane` is the Y plane of the frame, `row_stride` bytes per row.
/// * `rotation` is the clockwise angle in degrees needed to bring the frame upright.
/// * `mirror` mirrors the returned x coordinates without mirroring the frame.
///
/// Returns the JSON described in [`scan_json`]. Invalid input yields the empty
/// document rather than an exception.
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscan_core_NativeScanner_nativeScanFrame(
    env: JNIEnv,
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
        Ok(bytes) => unsafe {
            scan_json(
                handle as *const WxScanScanner,
                &bytes,
                width,
                height,
                row_stride,
                rotation,
                mirror != 0,
            )
        },
        Err(_) => empty_json(),
    };
    env.new_string(json)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

/// Confirm the library is loaded, called once after `System.loadLibrary`.
#[no_mangle]
pub extern "system" fn Java_com_wilinz_wxscan_core_NativeScanner_nativePing(
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
/// # Safety
/// `handle` must be a live scanner from `nativeCreate`.
unsafe fn scan_json(
    handle: *const WxScanScanner,
    bytes: &[u8],
    width: jint,
    height: jint,
    row_stride: jint,
    rotation: jint,
    mirror: bool,
) -> String {
    if handle.is_null() || width <= 0 || height <= 0 || row_stride < width {
        return empty_json();
    }
    let (w, h, stride) = (width as usize, height as usize, row_stride as usize);
    if bytes.len() < stride * h {
        return empty_json();
    }

    let (gray, ow, oh) = upright_gray(bytes, w, h, stride, rotation);
    let (results, candidates) = (*handle).scan_upright(&gray, ow, oh);

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
