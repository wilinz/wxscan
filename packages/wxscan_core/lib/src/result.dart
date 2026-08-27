import 'dart:typed_data';

/// A point in image coordinates.
///
/// This package is plain Dart, so it cannot use `dart:ui`'s `Offset`. The field
/// names match it, which is what a Flutter caller needs: `Offset(p.dx, p.dy)`.
class ScanPoint {
  const ScanPoint(this.dx, this.dy);

  final double dx;
  final double dy;

  @override
  bool operator ==(Object other) =>
      other is ScanPoint && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() => 'ScanPoint($dx, $dy)';
}

/// Helpers for the four corners of a symbol or a candidate.
///
/// Both [ScanResult.corners] and each entry of [ScanOutcome.candidates] are
/// four points, so anything that wants a box or a centre out of them ends up
/// writing the same loop. These are that loop.
extension ScanQuad on List<ScanPoint> {
  /// The average of the points, which for four corners is the centre.
  ScanPoint get centre {
    if (isEmpty) return const ScanPoint(0, 0);
    var x = 0.0;
    var y = 0.0;
    for (final p in this) {
      x += p.dx;
      y += p.dy;
    }
    return ScanPoint(x / length, y / length);
  }

  /// The smallest axis-aligned box containing the points, as
  /// `(left, top, right, bottom)`.
  ///
  /// A rotated symbol fills less of this box than it looks; it is meant for
  /// hit-testing and for deciding how far away a symbol is, not for drawing an
  /// outline. Use the corners themselves for that.
  ({double left, double top, double right, double bottom}) get bounds {
    if (isEmpty) return (left: 0, top: 0, right: 0, bottom: 0);
    var left = first.dx, right = first.dx;
    var top = first.dy, bottom = first.dy;
    for (final p in skip(1)) {
      if (p.dx < left) left = p.dx;
      if (p.dx > right) right = p.dx;
      if (p.dy < top) top = p.dy;
      if (p.dy > bottom) bottom = p.dy;
    }
    return (left: left, top: top, right: right, bottom: bottom);
  }

  /// The longer side of [bounds], which is what tells a caller whether a symbol
  /// is too small to decode and zooming in would help.
  double get longestSide {
    final b = bounds;
    final w = b.right - b.left;
    final h = b.bottom - b.top;
    return w > h ? w : h;
  }
}

/// One decoded symbol.
class ScanResult {
  ScanResult({
    required this.text,
    required this.bytes,
    required this.charset,
    required this.corners,
    required this.version,
    required this.ecLevel,
    required this.charsetMode,
    required this.binaryMethod,
  });

  /// The payload decoded to a Dart string. GB2312 payloads are converted;
  /// anything else is read as UTF-8 with invalid sequences replaced.
  final String text;

  /// The payload as it was encoded. QR content is not required to be text, so
  /// this is the authoritative value.
  final Uint8List bytes;

  /// The encoding reported by the decoder, `UTF-8` or `GB2312`.
  final String charset;

  /// The four corners in image coordinates, ordered top-left, top-right,
  /// bottom-right, bottom-left.
  final List<ScanPoint> corners;

  /// QR version, 1 to 40.
  final int version;

  /// Error correction level: `L`, `M`, `Q` or `H`.
  final String ecLevel;

  /// The encoding mode segment the payload came from, such as `BYTE` or `HANZI`.
  final String charsetMode;

  /// Which binarizer produced the decode: 0 hybrid, 1 fast window,
  /// 2 simple adaptive, 3 adaptive threshold.
  final int binaryMethod;

  @override
  String toString() => 'ScanResult($text, v$version/$ecLevel/$charset)';
}

/// The outcome of scanning one image.
class ScanOutcome {
  const ScanOutcome({
    required this.results,
    required this.candidates,
    required this.width,
    required this.height,
  });

  static const empty = ScanOutcome(
    results: [],
    candidates: [],
    width: 0,
    height: 0,
  );

  /// Symbols that were decoded.
  final List<ScanResult> results;

  /// Quadrilaterals the detector found, each with four corners in the same
  /// order as [ScanResult.corners].
  ///
  /// Candidates without results mean a symbol was located but could not be
  /// decoded, usually because it is too small or too blurred. A caller can use
  /// this to zoom in rather than reporting a failure.
  final List<List<ScanPoint>> candidates;

  /// Size of the image the coordinates refer to. For a rotated camera frame
  /// this is the size after rotation, not the size that was passed in.
  final int width;
  final int height;

  bool get isEmpty => results.isEmpty && candidates.isEmpty;

  /// Something was located but could not be decoded, usually because it is too
  /// small or too blurred. A caller can zoom in rather than report a failure.
  bool get hasUndecodable => results.isEmpty && candidates.isNotEmpty;
}

/// Why a picture handed to `WxScanner.scanPath` never reached the scanner.
///
/// Neither of these is a picture with no code in it, which comes back as an
/// empty [ScanOutcome] instead. Keeping the two apart is the point: a file the
/// library never managed to read looks exactly like an empty picture if the
/// distinction is dropped, and the reader is left with nothing to act on.
enum PictureReadFailure {
  /// The path could not be opened or read at all.
  unreadable,

  /// The bytes were read but are not an image the library decodes. PNG, JPEG
  /// and GIF are; HEIC is not, being a system framework's business rather than
  /// this library's. The platform's own decoder and `WxScanner.scanPixels`
  /// will get further with one of those.
  unsupportedFormat,
}

/// Thrown when a picture could not be read. See [PictureReadFailure].
class PictureUnreadable implements Exception {
  const PictureUnreadable(this.path, this.failure);

  final String path;
  final PictureReadFailure failure;

  @override
  String toString() => switch (failure) {
        PictureReadFailure.unreadable =>
          'PictureUnreadable: could not open or read $path',
        PictureReadFailure.unsupportedFormat =>
          'PictureUnreadable: $path is not an image this build can decode; '
              'HEIC and anything else needing a system decoder must go '
              'through the platform and WxScanner.scanPixels',
      };
}
