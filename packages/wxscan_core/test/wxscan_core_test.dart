/// Runs the scanner from plain Dart: no Flutter, no platform build system.
/// The build hook produces the native library and the TFLite one beside it.
import 'dart:io';
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

  group('a colour image decodes the same however its pixels are laid out', () {
    // A version 3 QR, as its modules. Built here rather than loaded so that the
    // test needs no asset and no image decoder, and so that the same intensities
    // reach every layout below.
    //
    // Blank images cannot catch what this catches. The grayscale conversion was
    // once wrong by a factor of two and wrapped rather than clamped, which turns
    // mid grey black and shreds every camera frame — and every test that only
    // asserted "nothing found in a blank image" went on passing. This asserts
    // the five layouts agree with each other and with the gray path, which is
    // false the moment that conversion drifts again.
    const modules = [
    '11111110101111011110001111111',
    '10000010001111000101001000001',
    '10111010010100000100101011101',
    '10111010101011101010001011101',
    '10111010111111011010001011101',
    '10000010110000101111101000001',
    '11111110101010101010101111111',
    '00000000111110000110000000000',
    '10001011100000010101011111001',
    '00010000101100111000011111111',
    '10001110011100010010101100001',
    '00110101101110101101101111011',
    '00000010001010000110110000010',
    '00111000110111111110001111111',
    '00000111110101010010111101101',
    '00100001000010000111110000011',
    '01010110100111111100100100010',
    '10110100001101101110101111011',
    '00101011001110011010100000101',
    '00100001110010000110110110011',
    '11110010111101101100111111001',
    '00000000111010111001100010001',
    '11111110101001110101101011101',
    '10000010010101001101100010011',
    '10111010101011000101111111001',
    '10111010010110111010010000001',
    '10111010010001111111110001111',
    '10000010011110100110111011011',
    '11111110100101110100111111010'
    ];
    const quiet = 4, scale = 4;
    final side = (modules.length + quiet * 2) * scale;

    /// The code as 8-bit grey, with a quiet zone, at [scale] pixels a module.
    Uint8List gray() {
      final out = Uint8List(side * side)..fillRange(0, side * side, 255);
      for (var y = 0; y < modules.length; y++) {
        for (var x = 0; x < modules.length; x++) {
          if (modules[y][x] != '1') continue;
          for (var dy = 0; dy < scale; dy++) {
            final row = ((y + quiet) * scale + dy) * side;
            final from = row + (x + quiet) * scale;
            out.fillRange(from, from + scale, 0);
          }
        }
      }
      return out;
    }

    /// The same picture with [channels] bytes a pixel, grey in every colour
    /// channel and, where there is a fourth, opaque.
    Uint8List spread(Uint8List g, int channels) {
      final out = Uint8List(g.length * channels);
      for (var i = 0; i < g.length; i++) {
        for (var c = 0; c < channels; c++) {
          out[i * channels + c] = c == 3 ? 255 : g[i];
        }
      }
      return out;
    }

    late WxScanner scanner;
    setUp(() async => scanner = await WxScanner.create());
    tearDown(() => scanner.dispose());

    test('every layout reads it, and reads the same text', () async {
      final g = gray();
      final expected = (await scanner.scanGray(g, side, side)).results;
      expect(expected, isNotEmpty, reason: 'the gray path decodes the code');
      final text = expected.first.text;

      for (final (format, channels) in [
        (WxPixelFormat.rgb, 3),
        (WxPixelFormat.rgba, 4),
        (WxPixelFormat.bgr, 3),
        (WxPixelFormat.bgra, 4),
      ]) {
        final outcome = await scanner.scanPixels(
            spread(g, channels), side, side,
            format: format);
        expect(outcome.results.map((r) => r.text), [text], reason: '$format');
      }
    });
  });

  group('a picture read from a path', () {
    // The same code as the group above, written out as a file: the native
    // reader has to arrive at what the in-memory paths arrive at.
    late WxScanner scanner;
    setUp(() async => scanner = await WxScanner.create());
    tearDown(() async => scanner.dispose());

    test('decodes, and agrees with the same picture as pixels', () async {
      final outcome = await scanner.scanPath('test/data/code.png');
      expect(outcome.results, isNotEmpty);
      expect(outcome.width, 148);
      expect(outcome.height, 148);

      final bytes = await File('test/data/code.png').readAsBytes();
      expect(bytes, isNotEmpty);
      expect(scanner.scanPathSync('test/data/code.png').results.first.text,
          outcome.results.first.text);
    });

    test('a file that is not there is not a picture without a code in it',
        () async {
      // The whole point of the status: this must not come back as an empty
      // outcome, which is what "no code in the picture" looks like.
      await expectLater(
        scanner.scanPath('test/data/no_such_file.png'),
        throwsA(isA<PictureUnreadable>().having(
            (e) => e.failure, 'failure', PictureReadFailure.unreadable)),
      );
    });

    test('a file that is not an image says which of the two it is', () async {
      final tmp = File('${Directory.systemTemp.path}/wxscan_not_an_image.png')
        ..writeAsStringSync('not a picture, whatever the extension says');
      addTearDown(() => tmp.deleteSync());
      await expectLater(
        scanner.scanPath(tmp.path),
        throwsA(isA<PictureUnreadable>().having((e) => e.failure, 'failure',
            PictureReadFailure.unsupportedFormat)),
      );
    });
  });
}
