/// Live QR scanning driven by the native camera.
///
/// Frames go from CameraX or AVFoundation straight into the scanner and never
/// cross into Dart, which keeps a large per-frame copy off the UI isolate. What
/// arrives here is the outcome of each frame, plus the preview as a Flutter
/// texture.
///
/// To decode a still image instead, use the `wxscan_core` package, which this
/// one links against.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:wxscan_core/wxscan_core.dart';

import 'src/platform.dart';

export 'package:wxscan_core/wxscan_core.dart'
    show ScanResult, ScanOutcome, ScanPoint, ScanQuad;
export 'src/platform.dart' show WxScanPlatform, MethodChannelWxScan;
export 'src/preview.dart' show WxScanPreview;

/// What the camera reported when it started.
class WxScanCameraInfo {
  const WxScanCameraInfo({
    required this.textureId,
    required this.previewWidth,
    required this.previewHeight,
    required this.displayRotation,
    required this.nativeReady,
    required this.modelsLoaded,
  });

  /// Texture to render with a [Texture] widget.
  final int textureId;

  /// Preview size in the device's natural orientation; see [WxPreviewSize].
  final int previewWidth;
  final int previewHeight;

  /// Current interface orientation in degrees: 0, 90, 180 or 270.
  final int displayRotation;

  /// Whether the native library loaded. Nothing is decoded when this is false.
  final bool nativeReady;

  /// Whether the CNN models loaded. Scanning still works without them, but
  /// small or distant symbols are detected far less reliably.
  final bool modelsLoaded;
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

/// The scanning camera. CameraX on Android, AVFoundation on Apple platforms.
class WxScan {
  static WxScanPlatform get _platform => WxScanPlatform.instance;

  static Stream<ScanOutcome>? _stream;
  static Stream<WxPreviewSize>? _sizeStream;

  static WxScanCameraInfo? _camera;
  static var _resolution = WxResolution.p720;
  static var _scanning = true;
  static var _torch = false;
  static var _zoom = 1.0;

  /// What [initialize] reported, or null before it ran or after [dispose].
  ///
  /// The settings below read back from here and from what the native side
  /// confirmed, so a value the device refused is not reported as if it took.
  static WxScanCameraInfo? get camera => _camera;

  /// Whether the camera is open.
  static bool get isInitialized => _camera != null;

  /// The capture resolution currently requested. The size that actually took
  /// effect arrives on [previewSizeStream], since a device may fall back.
  static WxResolution get resolution => _resolution;

  /// Whether frames are being decoded. The camera and preview run either way.
  static bool get isScanning => _scanning;

  /// Whether the torch is on. Always false where there is no torch.
  static bool get torchEnabled => _torch;

  /// The zoom ratio in effect, as the device reported it after the last
  /// [setZoom].
  static double get zoom => _zoom;

  /// Opens the camera and starts delivering frames.
  ///
  /// Camera permission must already be granted; without it this throws a
  /// `NO_PERMISSION` [PlatformException].
  ///
  /// [detectModel] and [srModel] are the TFLite weights. They are loaded into a
  /// scanner owned by the native side, separate from any scanner the
  /// `wxscan_core` bindings hold. Omitting them, or passing weights that fail
  /// to load, falls back to decoding without the CNN stages rather than
  /// failing; check [WxScanCameraInfo.modelsLoaded] for which mode is active.
  ///
  /// [resolution] can be changed later with [setResolution].
  static Future<WxScanCameraInfo> initialize({
    WxResolution resolution = WxResolution.p720,
    Uint8List? detectModel,
    Uint8List? srModel,
  }) async {
    final res = await _platform.initialize(
      shortSide: resolution.shortSide,
      detectModel: detectModel,
      srModel: srModel,
    );
    if (res == null) {
      throw PlatformException(
        code: 'INIT_ERROR',
        message: 'the camera returned no result',
      );
    }
    _resolution = resolution;
    _scanning = true;
    _torch = false;
    _zoom = 1.0;
    return _camera = WxScanCameraInfo(
      textureId: res['textureId'] as int,
      previewWidth: res['previewWidth'] as int,
      previewHeight: res['previewHeight'] as int,
      displayRotation: (res['displayRotation'] as num?)?.toInt() ?? 0,
      nativeReady: res['nativeReady'] as bool? ?? false,
      modelsLoaded: res['modelsLoaded'] as bool? ?? false,
    );
  }

  /// One event per frame, with empty results when nothing was found.
  static Stream<ScanOutcome> get scanStream {
    _stream ??= _platform.scanEvents.map(parseFrameJson);
    return _stream!;
  }

  /// Size of the preview buffer. Emits the current value on subscription and
  /// again whenever the screen rotates.
  static Stream<WxPreviewSize> get previewSizeStream {
    _sizeStream ??= _platform.previewSizeEvents.map(
      (m) => WxPreviewSize(
        (m['width'] as num).toInt(),
        (m['height'] as num).toInt(),
        (m['displayRotation'] as num?)?.toInt() ?? 0,
      ),
    );
    return _sizeStream!;
  }

  /// Changes the capture resolution. The camera is reconfigured, so the preview
  /// blinks; the size that took effect arrives on [previewSizeStream].
  static Future<void> setResolution(WxResolution value) async {
    await _platform.setResolution(value.shortSide);
    _resolution = value;
  }

  /// Pauses or resumes decoding. The camera and the preview keep running.
  static Future<void> setScanning(bool value) async {
    await _platform.setScanning(value);
    _scanning = value;
  }

  /// Turns the torch on or off. Reads back through [torchEnabled].
  static Future<void> setTorch(bool value) async {
    await _platform.setTorch(value);
    _torch = value;
  }

  /// Sets an absolute zoom ratio and returns the one that took effect, clamped
  /// to what the device supports.
  static Future<double> setZoom(double ratio) async =>
      _zoom = await _platform.setZoom(ratio);

  /// The supported zoom range and the current value.
  static Future<({double min, double max, double current})> zoomRange() async {
    final m = await _platform.zoomRange();
    _zoom = (m?['current'] as num?)?.toDouble() ?? _zoom;
    return (
      min: (m?['min'] as num?)?.toDouble() ?? 1.0,
      max: (m?['max'] as num?)?.toDouble() ?? 1.0,
      current: (m?['current'] as num?)?.toDouble() ?? 1.0,
    );
  }

  /// Grabs the most recent frame as an upright JPEG, at the same size as the
  /// frames being decoded, so it can be shown as a frozen picture.
  static Future<Uint8List?> grabFrame() => _platform.grabFrame();

  /// Whether the device has a torch to turn on.
  static Future<bool> hasTorch() => _platform.hasTorch();

  static Future<void> dispose() {
    _stream = null;
    _sizeStream = null;
    _camera = null;
    _torch = false;
    _zoom = 1.0;
    return _platform.dispose();
  }

  /// Sends a grayscale image through the same native path a camera frame takes,
  /// including row padding and rotation, and returns what the scanner produced.
  /// For verifying the platform binding on a real device.
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
}
