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

import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../result.dart';
import 'decode.dart';
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
      'wxscan: could not fetch $url. The browser build needs its files '
      'served by the application — see configureWxScanWeb() in '
      'package:wxscan/web.dart.',
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
  WxScanner._(this._worker) {
    _live.add(this);
  }

  final WxScanWorker _worker;
  var _disposed = false;

  /// Every scanner that has not been disposed.
  ///
  /// Kept here rather than asked of the library: a browser scanner is a worker
  /// reached by message, and there is no table on this side of that message to
  /// ask. Counting the objects answers the same question — how many are alive
  /// — which is what this is for.
  ///
  /// Strong references on purpose. There is no collector hook that would stop
  /// a worker, so a scanner nobody disposes keeps its worker either way, and a
  /// count that quietly forgot about it would be the wrong answer.
  static final _live = <WxScanner>{};

  /// Whether the CNN detector is available.
  bool get hasDetector => _worker.hasDetector;

  /// Whether the super resolution stage is available.
  bool get hasSuperResolution => _worker.hasSuperResolution;

  /// Whether either CNN stage is available.
  bool get hasModels => hasDetector || hasSuperResolution;

  /// How many scanners are alive on this page, this one included.
  ///
  /// For finding one that was never disposed. A test can assert it is back to
  /// zero at the end; a screen that opens and closes can be watched across a
  /// few passes to see whether it climbs.
  ///
  /// This is a diagnostic. Nothing about how an application scans should depend
  /// on it.
  ///
  /// It matters more here than it does natively: a browser has no finalizer
  /// standing behind a scanner nobody disposed. Its worker, and the two
  /// WebAssembly modules in it, stay for the life of the page.
  static int get liveCount => _live.length;

  /// Runs [body] with a scanner, and disposes it however that ends.
  ///
  /// For work with a beginning and an end — a picture the user just picked, a
  /// batch of files — where a scanner that outlives it is only a way to forget
  /// to dispose it:
  ///
  /// ```dart
  /// final outcome = await WxScanner.use(
  ///   (scanner) => scanner.scanImage(bytes),
  ///   detectModel: detect,
  ///   srModel: sr,
  /// );
  /// ```
  ///
  /// Do not use it for a screen that scans continuously: creating a scanner
  /// starts a worker and fetches two WebAssembly modules, which is far too much
  /// to pay per frame. Hold one for as long as the screen lives and [dispose]
  /// it there.
  ///
  /// The scanner is gone by the time this returns, so nothing [body] hands back
  /// may reference it. Results do not: they are plain values.
  static Future<R> use<R>(
    FutureOr<R> Function(WxScanner scanner) body, {
    Uint8List? detectModel,
    Uint8List? srModel,
    String? detectModelPath,
    String? srModelPath,
  }) async {
    final scanner = await create(
      detectModel: detectModel,
      srModel: srModel,
      detectModelPath: detectModelPath,
      srModelPath: srModelPath,
    );
    try {
      return await body(scanner);
    } finally {
      await scanner.dispose();
    }
  }

  /// Creates a scanner, starting the worker that runs it.
  ///
  /// Passing null for both weights selects the mode without models, which
  /// still decodes but finds small or distant symbols far less often. Loading
  /// takes a moment: the worker fetches two WebAssembly modules.
  ///
  /// [detectModelPath] and [srModelPath] exist on the other platforms and
  /// throw [UnsupportedError] here: a browser has no filesystem, and the
  /// scanner is a WebAssembly module in a worker that could not open a path if
  /// there were one. Refused rather than ignored, because a path quietly
  /// dropped leaves the page decoding without its detector and nothing said.
  /// Fetch the weights and pass the bytes.
  static Future<WxScanner> create({
    Uint8List? detectModel,
    Uint8List? srModel,
    String? detectModelPath,
    String? srModelPath,
  }) async {
    if (detectModelPath != null || srModelPath != null) {
      throw UnsupportedError(
        'wxscan: a browser cannot read weights from a path. Pass the bytes '
        'instead — detectModel and srModel — fetched or loaded from an asset.',
      );
    }
    return WxScanner._(
      await startWxScanWorker(detectModel: detectModel, srModel: srModel),
    );
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('wxscan: this scanner has been disposed');
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
      Uint8List.fromList(pixels),
      width,
      height,
      format.nativeValue,
    );
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
    'wxscan: scanPath is not available in a browser, which has no '
    'filesystem. Read the picture yourself and use scanPixels.',
  );

  /// Not available in a browser. See [scanPath].
  ScanOutcome scanPathSync(String path) => throw UnsupportedError(
    'wxscan: scanPath is not available in a browser, which has no '
    'filesystem. Read the picture yourself and use scanPixels.',
  );

  /// Decodes an encoded picture already in memory.
  ///
  /// [data] is the file — not pixels — exactly as for the native scanner, and
  /// this is the way to reach a picture in a browser at all, there being no
  /// paths. A file from an `<input type=file>`, a download, an asset.
  ///
  /// The browser does the decoding here rather than the wasm module, which
  /// carries no decoders. That is not a lesser path: it reads everything the
  /// native build does and more — WebP, AVIF, and HEIC on Apple platforms,
  /// which natively has to be handed back to the caller. The orientation the
  /// file records is applied, as it is natively.
  ///
  /// Throws [PictureUnreadable] with [PictureReadFailure.unsupportedFormat],
  /// and a null `path`, when the browser cannot decode the bytes. A picture
  /// with no code in it returns an empty [ScanOutcome], which is a different
  /// thing.
  Future<ScanOutcome> scanImage(Uint8List data) async {
    _checkAlive();
    final decoded = await decodeImage(data);
    if (decoded == null) {
      throw const PictureUnreadable(null, PictureReadFailure.unsupportedFormat);
    }
    // Alive again after the await: decoding is not instant, and the scanner
    // can be disposed while a large photograph is being read.
    _checkAlive();
    return _worker.scanPixels(
      decoded.pixels,
      decoded.width,
      decoded.height,
      WxPixelFormat.rgba.nativeValue,
    );
  }

  /// Not available in a browser: the browser's decoder is asynchronous, and so
  /// is the scanner. See [scanImage].
  ScanOutcome scanImageSync(Uint8List data) => _noSync('scanImageSync');

  /// Zero in a browser: there is no native scanner to point at.
  ///
  /// Natively this is how the camera plugin scans against the application's own
  /// scanner instead of building a second one. Here the scanner is a worker,
  /// and the camera reaches it by message rather than by pointer, so there is
  /// nothing to hand over — and nothing is duplicated either way.
  @internal
  int get nativeHandle {
    _checkAlive();
    return 0;
  }

  static Never _noSync(String name) => throw UnsupportedError(
    'wxscan: $name is not available in a browser. The scanner runs in '
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
  }) => _noSync('scanPixelsSync');

  /// Not available in a browser: the scanner runs in a worker.
  ScanOutcome scanFrameSync(
    Uint8List data,
    int width,
    int height, {
    int? rowStride,
    int rotation = 0,
    bool mirror = false,
  }) => _noSync('scanFrameSync');

  /// Stops the worker. Using the scanner afterwards throws.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _live.remove(this);
    await _worker.dispose();
  }
}
