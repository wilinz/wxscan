# Changelog

## 0.1.0

First release.

- Live scanning with the camera driven natively: CameraX on Android,
  AVFoundation on iOS and macOS. Frames go straight into the scanner without
  passing through Dart, and the preview is a Flutter texture backed by the same
  buffer.
- Reports every symbol in a frame, with corner coordinates, so several codes in
  view can be told apart and picked between.
- Torch, zoom and capture resolution, each readable as well as settable;
  `setZoom` reports the ratio the device clamped to rather than the one asked
  for.
- The native side is reached through `WxScanPlatform.instance`, which a test can
  replace to stand in for the camera.
- No native code is built here: the scanner comes from `wxscan_core` as a code
  asset, which Android finds through `System.loadLibrary` and Apple platforms
  through `dlsym`.
