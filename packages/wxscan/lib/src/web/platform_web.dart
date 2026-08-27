/// The camera side of wxscan, in a browser.
///
/// Native builds hand frames from CameraX or AVFoundation straight to the
/// scanner without Dart seeing them. A browser has no such path: frames are
/// read from a `<video>` through a canvas, which does cross Dart, and are then
/// sent to the scanner's worker. What comes back is the same JSON document the
/// Swift and Kotlin bindings produce, so everything above this is unchanged.
///
/// One frame at a time: the pump waits for a result before taking the next,
/// which is what keeps a slow device from queueing frames it will never catch
/// up with.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:wxscan_core/web.dart';

import '../platform.dart';
import '../preview.dart' show wxScanPreviewViewType;
import 'camera.dart';

@JS('document.createElement')
external JSObject _createElement(String tag);

/// [WxScanPlatform] over `getUserMedia` and the scanner's worker.
class WxScanWeb extends WxScanPlatform {
  WxScanWeb();

  /// Registers this implementation. Flutter calls it for a web build.
  static void registerWith(Registrar registrar) {
    WxScanPlatform.instance = WxScanWeb();
  }

  WxCamera? _camera;
  WxScanWorker? _worker;
  Timer? _pump;
  var _scanning = true;
  var _busy = false;

  final _scans = StreamController<String>.broadcast();
  final _sizes = StreamController<Map<String, dynamic>>.broadcast();

  /// The element the preview shows, once the camera is open.
  static JSObject? _previewElement;
  static var _viewRegistered = false;

  @override
  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
  }) async {
    await dispose();

    final WxCamera camera;
    try {
      camera = await WxCamera.open(shortSide);
    } on Object catch (e) {
      // What a browser raises when the user says no, or when the page is not
      // on a secure origin. The plugin's contract is a PlatformException.
      throw PlatformException(
        code: 'NO_PERMISSION',
        message: 'wxscan: the camera is not available ($e)',
      );
    }
    _camera = camera;
    _registerView(camera);

    var nativeReady = false;
    try {
      _worker = await startWxScanWorker(
        detectModel: detectModel,
        srModel: srModel,
      );
      nativeReady = true;
    } on Object catch (e) {
      // An engine that will not start leaves the preview running and nothing
      // decoding, which is what `nativeReady: false` means everywhere else.
      // Worth saying why, since nothing else will: the usual cause is the four
      // files not being served, and silence would send the reader looking at
      // the camera instead.
      debugPrint('wxscan: the scanner did not start: $e');
    }

    _startPump();

    return {
      // A browser shows the preview through a platform view, not a texture.
      'textureId': -1,
      'previewWidth': camera.width,
      'previewHeight': camera.height,
      // The video track follows the device, so the image is already upright.
      'displayRotation': 0,
      'nativeReady': nativeReady,
      'modelsLoaded':
          (_worker?.hasDetector ?? false) || (_worker?.hasSuperResolution ?? false),
    };
  }

  void _registerView(WxCamera camera) {
    _previewElement = camera.video;
    if (_viewRegistered) return;
    _viewRegistered = true;
    // The factory is registered once and hands back whichever element the
    // current camera is playing into, since a view type cannot be replaced.
    ui_web.platformViewRegistry.registerViewFactory(
      wxScanPreviewViewType,
      (int viewId) {
        final host = _createElement('div');
        host.setProperty('style'.toJS, 'width:100%;height:100%'.toJS);
        final element = _previewElement;
        if (element != null) {
          host.callMethod<JSAny?>('appendChild'.toJS, element);
        }
        return host;
      },
    );
  }

  /// Takes a frame, scans it, and goes round again.
  ///
  /// A timer rather than `requestAnimationFrame`: the page may be showing
  /// nothing that animates, and scanning should not stop because of it.
  void _startPump() {
    _pump = Timer.periodic(const Duration(milliseconds: 33), (_) async {
      if (_busy || !_scanning) return;
      final camera = _camera, worker = _worker;
      if (camera == null || worker == null) return;
      _busy = true;
      try {
        final frame = camera.grab();
        if (frame == null) return;
        // 2 is WxScanPixelFormat's RGBA, which is what a canvas produces.
        final document = await worker.scanPixelsJson(
            frame.pixels, frame.width, frame.height, 2);
        if (document != null && !_scans.isClosed) _scans.add(document);
      } on Object catch (_) {
        // A frame that fails is dropped; the next one is along in a moment.
      } finally {
        _busy = false;
      }
    });
  }

  @override
  Stream<String> get scanEvents => _scans.stream;

  @override
  Stream<Map<String, dynamic>> get previewSizeEvents => _sizes.stream;

  @override
  Future<void> setResolution(int shortSide) async {
    if (_camera == null) return;
    // Reopening is the only way to change what the track produces, and the
    // scanner outlives it.
    _camera?.close();
    final camera = await WxCamera.open(shortSide);
    _camera = camera;
    _previewElement = camera.video;
    _sizes.add({
      'previewWidth': camera.width,
      'previewHeight': camera.height,
      'displayRotation': 0,
    });
  }

  @override
  Future<void> setScanning(bool value) async => _scanning = value;

  @override
  Future<void> setTorch(bool value) async => _camera?.setTorch(value);

  @override
  Future<bool> hasTorch() async => _camera?.hasTorch ?? false;

  @override
  Future<double> setZoom(double ratio) async =>
      await _camera?.setZoom(ratio) ?? 1;

  @override
  Future<Map<String, dynamic>?> zoomRange() async {
    final range = _camera?.zoomRange();
    return range == null
        ? {'min': 1.0, 'max': 1.0}
        : {'min': range.min, 'max': range.max};
  }

  @override
  Future<Uint8List?> grabFrame() async => _camera?.jpeg();

  @override
  Future<String?> selfTestNative({
    required Uint8List gray,
    required int width,
    required int height,
    required int rotation,
  }) async {
    final worker = _worker;
    if (worker == null) return null;
    final outcome = await worker.scanGray(gray, width, height);
    return outcome.results.isEmpty ? '' : outcome.results.first.text;
  }

  @override
  Future<void> dispose() async {
    _pump?.cancel();
    _pump = null;
    _camera?.close();
    _camera = null;
    _previewElement = null;
    await _worker?.dispose();
    _worker = null;
  }
}
