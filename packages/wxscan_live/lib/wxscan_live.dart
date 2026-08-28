/// Live QR scanning driven by the native camera.
///
/// Frames go from CameraX or AVFoundation straight into the scanner and never
/// cross into Dart, which keeps a large per-frame copy off the UI isolate. What
/// arrives here is the outcome of each frame, plus the preview as a Flutter
/// texture.
///
/// To decode a still image instead, use the `wxscan` package, which this
/// one links against.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wxscan/wxscan.dart';

import 'src/platform.dart';

export 'package:wxscan/wxscan.dart'
    show ScanResult, ScanOutcome, ScanPoint, ScanQuad;
export 'src/platform.dart' show WxScanPlatform, MethodChannelWxScan;
export 'src/preview.dart' show WxScanPreview;

/// Everything a scanning screen needs to know, as one immutable snapshot.
///
/// A [WxScanController] is a `ValueNotifier` of this, so a widget that listens
/// rebuilds when any of it changes — the preview size on a rotation, the torch
/// after the device confirms it, the zoom the hardware clamped to. The pattern
/// is `CameraController` and `CameraValue`, which is what a Flutter developer
/// already expects.
///
/// Every field is what the platform confirmed, never what was asked for. A
/// device that refuses a zoom ratio reports the one it took.
class WxScanValue {
  const WxScanValue({
    this.isInitialized = false,
    this.textureId = -1,
    this.previewSize,
    this.isScanning = false,
    this.torchEnabled = false,
    this.zoom = 1.0,
    this.resolution = WxResolution.p720,
    this.nativeReady = false,
    this.modelsLoaded = false,
    this.error,
  });

  /// Whether the camera is open. Everything below is meaningless until it is.
  final bool isInitialized;

  /// Texture to render, or -1 before the camera opens. [WxScanPreview] reads
  /// this so an application does not have to.
  final int textureId;

  /// Size of the preview buffer and the rotation still to apply. Null until
  /// the camera reports one, and replaced whenever the screen rotates.
  final WxPreviewSize? previewSize;

  /// Whether frames are being decoded. The camera and preview run either way.
  final bool isScanning;

  /// Whether the torch is on, as the device confirmed. Always false where
  /// there is no torch.
  final bool torchEnabled;

  /// The zoom ratio in effect, as the device reported after the last request.
  final double zoom;

  /// The capture resolution requested. What took effect arrives in
  /// [previewSize], since a device may fall back to something it prefers.
  final WxResolution resolution;

  /// Whether the native library loaded. Nothing is decoded when this is false.
  final bool nativeReady;

  /// Whether the CNN models loaded. Scanning still works without them, but
  /// small or distant symbols are detected far less reliably.
  final bool modelsLoaded;

  /// What went wrong, if anything. Set rather than thrown for failures that
  /// arrive after `initialize` has returned — a camera the system took away,
  /// say — which have nowhere to be thrown to.
  final Object? error;

  WxScanValue copyWith({
    bool? isInitialized,
    int? textureId,
    WxPreviewSize? previewSize,
    bool? isScanning,
    bool? torchEnabled,
    double? zoom,
    WxResolution? resolution,
    bool? nativeReady,
    bool? modelsLoaded,
    Object? error,
    bool clearError = false,
  }) =>
      WxScanValue(
        isInitialized: isInitialized ?? this.isInitialized,
        textureId: textureId ?? this.textureId,
        previewSize: previewSize ?? this.previewSize,
        isScanning: isScanning ?? this.isScanning,
        torchEnabled: torchEnabled ?? this.torchEnabled,
        zoom: zoom ?? this.zoom,
        resolution: resolution ?? this.resolution,
        nativeReady: nativeReady ?? this.nativeReady,
        modelsLoaded: modelsLoaded ?? this.modelsLoaded,
        error: clearError ? null : (error ?? this.error),
      );

  @override
  String toString() => 'WxScanValue(initialized: $isInitialized, '
      'texture: $textureId, preview: $previewSize, scanning: $isScanning, '
      'torch: $torchEnabled, zoom: $zoom, models: $modelsLoaded)';
}

/// Size of the preview and the rotation still to be applied.
///
/// The native side pins `Preview.targetRotation` to `ROTATION_0`, so the
/// texture always holds the image upright in the device's natural orientation,
/// at a size that does not change with how the device was held at startup.
/// Whatever the screen rotates to is compensated here.
///
/// The official `camera_android_camerax` splits this compensation across two
/// layers (`CameraPreview` applies `preapplied`, then
/// `SurfaceTextureRotatedPreview` applies `displayCCW - preapplied`), which
/// nets out to rotating by `displayCCW`. There is only one layer here, so the
/// net value is computed directly.
class WxPreviewSize {
  const WxPreviewSize(this.width, this.height, this.displayRotation);

  /// Size of the image in the texture, fixed once the camera is bound.
  final int width;
  final int height;

  /// Interface orientation relative to the device's natural orientation.
  final int displayRotation;

  /// Counter-clockwise quarter turns for a surface rotation constant,
  /// equivalent to `getQuarterTurnsFromSurfaceRotationConstant`
  /// (0 to 0, 90 to 3, 180 to 2, 270 to 1).
  static int _quarterTurnsCcw(int degrees) => (4 - (degrees ~/ 90) % 4) % 4;

  /// Turns to apply, ready for `RotatedBox.quarterTurns`.
  int get quarterTurns => _quarterTurnsCcw(displayRotation);

  /// Size after rotation, with width and height swapped on odd turns.
  int get rotatedWidth => quarterTurns.isEven ? width : height;
  int get rotatedHeight => quarterTurns.isEven ? height : width;
}

/// Capture resolution, given as the pixel count of the short side.
///
/// Higher costs proportionally more time per frame, but a dense symbol - high
/// version, many small modules - cannot be decoded at all without enough
/// pixels. 720p is enough for everyday codes.
enum WxResolution {
  p720(720, '720P'),
  p1080(1080, '1080P'),
  max(0, 'Max');

  const WxResolution(this.shortSide, this.label);

  /// Pixels on the short side; 0 means the highest the device supports.
  final int shortSide;

  /// Name to show in a picker.
  final String label;
}

/// The camera was taken over by another [WxScanController].
///
/// Reported through [WxScanValue.error] rather than thrown: it happens to a
/// controller that is not calling anything at the time, so there is nowhere to
/// throw it. See "One camera" on [WxScanController].
class WxCameraLost implements Exception {
  const WxCameraLost();

  @override
  String toString() =>
      'wxscan_live: another controller took the camera over';
}

/// The scanning camera. CameraX on Android, AVFoundation on Apple platforms.
///
/// ```dart
/// final controller = WxScanController();
/// await controller.initialize(detectModel: detect, srModel: sr);
///
/// controller.scans.listen((outcome) { ... });
///
/// // The preview listens to the controller, so a rotation redraws it without
/// // anything else being wired up.
/// WxScanPreview(controller: controller)
/// ```
///
/// Dispose it when the screen goes away. A controller left undisposed holds the
/// camera open.
///
/// ## One camera
///
/// A device has one camera session, so one controller at a time can hold it,
/// and the last one to [initialize] is the one that has it. A second
/// controller does not fail and does not split frames: it takes the camera
/// over, and the controller that held it is told so — [WxScanValue.error]
/// becomes a [WxCameraLost], [WxScanValue.isInitialized] goes back to false,
/// and its [scans] stop. A screen that can be reached twice therefore has to
/// watch for that error, the same way it would watch for a camera the system
/// took away.
///
/// Taking over rather than refusing is what makes a hot restart work: the
/// plugin outlives the isolate, so the first `initialize` after a restart
/// arrives at a plugin that still holds the camera from the run before, and
/// is indistinguishable from a second controller. Refusing one refuses both.
///
/// The controller that lost the camera does not close it when it is disposed
/// — it no longer owns it, and tearing it down would take the camera away
/// from the controller that does. That was the defect this replaced.
///
/// The scanner is a different matter: as many as you like, as below.
///
/// ## Sharing a scanner
///
/// Pass one and the camera decodes with it instead of building its own:
///
/// ```dart
/// final scanner = await WxScanner.create(detectModel: detect, srModel: sr);
/// final controller = WxScanController(scanner: scanner);
/// // ... and the same scanner reads pictures from the photo library:
/// final fromLibrary = await scanner.scanImage(bytes);
/// ```
///
/// Without this an application that scans both live and from a library holds
/// two scanners: two copies of the CNN weights in memory, and two sets of
/// thresholds that drift apart the moment one is tuned. A scanner passed in is
/// borrowed — this controller never disposes it, since it did not create it.
///
/// It changes nothing on the web, where the scanner is a worker reached by
/// message and there was never a second copy to avoid.
class WxScanController extends ValueNotifier<WxScanValue> {
  /// Creates a controller. Nothing happens until [initialize].
  ///
  /// [scanner] is optional; see the class documentation. [resolution] is the
  /// capture resolution to ask for, changeable later with [setResolution].
  WxScanController({
    WxScanner? scanner,
    WxResolution resolution = WxResolution.p720,
  })  : _scanner = scanner,
        super(WxScanValue(resolution: resolution));

  static WxScanPlatform get _platform => WxScanPlatform.instance;

  /// The scanner to decode with, if the caller lent one. Borrowed, never
  /// disposed here.
  final WxScanner? _scanner;

  Stream<ScanOutcome>? _scans;
  StreamSubscription<Map<String, dynamic>>? _sizes;
  var _disposed = false;

  /// The camera session this controller opened, as the platform numbered it,
  /// or 0 while it holds no camera. Sent back with the close so that a
  /// controller which has since lost the camera cannot close the one that
  /// took it — see "One camera" above.
  var _sessionId = 0;

  /// Whether this controller has ever asked for the camera. What it is for is
  /// the case below where there is no session to name: an `initialize` that
  /// threw may still have left the platform half open.
  var _asked = false;

  /// Whoever holds the camera, of all the controllers in this isolate.
  ///
  /// Static because the platform binding is: there is one camera and one
  /// plugin over it, so which controller owns it is a fact about the process
  /// rather than about any one controller. A hot restart starts this over as
  /// null, which is correct — the controllers it named are gone.
  static WxScanController? _owner;

  /// One event per frame, with empty results when nothing was found.
  ///
  /// Broadcast, and it survives [setScanning] being turned off and on: what
  /// stops is the decoding, not the stream.
  /// Frames reach this only while this controller holds the camera. The
  /// platform's stream is one broadcast for the whole process, so without the
  /// gate a controller that lost the camera would go on reporting the frames
  /// of the one that took it, as if nothing had happened.
  Stream<ScanOutcome> get scans {
    _scans ??= _platform.scanEvents
        .where((_) => identical(_owner, this))
        .map(parseFrameJson);
    return _scans!;
  }

  /// Opens the camera and starts delivering frames.
  ///
  /// Camera permission must already be granted; without it this throws a
  /// `NO_PERMISSION` [PlatformException].
  ///
  /// Returning does not by itself mean the camera is open: a controller
  /// disposed while this was in flight closes the camera again and returns
  /// quietly, since a screen left during startup is ordinary rather than an
  /// error. Check [WxScanValue.isInitialized] before calling anything that
  /// needs a camera.
  ///
  /// [detectModel] and [srModel] are the TFLite weights, and are used only when
  /// no scanner was passed to the constructor — a lent scanner brings its own.
  /// Weights that fail to load are not fatal: it falls back to decoding without
  /// the CNN stages, and [WxScanValue.modelsLoaded] says which mode is active.
  ///
  /// [detectModelPath] and [srModelPath] are the same weights as files on
  /// disk, for weights that were downloaded or copied somewhere rather than
  /// held in memory. The platform reads them, so the megabyte never crosses
  /// the method channel — and a path that will not read is not fatal either,
  /// for the same reason unloadable bytes are not: it falls back, says so
  /// through [WxScanValue.modelsLoaded], and logs which file and why.
  ///
  /// A model is given one way or the other, never both. **Flutter assets are
  /// not files**: an asset lives inside the application package and has no
  /// path to open, so `assets/models/detect.tflite` is a string that names
  /// nothing here — load it with `rootBundle` and pass the bytes.
  ///
  /// Paths are unsupported in a browser, which has no filesystem to read: that
  /// throws [UnsupportedError] rather than quietly scanning without a
  /// detector.
  Future<void> initialize({
    Uint8List? detectModel,
    Uint8List? srModel,
    String? detectModelPath,
    String? srModelPath,
  }) async {
    _checkAlive();
    if (detectModel != null && detectModelPath != null) {
      throw ArgumentError('wxscan_live: pass detectModel or detectModelPath, not both');
    }
    if (srModel != null && srModelPath != null) {
      throw ArgumentError('wxscan_live: pass srModel or srModelPath, not both');
    }
    _asked = true;
    final result = await _platform.initialize(
      shortSide: value.resolution.shortSide,
      // A lent scanner already holds its weights; sending them again would
      // build a second copy on the platform side, which is the whole thing
      // this avoids.
      detectModel: _scanner == null ? detectModel : null,
      srModel: _scanner == null ? srModel : null,
      detectModelPath: _scanner == null ? detectModelPath : null,
      srModelPath: _scanner == null ? srModelPath : null,
      // @internal, and deliberately so: the retain and release around this
      // are machinery, and an application reaching for the handle should hear
      // about it. This is the one place meant to, which is why the exemption
      // is written out rather than the annotation dropped.
      // ignore: invalid_use_of_internal_member
      scannerHandle: _scanner?.nativeHandle ?? 0,
    );
    // Before anything is claimed: a call that came back with nothing opened
    // no camera, so there is no camera to take and nobody to take it from.
    if (result == null) {
      throw PlatformException(
        code: 'INIT_ERROR',
        message: 'the camera returned no result',
      );
    }

    // Taken before the disposal check: the camera is open now whatever this
    // controller does next, and it is open on *this* call's terms — the
    // platform has already handed the previous holder's camera over. Telling
    // that holder late is still telling it; not telling it at all would leave
    // it believing it had a camera that this line is about to close.
    _takeCamera((result['sessionId'] as num?)?.toInt() ?? 0);

    if (_disposed) {
      // Disposed while the camera was opening. It is open now and nobody
      // wants it. This returns rather than throwing, because a screen popped
      // during startup is ordinary rather than an error — but it means an
      // awaited `initialize` can come back with nothing having been opened,
      // which is what [WxScanValue.isInitialized] is for.
      await _releaseCamera();
      return;
    }

    // The preview size arrives on subscription and again on every rotation,
    // and folding it into the value is what lets a preview redraw itself
    // without an application wiring up a StreamBuilder.
    _sizes ??= _platform.previewSizeEvents.listen((m) {
      if (_disposed) return;
      value = value.copyWith(
        previewSize: WxPreviewSize(
          (m['width'] as num).toInt(),
          (m['height'] as num).toInt(),
          (m['displayRotation'] as num?)?.toInt() ?? 0,
        ),
      );
    });

    value = value.copyWith(
      isInitialized: true,
      textureId: result['textureId'] as int,
      previewSize: WxPreviewSize(
        result['previewWidth'] as int,
        result['previewHeight'] as int,
        (result['displayRotation'] as num?)?.toInt() ?? 0,
      ),
      isScanning: true,
      torchEnabled: false,
      zoom: 1.0,
      nativeReady: result['nativeReady'] as bool? ?? false,
      modelsLoaded: result['modelsLoaded'] as bool? ?? false,
      clearError: true,
    );
  }

  /// Changes the capture resolution. The camera is reconfigured, so the preview
  /// blinks; the size that took effect arrives in [WxScanValue.previewSize].
  Future<void> setResolution(WxResolution resolution) async {
    _checkAlive();
    await _platform.setResolution(resolution.shortSide);
    if (_disposed) return;
    value = value.copyWith(resolution: resolution);
  }

  /// Pauses or resumes decoding. The camera and the preview keep running.
  Future<void> setScanning(bool scanning) async {
    _checkAlive();
    await _platform.setScanning(scanning);
    if (_disposed) return;
    value = value.copyWith(isScanning: scanning);
  }

  /// Turns the torch on or off. Reads back through [WxScanValue.torchEnabled].
  Future<void> setTorch(bool on) async {
    _checkAlive();
    await _platform.setTorch(on);
    if (_disposed) return;
    value = value.copyWith(torchEnabled: on);
  }

  /// Sets an absolute zoom ratio and returns the one that took effect, clamped
  /// to what the device supports.
  Future<double> setZoom(double ratio) async {
    _checkAlive();
    final actual = await _platform.setZoom(ratio);
    if (!_disposed) value = value.copyWith(zoom: actual);
    return actual;
  }

  /// Focuses and meters on one point of the picture.
  ///
  /// [x] and [y] are fractions of the preview, 0 to 1, in the coordinates of
  /// the picture the texture holds — the space [WxScanValue.previewSize]
  /// describes, before any [WxPreviewSize.quarterTurns] the screen asks for.
  /// A screen tap therefore has to be brought back through the same rotation
  /// and cover-fit the preview was drawn with; `example/lib/scan_page.dart`
  /// does exactly that.
  ///
  /// Exposure is metered on the same point, which is what a tap on a camera
  /// means everywhere else. Both revert to their continuous modes after a few
  /// seconds, so a scanner left alone goes on focusing by itself.
  ///
  /// Returns whether the device took it: false where the camera is closed, the
  /// point is outside the picture, or the hardware has no focus to point —
  /// a browser, and some front cameras.
  Future<bool> focusAt(double x, double y) => _platform.focusAt(x, y);

  /// The supported zoom range and the current value.
  Future<({double min, double max, double current})> zoomRange() async {
    final m = await _platform.zoomRange();
    final current = (m?['current'] as num?)?.toDouble() ?? value.zoom;
    if (!_disposed) value = value.copyWith(zoom: current);
    return (
      min: (m?['min'] as num?)?.toDouble() ?? 1.0,
      max: (m?['max'] as num?)?.toDouble() ?? 1.0,
      current: current,
    );
  }

  /// Grabs the most recent frame as an upright JPEG, at the same size as the
  /// frames being decoded, so it can be shown as a frozen picture.
  Future<Uint8List?> grabFrame() => _platform.grabFrame();

  /// Whether the device has a torch to turn on.
  Future<bool> hasTorch() => _platform.hasTorch();

  /// Closes the camera and releases the controller.
  ///
  /// A scanner passed to the constructor is *not* disposed: it belongs to
  /// whoever created it, and is very likely still in use for pictures.
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sizes?.cancel();
    _sizes = null;
    _scans = null;
    // Only if it still holds the camera. A controller that lost it to another
    // one closes nothing: the camera it would close is not its own any more,
    // and closing it was exactly the defect that "One camera" describes.
    unawaited(_releaseCamera());
    super.dispose();
  }

  /// Records that this controller now holds the camera, and tells whoever
  /// held it before that it does not.
  void _takeCamera(int sessionId) {
    _sessionId = sessionId;
    final previous = _owner;
    _owner = this;
    if (previous != null && !identical(previous, this)) previous._loseCamera();
  }

  /// The other half of a handover, on the controller that lost.
  ///
  /// Nothing is asked of the platform here: the camera has not closed, it
  /// belongs to someone else now. What changes is only this controller's
  /// account of itself, so a screen listening to it stops drawing a preview
  /// that has become another controller's and can say why.
  void _loseCamera() {
    _sizes?.cancel();
    _sizes = null;
    _sessionId = 0;
    if (_disposed) return;
    value = value.copyWith(
      isInitialized: false,
      isScanning: false,
      textureId: -1,
      error: const WxCameraLost(),
    );
  }

  /// Closes the camera, if this controller is the one holding it.
  Future<void> _releaseCamera() async {
    if (identical(_owner, this)) {
      _owner = null;
      final session = _sessionId;
      _sessionId = 0;
      await _platform.dispose(sessionId: session);
      return;
    }
    // No session to name, but the camera may still be half open: an
    // `initialize` that threw can leave the platform holding something it
    // never got to hand back a session for. Closing it unconditionally is
    // only safe while nobody holds the camera — if somebody does, this
    // controller is one that lost it, and what it would close is theirs.
    if (_asked && _owner == null) await _platform.dispose();
  }

  /// Sends a grayscale image through the same native path a camera frame takes,
  /// including row padding and rotation, and returns what the scanner produced.
  /// For verifying the platform binding on a real device.
  ///
  /// Static because it exercises the binding and not a camera: no controller
  /// has to be initialized, and nothing here touches one.
  static Future<ScanOutcome> selfTestNative(
    Uint8List gray,
    int width,
    int height, {
    int rotation = 90,
  }) async {
    final json = await _platform.selfTestNative(
      gray: gray,
      width: width,
      height: height,
      rotation: rotation,
    );
    if (json == null || json.isEmpty) return ScanOutcome.empty;
    return parseFrameJson(json);
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('wxscan_live: this controller has been disposed');
    }
  }
}
