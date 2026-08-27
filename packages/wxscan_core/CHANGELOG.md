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
- Scanning runs on a worker isolate owned by the scanner, so a stream costs one
  message round trip per frame rather than an isolate spawn.
- `scanPixels` takes RGB, RGBA, BGR or BGRA and converts natively, so a caller
  decoding a PNG or a JPEG does not convert pixels in Dart.
- Detection is configurable: `confidenceThreshold`, `nmsThreshold` and
  `scaleFactor` read and write without contending for the scanner's lock.
- Mismatched dimensions raise `ArgumentError` instead of returning an empty
  result that looks like a frame with nothing in it.
