# wxscan

QR scanning for Flutter, backed by a Rust port of the wechat_qrcode algorithm
(CNN detection, super resolution, decoding). No OpenCV.

Using it in an application:

```sh
flutter pub add wxscan          # live camera scanning
flutter pub add wxscan_core     # decoding images, no camera
```

Each package's README has a quick start, weights included:
[wxscan](packages/wxscan/README.md), [wxscan_core](packages/wxscan_core/README.md).
The rest of this file is about the repository itself.

## Packages

| Package | What it is |
|---|---|
| [`packages/wxscan`](packages/wxscan) | Live scanning. Camera frames go from CameraX or AVFoundation straight into the scanner without passing through Dart; the preview is a Flutter texture. |
| [`packages/wxscan_core`](packages/wxscan_core) | The decoding core. A C ABI that Dart opens through FFI for images and pixel buffers. A plain Dart package: its build hook builds and bundles the native library, so it works under `dart run` and `dart test` too. |
| [`packages/wxscan/example`](packages/wxscan/example) | Demo app: live scanning, decoding from the photo library, and picking among several codes in one frame. |

The Rust side lives in a separate repository,
[`wxscan-rs`](https://github.com/wilinz/wxscan-rs), which is expected next to
this one during development:

```
Documents/
├── wxscan/       this repository
└── wxscan-rs/    cvlite, wxing, wxscan, wxscan-ffi
```

## How the native library is built

One place builds it: the [build hook](https://dart.dev/tools/hooks) in
`packages/wxscan_core`. `hook/build.dart` downloads the TFLite C library,
builds the Rust crate in `rust/`, and declares both as code assets, which
Flutter bundles into the application. There is no podspec, no Gradle and no
CMake building native code anywhere in this repository, and `dart test` runs the
scanner without Flutter at all.

`wxscan` calls the same library from Swift and Kotlin, since camera frames never
pass through Dart. A code asset is loaded by the Dart runtime rather than linked
by Xcode or Gradle, so the plugin reaches it at run time instead:

| Platform | How the plugin reaches the library |
|---|---|
| Android | Flutter puts code assets in the APK's `lib/<abi>/`, which is where `System.loadLibrary` already looks, so `NativeScanner` finds it unchanged |
| iOS, macOS | `WxScanNative.swift` opens the bundled framework and resolves the entry points with `dlsym` |

So an application carries one copy of the scanner and one of TFLite, however
many of the two packages it uses.

Versions and checksums are in `packages/wxscan_core/tool/tflite.lock`. To
upgrade, run
`packages/wxscan_core/tool/update_tflite_lock.sh <litert-version> <desktop-version>`,
which re-downloads each artifact and rewrites the checksums. Editing that file
is the only way to point at a different build: the hook runner scrubs the
environment, so the overrides the old shell scripts read there no longer reach
anything.

32-bit x86 Android is not supported: LiteRT publishes no build for it. An
application that targets it must exclude that ABI.

## Building the demo

```sh
cd packages/wxscan/example
flutter run              # -d macos, an attached device, ...
```

The first build compiles the Rust sources and downloads the native library, so
it takes a few minutes; later builds are incremental.

## Without the models

The models are what the CNN stages need, and everything degrades rather than
fails without them: decoding still works, but small or distant symbols are
detected far less reliably. The same is true when a model fails to load, which
is reported through `modelsLoaded` rather than as an error.
