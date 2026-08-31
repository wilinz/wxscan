# Changelog

## 0.1.5

- No change of its own. Released alongside `wxscan` 0.1.5, which replaces a
  0.1.4 that could not build outside this repository. 0.1.4 is retracted.

## 0.1.4

- **Swift Package Manager support.** `ios/wxscan_live/Package.swift` and its
  macOS twin are the Swift Package form of the plugin; the podspecs stay and
  build the same sources from the same place, so CocoaPods keeps working until
  it goes read-only. The Swift files moved from `ios/Classes/` to
  `ios/wxscan_live/Sources/wxscan_live/`, which is where both build systems now
  read them.

  `wxscan.h` is a target of its own, because a Swift Package Manager target
  cannot mix Swift and C. Under CocoaPods the header still arrives through the
  pod's umbrella header, so the import of it is guarded with
  `#if canImport(wxscan_c)` and is simply absent there.

  Verified both ways on both platforms: CocoaPods and Swift Package Manager,
  iOS device, iOS simulator and macOS.
- Depends on `wxscan` 0.1.4, which fixes iOS simulator builds.
- Packaging: the `description` fits the 60-180 characters pub.dev asks for, and
  every file is `dart format` clean.

## 0.1.3

- Documentation only. The native library section now says that what that
  library carries — which image decoders, and how cargo built them — is set in
  the application's own pubspec, under `hooks: user_defines: wxscan:`, whether
  or not `wxscan` is a direct dependency. An application that only ever scans
  camera frames can carry no image decoders at all.

## 0.1.2

- No change of its own. Released alongside `wxscan` 0.1.2, whose image decoders
  and release profile an application can now configure in its pubspec.

## 0.1.1

- No change of its own. Released alongside `wxscan` 0.1.1, which builds for
  Intel Macs as well as Apple Silicon; a live-scanning application on macOS
  gets that through the scanner it depends on.

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
- `initialize` takes the weights as bytes or as paths — `detectModelPath` and
  `srModelPath` — and the path form is read by the library itself, so a
  megabyte does not cross the method channel. Flutter assets have no path and
  still go as bytes; a browser has no filesystem and refuses a path outright.
- Fixed a preview that froze on its first frame in a browser, on every visit
  to the scanner after the first. A `<video>` put into a host a platform view
  had already taken out of the page is paused by the browser and stays paused
  once it is attached again; Chromium does this and WebKit does not.
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
