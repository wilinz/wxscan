/// The JSON a platform binding produces for a frame, and how to read it.
///
/// Every binding that cannot hand Dart the C ABI's structs sends this instead:
/// the camera plugin's Swift and Kotlin sides, and the browser build, whose
/// results live in a worker's WebAssembly memory. Keeping it here rather than
/// beside the FFI scanner is what lets the web build use it, since that build
/// has no `dart:ffi` to import.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'result.dart';

/// Parses the JSON a platform binding produces for a camera frame.
///
/// The camera plugin sends frames straight from the native layer into the
/// scanner and forwards this document; the shape is defined by that binding.
ScanOutcome parseFrameJson(String json) {
  final map = jsonDecode(json) as Map<String, dynamic>;
  List<ScanPoint> pts(List<dynamic> flat) => [
    for (var i = 0; i < flat.length && i + 1 < flat.length; i += 2)
      ScanPoint((flat[i] as num).toDouble(), (flat[i + 1] as num).toDouble()),
  ];

  return ScanOutcome(
    width: (map['w'] as num?)?.toInt() ?? 0,
    height: (map['h'] as num?)?.toInt() ?? 0,
    results: [
      for (final r in (map['results'] as List? ?? const []))
        ScanResult(
          text: r['text'] as String? ?? '',
          bytes: Uint8List.fromList(
            (r['raw'] as List?)?.cast<int>() ??
                utf8.encode(r['text'] as String? ?? ''),
          ),
          charset: r['charset'] as String? ?? 'UTF-8',
          corners: pts(r['points'] as List? ?? const []),
          version: (r['version'] as num?)?.toInt() ?? 0,
          ecLevel: r['ecLevel'] as String? ?? '',
          charsetMode: r['charsetMode'] as String? ?? '',
          binaryMethod: (r['binaryMethod'] as num?)?.toInt() ?? 0,
        ),
    ],
    candidates: [
      for (final c in (map['candidates'] as List? ?? const [])) pts(c as List),
    ],
  );
}
