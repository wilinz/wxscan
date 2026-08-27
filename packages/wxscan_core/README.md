# wxscan_core

QR decoding for Flutter, backed by a Rust port of the `wechat_qrcode` algorithm:
CNN-based detection, super resolution, and decoding.

This package decodes images and raw pixel buffers. It does not open a camera —
for live scanning use [`wxscan`](https://pub.dev/packages/wxscan), which drives
the camera natively and builds the same Rust crate for its own link step.

It is a plain Dart package, not a Flutter plugin: the native library is built
and bundled by a [build hook](https://dart.dev/tools/hooks), so it works under
`dart run` and `dart test` as well as in a Flutter application, and there are no
platform build files to maintain.

## Quick start

```sh
flutter pub add wxscan_core     # or `dart pub add wxscan_core` outside Flutter
```

The CNN weights are not bundled with the package. Download `detect.tflite` and
`sr.tflite` from
[wxscan-weights](https://github.com/wilinz/wxscan-weights), put them in
`assets/models/`, and declare the folder in `pubspec.yaml`:

```yaml
flutter:
  assets:
    - assets/models/
```

```dart
import 'package:flutter/services.dart' show rootBundle;
import 'package:wxscan_core/wxscan_core.dart';

Future<Uint8List> _asset(String path) async {
  final data = await rootBundle.load(path);
  // The offset and length are not optional: a bundled asset can be a view into
  // a larger buffer, and `asUint8List()` with no arguments reads past it.
  return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
}

final scanner = await WxScanner.create(
  detectModel: await _asset('assets/models/detect.tflite'),
  srModel: await _asset('assets/models/sr.tflite'),
);

// `gray` is 8-bit grayscale, one byte per pixel, row after row.
final outcome = await scanner.scanGray(gray, width, height);
for (final r in outcome.results) {
  print('${r.text} (v${r.version}/${r.ecLevel}/${r.charset})');
}

scanner.dispose();
```

Both weights are optional. Leaving them out decodes without the CNN stages,
which still reads ordinary codes — see [Models](#models).

## Working with a scanner

Creating a scanner is expensive, since it builds a TFLite interpreter, so keep
one for as long as you are scanning. One instance decodes one image at a time;
concurrent calls are serialized natively, and several instances scan in
parallel.

The asynchronous methods run in a background isolate, so a large image does not
block the UI. `scanGraySync` and `scanFrameSync` are for callers already off the
main isolate. Dropping a scanner without `dispose()` still releases it, but only
when the garbage collector gets to it, which keeps the models in memory
meanwhile.

For camera frames, `scanFrame` takes a row stride, a rotation, and a `mirror`
flag that mirrors the returned x coordinates. The frame itself is never
mirrored, because the detector is trained on unmirrored input; the flag exists
so coordinates line up with a preview displayed mirrored.

## Results

Coordinates are `ScanPoint`, not `dart:ui`'s `Offset`: this package is plain
Dart and cannot depend on Flutter. The field names match, so a Flutter caller
writes `Offset(p.dx, p.dy)`.

`ScanResult` carries both `text` and `bytes`. QR content is not required to be
text, so `bytes` is authoritative; `text` is it decoded according to `charset`,
which the decoder reports as `UTF-8` or `GB2312` without converting.

`ScanOutcome.candidates` holds what the detector found. Candidates without
results — `hasUndecodable` — mean a symbol was located but could not be decoded,
usually because it is too small or too blurred. Zooming in is a better response
than reporting a failure.

## Models

The TFLite weights are not bundled; pass them in as bytes, typically from an
asset. Passing null for both selects the mode without models, and a model that
fails to load falls back to that mode rather than throwing. Decoding still works
there; what it loses is the detection rate on small or distant symbols, which is
what the CNN stages contribute. `hasModels` reports which mode is active.

## The build hook

`hook/build.dart` does everything the platform build systems used to: it
downloads the TFLite C library, builds the Rust crate in `rust/`, and declares
both as code assets. The Dart tooling then places them together and rewrites the
dependency between them, so nothing has to arrange an rpath.

CNN inference uses the TFLite C library, which is downloaded at build time
rather than shipped here. Every artifact is pinned by version and SHA-256 in
`tool/tflite.lock`; a mismatch fails the build. To upgrade, run
`tool/update_tflite_lock.sh <litert-version> <desktop-version>`, which
re-downloads each artifact and rewrites the checksums. Editing that file is the
only way to point at a different build: the hook runner scrubs the environment,
so nothing there is consulted.

| Platform | Source |
|---|---|
| Android | Google Maven, `com.google.ai.edge.litert:litert` |
| iOS | the release channel the TensorFlowLiteC pod serves — a static framework, so it is linked into the Rust library rather than bundled beside it |
| macOS, Linux, Windows | prebuilt release; there is no official desktop distribution, so the repository is named in `tflite.lock` |

Downloads are cached in the hook's shared output directory, so only the first
build pays for them. That build also compiles the Rust sources, which takes a
few minutes; later builds are incremental.

## The browser

The web build is the same algorithm and the same weights, compiled to
WebAssembly, running in a worker so that decoding a frame does not block the
page. `WxScanner` is the same class with the same methods; what differs:

- `scanGraySync` and the other `*Sync` methods throw `UnsupportedError`. The
  engine answers by message from a worker, so there is nothing to return in the
  same call.
- Four files have to be served by the application. They ship inside this
  package, and one command copies them out:

  ```sh
  dart run wxscan_core:fetch_web        # into web/wxscan
  ```

  Nothing else needs configuring, since that is where the package looks. For
  another directory, pass `--into` and say where with `configureWxScanWeb` from
  `package:wxscan_core/web.dart`.

  They are files rather than declared assets because declaring Flutter assets
  would make this a Flutter package, and `dart run` and `dart test` would stop
  working. `crates/wxscan-wasm` and `tools/tflite-wasm` in
  [wxscan-rs](https://github.com/wilinz/wxscan-rs) build the three WebAssembly
  ones; `--from` takes them from such a build instead of from here.

Inference is TensorFlow Lite with the XNNPACK delegate, the same runtime the
other platforms use, so a browser reads the same `.tflite` files. A 1080p frame
takes about 220 ms against a native 135 ms, of which inference is 8 ms; the
rest is the decoder, in the same proportion as native.

The four files come to 1.8 MB, 660 KB over the wire compressed — the scanner
462 KB and the runtime 1.3 MB, the latter carrying only the sixteen operators
these two models use rather than the 150 a stock build registers.

## Platforms

| Platform | Notes |
|---|---|
| Android | arm64-v8a, armeabi-v7a, x86_64. LiteRT publishes no 32-bit x86 build, so an application targeting that ABI must exclude it. |
| iOS | 13.0+ |
| macOS | 10.15+, arm64 |
| Linux, Windows | x86_64 (Linux also arm64) |
| Dart (no Flutter) | macOS, Linux, Windows — `dart run` and `dart test` build and load the library through the hook |
| Web | WebAssembly in a worker; see [The browser](#the-browser) |

## Licence

Apache-2.0. The Rust sources are in
[wxscan-rs](https://github.com/wilinz/wxscan-rs).
