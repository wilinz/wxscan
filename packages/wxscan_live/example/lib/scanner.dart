import 'dart:developer' as developer;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:wxscan_live/wxscan_live.dart';
import 'package:wxscan/wxscan.dart';

/// A file no decoder on this device could open.
class UnreadableImage implements Exception {
  const UnreadableImage();

  @override
  String toString() => 'wxscan: that file is not a picture this device can read';
}

/// Image decoding, plus the models the camera plugin needs.
///
/// Camera frames take a different path: the plugin drives them from the native
/// layer straight into its own scanner, without passing through Dart. This
/// class owns the scanner used for still images.
/// A picture the reader chose, and what was found in it. See
/// [Scanner.pickAndScan].
typedef PickedPicture = ({XFile file, ScanOutcome outcome});

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
      detectModel = await _bytes('assets/models/detect.tflite');
      srModel = await _bytes('assets/models/sr.tflite');
    } on Object catch (e) {
      // Worth saying which asset and why. Swallowing this leaves the whole
      // application quietly on the fallback engine, and the only visible
      // symptom is that real photographs stop decoding.
      _log('the weights did not load: $e');
      detectModel = null;
      srModel = null;
    }
    _scanner = await WxScanner.create(
      detectModel: detectModel,
      srModel: srModel,
    );
    // The label reports the detector, which is what changes the detection rate.
    _nnEnabled = _scanner!.hasDetector;
    _log('scanner ready: detector $_nnEnabled, '
        'sr ${_scanner!.hasSuperResolution}');
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

  /// An asset as bytes.
  ///
  /// `asUint8List()` with no arguments is the trap here: `rootBundle.load`
  /// hands back a `ByteData` that on some platforms is a *view* into a larger
  /// buffer, and dropping its offset and length reads the wrong bytes — enough
  /// for a `.tflite` to be rejected, which leaves the scanner on its fallback
  /// engine with nothing said. The two arguments are not optional in practice.
  static Future<Uint8List> _bytes(String key) async {
    final data = await rootBundle.load(key);
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  /// Picks a picture from the photo library and decodes it.
  ///
  /// Null when the picker was dismissed, so that a caller can tell "nothing
  /// chosen" from "nothing found" — the two want different things said. Shared
  /// by the home screen and the scanning screen, which otherwise agree on the
  /// steps and would drift apart on the wording.
  ///
  /// The file comes back with the outcome, unread: a picture holding several
  /// codes has to be shown for the reader to pick among them, and only that
  /// case pays for pulling a photograph into memory.
  static Future<PickedPicture?> pickAndScan() async {
    final file = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (file == null) return null;

    // The native reader first, which never materialises the pixels: a 12
    // megapixel photograph is 48 MB as RGBA, and going through Dart copies
    // that into the worker isolate and again into native memory. It has no
    // path to read in a browser, and no decoder for a format outside PNG,
    // JPEG and GIF, so both cases fall back to the platform's own decoder —
    // which reads everything the device can display, HEIC included.
    if (!kIsWeb) {
      final outcome = await _scanPathOrNull(file.path);
      if (outcome != null) return (file: file, outcome: outcome);
    }
    return (file: file, outcome: await scanImageBytes(await file.readAsBytes()));
  }

  /// Scans a file the way [pickAndScan] does, for callers that already have a
  /// path — a device test, say, which has no one to work the picker.
  static Future<ScanOutcome> scanPicked(String path) async =>
      (await _scanPathOrNull(path)) ?? scanImageBytes(await XFile(path).readAsBytes());

  /// The native reader, or null when it declined the file.
  static Future<ScanOutcome?> _scanPathOrNull(String path) async {
    final scanner = _scanner;
    if (scanner == null) return null;
    try {
      return _report('path', await scanner.scanPath(path));
    } on PictureUnreadable catch (e) {
      _log('the native reader passed on it: $e');
      return null;
    }
  }

  /// Decodes encoded image bytes, such as PNG or JPEG.
  ///
  /// Throws [UnreadableImage] when nothing here can read the file at all,
  /// which is a different thing from finding no code in it and wants saying
  /// differently.
  static Future<ScanOutcome> scanImageBytes(Uint8List bytes) async {
    _log('picture: ${bytes.length} bytes, '
        'scanner ${_scanner == null ? "MISSING" : "ready"}, '
        'detector ${_scanner?.hasDetector}, sr ${_scanner?.hasSuperResolution}');
    // The platform's own decoder first. It reads everything the device can
    // show, HEIC included — which is what an iPhone's photo library is full of
    // and what `package:image` cannot open, and a file it could not open used
    // to come back indistinguishable from a picture with no code in it.
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final (width, height) = (image.width, image.height);
      final ByteData? data;
      try {
        data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      } finally {
        image.dispose();
        codec.dispose();
      }
      if (data != null) {
        final rgba = data.buffer.asUint8List();
        _log('platform codec: ${width}x$height rgba, ${rgba.length} bytes');
        return _report('rgba', await scanRgba(rgba, width, height));
      }
      _log('platform codec: decoded but gave no bytes');
    } on Object catch (e) {
      _log('platform codec could not read it: $e');
    }

    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      _log('package:image could not read it either');
      throw const UnreadableImage();
    }
    // Normalised to 8-bit RGB first: a PNG may be palette-based or 1-bit,
    // where reading channels directly yields indices rather than intensities.
    // The conversion to grayscale is left to the scanner.
    final rgb = decoded.convert(numChannels: 3, format: img.Format.uint8);
    _log('package:image: ${rgb.width}x${rgb.height} rgb');
    return _report('rgb', await scanRgb(rgb.toUint8List(), rgb.width, rgb.height));
  }

  /// Says what a scan came back with, which is the one thing a failure report
  /// from a device cannot be guessed at without.
  static ScanOutcome _report(String path, ScanOutcome outcome) {
    _log('$path -> frame ${outcome.width}x${outcome.height}, '
        '${outcome.results.length} decoded, '
        '${outcome.candidates.length} candidates'
        '${outcome.results.isEmpty ? "" : ": ${outcome.results.first.text}"}');
    return outcome;
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
