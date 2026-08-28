/// The camera can now be stood in for, which is what makes any of this
/// testable: every call goes through [WxScanPlatform.instance].
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;
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

  /// Which session the last close named, and how many sessions have been
  /// opened. The plugin hands the camera to whoever asked last, so a close
  /// carries the session it means.
  int? lastDisposedSession;
  var sessions = 0;

  /// Makes initialize fail the way a platform that could not open the camera
  /// does, to reach the paths that run when it throws.
  var failInitialize = false;

  /// What setZoom pretends the device clamped to.
  double clampZoomTo = 2.0;

  /// The scanner Dart lent, if any. Zero means "build your own".
  int? lastScannerHandle;
  Uint8List? lastDetectModel;
  String? lastDetectModelPath;
  String? lastSrModelPath;

  @override
  Future<Map<String, dynamic>?> initialize({
    required int shortSide,
    Uint8List? detectModel,
    Uint8List? srModel,
    String? detectModelPath,
    String? srModelPath,
    int scannerHandle = 0,
  }) async {
    lastShortSide = shortSide;
    lastScannerHandle = scannerHandle;
    lastDetectModel = detectModel;
    lastDetectModelPath = detectModelPath;
    lastSrModelPath = srModelPath;
    if (failInitialize) {
      throw PlatformException(code: 'INIT_ERROR', message: 'no camera');
    }
    sessions += 1;
    return {
      'textureId': 7,
      'sessionId': sessions,
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
  Future<void> dispose({int sessionId = 0}) async {
    lastDisposedSession = sessionId;
    disposed = true;
  }

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

  /// One camera, and the last caller has it. These are the Dart half of the
  /// rule; the native half — that a stale close closes nothing — is checked on
  /// a device in `example/integration_test/scanner_sharing_test.dart`, since
  /// this fake cannot lose a camera it never had.
  group('one camera, and the last caller has it', () {
    /// A second controller, disposed for us whichever way the test goes.
    Future<WxScanController> second() async {
      final c = WxScanController();
      addTearDown(c.dispose);
      await c.initialize();
      return c;
    }

    test('a second initialize takes the camera, and the first is told',
        () async {
      final a = await opened();
      final b = await second();

      expect(b.value.isInitialized, isTrue);
      expect(a.value.isInitialized, isFalse,
          reason: 'it does not have a camera any more');
      expect(a.value.error, isA<WxCameraLost>(),
          reason: 'and it can say why, rather than going quiet');
      expect(a.value.textureId, -1,
          reason: 'the texture it would draw belongs to b');
    });

    test('the controller that lost the camera does not close it', () async {
      // The defect this replaced: the second controller believed it owned the
      // camera, and disposing it tore down the first one's.
      final a = await opened();
      final b = await second();

      a.dispose();
      controller = null;
      expect(fake.disposed, isFalse,
          reason: "a is not holding the camera, so it closes nothing");

      b.dispose();
      expect(fake.disposed, isTrue);
      expect(fake.lastDisposedSession, 2,
          reason: 'and it names the session it opened, not whatever is open');
    });

    test('a controller whose initialize threw still closes the camera',
        () async {
      // There is no session to name — the throw came before one was handed
      // back — but the platform may be holding a camera half open, and this
      // controller is the only one that could have left it that way.
      fake.failInitialize = true;
      final c = WxScanController();
      await expectLater(c.initialize(), throwsA(isA<PlatformException>()));
      c.dispose();

      expect(fake.disposed, isTrue);
      expect(fake.lastDisposedSession, 0, reason: 'it has no session to name');
    });

    test('a controller that never opened a camera closes nothing', () async {
      final a = await opened();
      WxScanController().dispose();
      expect(fake.disposed, isFalse);
      expect(a.value.isInitialized, isTrue, reason: 'and a is untouched');
    });

    test('frames stop reaching the controller that lost the camera', () async {
      // The platform's stream is one broadcast for the whole process, so
      // without the gate a is left reporting b's frames as its own.
      final a = await opened();
      final fromA = <ScanOutcome>[];
      final fromB = <ScanOutcome>[];
      a.scans.listen(fromA.add);

      final b = await second();
      b.scans.listen(fromB.add);

      fake.scanController.add('{"w":640,"h":480,"results":[],"candidates":[]}');
      await pumpEventQueue();

      expect(fromA, isEmpty);
      expect(fromB, hasLength(1));
    });

    test('reopening after losing the camera takes it back', () async {
      final a = await opened();
      final b = await second();
      await a.initialize();

      expect(a.value.isInitialized, isTrue);
      expect(a.value.error, isNull, reason: 'the loss it reported is over');
      expect(b.value.error, isA<WxCameraLost>(),
          reason: 'and b is the one told this time');
    });
  });

  group('weights from a path', () {
    test('the paths go to the platform and the bytes do not', () async {
      final c = WxScanController();
      controller = c;
      await c.initialize(
        detectModelPath: '/tmp/detect.tflite',
        srModelPath: '/tmp/sr.tflite',
      );

      // The point of the path form: a megabyte of weights does not cross the
      // channel, so nothing but the two strings should have been sent.
      expect(fake.lastDetectModelPath, '/tmp/detect.tflite');
      expect(fake.lastSrModelPath, '/tmp/sr.tflite');
      expect(fake.lastDetectModel, isNull);
    });

    test('bytes and a path for the same model is refused', () async {
      final c = WxScanController();
      controller = c;
      // Not a preference between them: taking one silently would mean the
      // scanner ran on weights the caller did not think it had passed.
      expect(
        () => c.initialize(
          detectModel: Uint8List.fromList([1, 2, 3]),
          detectModelPath: '/tmp/detect.tflite',
        ),
        throwsArgumentError,
      );
      expect(
        () => c.initialize(
          srModel: Uint8List.fromList([1, 2, 3]),
          srModelPath: '/tmp/sr.tflite',
        ),
        throwsArgumentError,
      );
    });

    test('a lent scanner keeps the paths from being sent as well', () async {
      final scanner = await WxScanner.create();
      addTearDown(scanner.dispose);

      final c = WxScanController(scanner: scanner);
      controller = c;
      await c.initialize(detectModelPath: '/tmp/detect.tflite');

      expect(fake.lastScannerHandle, isNot(0));
      expect(fake.lastDetectModelPath, isNull,
          reason: 'the lent scanner already holds its weights');
    });
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
