/// Runs the scanner from plain Dart: no Flutter, no platform build system.
/// The build hook produces the native library and the TFLite one beside it.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:wxscan_core/src/bindings.dart';
import 'package:wxscan_core/wxscan_core.dart';

void main() {
  test('the native library is loaded through the code asset', () {
    expect(wxscan_ping(), isNonZero);
  });

  group('a scanner without models', () {
    late WxScanner scanner;

    setUp(() async => scanner = await WxScanner.create());
    tearDown(() => scanner.dispose());

    test('decodes a blank image to nothing', () async {
      // Exercises the whole path from Dart through the C ABI and back.
      final gray = Uint8List(64 * 64)..fillRange(0, 64 * 64, 255);
      final outcome = await scanner.scanGray(gray, 64, 64);
      expect(outcome.results, isEmpty);
    });

    test('takes colour pixels without a conversion in Dart', () async {
      final rgba = Uint8List(32 * 32 * 4)..fillRange(0, 32 * 32 * 4, 255);
      final outcome = await scanner.scanPixels(rgba, 32, 32);
      expect(outcome.results, isEmpty);
    });

    test('reports which networks are loaded', () {
      expect(scanner.hasDetector, isFalse);
      expect(scanner.hasSuperResolution, isFalse);
      expect(scanner.hasModels, isFalse);
    });

    test('scale factor reads back what was set', () {
      scanner.scaleFactor = 0.5;
      expect(scanner.scaleFactor, closeTo(0.5, 1e-6));
      // Out of range restores the automatic default, which reads negative.
      scanner.scaleFactor = 3;
      expect(scanner.scaleFactor, lessThan(0));
    });

    test('detection thresholds are unavailable without a detector', () {
      // They are the detector's, and there is none in this mode.
      expect(scanner.confidenceThreshold, lessThan(0));
      expect(scanner.nmsThreshold, lessThan(0));
    });

    test('a mismatched buffer is an ArgumentError, not an empty result',
        () async {
      final gray = Uint8List(10);
      expect(
        () => scanner.scanGray(gray, 64, 64),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => scanner.scanFrame(gray, 4, 2, rowStride: 2),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => scanner.scanFrame(Uint8List(16), 4, 4, rotation: 45),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => scanner.scanPixels(Uint8List(16), 4, 4),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('queued scans all complete on the one worker isolate', () async {
      final gray = Uint8List(48 * 48)..fillRange(0, 48 * 48, 200);
      final outcomes = await Future.wait([
        for (var i = 0; i < 8; i++) scanner.scanGray(gray, 48, 48),
      ]);
      expect(outcomes, hasLength(8));
      expect(outcomes.every((o) => o.results.isEmpty), isTrue);
    });

    test('using a disposed scanner throws', () async {
      final other = await WxScanner.create();
      await other.dispose();
      expect(() => other.scanGray(Uint8List(16), 4, 4), throwsStateError);
      expect(() => other.scaleFactor = 0.5, throwsStateError);
      // Disposing twice is a no-op rather than a double free.
      await other.dispose();
    });

    test('settings do not reach for the scanner while it is busy', () async {
      // The getters mirror the native state instead of locking, so reading one
      // while a scan is in flight returns at once rather than waiting for it.
      final gray = Uint8List(256 * 256)..fillRange(0, 256 * 256, 128);
      final scanning = scanner.scanGray(gray, 256, 256);

      final watch = Stopwatch()..start();
      scanner.scaleFactor;
      scanner.confidenceThreshold;
      scanner.hasDetector;
      watch.stop();

      expect(watch.elapsedMilliseconds, lessThan(50));
      await scanning;
    });

    test('setting a value after disposal does not escape as an async error',
        () async {
      final other = await WxScanner.create();
      await other.dispose();
      // The setter throws synchronously; nothing must be left unawaited.
      expect(() => other.scaleFactor = 0.5, throwsStateError);
      await Future<void>.delayed(Duration.zero);
    });

    test('a rejected setting does not read back as if it took', () {
      final before = scanner.confidenceThreshold;
      // Out of range, and there is no detector in this mode either.
      scanner.confidenceThreshold = 1.5;
      expect(scanner.confidenceThreshold, before);
    });

    test('dispose waits for work already handed to the worker', () async {
      final other = await WxScanner.create();
      final gray = Uint8List(256 * 256)..fillRange(0, 256 * 256, 90);
      // Not awaited: the scan is in flight when dispose runs, and freeing the
      // native scanner under it would be a use after free.
      final scanning = other.scanGray(gray, 256, 256);

      await other.dispose();

      await expectLater(scanning, completes);
    });
  });

  group('quad helpers', () {
    const quad = [
      ScanPoint(10, 20),
      ScanPoint(30, 20),
      ScanPoint(30, 60),
      ScanPoint(10, 60),
    ];

    test('centre is the average of the corners', () {
      expect(quad.centre, const ScanPoint(20, 40));
    });

    test('bounds is the enclosing box', () {
      final b = quad.bounds;
      expect((b.left, b.top, b.right, b.bottom), (10.0, 20.0, 30.0, 60.0));
    });

    test('longestSide takes the longer of the two', () {
      expect(quad.longestSide, 40);
    });

    test('an empty quad does not throw', () {
      expect(const <ScanPoint>[].centre, const ScanPoint(0, 0));
      expect(const <ScanPoint>[].longestSide, 0);
    });
  });
}
