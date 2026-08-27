import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';
import 'ffi.dart';
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
    _finalizer.attach(this, _handle.cast(), detach: this);
  }

  static final _finalizer = ffi.NativeFinalizer(scannerFinalizer);

  /// Scanners with work in flight, kept here so the garbage collector cannot
  /// run the finalizer, and free the native scanner, while the worker isolate
  /// is inside a call that uses it.
  static final _busy = <WxScanner>{};

  final ffi.Pointer<WxScanScanner> _handle;
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

  /// Creates a scanner from model bytes.
  ///
  /// The weights may be TFLite or ONNX; which formats work depends on the
  /// backends the native library was built with, and the format is detected
  /// from the buffer rather than declared.
  ///
  /// Passing null for both selects the mode without models. If a model fails to
  /// load, this falls back to that mode rather than throwing, so a corrupt
  /// asset degrades the detection rate instead of breaking the feature; check
  /// [hasDetector] for which mode is active.
  static Future<WxScanner> create({
    Uint8List? detectModel,
    Uint8List? srModel,
  }) async {
    final worker = await _ScanWorker.spawn();
    try {
      var address = await worker.run(_CreateRequest(detectModel, srModel));
      if (address == 0) {
        // A model that will not load is not fatal; plain decoding still reads
        // ordinary symbols.
        address = await worker.run(const _CreateRequest(null, null));
      }
      if (address == 0) {
        throw StateError('wxscan_core: could not create a scanner');
      }
      final snapshot = await worker.run(_SnapshotRequest(address));
      return WxScanner._(ffi.Pointer.fromAddress(address), worker, snapshot);
    } catch (_) {
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
    _track(_worker.run(_ConfigRequest(_handle.address, setting, value)))
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
      _handle.address,
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
      _handle.address,
      data,
      width,
      height,
      stride,
      rotation,
      mirror,
    )));
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
    return _PixelsRequest(_handle.address, pixels, width, height, format).run();
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
      _handle.address,
      data,
      width,
      height,
      stride,
      rotation,
      mirror,
    ).run();
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
    wxscan_scanner_free(_handle);
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('wxscan_core: the scanner has been disposed');
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
      ).address;
    } finally {
      if (detectBuf != null) calloc.free(detectBuf);
      if (srBuf != null) calloc.free(srBuf);
    }
  }
}

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
  const _SnapshotRequest(this.handleAddress);

  final int handleAddress;

  @override
  _Snapshot run() {
    final handle = ffi.Pointer<WxScanScanner>.fromAddress(handleAddress);
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
  const _ConfigRequest(this.handleAddress, this.setting, this.value);

  final int handleAddress;
  final _Setting setting;
  final double value;

  @override
  void run() {
    final handle = ffi.Pointer<WxScanScanner>.fromAddress(handleAddress);
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
    this.handleAddress,
    this.data,
    this.width,
    this.height,
    this.rowStride,
    this.rotation,
    this.mirror,
  );

  final int handleAddress;
  final Uint8List data;
  final int width;
  final int height;
  final int rowStride;
  final int rotation;
  final bool mirror;

  @override
  ScanOutcome run() => _withNative(data, (buf) {
        return wxscan_scan_frame(
          ffi.Pointer<WxScanScanner>.fromAddress(handleAddress),
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
    this.handleAddress,
    this.pixels,
    this.width,
    this.height,
    this.format,
  );

  final int handleAddress;
  final Uint8List pixels;
  final int width;
  final int height;
  final WxPixelFormat format;

  @override
  ScanOutcome run() => _withNative(pixels, (buf) {
        return wxscan_scan_pixels(
          ffi.Pointer<WxScanScanner>.fromAddress(handleAddress),
          buf,
          width,
          height,
          format.nativeValue,
        );
      });
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
  _ScanWorker._(this._isolate, this._commands, this._responses) {
    _responses.listen(_onResponse);
  }

  final Isolate _isolate;
  final SendPort _commands;
  final ReceivePort _responses;
  final _pending = <int, Completer<Object?>>{};
  var _nextId = 0;
  var _closed = false;

  static Future<_ScanWorker> spawn() async {
    final setup = ReceivePort();
    final isolate = await Isolate.spawn(_entry, setup.sendPort);
    final responses = ReceivePort();
    final commands = await setup.first as SendPort;
    setup.close();
    commands.send(responses.sendPort);
    return _ScanWorker._(isolate, commands, responses);
  }

  /// Whether any request is still outstanding.
  bool get hasPending => _pending.isNotEmpty;

  Future<T> run<T>(_Request<T> request) {
    if (_closed) {
      throw StateError('wxscan_core: the scanner has been disposed');
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
    if (_closed) return;
    _closed = true;
    if (_pending.isNotEmpty) {
      await Future.wait(
        // A request that failed has still finished with the scanner, which is
        // all that is being waited for here.
        _pending.values.map((c) => c.future.catchError((_) => null)),
      );
    }
    _responses.close();
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

/// Parses the JSON a platform binding produces for a camera frame.
///
/// The camera plugin sends frames straight from the native layer into the
/// scanner and forwards this document; the shape is defined by that binding.
ScanOutcome parseFrameJson(String json) {
  final map = jsonDecode(json) as Map<String, dynamic>;
  List<ScanPoint> pts(List<dynamic> flat) => [
        for (var i = 0; i < flat.length && i + 1 < flat.length; i += 2)
          ScanPoint((flat[i] as num).toDouble(), (flat[i + 1] as num).toDouble()),
      ];

  return ScanOutcome(
    width: (map['w'] as num?)?.toInt() ?? 0,
    height: (map['h'] as num?)?.toInt() ?? 0,
    results: [
      for (final r in (map['results'] as List? ?? const []))
        ScanResult(
          text: r['text'] as String? ?? '',
          bytes: Uint8List.fromList(
            (r['raw'] as List?)?.cast<int>() ??
                utf8.encode(r['text'] as String? ?? ''),
          ),
          charset: r['charset'] as String? ?? 'UTF-8',
          corners: pts(r['points'] as List? ?? const []),
          version: (r['version'] as num?)?.toInt() ?? 0,
          ecLevel: r['ecLevel'] as String? ?? '',
          charsetMode: r['charsetMode'] as String? ?? '',
          binaryMethod: (r['binaryMethod'] as num?)?.toInt() ?? 0,
        ),
    ],
    candidates: [
      for (final c in (map['candidates'] as List? ?? const []))
        pts(c as List),
    ],
  );
}
