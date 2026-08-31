// Scans image files for QR codes and prints what was decoded.
//
// Run it from the package root:
//
//     dart run example/main.dart test/data/code.png
//
// The CNN weights are optional. Without them the detector falls back to image
// processing, which reads clean pictures but fewer awkward ones; download
// `detect.tflite` and `sr.tflite` from https://github.com/wilinz/wxscan-weights
// and pass them to see the difference:
//
//     dart run example/main.dart --models=assets/models photo.jpg
import 'dart:io';

import 'package:wxscan/wxscan.dart';

Future<void> main(List<String> args) async {
  final paths = <String>[];
  String? models;
  for (final arg in args) {
    if (arg.startsWith('--models=')) {
      models = arg.substring('--models='.length);
    } else {
      paths.add(arg);
    }
  }
  if (paths.isEmpty) {
    stderr.writeln(
      'usage: dart run example/main.dart [--models=DIR] <image>...',
    );
    exitCode = 64;
    return;
  }

  // `use` disposes the scanner even if scanning throws. The native side holds
  // a worker isolate and the loaded weights, so it is worth creating once and
  // reusing across pictures rather than per image.
  await WxScanner.use(
    detectModelPath: models == null ? null : '$models/detect.tflite',
    srModelPath: models == null ? null : '$models/sr.tflite',
    (scanner) async {
      for (final path in paths) {
        await _scan(scanner, path);
      }
    },
  );
}

Future<void> _scan(WxScanner scanner, String path) async {
  final ScanOutcome outcome;
  try {
    outcome = await scanner.scanPath(path);
  } on PictureUnreadable catch (e) {
    // A picture that never reached the scanner, which is not the same as a
    // picture with no code in it.
    stderr.writeln('$path: ${e.failure.name}');
    exitCode = 1;
    return;
  }

  print('$path (${outcome.width}x${outcome.height}):');
  if (outcome.results.isEmpty) {
    // A located but undecodable symbol is usually too small or too blurred,
    // which is a reason to zoom in rather than to report a failure.
    print(
      outcome.hasUndecodable
          ? '  ${outcome.candidates.length} candidate(s), none decodable'
          : '  no QR code found',
    );
    return;
  }
  for (final r in outcome.results) {
    print('  ${r.text}');
    print(
      '    v${r.version}/${r.ecLevel}/${r.charset}, '
      'corners ${r.corners.map((p) => '(${p.dx.round()},${p.dy.round()})').join(' ')}',
    );
  }
}
