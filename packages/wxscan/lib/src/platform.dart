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

  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
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

  Future<void> dispose();

  Future<String?> selfTestNative({
    required Uint8List gray,
    required int width,
    required int height,
    required int rotation,
  });
}

/// The real implementation: three channels to the platform binding.
class MethodChannelWxScan extends WxScanPlatform {
  static const MethodChannel _method = MethodChannel('wxscan');
  static const EventChannel _events = EventChannel('wxscan/scan');
  static const EventChannel _sizeEvents = EventChannel('wxscan/preview_size');

  Stream<String>? _scanEvents;
  Stream<Map<String, dynamic>>? _previewSizeEvents;

  @override
  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
  }) =>
      _method.invokeMapMethod<String, dynamic>('initialize', {
        'shortSide': shortSide,
        'detectModel': detectModel,
        'srModel': srModel,
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
  Future<void> dispose() {
    _scanEvents = null;
    _previewSizeEvents = null;
    return _method.invokeMethod('dispose');
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
