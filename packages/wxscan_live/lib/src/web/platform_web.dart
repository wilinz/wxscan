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
import 'package:wxscan/web.dart';

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
  var _driven = false;

  final _scans = StreamController<String>.broadcast();
  final _sizes = StreamController<Map<String, dynamic>>.broadcast();

  /// The element the preview shows, once the camera is open, and the platform
  /// view's own element that holds it.
  static JSObject? _previewElement;
  static JSObject? _previewHost;
  static var _viewRegistered = false;

  /// Which camera session is open, or 0 when none is, and the last number
  /// minted. Never reused, so a close that arrives late names a session that
  /// has ended rather than the next one. See [WxScanPlatform.dispose] for what
  /// a caller does with it.
  static var _sessionId = 0;
  static var _lastSessionId = 0;

  @override
  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
    // Ignored here. A browser has no handle to lend: the scanner is a worker,
    // reached by message, and this implementation starts its own. Nothing is
    // duplicated either way, so there is nothing to share.
    int scannerHandle = 0,
  }) async {
    // The browser's own handover: whatever was open is closed, and the caller
    // asking now gets a session of its own. It is the same rule as the native
    // bindings — the camera goes to whoever asked last — reached by a shorter
    // road, since a `<video>` and a worker can simply be rebuilt.
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

    _lastSessionId += 1;
    _sessionId = _lastSessionId;
    return {
      // A browser shows the preview through a platform view, not a texture.
      'textureId': -1,
      'sessionId': _sessionId,
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
    _showPreview(camera.video);
    if (_viewRegistered) return;
    _viewRegistered = true;
    // The factory is registered once and hands back whichever element the
    // current camera is playing into, since a view type cannot be replaced.
    ui_web.platformViewRegistry.registerViewFactory(
      wxScanPreviewViewType,
      (int viewId) {
        final host = _createElement('div');
        host.setProperty('style'.toJS, 'width:100%;height:100%'.toJS);
        _previewHost = host;
        final element = _previewElement;
        if (element != null) {
          host.callMethod<JSAny?>('appendChild'.toJS, element);
          // Attaching is not resuming: an element that was paused while it sat
          // outside the page stays paused here.
          _play(element);
        }
        return host;
      },
    );
  }

  /// Puts [element] on screen as the preview.
  ///
  /// The view factory runs once, when the platform view is created, so a
  /// camera opened after that — a change of resolution, or initialising again
  /// — has to be swapped into the element it made. Without this the preview
  /// goes on showing the previous `<video>`, whose stream has just been
  /// stopped, and freezes or goes black.
  static void _showPreview(JSObject element) {
    _previewElement = element;
    final host = _previewHost;
    // Only into a host that is still in the page. The one left from a platform
    // view that has since been taken out is a detached node, and a media
    // element put there is paused by the browser — which it stays after being
    // attached again, showing one frame and never another. That is the frozen
    // preview on the second visit to a scanner: the picture was there, the
    // track was live, and the element was simply paused. Dropping the stale
    // reference leaves the element to the factory below, which attaches it to
    // the host that is really on screen.
    if (host == null || !_isConnected(host)) {
      _previewHost = null;
      return;
    }
    host.callMethod<JSAny?>('replaceChildren'.toJS, element);
    _play(element);
  }

  /// Whether [node] is in the page, rather than in a tree of its own.
  static bool _isConnected(JSObject node) =>
      node.getProperty<JSBoolean>('isConnected'.toJS).toDart;

  /// Starts the element again, for the pause that being out of the page
  /// leaves behind. Playing already is not an error, and neither is a refusal:
  /// the stream is muted and inline, so nothing here needs a gesture.
  static void _play(JSObject element) {
    try {
      element.callMethod<JSPromise<JSAny?>>('play'.toJS).toDart.then(
            (_) {},
            onError: (Object _) {},
          );
    } on Object catch (_) {}
  }

  /// Takes a frame, scans it, and goes round again.
  ///
  /// The camera drives this where it can: a browser that has
  /// `requestVideoFrameCallback` says when a new frame has been presented, so
  /// no frame is scanned twice and none is scanned stale. Where it does not, a
  /// timer stands in — a page may be showing nothing that animates, and
  /// scanning should not stop because of it.
  void _startPump() {
    _driven = _camera?.onFrame(_tick) ?? false;
    if (_driven) return;
    _pump = Timer.periodic(const Duration(milliseconds: 33), (_) => _tick());
  }

  void _driveNext() {
    if (_driven) _camera?.onFrame(_tick);
  }

  void _tick() {
    if (_busy) {
      _driveNext();
      return;
    }
    _busy = true;
    unawaited(_scanOnce().whenComplete(() {
      _busy = false;
      _driveNext();
    }));
  }

  Future<void> _scanOnce() async {
    if (!_scanning) return;
    final camera = _camera, worker = _worker;
    if (camera == null || worker == null) return;
    try {
      final frame = camera.grab();
      if (frame == null) return;
      // 2 is WxScanPixelFormat's RGBA, which is what a canvas produces.
      final document = await worker.scanPixelsJson(
          frame.pixels, frame.width, frame.height, 2);
      if (document != null && !_scans.isClosed) _scans.add(document);
    } on Object catch (_) {
      // A frame that fails is dropped; the next one is along in a moment.
    }
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
    _showPreview(camera.video);
    // The old camera's frame callback died with its track; where the pump is
    // driven by them, the new one has to be asked. Asking twice is harmless:
    // a camera holds at most one request open.
    _driveNext();
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

  /// A browser has no focus to point.
  ///
  /// `MediaStreamTrack.applyConstraints` names `pointsOfInterest`, but no
  /// engine ships it, and where focus is adjustable at all it is
  /// `focusDistance` — a distance, not a place in the picture. Saying so is
  /// better than a call that quietly does nothing.
  @override
  Future<bool> focusAt(double x, double y) async => false;

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
  Future<void> dispose({int sessionId = 0}) async {
    // A caller closing a session that has already been taken over closes
    // nothing, the same as on a device.
    if (sessionId != 0 && sessionId != _sessionId) return;
    _sessionId = 0;
    _pump?.cancel();
    _pump = null;
    _driven = false;
    _camera?.close();
    _camera = null;
    _previewElement = null;
    _previewHost?.callMethod<JSAny?>('replaceChildren'.toJS);
    await _worker?.dispose();
    _worker = null;
  }
}
