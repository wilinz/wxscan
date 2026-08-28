# wxscan_live

**English** · [简体中文](README.zh-CN.md)

Live QR scanning for Flutter, backed by a Rust port of the `wechat_qrcode`
algorithm: CNN-based detection, super resolution, and decoding.

Camera frames go from CameraX or AVFoundation straight into the scanner and
never cross into Dart, which keeps a per-frame copy off the UI isolate. What
arrives in Dart is the outcome of each frame; the preview is a Flutter texture
backed by the same buffer.

To decode a still image instead, use
[`wxscan`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan), which exposes the same
scanner to Dart.

**[Try it in a browser](https://wilinz.github.io/wxscan/)** — the example
application, built for the web and running the same Rust scanner as WebAssembly.
It opens on a menu, and asks for the camera only if you choose live scanning;
decoding a picture never needs one.

## Quick start

Not on pub.dev yet, so the dependency comes from git. Either form brings
`wxscan` with it:

```yaml
dependencies:
  wxscan_live:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan_live
```

The day it is published, that becomes:

```yaml
dependencies:
  wxscan_live: ^0.1.0
```

The git form follows the default branch; add a `ref` to pin a tag or a commit.

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
import 'package:wxscan_live/wxscan_live.dart';

Future<Uint8List> _asset(String path) async {
  final data = await rootBundle.load(path);
  // The offset and length are not optional: a bundled asset can be a view into
  // a larger buffer, and `asUint8List()` with no arguments reads past it.
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

final controller = WxScanController(resolution: WxResolution.p720);
await controller.initialize(
  detectModel: await _asset('assets/models/detect.tflite'),
  srModel: await _asset('assets/models/sr.tflite'),
);

controller.scans.listen((outcome) {
  for (final r in outcome.results) {
    print(r.text);
  }
});
```

`WxScanController` is a `ValueNotifier<WxScanValue>`, the shape
`CameraController` and `CameraValue` have: every setter awaits the platform and
then publishes what the device actually did, so `controller.value.zoom` is the
ratio in effect rather than the one asked for. Listen to it, or hand it to a
`ValueListenableBuilder`, and the screen follows.

**4. Show the preview.** `WxScanPreview` is the image and nothing else — a
texture natively, a platform view in a browser — held upright in the device's
natural orientation, so whatever the screen has rotated to is made up around
it:

```dart
ValueListenableBuilder<WxScanValue>(
  valueListenable: controller,
  builder: (context, value, _) {
    final size = value.previewSize;
    if (size == null) return const SizedBox.shrink();
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          // The box is sized *after* the turn, and the turn is applied
          // inside it. The two have to agree or BoxFit stretches by the
          // wrong ratio.
          width: size.rotatedWidth.toDouble(),
          height: size.rotatedHeight.toDouble(),
          child: RotatedBox(
            quarterTurns: size.quarterTurns,
            child: SizedBox(
              width: size.width.toDouble(),
              height: size.height.toDouble(),
              child: WxScanPreview(controller: controller),
            ),
          ),
        ),
      ),
    );
  },
);
```

Build from the controller rather than reading `previewSize` once: it changes
when the screen rotates, and on a device that fell back to a different capture
size than the one asked for.

Call `controller.dispose()` when leaving the screen — a controller left
undisposed holds the camera open. `setScanning(false)` pauses decoding while
leaving the camera and preview running, which is what you want while a result
sheet is up.

[`packages/wxscan_live/example`](example) is a working application doing all of the
above, plus torch, zoom, decoding from the photo library and picking among
several codes in one frame.

**It is also where the user interface is.** This package draws the camera image
and reports what was found; the viewfinder, the corners drawn over each decoded
code, the picker for several codes in one frame, and the mapping from frame
coordinates to screen coordinates that keeps drawing and tapping in agreement
are all in [`example/lib/scan_page.dart`](example/lib/scan_page.dart), written
to be read and copied rather than depended on.

## Results

Each frame produces one `ScanOutcome`, with empty results when nothing was
found. `candidates` holds what the detector located; candidates without results
— `hasUndecodable` — mean a symbol was seen but could not be decoded, usually
because it is too small or too blurred, which is the signal to zoom in.

Coordinates are in the upright frame, whose size is on the outcome. They already
account for rotation, and for mirroring where the preview is mirrored, so they
can be mapped onto the preview without further correction.

## Camera control

`setResolution`, `setTorch`, `hasTorch`, `setZoom`, `zoomRange`, `focusAt`, and
`grabFrame`, which returns the most recent frame as an upright JPEG at the size
being decoded — usable as a frozen picture while the user picks among several
codes.

Higher resolutions cost proportionally more per frame, but a dense symbol
cannot be decoded at all without enough pixels. 720p is enough for everyday
codes.

Each setting reads back from what the device confirmed rather than from what
was asked for: `setZoom` returns the ratio it clamped to, and `torchEnabled` is
false on hardware with no torch however many times it is set.

### Focus

`focusAt(x, y)` points focus and exposure at one place in the picture, and
returns whether the device took it — false where the camera is closed, the
point is outside the picture, or the hardware has no focus to point, which
includes every browser. Both revert to their continuous modes after a few
seconds, so a scanner left alone goes on focusing by itself.

**The coordinates are fractions of the preview, in the space
`previewWidth` and `previewHeight` describe — before any
`quarterTurns` the screen asks for.** A tap therefore has to be brought back
through the same transform the preview was drawn with: undo the fit, then undo
the turn.

```dart
// `tap` is local to the box the preview covers, `size` is the current
// WxPreviewSize.
final scale = math.max(box.width / size.rotatedWidth,
                       box.height / size.rotatedHeight);
final dx = (box.width - size.rotatedWidth * scale) / 2;
final dy = (box.height - size.rotatedHeight * scale) / 2;
final rx = (tap.dx - dx) / (size.rotatedWidth * scale);
final ry = (tap.dy - dy) / (size.rotatedHeight * scale);
if (rx < 0 || rx > 1 || ry < 0 || ry > 1) return;  // outside the picture

// Undo RotatedBox's clockwise quarter turns.
final (x, y) = switch (size.quarterTurns) {
  1 => (ry, 1 - rx),
  2 => (1 - rx, 1 - ry),
  3 => (1 - ry, rx),
  _ => (rx, ry),
};
await controller.focusAt(x, y);
```

A `ScanResult`'s own coordinates are in the scanned frame, which is upright
with respect to the screen — the same space, past the fit — so focusing on a
code found in a frame needs only the second half: divide its centre by
`ScanOutcome.width` and `height`, then undo the turns.

`example/lib/scan_page.dart` does both, one for the tap and one for focusing
automatically on a code that was seen and could not be read.

## Best practices

**Follow the application's lifecycle.** Scanning in the background costs
battery and produces frames nobody sees:

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  controller.setScanning(state == AppLifecycleState.resumed);
}
```

**`setScanning(false)`, not `dispose()`, for a pause.** It stops decoding and
leaves the camera and the preview running, which is what a result sheet or a
pushed page wants. `dispose()` is for leaving the screen, and every controller
that initialises must be disposed — the device has one camera session, so a
controller that outlives its screen holds it against the next one.

**Treat `hasUndecodable` as "move closer", not as failure.** A candidate with
no result means the detector found a symbol the decoder could not read — almost
always too small in the frame, or too soft. Two things help, and they help
independently:

- *Zoom, gradually.* Compute a target from how much of the frame the candidate
  fills, then walk towards it in small steps rather than setting it in one
  call. A ratio that jumps throws the code the user was holding steady out of
  frame, and reads as a scanner guessing. Note that a camera zooms about the
  centre of the picture and nowhere else, so a code near an edge has little
  room before zooming pushes it out — better to wait for the hand to move over.
- *Focus on it.* A small code is usually a soft one, sitting somewhere inside
  the frame while continuous focus, which weighs the middle, holds the wall
  behind it sharp. `focusAt` on the candidate's centre is often the whole
  difference, and it works on codes too far off centre to zoom towards.

The two want different patience. Make the **zoom** wait for several frames to
agree: firing on a misdetection throws the picture about and loses whatever the
user was aiming at. **Focus** can act on the first frame — at worst the lens
moves to a place with nothing there, which the next frame corrects and which
costs nothing meanwhile, while waiting only delays the reading it was going to
make possible.

**Freeze the picture before asking the user to pick.** When a frame decodes
more than one code, the markers belong to *that* frame; with the preview still
running the picture moves under them with every tremor of the hand and they can
never be tapped accurately. `grabFrame()` returns that very frame as a JPEG —
show it over the preview, with `setScanning(false)`, and the markers line up
for free.

**Stand in for the camera in tests.** Every call goes through
`WxScanPlatform.instance`; assign a subclass to it and the whole native side is
replaced, so a widget test can drive scan results, rotations and zoom clamping
without a device.

## Models

The TFLite weights are passed to `initialize`, typically from an asset. The
plugin loads them into a scanner it owns, on the native side, since this path
never goes through Dart. Omitting them, or passing weights that fail to load,
falls back to decoding without the CNN stages rather than failing —
`controller.value.modelsLoaded` reports which mode is active.

### Sharing one scanner

An application that scans both live and from the photo library otherwise holds
two scanners: two copies of the CNN weights in memory, and two sets of
thresholds that drift apart the moment one is tuned. Lend the camera the
scanner you already have and there is only ever one:

```dart
final scanner = await WxScanner.create(detectModel: detect, srModel: sr);

final controller = WxScanController(scanner: scanner);
await controller.initialize();          // no weights: it uses the lent one

final fromLibrary = await scanner.scanImage(bytes);   // the same scanner
```

The camera takes its own reference to a lent scanner and gives it back when it
closes, so the two sides can be disposed in either order — the scanner goes
when the last of them lets go. The handle they pass is a number the native
library looks up in a table of its own rather than an address, so even a stale
one, which is what a hot restart leaves behind, is refused rather than
followed.

On the web this changes nothing: the scanner there is a worker reached by
message, and there was no second copy to avoid.

## The browser

`getUserMedia` opens the camera, a `<video>` plays it, and each frame is read
through a canvas and sent to the scanner, which runs in a worker so that
decoding does not block the page. Every method is the same as on a phone; what
differs:

- The preview is a platform view rather than a texture, so compose it with
  [`WxScanPreview`](lib/src/preview.dart) instead of `Texture`. It is the same
  widget on every platform and stands in for `Texture` exactly — upright in the
  device's natural orientation, rotated and sized by whatever holds it.
- Frames cross into Dart here, where natively they never do. A 1080p frame
  costs a canvas read and a transfer to the worker, which is why the scan rate
  on the web follows the frame size closely.
- Torch and zoom are `MediaStreamTrack` constraints. Browsers support them
  unevenly, so `hasTorch` and `zoomRange` report what the track actually
  claims — usually nothing on a desktop.
- A `<video>` that leaves the page is paused by the browser, and stays paused
  when it is put back. That is the HTML rule for a media element removed from a
  document, and Chromium applies it while WebKit does not — which is why a
  preview that froze on its first frame in Chrome on both a desktop and Android
  was fine in Safari. Anything that moves the preview element between hosts has
  to `play()` it again after attaching, and must never park it in a host that a
  platform view has already taken out of the page. Both are handled in
  [`platform_web.dart`](lib/src/web/platform_web.dart); the note is here
  because from the outside it presents as a camera that opened and delivered
  one frame, with a live track, an element in the page, and nothing in the
  console.
- The four files `wxscan` needs on the web have to be served by the
  application: `dart run wxscan:fetch_web` places them, fetching the compiled
  ones from the releases that package pins. Nothing has to be built —
  [wxscan's README](../wxscan/README.md#building-the-scanner-yourself)
  covers building them yourself, and why they are not shipped compiled. They go
  in `web/wxscan/`, where they are found without configuration.

## Platforms

| Platform | Camera |
|---|---|
| Android | CameraX, API 24+ |
| iOS | AVFoundation, 13.0+ |
| macOS | AVFoundation, 10.15+ |
| Web | `getUserMedia`; see [The browser](#the-browser) |

Flutter 3.38.1 or newer, which is where the build hook that produces the native
library first works.

**On Android, use 3.44 or newer.** Engines up to 3.41 gate viewport metrics
behind a flag that stops them reaching Dart on a resize. A rotation is a resize,
so Dart stays on the previous orientation for good, and the part of the window
the old layout no longer fills shows through as blank — a white screen after
turning the phone. Nothing this package does can reach that: the metrics are
correct inside `FlutterView` and never leave the engine. The fix is
[flutter/flutter#182326](https://github.com/flutter/flutter/pull/182326),
released in 3.44.0. It is left out of the pubspec constraint because everything
but rotation works below it, and an iOS-only application should not be held back
by an Android engine bug.

## The native library

Nothing native is built here. The scanner comes from
[`wxscan`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan), whose build hook produces
it as a Dart code asset. This package depends on that one, so an application
using either gets exactly one copy.

The Swift and Kotlin code calls the scanner's C ABI directly, because camera
frames never pass through Dart. A code asset is loaded by the Dart runtime
rather than linked by Xcode or Gradle, so those entry points are resolved at run
time: on Android Flutter puts the asset in the APK's `lib/<abi>/`, where
`System.loadLibrary` already looks, and on iOS and macOS `WxScanNative.swift`
opens the bundled framework and reads the symbols with `dlsym`.

## Licence

Apache-2.0. The Rust sources are in
[wxscan-rs](https://github.com/wilinz/wxscan-rs).
