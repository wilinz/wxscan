# wxscan

QR scanning for Flutter that reads the codes other scanners give up on: the
`wechat_qrcode` algorithm — CNN detection and super resolution, not just a
decoder — ported to Rust. No OpenCV, and no native build files to maintain.

```sh
flutter pub add wxscan          # decoding images and pixel buffers, no camera
flutter pub add wxscan_live     # live camera scanning, on top of it
```

Then follow the quick start in [wxscan](packages/wxscan/README.md) or
[wxscan_live](packages/wxscan_live/README.md) — install, weights, permissions
and a first scan on one screen. The rest of this file is about the repository.

**[Live demo](https://wilinz.github.io/wxscan/)** — the example application in a
browser, running the same Rust scanner compiled to WebAssembly. Live scanning or
a picture from your library, decoded entirely on your machine: nothing leaves
the page, and the camera is asked for only if you go looking for it.

The packages give you the camera image and the result of each frame. The screen
around them — viewfinder, the corners drawn over each code, picking among
several at once — is
[`packages/wxscan_live/example`](packages/wxscan_live/example/lib/scan_page.dart),
which is there to be read and copied.

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
| macOS | 10.15+, arm64 | AVFoundation, 10.15+ |
| Linux, Windows | x86_64, and arm64 on Linux | — |
| Web | WebAssembly in a worker | `getUserMedia`, preview as a platform view |
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
