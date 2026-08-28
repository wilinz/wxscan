# Changelog

## 0.1.0

First release.

- Live scanning with the camera driven natively: CameraX on Android,
  AVFoundation on iOS and macOS. Frames go straight into the scanner without
  passing through Dart, and the preview is a Flutter texture backed by the same
  buffer.
- In a browser the camera is `getUserMedia` and a `<video>`, where frames do
  cross into Dart because there is no way for them not to. The files `wxscan`
  needs served are placed by `dart run wxscan:fetch_web`.
- The camera is a `WxScanController`, a `ValueNotifier<WxScanValue>` in the
  shape of `CameraController`: every setter publishes what the device
  confirmed, and `WxScanPreview(controller: ...)` follows a rotation on its own.
- A `WxScanner` from `wxscan` can be lent to the controller, so an application
  that scans both live and from the photo library holds one scanner and one
  copy of the weights instead of two.
- One camera, and the last controller to `initialize` has it. A second one
  takes it over rather than failing or splitting frames, and the controller
  that held it is told: its `value.error` becomes a `WxCameraLost` and its
  scans stop. Disposing a controller that lost the camera closes nothing, so
  it cannot take the camera away from the one that has it. Taking over rather
  than refusing is also what makes a hot restart work, since a restart reaches
  the plugin looking exactly like a second controller.
- Reports every symbol in a frame, with corner coordinates, so several codes in
  view can be told apart and picked between.
- Torch, zoom and capture resolution, each readable as well as settable;
  `setZoom` reports the ratio the device clamped to rather than the one asked
  for.
- The native side is reached through `WxScanPlatform.instance`, which a test can
  replace to stand in for the camera.
- No native code is built here: the scanner comes from `wxscan` as a code
  asset, which Android finds through `System.loadLibrary` and Apple platforms
  through `dlsym`.
