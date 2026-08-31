/// QR decoding core: a Rust port of the wechat_qrcode algorithm, covering CNN
/// detection, super resolution and decoding.
///
/// This package decodes images and raw pixel buffers. It does not open a
/// camera; for live scanning use the `wxscan_live` package, which drives the
/// camera natively and links the same library.
///
/// ```dart
/// final scanner = await WxScanner.create(
///   detectModel: detectBytes,
///   srModel: srBytes,
/// );
/// final outcome = await scanner.scanGray(gray, width, height);
/// for (final r in outcome.results) {
///   print(r.text);
/// }
/// await scanner.dispose();
/// ```
library;

export 'src/result.dart'
    show
        PictureReadFailure,
        PictureUnreadable,
        ScanOutcome,
        ScanPoint,
        ScanQuad,
        ScanResult;
export 'src/frame_json.dart' show parseFrameJson;
// The scanner is the FFI one everywhere a shared library can be opened, and
// the WebAssembly one in a browser, where it cannot. Both present the same
// API; the browser's `*Sync` methods throw, because its engine answers by
// message from a worker rather than in the same call.
export 'src/scanner.dart'
    if (dart.library.js_interop) 'src/web/scanner_web.dart'
    show WxScanner, WxPixelFormat;
