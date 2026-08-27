/// The camera can now be stood in for, which is what makes any of this
/// testable: every call goes through [WxScanPlatform.instance].
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxscan/wxscan.dart';

class _FakePlatform extends WxScanPlatform {
  final scanController = StreamController<String>.broadcast();
  final sizeController = StreamController<Map<String, dynamic>>.broadcast();

  bool? lastScanning;
  bool? lastTorch;
  int? lastShortSide;
  double? lastZoom;
  ({double x, double y})? lastFocus;
  var disposed = false;

  /// What setZoom pretends the device clamped to.
  double clampZoomTo = 2.0;

  @override
  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
  }) async {
    lastShortSide = shortSide;
    return {
      'textureId': 7,
      'previewWidth': 1280,
      'previewHeight': 720,
      'displayRotation': 90,
      'nativeReady': true,
      'modelsLoaded': detectModel != null,
    };
  }

  @override
  Stream<String> get scanEvents => scanController.stream;

  @override
  Stream<Map<String, dynamic>> get previewSizeEvents => sizeController.stream;

  @override
  Future<void> setResolution(int shortSide) async => lastShortSide = shortSide;

  @override
  Future<void> setScanning(bool value) async => lastScanning = value;

  @override
  Future<void> setTorch(bool value) async => lastTorch = value;

  @override
  Future<double> setZoom(double ratio) async {
    lastZoom = ratio;
    return clampZoomTo;
  }

  @override
  Future<bool> focusAt(double x, double y) async {
    lastFocus = (x: x, y: y);
    return true;
  }

  @override
  Future<Map<String, dynamic>?> zoomRange() async =>
      {'min': 1.0, 'max': 8.0, 'current': 3.0};

  @override
  Future<Uint8List?> grabFrame() async => Uint8List.fromList([1, 2, 3]);

  @override
  Future<bool> hasTorch() async => true;

  @override
  Future<void> dispose() async => disposed = true;

  @override
  Future<String?> selfTestNative({
    required Uint8List gray,
    required int width,
    required int height,
    required int rotation,
  }) async =>
      '{"w":$width,"h":$height,"results":[],"candidates":[]}';
}

void main() {
  late _FakePlatform fake;

  setUp(() {
    fake = _FakePlatform();
    WxScanPlatform.instance = fake;
  });

  tearDown(() async {
    await WxScan.dispose();
    WxScanPlatform.instance = MethodChannelWxScan();
  });

  test('initialize reports the camera and seeds the readable state', () async {
    expect(WxScan.isInitialized, isFalse);
    final info = await WxScan.initialize(resolution: WxResolution.p1080);

    expect(info.textureId, 7);
    expect(info.nativeReady, isTrue);
    expect(WxScan.isInitialized, isTrue);
    expect(WxScan.camera, same(info));
    expect(WxScan.resolution, WxResolution.p1080);
    expect(fake.lastShortSide, WxResolution.p1080.shortSide);
    expect(WxScan.isScanning, isTrue);
    expect(WxScan.torchEnabled, isFalse);
  });

  test('settings read back after they are applied', () async {
    await WxScan.initialize();

    await WxScan.setScanning(false);
    expect(WxScan.isScanning, isFalse);

    await WxScan.setTorch(true);
    expect(WxScan.torchEnabled, isTrue);

    await WxScan.setResolution(WxResolution.max);
    expect(WxScan.resolution, WxResolution.max);
  });

  test('zoom reads back what the device clamped to, not what was asked',
      () async {
    await WxScan.initialize();
    fake.clampZoomTo = 2.5;

    final applied = await WxScan.setZoom(9);
    expect(fake.lastZoom, 9);
    expect(applied, 2.5);
    expect(WxScan.zoom, 2.5);
  });

  test('zoomRange refreshes the current value', () async {
    await WxScan.initialize();
    final range = await WxScan.zoomRange();
    expect(range.max, 8.0);
    expect(WxScan.zoom, 3.0);
  });

  test('scan events are parsed into outcomes', () async {
    await WxScan.initialize();
    final outcomes = WxScan.scanStream;
    final first = outcomes.first;

    fake.scanController.add(
      '{"w":640,"h":480,"results":[{"text":"hello","points":[1,2,3,4,5,6,7,8]}],'
      '"candidates":[]}',
    );

    final outcome = await first;
    expect(outcome.width, 640);
    expect(outcome.results.single.text, 'hello');
    expect(outcome.results.single.corners, hasLength(4));
  });

  test('preview size events carry the rotation', () async {
    await WxScan.initialize();
    final first = WxScan.previewSizeStream.first;
    fake.sizeController.add({
      'width': 720,
      'height': 1280,
      'displayRotation': 270,
    });

    final size = await first;
    expect(size.width, 720);
    expect(size.displayRotation, 270);
    expect(size.quarterTurns, 1);
  });

  test('a focus point goes to the platform as it was given', () async {
    await WxScan.initialize();

    expect(await WxScan.focusAt(0.25, 0.75), isTrue);
    expect(fake.lastFocus, (x: 0.25, y: 0.75));
  });

  test('dispose clears the readable state', () async {
    await WxScan.initialize();
    await WxScan.setTorch(true);

    await WxScan.dispose();

    expect(fake.disposed, isTrue);
    expect(WxScan.isInitialized, isFalse);
    expect(WxScan.camera, isNull);
    expect(WxScan.torchEnabled, isFalse);
    expect(WxScan.zoom, 1.0);
  });
}
