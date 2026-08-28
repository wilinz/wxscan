/// The channel calls behind [WxScan], as a swappable object.
///
/// A device has one camera session, so the facade is static and convenient to
/// call. That would also make it impossible to test anything that scans, since
/// a method channel needs a real platform underneath. Routing every call
/// through [WxScanPlatform.instance] keeps the ergonomics and lets a test
/// substitute the whole native side.
library;

import 'dart:async';

import 'package:flutter/services.dart';

/// Everything [WxScan] asks the native side to do.
///
/// Subclass it to stand in for the camera in a test; assign the subclass to
/// [instance] before the code under test runs.
abstract class WxScanPlatform {
  WxScanPlatform();

  static WxScanPlatform _instance = MethodChannelWxScan();

  /// The implementation in use. Defaults to the real method channel.
  static WxScanPlatform get instance => _instance;

  static set instance(WxScanPlatform value) => _instance = value;

  /// Opens the camera.
  ///
  /// [scannerHandle], when not zero, names a scanner the caller already holds
  /// and the platform should decode with rather than building its own — one
  /// set of weights in memory instead of two. It is a handle the native
  /// library looks up in a table of its own, not an address, so one left over
  /// from an isolate that is gone is refused rather than followed; the
  /// platform takes its own reference to it and gives that back when the
  /// camera closes. Zero means build one from [detectModel] and [srModel].
  ///
  /// Returns what the camera opened as, including a `sessionId` naming this
  /// session — the platform hands the camera to the last caller, so the id is
  /// how a caller later tells whether the camera it opened is still its own.
  ///
  /// [detectModelPath] and [srModelPath] are the same weights as files on
  /// disk, for a caller that has paths. The platform reads them itself, so a
  /// megabyte does not cross the method channel; a browser has no filesystem
  /// and refuses them.
  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
    String? detectModelPath,
    String? srModelPath,
    int scannerHandle = 0,
  });

  Stream<String> get scanEvents;

  Stream<Map<String, dynamic>> get previewSizeEvents;

  Future<void> setResolution(int shortSide);

  Future<void> setScanning(bool value);

  Future<void> setTorch(bool value);

  Future<double> setZoom(double ratio);

  Future<bool> focusAt(double x, double y);

  Future<Map<String, dynamic>?> zoomRange();

  Future<Uint8List?> grabFrame();

  Future<bool> hasTorch();

  /// Closes the camera.
  ///
  /// [sessionId] names the session the caller opened, as `initialize`
  /// returned it. The platform closes nothing when it does not match the one
  /// open, which is what keeps a controller that has since lost the camera
  /// from closing the one that took it. Zero means "whatever is open", for a
  /// caller that never had a session of its own.
  Future<void> dispose({int sessionId = 0});

  Future<String?> selfTestNative({
    required Uint8List gray,
    required int width,
    required int height,
    required int rotation,
  });
}

/// The real implementation: three channels to the platform binding.
class MethodChannelWxScan extends WxScanPlatform {
  static const MethodChannel _method = MethodChannel('wxscan_live');
  static const EventChannel _events = EventChannel('wxscan_live/scan');
  static const EventChannel _sizeEvents = EventChannel('wxscan_live/preview_size');

  Stream<String>? _scanEvents;
  Stream<Map<String, dynamic>>? _previewSizeEvents;

  @override
  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
    String? detectModelPath,
    String? srModelPath,
    int scannerHandle = 0,
  }) =>
      _method.invokeMapMethod<String, dynamic>('initialize', {
        'shortSide': shortSide,
        'detectModel': detectModel,
        'srModel': srModel,
        // Omitted rather than sent as null, so the platform reads their
        // absence the same way it reads an absent scanner handle.
        if (detectModelPath != null) 'detectModelPath': detectModelPath,
        if (srModelPath != null) 'srModelPath': srModelPath,
        // Omitted rather than sent as zero: the platform reads its absence as
        // "build your own", and a zero pointer arriving as a number is a
        // shape worth never producing.
        if (scannerHandle != 0) 'scannerHandle': scannerHandle,
      });

  @override
  Stream<String> get scanEvents =>
      _scanEvents ??= _events.receiveBroadcastStream().cast<String>();

  @override
  Stream<Map<String, dynamic>> get previewSizeEvents =>
      _previewSizeEvents ??= _sizeEvents
          .receiveBroadcastStream()
          .map((event) => (event as Map).cast<String, dynamic>());

  @override
  Future<void> setResolution(int shortSide) =>
      _method.invokeMethod('setResolution', {'shortSide': shortSide});

  @override
  Future<void> setScanning(bool value) =>
      _method.invokeMethod('setScanning', {'value': value});

  @override
  Future<void> setTorch(bool value) =>
      _method.invokeMethod('setTorch', {'value': value});

  @override
  Future<double> setZoom(double ratio) async =>
      (await _method.invokeMethod<double>('setZoom', {'ratio': ratio})) ?? 1.0;

  @override
  Future<bool> focusAt(double x, double y) async =>
      (await _method.invokeMethod<bool>('focusAt', {'x': x, 'y': y})) ?? false;

  @override
  Future<Map<String, dynamic>?> zoomRange() =>
      _method.invokeMapMethod<String, dynamic>('zoomRange');

  @override
  Future<Uint8List?> grabFrame() =>
      _method.invokeMethod<Uint8List>('grabFrame');

  @override
  Future<bool> hasTorch() async =>
      (await _method.invokeMethod<bool>('hasTorch')) ?? false;

  @override
  Future<void> dispose({int sessionId = 0}) {
    _scanEvents = null;
    _previewSizeEvents = null;
    return _method.invokeMethod('dispose', {'sessionId': sessionId});
  }

  @override
  Future<String?> selfTestNative({
    required Uint8List gray,
    required int width,
    required int height,
    required int rotation,
  }) =>
      _method.invokeMethod<String>('selfTestNative', {
        'gray': gray,
        'width': width,
        'height': height,
        'rotation': rotation,
      });
}
