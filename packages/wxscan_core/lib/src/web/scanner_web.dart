/// The browser implementation of [WxScanner].
///
/// Same API as the native one and the same algorithm underneath, but the
/// engine lives in a worker rather than in an isolate: a browser has neither
/// isolates nor a way to share a WebAssembly module's memory with a worker
/// without cross-origin isolation. Frames are transferred in and results come
/// back as JSON, which costs a copy of a few hundred bytes and keeps the page
/// responsive while a frame is decoded.
///
/// Four files have to be reachable over HTTP: the worker script, the scanner
/// module, and the inference host, which is an emscripten pair — a loader that
/// fetches the `.wasm` beside itself. This package ships no assets, being
/// plain Dart, so the application serves them; copying all four into
/// `web/wxscan/` works for a Flutter application and a plain Dart one alike,
/// since that directory is published as it stands.
library;

import 'dart:typed_data';

import '../result.dart';
import 'fetch.dart';
import 'worker.dart';

/// Pixel layouts [WxScanner.scanPixels] accepts, matching `WxScanPixelFormat`.
enum WxPixelFormat {
  gray(0, 1),
  rgb(1, 3),
  rgba(2, 4),
  bgr(3, 3),
  bgra(4, 4);

  const WxPixelFormat(this.nativeValue, this.bytesPerPixel);

  /// The value the native enum uses.
  final int nativeValue;

  /// How many bytes one pixel occupies in this layout.
  final int bytesPerPixel;
}

/// Where the browser build's three files are served from.
class WxScanWebPaths {
  /// The defaults put all four files in `web/wxscan/`.
  ///
  /// Note where each URL is resolved from, which is why the last one looks
  /// different: the page fetches the first two, and the worker imports the
  /// third, so `./wxscan_tflite.js` is a sibling of the worker script.
  const WxScanWebPaths({
    this.workerUrl = 'wxscan/wxscan_worker.js',
    this.wasmUrl = 'wxscan/wxscan_wasm.wasm',
    this.tfliteUrl = './wxscan_tflite.js',
  });

  /// The worker script, relative to the page.
  final String workerUrl;

  /// The scanner module, relative to the page.
  final String wasmUrl;

  /// The inference host's loader, **relative to the worker script**, since the
  /// worker is what imports it. It fetches `wxscan_tflite.wasm` from its own
  /// directory, which therefore needs no URL of its own.
  final String tfliteUrl;
}

/// The paths in use. Replaced by `configureWxScanWeb`.
WxScanWebPaths wxScanWebPaths = const WxScanWebPaths();

/// Fetches [url] as bytes.
Future<Uint8List> _fetch(String url) async {
  final response = await httpGet(url);
  if (response == null) {
    throw StateError(
      'wxscan_core: could not fetch $url. The browser build needs its files '
      'served by the application — see configureWxScanWeb() in '
      'package:wxscan_core/web.dart.',
    );
  }
  return response;
}

/// Starts a worker with the engine in it, fetching what it needs.
///
/// [WxScanner] is one caller. The other is the camera plugin, which forwards
/// the documents a scan produces rather than the outcomes parsed from them,
/// and so works one level below.
Future<WxScanWorker> startWxScanWorker({
  Uint8List? detectModel,
  Uint8List? srModel,
}) async {
  final paths = wxScanWebPaths;
  final withModels = detectModel != null && srModel != null;
  return WxScanWorker.start(
    workerUrl: paths.workerUrl,
    wxscanWasm: await _fetch(paths.wasmUrl),
    tfliteUrl: withModels ? paths.tfliteUrl : null,
    detectModel: detectModel,
    srModel: srModel,
  );
}

/// A scanner backed by the WebAssembly build, running in a worker.
class WxScanner {
  WxScanner._(this._worker);

  final WxScanWorker _worker;
  var _disposed = false;

  /// Whether the CNN detector is available.
  bool get hasDetector => _worker.hasDetector;

  /// Whether the super resolution stage is available.
  bool get hasSuperResolution => _worker.hasSuperResolution;

  /// Whether either CNN stage is available.
  bool get hasModels => hasDetector || hasSuperResolution;

  /// Creates a scanner, starting the worker that runs it.
  ///
  /// Passing null for both weights selects the mode without models, which
  /// still decodes but finds small or distant symbols far less often. Loading
  /// takes a moment: the worker fetches two WebAssembly modules.
  static Future<WxScanner> create({
    Uint8List? detectModel,
    Uint8List? srModel,
  }) async =>
      WxScanner._(await startWxScanWorker(
        detectModel: detectModel,
        srModel: srModel,
      ));

  void _checkAlive() {
    if (_disposed) {
      throw StateError('wxscan_core: this scanner has been disposed');
    }
  }

  /// Decodes an upright, tightly packed grayscale image.
  Future<ScanOutcome> scanGray(Uint8List gray, int width, int height) {
    _checkAlive();
    return _worker.scanGray(Uint8List.fromList(gray), width, height);
  }

  /// Decodes a colour image, converting it to grayscale first.
  Future<ScanOutcome> scanPixels(
    Uint8List pixels,
    int width,
    int height, {
    WxPixelFormat format = WxPixelFormat.rgba,
  }) {
    _checkAlive();
    return _worker.scanPixels(
        Uint8List.fromList(pixels), width, height, format.nativeValue);
  }

  /// Decodes a camera frame: a Y plane with a row stride, rotated upright.
  Future<ScanOutcome> scanFrame(
    Uint8List data,
    int width,
    int height, {
    int? rowStride,
    int rotation = 0,
    bool mirror = false,
  }) {
    _checkAlive();
    return _worker.scanFrame(
      Uint8List.fromList(data),
      width,
      height,
      rowStride: rowStride ?? width,
      rotation: rotation,
      mirror: mirror,
    );
  }

  /// Not available in a browser: there is no filesystem to read a path from.
  ///
  /// It exists so that code shared with the native scanner still compiles for
  /// the web, and says what to do instead rather than failing to build. Fetch
  /// or read the picture yourself and use [scanPixels].
  Future<ScanOutcome> scanPath(String path) => throw UnsupportedError(
        'wxscan_core: scanPath is not available in a browser, which has no '
        'filesystem. Read the picture yourself and use scanPixels.',
      );

  /// Not available in a browser. See [scanPath].
  ScanOutcome scanPathSync(String path) => throw UnsupportedError(
        'wxscan_core: scanPath is not available in a browser, which has no '
        'filesystem. Read the picture yourself and use scanPixels.',
      );

  static Never _noSync(String name) => throw UnsupportedError(
        'wxscan_core: $name is not available in a browser. The scanner runs in '
        'a worker, so results arrive as a message; use the asynchronous '
        'method of the same name.',
      );

  /// Not available in a browser: the scanner runs in a worker.
  ScanOutcome scanGraySync(Uint8List gray, int width, int height) =>
      _noSync('scanGraySync');

  /// Not available in a browser: the scanner runs in a worker.
  ScanOutcome scanPixelsSync(
    Uint8List pixels,
    int width,
    int height, {
    WxPixelFormat format = WxPixelFormat.rgba,
  }) =>
      _noSync('scanPixelsSync');

  /// Not available in a browser: the scanner runs in a worker.
  ScanOutcome scanFrameSync(
    Uint8List data,
    int width,
    int height, {
    int? rowStride,
    int rotation = 0,
    bool mirror = false,
  }) =>
      _noSync('scanFrameSync');

  /// Stops the worker. Using the scanner afterwards throws.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _worker.dispose();
  }
}
