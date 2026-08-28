# Changelog

## 0.1.0

First release.

- Decodes images and raw pixel buffers through a Rust port of the
  `wechat_qrcode` algorithm: CNN detection, super resolution and decoding, with
  no OpenCV.
- A plain Dart package rather than a Flutter plugin. `hook/build.dart` builds
  the native library and bundles it, together with the TFLite C library, as
  code assets, so `dart run` and `dart test` work as well as Flutter does and
  there are no platform build files.
- Runs in a browser too, as WebAssembly on a worker, against the same TFLite
  weights and the same runtime as every other platform. The four files an
  application serves are placed by `dart run wxscan:fetch_web`, which fetches
  the compiled three from pinned releases rather than carrying them here; see
  `doc/web_build.md`.
- Decodes pictures as well as pixels: `scanPath` for a file, `scanImage` for
  bytes already in hand — a picked image, a download, or a browser, which has
  no paths. PNG, JPEG and GIF everywhere; WebP, BMP and TIFF where the platform
  lends nothing; HEIC on Apple, Android and in Safari. `doc/image_formats.md`
  is the matrix, and the platform can be lent a decoder for the rest.
- Scanning runs on a worker isolate owned by the scanner, so a stream costs one
  message round trip per frame rather than an isolate spawn.
- `scanPixels` takes RGB, RGBA, BGR or BGRA and converts natively, so a caller
  decoding a PNG or a JPEG does not convert pixels in Dart.
- Detection is configurable: `confidenceThreshold`, `nmsThreshold` and
  `scaleFactor` read and write without contending for the scanner's lock.
- A scanner can be lent to `wxscan_live`, so an application that scans both
  live and from the photo library holds one scanner and one copy of the
  weights. The two sides may be disposed in either order.
- Mismatched dimensions raise `ArgumentError` instead of returning an empty
  result that looks like a frame with nothing in it.
