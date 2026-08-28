/// The camera can now be stood in for, which is what makes any of this
/// testable: every call goes through [WxScanPlatform.instance].
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wxscan/wxscan.dart';
import 'package:wxscan_live/wxscan_live.dart';

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

  /// The scanner Dart lent, if any. Zero means "build your own".
  int? lastScannerHandle;
  Uint8List? lastDetectModel;

  @override
  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
    int scannerHandle = 0,
  }) async {
    lastShortSide = shortSide;
    lastScannerHandle = scannerHandle;
    lastDetectModel = detectModel;
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
  WxScanController? controller;

  setUp(() {
    fake = _FakePlatform();
    WxScanPlatform.instance = fake;
  });

  tearDown(() {
    controller?.dispose();
    controller = null;
    WxScanPlatform.instance = MethodChannelWxScan();
  });

  /// A controller that is disposed for us whatever the test does.
  Future<WxScanController> opened({
    WxResolution resolution = WxResolution.p720,
    Uint8List? detectModel,
  }) async {
    final c = WxScanController(resolution: resolution);
    controller = c;
    await c.initialize(detectModel: detectModel);
    return c;
  }

  test('initialize fills in the value', () async {
    final c = WxScanController(resolution: WxResolution.p1080);
    controller = c;
    expect(c.value.isInitialized, isFalse);

    await c.initialize();

    expect(c.value.isInitialized, isTrue);
    expect(c.value.textureId, 7);
    expect(c.value.nativeReady, isTrue);
    expect(c.value.resolution, WxResolution.p1080);
    expect(fake.lastShortSide, WxResolution.p1080.shortSide);
    expect(c.value.isScanning, isTrue);
    expect(c.value.torchEnabled, isFalse);
    // Seeded from what initialize returned, so a preview can be drawn before
    // any rotation event arrives.
    expect(c.value.previewSize?.width, 1280);
    expect(c.value.previewSize?.displayRotation, 90);
  });

  test('settings read back after the platform confirms them', () async {
    final c = await opened();

    await c.setScanning(false);
    expect(c.value.isScanning, isFalse);

    await c.setTorch(true);
    expect(c.value.torchEnabled, isTrue);

    await c.setResolution(WxResolution.max);
    expect(c.value.resolution, WxResolution.max);
  });

  test('zoom reads back what the device clamped to, not what was asked',
      () async {
    final c = await opened();
    fake.clampZoomTo = 2.5;

    final applied = await c.setZoom(9);
    expect(fake.lastZoom, 9);
    expect(applied, 2.5);
    expect(c.value.zoom, 2.5);
  });

  test('zoomRange refreshes the current value', () async {
    final c = await opened();
    final range = await c.zoomRange();
    expect(range.max, 8.0);
    expect(c.value.zoom, 3.0);
  });

  test('scan events are parsed into outcomes', () async {
    final c = await opened();
    final first = c.scans.first;

    fake.scanController.add(
      '{"w":640,"h":480,"results":[{"text":"hello","points":[1,2,3,4,5,6,7,8]}],'
      '"candidates":[]}',
    );

    final outcome = await first;
    expect(outcome.width, 640);
    expect(outcome.results.single.text, 'hello');
    expect(outcome.results.single.corners, hasLength(4));
  });

  /// The reason the value is a ValueNotifier: a rotation reaches a widget
  /// without an application subscribing to anything.
  test('a rotation lands in the value and notifies', () async {
    final c = await opened();
    var notifications = 0;
    c.addListener(() => notifications++);

    fake.sizeController.add({
      'width': 720,
      'height': 1280,
      'displayRotation': 270,
    });
    // The event is delivered asynchronously.
    await Future<void>.delayed(Duration.zero);

    expect(c.value.previewSize?.width, 720);
    expect(c.value.previewSize?.displayRotation, 270);
    expect(c.value.previewSize?.quarterTurns, 1);
    expect(notifications, greaterThan(0));
  });

  test('a focus point goes to the platform as it was given', () async {
    final c = await opened();

    expect(await c.focusAt(0.25, 0.75), isTrue);
    expect(fake.lastFocus, (x: 0.25, y: 0.75));
  });

  test('dispose closes the camera and refuses further use', () async {
    final c = await opened();
    await c.setTorch(true);

    c.dispose();
    controller = null;

    expect(fake.disposed, isTrue);
    expect(() => c.setTorch(false), throwsStateError);
  });

  group('sharing a scanner with the application', () {
    test('a lent scanner is handed over, and the weights are not', () async {
      // The camera decodes with a scanner that already holds its weights, so
      // sending them again would build a second copy on the platform side —
      // which is the whole thing this avoids.
      final scanner = await WxScanner.create();
      addTearDown(scanner.dispose);

      final c = WxScanController(scanner: scanner);
      controller = c;
      await c.initialize(detectModel: Uint8List.fromList([1, 2, 3]));

      expect(fake.lastScannerHandle, isNot(0));
      expect(fake.lastDetectModel, isNull);
    });

    test('without one, the weights go instead', () async {
      final c = await opened(detectModel: Uint8List.fromList([1, 2, 3]));
      expect(fake.lastScannerHandle, 0);
      expect(fake.lastDetectModel, isNotNull);
      expect(c.value.modelsLoaded, isTrue);
    });

    test('disposing the controller leaves the lent scanner alive', () async {
      final scanner = await WxScanner.create();
      addTearDown(scanner.dispose);

      final c = WxScanController(scanner: scanner);
      controller = c;
      await c.initialize();
      c.dispose();
      controller = null;

      // Still usable: it was borrowed, not taken. Disposing it here would
      // leave the application holding a freed pointer.
      expect(scanner.hasDetector, isFalse);
      await scanner.scanGray(Uint8List(16), 4, 4);
    });
  });
}
