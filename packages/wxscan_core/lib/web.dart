/// Configuration the browser build needs, and nothing the other platforms do.
///
/// The browser build's four files ship inside this package, and
/// `dart run wxscan_core:fetch_web` copies them into `web/wxscan`, where the
/// package looks by default. They are files rather than declared assets
/// because declaring Flutter assets would make this a Flutter package, which
/// would cost `dart run` and `dart test`. This says where they are when they
/// are somewhere else.
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
/// Of the four, `wxscan_worker.js` is this package's own; the rest are built
/// in the wxscan-rs repository — `wxscan_wasm.wasm` by `crates/wxscan-wasm`,
/// and the `wxscan_tflite.js` and `wxscan_tflite.wasm` pair by
/// `tools/tflite-wasm`. Only the loader of that pair takes a URL, since it
/// fetches the module beside itself, and the two must keep their names: the
/// loader has its module's file name compiled into it.
library;

import 'src/web/scanner_web.dart';

export 'src/web/scanner_web.dart' show WxScanWebPaths;

/// Points the browser build at the files the application serves.
///
/// Call it before creating a scanner; a scanner already running keeps the
/// paths it started with.
void configureWxScanWeb(WxScanWebPaths paths) => wxScanWebPaths = paths;
