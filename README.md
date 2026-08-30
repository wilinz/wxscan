# wxscan

**English** · [简体中文](README.zh-CN.md)

QR scanning for Flutter that reads the codes other scanners give up on: the
`wechat_qrcode` algorithm — CNN detection and super resolution, not just a
decoder — ported to Rust. No OpenCV, and no native build files to maintain.

<img src="https://raw.githubusercontent.com/wilinz/wxscan/main/docs/demo.webp" width="300"
     alt="Two QR codes in one camera frame, each marked; tapping one opens its decoded
     text, a Chinese payload read as UTF-8.">

*Two codes in one frame, one of them turned, read off a laptop screen — then
the one that was tapped. The page being scanned is
[`tool/qr_bench.html`](tool/qr_bench.html).*

```sh
flutter pub add wxscan wxscan_live
```

`wxscan` decodes images and pixel buffers and opens no camera; `wxscan_live` is
the live camera on top of it. Either can be added on its own.

Or from git, which takes whatever the default branch holds — add a `ref` to hold
it to a tag or a commit:

```yaml
dependencies:
  # Decoding images and pixel buffers, no camera.
  wxscan:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan

  # Live camera scanning, on top of it.
  wxscan_live:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan_live
```

**What you need**

| | Version |
|---|---|
| Dart | 3.10 or newer |
| Flutter | 3.38.1 or newer — on Android, 3.44, [for a rotation bug](packages/wxscan_live/README.md#platforms) |
| Rust | rustup on `PATH`; the compiler itself is pinned and installed on the first build |

Nothing else. The build hook compiles the Rust and fetches the TFLite library,
reading `rust-toolchain.toml` for the version (1.95.0) and the targets, so
rustup installs both the first time it runs. No Xcode project, no Gradle, no
CMake, and no Android NDK beyond what Flutter already installs.

Then follow the quick start in [wxscan](packages/wxscan/README.md#quick-start)
or [wxscan_live](packages/wxscan_live/README.md#quick-start) — install, weights,
permissions and a first scan on one screen. The rest of this file is about the
repository.

**[Live demo](https://wilinz.github.io/wxscan/)** — the example application in a
browser, running the same Rust scanner compiled to WebAssembly. Live scanning or
a picture from your library, decoded entirely on your machine: nothing leaves
the page, and the camera is asked for only if you go looking for it.

The packages give you the camera image and the result of each frame. The screen
around them — viewfinder, the corners drawn over each code, picking among
several at once — is
[`packages/wxscan_live/example`](packages/wxscan_live/example/lib/scan_page.dart),
which is there to be read and copied.

## Using it

Both need the CNN weights, which are not bundled — download `detect.tflite` and
`sr.tflite` from [wxscan-weights](https://github.com/wilinz/wxscan-weights) and
declare the folder that holds them. Without them decoding still works; what it
loses is the detection rate on small and distant symbols.

**Decode a picture.** `scanPath` reads and decodes the file natively, so a 12
megapixel photograph never becomes 48 MB of RGBA in Dart:

`detectBytes` and `srBytes` below are those two files' bytes; both quick starts
show loading them from assets, offsets and all.

```dart
import 'package:wxscan/wxscan.dart';

final scanner = await WxScanner.create(
  detectModel: detectBytes,
  srModel: srBytes,
);

try {
  final outcome = await scanner.scanPath('/path/to/photo.jpg');
  for (final r in outcome.results) print(r.text);
} on PictureUnreadable {
  // Not a picture, or a format this build cannot decode — HEIC wants the
  // platform's own decoder and `scanPixels`. Different from a picture with
  // no code in it, which comes back as an empty outcome.
}
```

→ [which method to call](packages/wxscan/README.md#which-method-to-call) ·
[the HEIC fallback](packages/wxscan/README.md#which-pictures-decode) ·
[tuning detection](packages/wxscan/README.md#tuning-detection) ·
[working with a scanner](packages/wxscan/README.md#working-with-a-scanner)

**Scan with the camera.** Camera permission has to be granted before
`initialize`; the plugin does not ask for it.

```dart
import 'package:wxscan_live/wxscan_live.dart';

final controller = WxScanController(resolution: WxResolution.p720);
await controller.initialize(detectModel: detectBytes, srModel: srBytes);

controller.scans.listen((outcome) {
  for (final r in outcome.results) print(r.text);
});

// The preview is `WxScanPreview(controller: controller)` — a texture natively,
// a platform view in a browser — turned and fitted by whatever holds it. The
// controller is a `ValueNotifier`, so it redraws on rotation by itself.

// Scanning a picture too? Lend the camera the scanner you already have, and
// the CNN weights are held once rather than twice:
// WxScanController(scanner: scanner)
```

→ [permissions and a full first screen](packages/wxscan_live/README.md#quick-start) ·
[camera control](packages/wxscan_live/README.md#camera-control) ·
[tap to focus](packages/wxscan_live/README.md#focus) ·
[best practices](packages/wxscan_live/README.md#best-practices)

**Where the rest lives**

| Question | Answer |
|---|---|
| What comes back from a frame | [Results](packages/wxscan/README.md#results) · [live results](packages/wxscan_live/README.md#results) |
| What the weights do, and life without them | [Models](packages/wxscan/README.md#models) |
| Serving it in a browser | [wxscan](packages/wxscan/README.md#the-browser) · [building the scanner](packages/wxscan/README.md#building-the-scanner-yourself) · [wxscan_live](packages/wxscan_live/README.md#the-browser) |
| How the native library is built and found | [the build hook](packages/wxscan/README.md#the-build-hook) · [the native library](packages/wxscan_live/README.md#the-native-library) |
| A whole scanning screen to read or copy | [`example/lib/scan_page.dart`](packages/wxscan_live/example/lib/scan_page.dart) |

## Why this one

**It sees small and distant codes.** A neural network locates candidate symbols
in the frame and a second one upscales each crop before decoding. That is the
difference between a scanner that needs the code held up to the lens and one
that reads it across a room, and it is what WeChat's own scanner does.

**Camera frames never enter Dart.** CameraX and AVFoundation hand each frame
straight to the Rust scanner, and the preview is a Flutter texture over that
same buffer. What crosses into Dart is the result — some text and four corners —
so no per-frame copy lands on the UI isolate.

**Several codes at once.** Every symbol in the frame comes back with its corners
in preview coordinates, already corrected for rotation and mirroring, ready to
draw over. Symbols that were seen but could not be read are reported too, which
is the cue to zoom rather than to say "no code found".

**Nothing native to maintain.** No podspec, no Gradle, no CMake. A Dart
[build hook](https://dart.dev/tools/hooks) compiles the Rust and fetches the
TFLite library, so `dart test` runs the scanner with no Flutter involved at all.

## Packages

| Package | What it is |
|---|---|
| [`packages/wxscan`](packages/wxscan) | The scanner. A C ABI that Dart opens through FFI for images and pixel buffers. A plain Dart package: its build hook builds and bundles the native library, so it works under `dart run` and `dart test` too. |
| [`packages/wxscan_live`](packages/wxscan_live) | The camera in front of it. Frames go from CameraX or AVFoundation straight into the scanner without passing through Dart; the preview is a Flutter texture. |
| [`packages/wxscan_live/example`](packages/wxscan_live/example) | Demo app: live scanning, decoding from the photo library, and picking among several codes in one frame. |

## Platforms

| | Decoding (`wxscan`) | Live scanning (`wxscan_live`) |
|---|---|---|
| Android | arm64-v8a, armeabi-v7a, x86_64 | CameraX, API 24+ |
| iOS | 13.0+ | AVFoundation, 13.0+ |
| macOS | 10.15+, arm64 and x86_64 | AVFoundation, 10.15+ |
| Linux, Windows | x86_64, and arm64 on Linux | — |
| Web | WebAssembly in a worker; the scanner module is [built, not bundled](packages/wxscan/README.md#building-the-scanner-yourself) | `getUserMedia`, preview as a platform view |
| Dart, no Flutter | `dart run` and `dart test` | — |

32-bit x86 Android is not supported: LiteRT publishes no build for it, so an
application targeting that ABI has to exclude it.

## The weights

The two CNN weight files are not bundled in any package. They are in
[wxscan-weights](https://github.com/wilinz/wxscan-weights), together with the
scripts that rebuild them from the Caffe models WeChat publishes — and a
reproduction check, so they can be verified rather than trusted.

Without them the pipeline degrades instead of failing: decoding still works, and
what it loses is the detection rate on small or distant symbols. The same is
true of a file that fails to load, which is reported through `modelsLoaded`
rather than thrown.

## How it fits together

The Rust sources are in [`wxscan-rs`](https://github.com/wilinz/wxscan-rs),
expected next to this repository during development:

```
Documents/
├── wxscan/       this repository — the Dart and platform side
└── wxscan-rs/    cvlite, wxing, wxscan, wxscan-ffi — the algorithm
```

One place builds the native library: `hook/build.dart` in `packages/wxscan`
compiles the Rust crate in `rust/`, downloads the TFLite C library, and declares
both as code assets for Flutter to bundle. `wxscan_live` then calls that same
library from Swift and Kotlin, resolving its entry points at run time — on
Android from
`lib/<abi>/` where `System.loadLibrary` already looks, on Apple platforms with
`dlsym`. So an application carries one copy of the scanner and one of TFLite
however many of the two packages it uses. The details, including how to move the
TFLite version, are in
[wxscan's README](packages/wxscan/README.md#the-build-hook).

## Building the demo

```sh
cd packages/wxscan_live/example
flutter run              # -d macos, an attached device, ...
```

The first build compiles the Rust sources and downloads the native library, so
it takes a few minutes; later builds are incremental.

## Licence

Apache-2.0, as is the upstream implementation this is ported from.
