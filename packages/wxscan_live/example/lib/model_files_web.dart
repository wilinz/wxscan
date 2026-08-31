import 'dart:typed_data';

/// Never reached: [Scanner] keeps to the bytes in a browser, which has no
/// filesystem to copy into and no path to open. Present so that the
/// conditional export has both halves.
Future<(String detect, String sr)> installWeights(
  Future<Uint8List> Function(String assetKey) readAsset,
) => throw UnsupportedError(
  'a browser has no sandbox to copy the weights into; pass the bytes',
);
