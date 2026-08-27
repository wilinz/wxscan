import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:wxscan/wxscan.dart';
import 'package:wxscan_core/wxscan_core.dart';

/// Image decoding, plus the models the camera plugin needs.
///
/// Camera frames take a different path: the plugin drives them from the native
/// layer straight into its own scanner, without passing through Dart. This
/// class owns the scanner used for still images.
class Scanner {
  static WxScanner? _scanner;
  static bool _nnEnabled = false;

  /// Model bytes, kept so they can be handed to [WxScan.initialize].
  static Uint8List? detectModel;
  static Uint8List? srModel;

  /// Whether the CNN detector is active, which requires the models to load.
  static bool get nnEnabled => _nnEnabled;

  /// Loads the TFLite models from assets and creates the scanner.
  ///
  /// A model that fails to load is not an error: decoding falls back to plain
  /// image processing, which still works but detects small or distant symbols
  /// less reliably.
  static Future<bool> init() async {
    if (_scanner != null) return _nnEnabled;
    try {
      detectModel = (await rootBundle.load('assets/models/detect.tflite'))
          .buffer
          .asUint8List();
      srModel =
          (await rootBundle.load('assets/models/sr.tflite')).buffer.asUint8List();
    } catch (_) {
      detectModel = null;
      srModel = null;
    }
    _scanner = await WxScanner.create(
      detectModel: detectModel,
      srModel: srModel,
    );
    // The label reports the detector, which is what changes the detection rate.
    _nnEnabled = _scanner!.hasDetector;
    return _nnEnabled;
  }

  /// Decodes an RGBA image, such as one from the photo library.
  static Future<ScanOutcome> scanRgba(
    Uint8List rgba,
    int width,
    int height,
  ) async {
    final scanner = _scanner;
    if (scanner == null) return ScanOutcome.empty;
    return scanner.scanPixels(rgba, width, height);
  }

  /// Decodes encoded image bytes, such as PNG or JPEG.
  static Future<ScanOutcome> scanImageBytes(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return ScanOutcome.empty;
    // Normalised to 8-bit RGB first: a PNG may be palette-based or 1-bit,
    // where reading channels directly yields indices rather than intensities.
    // The conversion to grayscale is left to the scanner.
    final rgb = decoded.convert(numChannels: 3, format: img.Format.uint8);
    return scanRgb(rgb.toUint8List(), rgb.width, rgb.height);
  }

  /// Decodes a tightly packed 24-bit RGB image.
  static Future<ScanOutcome> scanRgb(
    Uint8List rgb,
    int width,
    int height,
  ) async {
    final scanner = _scanner;
    if (scanner == null) return ScanOutcome.empty;
    return scanner.scanPixels(rgb, width, height, format: WxPixelFormat.rgb);
  }

  /// Decodes a grayscale image.
  static Future<ScanOutcome> scanGray(
    Uint8List gray,
    int width,
    int height, {
    int? rowStride,
  }) async {
    final scanner = _scanner;
    if (scanner == null) return ScanOutcome.empty;
    return scanner.scanFrame(gray, width, height, rowStride: rowStride);
  }

  /// Runs the sample image through the whole path and logs the outcome, to
  /// confirm on a device that the library and the models are wired up.
  static Future<String> selfTest() async {
    try {
      final data = await rootBundle.load('assets/test/qr_sample.png');
      final sw = Stopwatch()..start();
      final outcome = await scanImageBytes(data.buffer.asUint8List());
      final elapsed = sw.elapsedMilliseconds;
      final first = outcome.results.isEmpty ? null : outcome.results.first;
      final msg = first == null
          ? 'selftest: nothing found (${elapsed}ms)'
          : 'selftest: ok (${elapsed}ms) -> ${first.text} '
              '(v${first.version}/${first.ecLevel}/${first.charset})';
      _log(msg);
      return msg;
    } catch (e) {
      final msg = 'selftest: failed $e';
      _log(msg);
      return msg;
    }
  }

  /// Same check for the camera path: the sample image is sent through the
  /// native binding as a camera frame would be, with row padding and rotation.
  static Future<String> selfTestCameraPath() async {
    try {
      final data = await rootBundle.load('assets/test/qr_sample.png');
      final decoded = img.decodeImage(data.buffer.asUint8List());
      if (decoded == null) return 'selftest-native: could not decode the sample';
      final rgb = decoded.convert(numChannels: 3, format: img.Format.uint8);
      final gray = img.grayscale(rgb);
      final buf = Uint8List(gray.width * gray.height);
      var i = 0;
      for (final p in gray) {
        buf[i++] = p.r.toInt();
      }
      final outcome =
          await WxScan.selfTestNative(buf, gray.width, gray.height);
      final first = outcome.results.isEmpty ? null : outcome.results.first;
      final msg = 'selftest-native: ${first?.text ?? 'nothing found'}';
      _log(msg);
      return msg;
    } catch (e) {
      final msg = 'selftest-native: failed $e';
      _log(msg);
      return msg;
    }
  }

  static void _log(String msg) {
    developer.log(msg, name: 'wxscan');
    // ignore: avoid_print
    print('[wxscan] $msg');
  }
}
