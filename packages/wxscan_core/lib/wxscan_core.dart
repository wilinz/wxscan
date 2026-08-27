/// QR decoding core: a Rust port of the wechat_qrcode algorithm, covering CNN
/// detection, super resolution and decoding.
///
/// This package decodes images and raw pixel buffers. It does not open a
/// camera; for live scanning use the `wxscan` package, which drives the camera
/// natively and links the same library.
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

export 'src/result.dart' show ScanResult, ScanOutcome, ScanPoint, ScanQuad;
export 'src/scanner.dart' show WxScanner, WxPixelFormat, parseFrameJson;
