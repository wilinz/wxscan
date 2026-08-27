/// Configuration the browser build needs, and nothing the other platforms do.
///
/// This package ships no assets: it is a plain Dart package, and declaring
/// Flutter assets would make it a Flutter one, which would cost `dart run` and
/// `dart test`. So an application serves the browser build's files itself and,
/// if they are not where this package looks by default, says where they are.
///
/// ```dart
/// // Before creating a scanner, and only on the web.
/// configureWxScanWeb(const WxScanWebPaths(
///   workerUrl: 'assets/wxscan/wxscan_worker.js',
///   wasmUrl: 'assets/wxscan/wxscan_wasm.wasm',
///   tfliteUrl: './wxscan_tflite.js',
/// ));
/// ```
///
/// The files are `wxscan_worker.js`, which is
/// `lib/src/web/assets/wxscan_worker.js` in this package, and three built in
/// the wxscan-rs repository: `wxscan_wasm.wasm` from `crates/wxscan-wasm`, and
/// the `wxscan_tflite.js` and `wxscan_tflite.wasm` pair from
/// `tools/tflite-wasm`. Only the loader of that pair takes a URL; it fetches
/// the module beside itself.
library;

import 'src/web/scanner_web.dart';

export 'src/web/scanner_web.dart' show WxScanWebPaths;

/// Points the browser build at the files the application serves.
///
/// Call it before creating a scanner; a scanner already running keeps the
/// paths it started with.
void configureWxScanWeb(WxScanWebPaths paths) => wxScanWebPaths = paths;
