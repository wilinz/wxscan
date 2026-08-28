import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'bindings.dart';
import 'ffi.dart';
import 'platform_decoder.dart';
import 'result.dart';

/// How the bytes of a colour buffer are laid out.
///
/// The conversion to grayscale happens natively, so a caller decoding a PNG or
/// a JPEG hands the pixels over as they are rather than converting them first.
enum WxPixelFormat {
  /// One byte per pixel, already grayscale.
  gray(0, 1),

  /// Three bytes per pixel, red first. What an image decoder usually gives.
  rgb(1, 3),

  /// Four bytes per pixel, red first; the alpha channel is ignored.
  rgba(2, 4),

  /// Three bytes per pixel, blue first.
  bgr(3, 3),

  /// Four bytes per pixel, blue first; the alpha channel is ignored.
  bgra(4, 4);

  const WxPixelFormat(this.nativeValue, this.bytesPerPixel);

  /// The value the C ABI uses.
  final int nativeValue;

  /// How many bytes one pixel takes in this layout.
  final int bytesPerPixel;
}

/// A scanner instance holding the loaded models.
///
/// Creating one is expensive, since it builds an inference interpreter, so keep
/// it for the lifetime of the screen that scans and [dispose] it afterwards.
///
/// Scanning runs on a worker isolate that belongs to this scanner, so a large
/// image does not block the caller and the isolate is not rebuilt per frame.
/// One instance decodes one image at a time; calls queue up. Create several
/// instances to scan in parallel.
///
/// The synchronous variants skip the worker and run on the calling isolate, for
/// callers already off the main one.
class WxScanner implements ffi.Finalizable {
  WxScanner._(this._handle, this._worker, _Snapshot snapshot)
      : hasDetector = snapshot.hasDetector,
        hasSuperResolution = snapshot.hasSuperResolution,
        _scaleFactor = snapshot.scaleFactor,
        _confidenceThreshold = snapshot.confidenceThreshold,
        _nmsThreshold = snapshot.nmsThreshold {
    // The finalizer carries one machine word to the release function, which is
    // exactly what a handle is. Typed as a pointer because that is the only
    // token a NativeFinalizer takes; nothing ever dereferences it, here or in
    // Rust. Handles start at one, so the token is never null.
    _finalizer.attach(this, ffi.Pointer<ffi.Void>.fromAddress(_handle),
        detach: this);
    _leakWatch?.attach(this, _handle, detach: this);
  }

  /// Says so when a scanner reaches the collector without having been disposed.
  ///
  /// Only the native finalizer above actually releases anything; this one runs
  /// beside it purely to leave a line in the log, because from the outside a
  /// scanner whose weights sat in memory until a collection happened to come
  /// round looks exactly like one that was disposed on time. Best-effort, as
  /// every finalizer is, and absent in a release build.
  static final Finalizer<int>? _leakWatch = () {
    Finalizer<int>? watch;
    assert(() {
      watch = Finalizer<int>((handle) {
        developer.log(
          'a scanner ($handle) was collected without dispose(). It is released '
          'now, but its models stayed in memory until the collector reached '
          'it. Dispose it where it goes out of use, or use WxScanner.use().',
          name: 'wxscan',
        );
      });
      return true;
    }());
    return watch;
  }();

  static final _finalizer = ffi.NativeFinalizer(scannerFinalizer);

  /// Scanners with work in flight, kept here so the garbage collector cannot
  /// run the finalizer, and free the native scanner, while the worker isolate
  /// is inside a call that uses it.
  static final _busy = <WxScanner>{};

  /// The scanner, as the library's own handle for it. Not an address: it names
  /// an entry in a table inside the library, so a stale one is refused rather
  /// than followed.
  final int _handle;
  final _ScanWorker _worker;
  bool _disposed = false;

  /// Whether the SSD detector network is loaded. Without it decoding still
  /// works, but small or distant symbols are detected far less reliably.
  final bool hasDetector;

  /// Whether the super resolution network is loaded. It upscales small crops
  /// before decoding, which is what recovers a symbol that is merely small.
  final bool hasSuperResolution;

  /// Whether both networks are loaded.
  bool get hasModels => hasDetector && hasSuperResolution;

  // The settings are mirrored here rather than read back from native on every
  // access. The native side guards the scanner with one mutex, which a scan in
  // progress holds, so a getter that reached for it would block the caller for
  // as long as that scan takes. Nothing else can change these values, so a
  // mirror cannot drift.
  double _scaleFactor;
  double _confidenceThreshold;
  double _nmsThreshold;

  /// How many scanners are alive in this process, this one included.
  ///
  /// For finding one that was never disposed. A test can assert it is back to
  /// zero at the end; a screen that opens and closes can be watched across a
  /// few passes to see whether it climbs. It counts scanners, not holders, so
  /// one lent to `wxscan_live` still counts once.
  ///
  /// This is a diagnostic. Nothing about how an application scans should depend
  /// on it.
  static int get liveCount => wxscan_scanner_count();

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
  /// builds an inference interpreter, which is far too much to pay per frame.
  /// Hold one for as long as the screen lives and [dispose] it there.
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

  /// Creates a scanner from model bytes, or from model files.
  ///
  /// The weights may be TFLite or ONNX; which formats work depends on the
  /// backends the native library was built with, and the format is detected
  /// from the buffer rather than declared.
  ///
  /// Passing null for everything selects the mode without models. If a model
  /// fails to load, this falls back to that mode rather than throwing, so a
  /// corrupt asset degrades the detection rate instead of breaking the
  /// feature; check [hasDetector] for which mode is active.
  ///
  /// [detectModelPath] and [srModelPath] are the same weights as files on
  /// disk, for weights that were downloaded or copied somewhere. The native
  /// library reads them on the worker isolate, so the megabyte is never held
  /// here. **A Flutter asset is not a file**: it lives inside the application
  /// package with no path to open, so `assets/models/detect.tflite` names
  /// nothing — load it with `rootBundle` and pass the bytes.
  ///
  /// A model is given as bytes or as a path, never both, and a path is
  /// unsupported in a browser, which has no filesystem to read.
  static Future<WxScanner> create({
    Uint8List? detectModel,
    Uint8List? srModel,
    String? detectModelPath,
    String? srModelPath,
  }) async {
    if (detectModel != null && detectModelPath != null) {
      throw ArgumentError('wxscan: pass detectModel or detectModelPath, not both');
    }
    if (srModel != null && srModelPath != null) {
      throw ArgumentError('wxscan: pass srModel or srModelPath, not both');
    }
    // Before anything is scanned, so that scanImage reads what the platform
    // reads rather than only png, jpeg and gif. Idempotent, and a no-op where
    // the platform has nothing to lend.
    installPlatformImageDecoder();
    final worker = await _ScanWorker.spawn();
    // Declared out here so the catch below can give it back: between the
    // native scanner existing and a WxScanner being built around it, nothing
    // else holds it.
    var handle = 0;
    try {
      if (detectModelPath != null || srModelPath != null) {
        final (id, status) =
            await worker.run(_CreatePathRequest(detectModelPath, srModelPath));
        handle = id;
        if (handle == 0) {
          // Which of the three mistakes it was, since only the caller can fix
          // it and only this line knows. Not thrown, for the same reason
          // weights that will not load are not: the scanner still decodes.
          developer.log(
            'weights were not loaded from those paths (${_pathTrouble(status)}): '
            'detect=$detectModelPath sr=$srModelPath. Continuing without them, '
            'so detection is image processing only',
            name: 'wxscan',
          );
        }
      } else {
        handle = await worker.run(_CreateRequest(detectModel, srModel));
      }
      if (handle == 0) {
        // A model that will not load is not fatal; plain decoding still reads
        // ordinary symbols. It is worth saying out loud, though: this used to
        // happen silently, and a whole platform ran without its detector for
        // weeks before anyone noticed the decoding rate had dropped.
        developer.log(
          'weights were refused by the native backend; '
          'continuing without them, so detection is image processing only',
          name: 'wxscan',
        );
        handle = await worker.run(const _CreateRequest(null, null));
      }
      if (handle == 0) {
        throw StateError('wxscan: could not create a scanner');
      }
      final snapshot = await worker.run(_SnapshotRequest(handle));
      return WxScanner._(handle, worker, snapshot);
    } catch (_) {
      // The native scanner exists by now, and no WxScanner was built to carry
      // a finalizer for it, so nothing else will ever give it back. Releasing
      // it here is the only chance: otherwise it holds its weights for the
      // life of the process, which is what liveCount would go on reporting.
      if (handle != 0) wxscan_scanner_release(handle);
      await worker.close();
      rethrow;
    }
  }

  /// Scales the image down before detection, which trades detection rate for
  /// speed. Values outside `(0, 1]` restore the default, which targets an area
  /// of 400x400.
  double get scaleFactor => _scaleFactor;

  set scaleFactor(double value) {
    _checkAlive();
    // Native restores the automatic default for anything out of range, and the
    // mirror has to agree with it.
    _scaleFactor = value > 0 && value <= 1 ? value : -1;
    _configure(_Setting.scaleFactor, value);
  }

  /// How confident the detector must be to report a candidate, 0.2 by default.
  ///
  /// Lowering it recalls more weak symbols along with more false positives;
  /// raising it does the reverse. Values outside `(0, 1)` are ignored. Reads
  /// back negative when no detector is loaded.
  double get confidenceThreshold => _confidenceThreshold;

  set confidenceThreshold(double value) {
    _checkAlive();
    // Native ignores anything outside the open interval, and so does the
    // mirror; a rejected value must not read back as if it took.
    if (value <= 0 || value >= 1 || !hasDetector) return;
    _confidenceThreshold = value;
    _configure(_Setting.confidenceThreshold, value);
  }

  /// The overlap above which two candidates are treated as one symbol, 0.45 by
  /// default. Values outside `(0, 1)` are ignored.
  double get nmsThreshold => _nmsThreshold;

  set nmsThreshold(double value) {
    _checkAlive();
    if (value <= 0 || value >= 1 || !hasDetector) return;
    _nmsThreshold = value;
    _configure(_Setting.nmsThreshold, value);
  }

  /// Applies a setting on the worker, so it queues behind whatever is being
  /// scanned instead of contending for the scanner's lock.
  ///
  /// The result is not awaited, since assigning to a property cannot be. A
  /// failure can only mean the scanner went away underneath, which the mirror
  /// already reflects, so it is swallowed rather than left to surface as an
  /// unhandled asynchronous error.
  void _configure(_Setting setting, double value) {
    _track(_worker.run(_ConfigRequest(_handle, setting, value)))
        .ignore();
  }

  /// Keeps this scanner reachable until [work] finishes.
  Future<T> _track<T>(Future<T> work) {
    _busy.add(this);
    return work.whenComplete(() {
      if (!_worker.hasPending) _busy.remove(this);
    });
  }

  /// Decodes a tightly packed grayscale image, one byte per pixel.
  Future<ScanOutcome> scanGray(Uint8List gray, int width, int height) =>
      scanFrame(gray, width, height, rowStride: width);

  /// Decodes a colour image, converting it to grayscale natively.
  ///
  /// This is the entry point for a decoded still image: hand it the pixels an
  /// image library produced, in whatever layout it produced them, rather than
  /// converting them in Dart.
  ///
  /// Rows are tightly packed, so [pixels] must hold
  /// `width * height * format.bytesPerPixel` bytes.
  Future<ScanOutcome> scanPixels(
    Uint8List pixels,
    int width,
    int height, {
    WxPixelFormat format = WxPixelFormat.rgba,
  }) {
    _checkAlive();
    _validatePixels(pixels, width, height, format);
    return _track(_worker.run(_PixelsRequest(
      _handle,
      pixels,
      width,
      height,
      format,
    )));
  }

  /// Decodes a camera frame.
  ///
  /// * [rowStride] is the byte distance between rows and may exceed [width].
  /// * [rotation] is the clockwise angle in degrees needed to bring the frame
  ///   upright; the returned coordinates are in the rotated image.
  /// * [mirror] mirrors the returned x coordinates. The frame itself is never
  ///   mirrored, because the detector is trained on unmirrored input; use this
  ///   when the preview is shown mirrored, as front-facing previews usually are.
  ///
  /// Throws [ArgumentError] if the dimensions and the buffer do not agree,
  /// which is a mistake in the call rather than a frame with nothing in it.
  Future<ScanOutcome> scanFrame(
    Uint8List data,
    int width,
    int height, {
    int? rowStride,
    int rotation = 0,
    bool mirror = false,
  }) {
    _checkAlive();
    final stride = rowStride ?? width;
    _validateFrame(data, width, height, stride, rotation);
    return _track(_worker.run(_FrameRequest(
      _handle,
      data,
      width,
      height,
      stride,
      rotation,
      mirror,
    )));
  }

  /// Decodes a picture on disk, reading and decoding the file natively.
  ///
  /// This is the cheap way to scan a file: nothing is decoded on the Dart side
  /// and no pixel buffer crosses an isolate boundary. A 12 megapixel
  /// photograph is 48 MB as RGBA, and handing that to [scanPixels] copies it
  /// once into the worker and again into native memory; here the file is read,
  /// decoded and reduced to grayscale without any of it leaving native code.
  ///
  /// The orientation recorded in the file is applied, so a photograph taken
  /// with the phone turned sideways comes back upright and its coordinates
  /// match what was on screen.
  ///
  /// Throws [PictureUnreadable] when the file could not be read or is not a
  /// format this build decodes — HEIC in particular, which wants the
  /// platform's decoder and [scanPixels]. A picture that simply has no code in
  /// it returns an empty [ScanOutcome] instead, which is a different thing.
  Future<ScanOutcome> scanPath(String path) async {
    _checkAlive();
    final (status, outcome) =
        await _track(_worker.run(_PathRequest(_handle, path)));
    return _unwrapPath(path, status, outcome);
  }

  /// Decodes a picture on disk on the current isolate. See [scanPath].
  ScanOutcome scanPathSync(String path) {
    _checkAlive();
    final (status, outcome) = _PathRequest(_handle, path).run();
    return _unwrapPath(path, status, outcome);
  }

  /// Decodes an encoded picture already in memory.
  ///
  /// [data] is the file — PNG, JPEG or GIF — not pixels; the format is read
  /// from the bytes, so nothing has to say which it is. For pixels you already
  /// hold, use [scanPixels] instead.
  ///
  /// This is [scanPath] for a caller that has the bytes rather than a path: a
  /// picture a picker handed over as data, an asset, a download, or a browser,
  /// where there are no paths at all. Decoding happens natively, so a 12
  /// megapixel photograph never exists as 48 MB of RGBA on the Dart side.
  ///
  /// The orientation recorded in the file is applied, exactly as for a path.
  ///
  /// Throws [PictureUnreadable] with [PictureReadFailure.unsupportedFormat]
  /// when the bytes are not a picture this build decodes — HEIC in particular,
  /// which wants the platform's decoder and [scanPixels]. Its `path` is null,
  /// there having been no file. A picture that simply has no code in it
  /// returns an empty [ScanOutcome] instead, which is a different thing.
  Future<ScanOutcome> scanImage(Uint8List data) async {
    _checkAlive();
    final (status, outcome) =
        await _track(_worker.run(_BytesRequest(_handle, data)));
    return _unwrapPath(null, status, outcome);
  }

  /// Decodes an encoded picture on the current isolate. See [scanImage].
  ScanOutcome scanImageSync(Uint8List data) {
    _checkAlive();
    final (status, outcome) = _BytesRequest(_handle, data).run();
    return _unwrapPath(null, status, outcome);
  }

  /// Decodes a tightly packed grayscale image on the current isolate.
  ScanOutcome scanGraySync(Uint8List gray, int width, int height) =>
      scanFrameSync(gray, width, height, rowStride: width);

  /// Decodes a colour image on the current isolate. See [scanPixels].
  ScanOutcome scanPixelsSync(
    Uint8List pixels,
    int width,
    int height, {
    WxPixelFormat format = WxPixelFormat.rgba,
  }) {
    _checkAlive();
    _validatePixels(pixels, width, height, format);
    return _PixelsRequest(_handle, pixels, width, height, format).run();
  }

  /// Decodes a camera frame on the current isolate. See [scanFrame].
  ScanOutcome scanFrameSync(
    Uint8List data,
    int width,
    int height, {
    int? rowStride,
    int rotation = 0,
    bool mirror = false,
  }) {
    _checkAlive();
    final stride = rowStride ?? width;
    _validateFrame(data, width, height, stride, rotation);
    return _FrameRequest(
      _handle,
      data,
      width,
      height,
      stride,
      rotation,
      mirror,
    ).run();
  }

  /// The library's handle for this scanner, for a camera plugin to scan with.
  ///
  /// This exists so that `wxscan_live` can drive the camera against the same
  /// scanner an application already holds, rather than building a second one:
  /// two scanners mean two copies of the CNN weights in memory, and a
  /// threshold changed on one that the other never sees.
  ///
  /// Not an address. It names an entry in a table inside the library, so a
  /// handle that has been released is refused rather than followed — which is
  /// what makes it safe to hand to another language at all, where the two
  /// sides cannot see each other's lifetimes. A borrower takes its own
  /// reference to it and gives that back when it is done; the scanner goes
  /// when its last holder does, in whichever order that happens.
  ///
  /// Not for application code all the same: the pairing is machinery, and a
  /// borrow that is never given back keeps the weights in memory for the life
  /// of the process.
  ///
  /// Zero in a browser, which has no such handle: the scanner is a worker
  /// there, and the camera reaches it by message.
  @internal
  int get nativeHandle {
    // Guarded like every other member. A disposed scanner's handle names
    // nothing, and the borrower's fallback for that is to build a scanner of
    // its own — from weights the borrower deliberately did not send, because
    // it believed it was being lent one. The camera would come up without its
    // detector and nothing would say why, so the mistake is refused here
    // instead, where it was made.
    _checkAlive();
    return _handle;
  }

  /// Releases the native scanner and its worker isolate. Further calls throw.
  ///
  /// Awaiting this matters: work already handed to the worker is still using
  /// the native scanner, so it is drained before the scanner is freed. Calls
  /// that were queued but not started fail with a [StateError].
  ///
  /// A scanner that is dropped without this is still released, but only when
  /// the garbage collector gets to it, which keeps the models in memory in the
  /// meantime.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _worker.close();
    _busy.remove(this);
    _finalizer.detach(this);
    _leakWatch?.detach(this);
    wxscan_scanner_release(_handle);
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('wxscan: the scanner has been disposed');
    }
  }
}

void _validateFrame(
  Uint8List data,
  int width,
  int height,
  int rowStride,
  int rotation,
) {
  if (width <= 0) {
    throw ArgumentError.value(width, 'width', 'must be positive');
  }
  if (height <= 0) {
    throw ArgumentError.value(height, 'height', 'must be positive');
  }
  if (rowStride < width) {
    throw ArgumentError.value(
      rowStride,
      'rowStride',
      'must be at least width ($width)',
    );
  }
  if (data.length < rowStride * height) {
    throw ArgumentError.value(
      data.length,
      'data.length',
      'too short for ${rowStride}x$height; expected at least '
          '${rowStride * height} bytes',
    );
  }
  if (rotation % 90 != 0) {
    throw ArgumentError.value(
      rotation,
      'rotation',
      'must be a multiple of 90 degrees',
    );
  }
}

void _validatePixels(
  Uint8List pixels,
  int width,
  int height,
  WxPixelFormat format,
) {
  if (width <= 0) {
    throw ArgumentError.value(width, 'width', 'must be positive');
  }
  if (height <= 0) {
    throw ArgumentError.value(height, 'height', 'must be positive');
  }
  final need = width * height * format.bytesPerPixel;
  if (pixels.length < need) {
    throw ArgumentError.value(
      pixels.length,
      'pixels.length',
      'too short for ${width}x$height ${format.name}; expected at least '
          '$need bytes',
    );
  }
}

/// A unit of work the worker isolate can run.
///
/// A request runs the same way on either side, so the synchronous entry points
/// call [run] directly instead of duplicating the native call.
sealed class _Request<T> {
  const _Request();

  T run();
}

class _CreateRequest extends _Request<int> {
  const _CreateRequest(this.detect, this.sr);

  final Uint8List? detect;
  final Uint8List? sr;

  @override
  int run() {
    final detectBuf = _copyToNative(detect);
    final srBuf = _copyToNative(sr);
    try {
      return wxscan_scanner_new(
        detectBuf ?? ffi.nullptr,
        detect?.length ?? 0,
        srBuf ?? ffi.nullptr,
        sr?.length ?? 0,
      );
    } finally {
      if (detectBuf != null) calloc.free(detectBuf);
      if (srBuf != null) calloc.free(srBuf);
    }
  }
}

/// Builds a scanner from weight files, reading them on the worker isolate.
///
/// The reading is here rather than in [WxScanner.create] so that a megabyte of
/// weights is never held on the isolate that called it: the path goes across,
/// the bytes never come back.
///
/// Carries the status out rather than throwing, because the three ways a path
/// can be wrong are the caller's to tell apart and a handle of zero says only
/// that something was.
class _CreatePathRequest extends _Request<(int, int)> {
  const _CreatePathRequest(this.detectPath, this.srPath);

  final String? detectPath;
  final String? srPath;

  @override
  (int, int) run() {
    final d = detectPath?.toNativeUtf8();
    final s = srPath?.toNativeUtf8();
    final status = calloc<ffi.Int32>();
    try {
      final id = wxscan_scanner_new_path(
        d?.cast() ?? ffi.nullptr,
        s?.cast() ?? ffi.nullptr,
        status,
      );
      return (id, status.value);
    } finally {
      calloc.free(status);
      if (d != null) calloc.free(d);
      if (s != null) calloc.free(s);
    }
  }
}

/// A `WxScanStatus` from [_CreatePathRequest], as something worth reading.
String _pathTrouble(int status) => switch (status) {
      1 => 'a path is not valid text',
      2 => 'a file could not be read',
      4 => 'a file was read but is not weights this build can load',
      _ => 'the scanner could not be created',
    };

/// Which setting a [_ConfigRequest] applies.
enum _Setting { scaleFactor, confidenceThreshold, nmsThreshold }

/// The settings as native reports them, taken once at creation.
class _Snapshot {
  const _Snapshot({
    required this.hasDetector,
    required this.hasSuperResolution,
    required this.scaleFactor,
    required this.confidenceThreshold,
    required this.nmsThreshold,
  });

  final bool hasDetector;
  final bool hasSuperResolution;
  final double scaleFactor;
  final double confidenceThreshold;
  final double nmsThreshold;
}

class _SnapshotRequest extends _Request<_Snapshot> {
  const _SnapshotRequest(this.handle);

  final int handle;

  @override
  _Snapshot run() {
    return _Snapshot(
      hasDetector: wxscan_scanner_has_detector(handle) != 0,
      hasSuperResolution: wxscan_scanner_has_super_resolution(handle) != 0,
      scaleFactor: wxscan_scanner_scale_factor(handle),
      confidenceThreshold: wxscan_scanner_confidence_threshold(handle),
      nmsThreshold: wxscan_scanner_nms_threshold(handle),
    );
  }
}

class _ConfigRequest extends _Request<void> {
  const _ConfigRequest(this.handle, this.setting, this.value);

  final int handle;
  final _Setting setting;
  final double value;

  @override
  void run() {
    switch (setting) {
      case _Setting.scaleFactor:
        wxscan_scanner_set_scale_factor(handle, value);
      case _Setting.confidenceThreshold:
        wxscan_scanner_set_confidence_threshold(handle, value);
      case _Setting.nmsThreshold:
        wxscan_scanner_set_nms_threshold(handle, value);
    }
  }
}

/// Scans a frame. The bytes are copied into native memory because Dart may
/// relocate a [Uint8List] during a garbage collection, which a pointer handed
/// to native code would not survive.
class _FrameRequest extends _Request<ScanOutcome> {
  const _FrameRequest(
    this.handle,
    this.data,
    this.width,
    this.height,
    this.rowStride,
    this.rotation,
    this.mirror,
  );

  final int handle;
  final Uint8List data;
  final int width;
  final int height;
  final int rowStride;
  final int rotation;
  final bool mirror;

  @override
  ScanOutcome run() => _withNative(data, (buf) {
        return wxscan_scan_frame(
          handle,
          buf,
          width,
          height,
          rowStride,
          rotation,
          mirror ? 1 : 0,
        );
      });
}

class _PixelsRequest extends _Request<ScanOutcome> {
  const _PixelsRequest(
    this.handle,
    this.pixels,
    this.width,
    this.height,
    this.format,
  );

  final int handle;
  final Uint8List pixels;
  final int width;
  final int height;
  final WxPixelFormat format;

  @override
  ScanOutcome run() => _withNative(pixels, (buf) {
        return wxscan_scan_pixels(
          handle,
          buf,
          width,
          height,
          format.nativeValue,
        );
      });
}

/// Turns the native status into either an outcome or the exception it stands
/// for. It arrives as a plain integer because an exception thrown inside the
/// worker isolate reaches the caller with its type flattened away.
/// Turns a native status into a result or an exception.
///
/// [path] is null when the bytes came from [WxScanner.scanImage], where status
/// 2 cannot arise: there was nothing to open.
ScanOutcome _unwrapPath(String? path, int status, ScanOutcome outcome) =>
    switch (status) {
      0 => outcome,
      2 => throw PictureUnreadable(path, PictureReadFailure.unreadable),
      3 => throw PictureUnreadable(path, PictureReadFailure.unsupportedFormat),
      // 1 is a null or non-UTF-8 argument, which from here can only be
      // something this library failed to hand over rather than anything the
      // caller did.
      _ => throw StateError(
          'wxscan: scanning ${path ?? 'the image data'} failed ($status)'),
    };

/// Reads a picture from a path natively, carrying the status back rather than
/// throwing: the worker isolate flattens exception types on the way out.
class _PathRequest extends _Request<(int, ScanOutcome)> {
  const _PathRequest(this.handle, this.path);

  final int handle;
  final String path;

  @override
  (int, ScanOutcome) run() {
    final cPath = path.toNativeUtf8();
    final status = calloc<ffi.Int32>();
    ffi.Pointer<WxScanResults> out = ffi.nullptr;
    try {
      out = wxscan_scan_path(
        handle,
        cPath.cast(),
        status,
      );
      if (out == ffi.nullptr) return (status.value, ScanOutcome.empty);
      return (status.value, _readOutcome(out.ref));
    } finally {
      if (out != ffi.nullptr) wxscan_results_free(out);
      calloc.free(status);
      calloc.free(cPath);
    }
  }
}

/// Decodes an encoded picture held in memory, carrying the status back rather
/// than throwing, for the same reason [_PathRequest] does.
class _BytesRequest extends _Request<(int, ScanOutcome)> {
  const _BytesRequest(this.handle, this.data);

  final int handle;
  final Uint8List data;

  @override
  (int, ScanOutcome) run() {
    final buf = calloc<ffi.Uint8>(data.length);
    buf.asTypedList(data.length).setAll(0, data);
    final status = calloc<ffi.Int32>();
    ffi.Pointer<WxScanResults> out = ffi.nullptr;
    try {
      out = wxscan_scan_bytes(
        handle,
        buf,
        data.length,
        status,
      );
      if (out == ffi.nullptr) return (status.value, ScanOutcome.empty);
      return (status.value, _readOutcome(out.ref));
    } finally {
      if (out != ffi.nullptr) wxscan_results_free(out);
      calloc.free(status);
      calloc.free(buf);
    }
  }
}

/// Copies [data] into native memory, runs [scan], and reads the outcome,
/// releasing both buffers whatever happens.
ScanOutcome _withNative(
  Uint8List data,
  ffi.Pointer<WxScanResults> Function(ffi.Pointer<ffi.Uint8>) scan,
) {
  final buf = calloc<ffi.Uint8>(data.length);
  buf.asTypedList(data.length).setAll(0, data);
  ffi.Pointer<WxScanResults> out = ffi.nullptr;
  try {
    out = scan(buf);
    if (out == ffi.nullptr) return ScanOutcome.empty;
    return _readOutcome(out.ref);
  } finally {
    if (out != ffi.nullptr) wxscan_results_free(out);
    calloc.free(buf);
  }
}

/// The isolate one scanner does its work on.
///
/// It outlives the individual calls, so scanning a stream costs one message
/// round trip per frame rather than an isolate spawn. Requests are answered in
/// order, which matches the native side serializing them anyway.
class _ScanWorker {
  _ScanWorker._(this._isolate, this._commands, this._responses, this._exit) {
    _responses.listen(_onResponse);
    // An isolate that dies without answering would otherwise leave every
    // caller waiting forever, and `close` — which waits for exactly those
    // futures — would never return. That is worse than it sounds: `dispose`
    // awaits `close`, so the scanner would never be released, never leave the
    // set that holds it, and the finalizer standing behind it could never run
    // either. One dead isolate would pin the models for the life of the
    // process and hang everything that touched it.
    _exit.listen((_) => _failAll('the scanner isolate stopped unexpectedly'));
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;

  /// Told when the isolate stops for any reason, including one it did not
  /// choose: an uncaught error, or the process running out of memory.
  final ReceivePort _exit;

  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;

  /// No longer taking work. Set by [close], and by the isolate dying.
  var _closed = false;

  /// The ports are shut and the isolate is killed. Separate from [_closed]
  /// because an isolate that died on its own stops taking work without any of
  /// that having happened yet, and [close] still has to do it.
  var _cleaned = false;

  static Future<_ScanWorker> spawn() async {
    final setup = ReceivePort();
    final exit = ReceivePort();
    final isolate = await Isolate.spawn(
      _entry,
      setup.sendPort,
      onExit: exit.sendPort,
      onError: exit.sendPort,
    );
    final responses = ReceivePort();
    final commands = await setup.first as SendPort;
    setup.close();
    commands.send(responses.sendPort);
    return _ScanWorker._(isolate, commands, responses, exit);
  }

  /// Fails everything still outstanding, for when no answer is ever coming.
  ///
  /// Closing is part of it: an isolate that has stopped will not answer the
  /// next request either, and `run` would go on handing out futures that
  /// nobody completes — which puts back exactly the hang this is here to
  /// prevent, one request later. It runs even with nothing pending, because an
  /// isolate that dies while idle still has to stop taking work.
  void _failAll(String why) {
    _closed = true;
    if (_pending.isEmpty) return;
    final waiting = _pending.values.toList(growable: false);
    _pending.clear();
    for (final c in waiting) {
      if (!c.isCompleted) c.completeError(StateError('wxscan: $why'));
    }
  }

  /// Whether any request is still outstanding.
  bool get hasPending => _pending.isNotEmpty;

  Future<T> run<T>(_Request<T> request) {
    if (_closed) {
      throw StateError('wxscan: the scanner has been disposed');
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send((id, request));
    return completer.future.then((value) => value as T);
  }

  void _onResponse(dynamic message) {
    final (int id, Object? value) = message as (int, Object?);
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (value is _WorkerError) {
      completer.completeError(StateError(value.message), value.stack);
    } else {
      completer.complete(value);
    }
  }

  /// Stops taking work and waits for what is already running.
  ///
  /// The isolate is not killed until then: it may be inside a native call that
  /// uses the scanner, and freeing that out from under it is a use after free.
  /// Killing would not even interrupt such a call, which cannot be preempted.
  Future<void> close() async {
    if (_cleaned) return;
    _cleaned = true;
    _closed = true;
    if (_pending.isNotEmpty) {
      await Future.wait(
        // A request that failed has still finished with the scanner, which is
        // all that is being waited for here.
        _pending.values.map((c) => c.future.catchError((_) => null)),
      );
    }
    _responses.close();
    _exit.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _entry(SendPort setup) {
    final commands = ReceivePort();
    setup.send(commands.sendPort);
    late final SendPort responses;
    var haveResponses = false;
    commands.listen((message) {
      if (!haveResponses) {
        responses = message as SendPort;
        haveResponses = true;
        return;
      }
      final (int id, _Request<Object?> request) =
          message as (int, _Request<Object?>);
      try {
        responses.send((id, request.run()));
      } catch (e, stack) {
        responses.send((id, _WorkerError('$e', stack)));
      }
    });
  }
}

/// A failure carried back from the worker; a raw error object is not always
/// sendable between isolates.
class _WorkerError {
  const _WorkerError(this.message, this.stack);

  final String message;
  final StackTrace stack;
}

ffi.Pointer<ffi.Uint8>? _copyToNative(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return null;
  final buf = calloc<ffi.Uint8>(bytes.length);
  buf.asTypedList(bytes.length).setAll(0, bytes);
  return buf;
}

ScanOutcome _readOutcome(WxScanResults raw) {
  final results = <ScanResult>[];
  for (var i = 0; i < raw.results_len; i++) {
    final r = raw.results[i];
    results.add(
      ScanResult(
        text: r.text.cast<Utf8>().toDartString(),
        bytes: Uint8List.fromList(r.bytes.asTypedList(r.bytes_len)),
        charset: r.charset.cast<Utf8>().toDartString(),
        corners: _corners((j) => r.points[j]),
        version: r.qrcode_version,
        ecLevel: r.ec_level.cast<Utf8>().toDartString(),
        charsetMode: r.charset_mode.cast<Utf8>().toDartString(),
        binaryMethod: r.binary_method,
      ),
    );
  }

  final candidates = <List<ScanPoint>>[];
  for (var i = 0; i < raw.candidates_len; i++) {
    final base = i * 8;
    candidates.add(_corners((j) => raw.candidates[base + j]));
  }

  return ScanOutcome(
    results: results,
    candidates: candidates,
    width: raw.width,
    height: raw.height,
  );
}

List<ScanPoint> _corners(double Function(int) at) =>
    [for (var i = 0; i < 4; i++) ScanPoint(at(i * 2), at(i * 2 + 1))];
