# wxscan

Live QR scanning for Flutter, backed by a Rust port of the `wechat_qrcode`
algorithm: CNN-based detection, super resolution, and decoding.

Camera frames go from CameraX or AVFoundation straight into the scanner and
never cross into Dart, which keeps a per-frame copy off the UI isolate. What
arrives in Dart is the outcome of each frame; the preview is a Flutter texture
backed by the same buffer.

To decode a still image instead, use
[`wxscan_core`](https://pub.dev/packages/wxscan_core), which exposes the same
scanner to Dart.

## Quick start

```sh
flutter pub add wxscan
```

**1. The weights.** They are not bundled. Download `detect.tflite` and
`sr.tflite` from
[wxscan-weights](https://github.com/wilinz/wxscan-weights), put them in
`assets/models/`, and declare the folder in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/models/
```

**2. Camera permission.** The plugin does not ask for it; it fails with a
`NO_PERMISSION` `PlatformException` if it has not been granted. Declare it, and
request it with a package such as
[`permission_handler`](https://pub.dev/packages/permission_handler) before
calling `initialize`:

| Platform | Where |
|---|---|
| Android | `<uses-permission android:name="android.permission.CAMERA" />` in `AndroidManifest.xml` |
| iOS, macOS | `NSCameraUsageDescription` in `Info.plist` |
| macOS | also `com.apple.security.device.camera` in both `.entitlements` files |

**3. Start the camera and listen.**

```dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:wxscan/wxscan.dart';

Future<Uint8List> _asset(String path) async =>
    (await rootBundle.load(path)).buffer.asUint8List();

final info = await WxScan.initialize(
  resolution: WxResolution.p720,
  detectModel: await _asset('assets/models/detect.tflite'),
  srModel: await _asset('assets/models/sr.tflite'),
);

WxScan.scanStream.listen((outcome) {
  for (final r in outcome.results) {
    print(r.text);
  }
});
```

**4. Show the preview.** It is a Flutter texture, rotated for the current
interface orientation:

```dart
StreamBuilder<WxPreviewSize>(
  stream: WxScan.previewSizeStream,
  builder: (context, snapshot) {
    final size = snapshot.data;
    if (size == null) return const SizedBox.shrink();
    return RotatedBox(
      quarterTurns: size.quarterTurns,
      child: Texture(textureId: info.textureId),
    );
  },
);
```

Call `WxScan.dispose()` when leaving the screen. `setScanning(false)` pauses
decoding while leaving the camera and preview running, which is what you want
while a result sheet is up.

[`packages/wxscan/example`](example) is a working application doing all of the
above, plus torch, zoom, decoding from the photo library and picking among
several codes in one frame.

## Results

Each frame produces one `ScanOutcome`, with empty results when nothing was
found. `candidates` holds what the detector located; candidates without results
— `hasUndecodable` — mean a symbol was seen but could not be decoded, usually
because it is too small or too blurred, which is the signal to zoom in.

Coordinates are in the upright frame, whose size is on the outcome. They already
account for rotation, and for mirroring where the preview is mirrored, so they
can be mapped onto the preview without further correction.

## Camera control

`setResolution`, `setTorch`, `hasTorch`, `setZoom`, `zoomRange`, and
`grabFrame`, which returns the most recent frame as an upright JPEG at the size
being decoded — usable as a frozen picture while the user picks among several
codes.

Higher resolutions cost proportionally more per frame, but a dense symbol
cannot be decoded at all without enough pixels. 720p is enough for everyday
codes.

## Models

The TFLite weights are passed to `initialize`, typically from an asset. The
plugin loads them into a scanner it owns; that scanner is separate from any held
by `wxscan_core`, since this path never goes through Dart. Omitting them, or
passing weights that fail to load, falls back to decoding without the CNN stages
rather than failing — `WxScanCameraInfo.modelsLoaded` reports which mode is
active.

## Platforms

| Platform | Camera |
|---|---|
| Android | CameraX, API 24+ |
| iOS | AVFoundation, 13.0+ |
| macOS | AVFoundation, 10.15+ |

## The native library

Nothing native is built here. The scanner comes from
[`wxscan_core`](https://pub.dev/packages/wxscan_core), whose build hook produces
it as a Dart code asset; this package is a dependency of that one, so an
application that uses either gets exactly one copy.

The Swift and Kotlin code calls the scanner's C ABI directly, because camera
frames never pass through Dart. A code asset is loaded by the Dart runtime
rather than linked by Xcode or Gradle, so those entry points are resolved at run
time: on Android Flutter puts the asset in the APK's `lib/<abi>/`, where
`System.loadLibrary` already looks, and on iOS and macOS `WxScanNative.swift`
opens the bundled framework and reads the symbols with `dlsym`.

## Licence

Apache-2.0. The Rust sources are in
[wxscan-rs](https://github.com/wilinz/wxscan-rs).
