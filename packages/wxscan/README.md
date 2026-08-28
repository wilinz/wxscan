# wxscan

**English** · [简体中文](README.zh-CN.md)

QR decoding for Flutter, backed by a Rust port of the `wechat_qrcode` algorithm:
CNN-based detection, super resolution, and decoding.

This package decodes images and raw pixel buffers. It does not open a camera —
for live scanning use
[`wxscan_live`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan_live), which drives the camera
natively and calls this package's native library from Swift and Kotlin.

It is a plain Dart package, not a Flutter plugin: the native library is built
and bundled by a [build hook](https://dart.dev/tools/hooks), so it works under
`dart run` and `dart test` as well as in a Flutter application, and there are no
platform build files to maintain.

## Quick start

Not on pub.dev yet. Both forms are written out, so that the day it is
published the switch is one line — and either works from Flutter and from plain
Dart alike:

```yaml
dependencies:
  wxscan:
    git:
      url: https://github.com/wilinz/wxscan.git
      path: packages/wxscan
  # wxscan: ^0.1.0        # from pub.dev, once published
```

The git form follows the default branch; add a `ref` to pin a tag or a commit.

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
import 'package:wxscan/wxscan.dart';

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

final outcome = await scanner.scanPath('/path/to/photo.jpg');
for (final r in outcome.results) {
  print('${r.text} (v${r.version}/${r.ecLevel}/${r.charset})');
}

scanner.dispose();
```

Both weights are optional. Leaving them out decodes without the CNN stages,
which still reads ordinary codes — see [Models](#models).

## Which method to call

Four ways in, differing only in what you already hold. None of them converts
pixels in Dart.

| You have | Call | Notes |
|---|---|---|
| A file on disk | `scanPath` | Reads and decodes natively; nothing is materialised in Dart |
| An encoded picture in memory | `scanImage` | The file's bytes — a picked image, a download, an asset |
| Decoded pixels | `scanPixels` | RGB, RGBA, BGR or BGRA, tightly packed |
| Grayscale | `scanGray` | One byte per pixel, rows packed |
| A camera frame | `scanFrame` | Adds a row stride, a rotation and `mirror` |

**Prefer `scanPath` or `scanImage` over decoding yourself.** A 12 megapixel
photograph is 48 MB as RGBA; decoding it in Dart copies that into the worker
isolate and again into native memory, and none of those copies buys anything.
`scanImage` is the one to reach for in a browser, which has no paths at all.

```dart
try {
  final outcome = await scanner.scanPath(file.path);
  if (outcome.results.isEmpty) {
    // A picture with no code in it. Say so — and if `outcome.candidates` is
    // not empty, a symbol *was* found and could not be read, which is worth
    // saying differently.
  }
} on PictureUnreadable catch (e) {
  // Not a picture, or not one this build decodes. Different from the above,
  // and the reader wants to be told something different.
}
```

That distinction is the point of the exception. A file nothing could open used
to be indistinguishable from a picture with no code in it, and the two call for
different things to be said.

### Which pictures decode

PNG, JPEG, GIF, WebP, BMP, TIFF and HEIC on every platform this package
supports. AVIF on Apple and in a browser. RAW, JPEG XL and another fifty on
Apple.

The rule behind that: a decoder is either carried here, at a cost in size, or
borrowed from the platform, at no cost at all. **Apple lends** 62 formats
through ImageIO, RAW included, since every application links it already.
**Nowhere else lends anything usable** — Android's HEIC decoder is API 30 and
ignores the orientation tag, Linux has none, Windows has one only if the user
installed it — so those three carry their own. **A browser decodes its own
pictures**, which is why the web build carries no decoders whatsoever.

**[doc/image_formats.md](doc/image_formats.md)** has the full matrix, what each
platform borrows and why, and how to lend one of your own.

For a format nothing here reads, decode it with the platform's own API and pass
the pixels to `scanPixels`:

```dart
Future<ScanOutcome> scanAnyPicture(WxScanner scanner, String path) async {
  try {
    return await scanner.scanPath(path);
  } on PictureUnreadable {
    // Flutter's own decoder, which reads whatever the device can display.
    final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
    final image = (await codec.getNextFrame()).image;
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      // Awaited inside the try, so `finally` does not dispose the image
      // out from under the scan.
      return await scanner.scanPixels(
        data!.buffer.asUint8List(),
        image.width,
        image.height,
        format: WxPixelFormat.rgba,
      );
    } finally {
      image.dispose();
      codec.dispose();
    }
  }
}
```

Worth far less than it used to be: the formats this reaches that the scanner
does not are now the unusual ones — a JPEG XL, a RAW file on a platform other
than Apple.

## Working with a scanner

Creating a scanner is expensive, since it builds a TFLite interpreter, so keep
one for as long as you are scanning. One instance decodes one image at a time;
concurrent calls are serialized natively, and several instances scan in
parallel.

The asynchronous methods run in a background isolate, so a large image does not
block the UI. `scanGraySync` and `scanFrameSync` are for callers already off the
main isolate. Dropping a scanner without `dispose()` still releases it, but only
when the garbage collector gets to it, which keeps the models in memory
meanwhile — a debug build says so in the log when it happens.

For a scanner that is wanted once rather than kept, `WxScanner.use` creates one,
hands it to a callback and disposes it however that ends:

```dart
final outcome = await WxScanner.use((scanner) => scanner.scanImage(bytes));
```

`WxScanner.liveCount` reports how many scanners exist in the process. It is a
diagnostic, for finding one that was never disposed: a test can assert it is
back to zero, and a screen that opens and closes can be watched across a few
passes to see whether it climbs. It counts scanners rather than holders, so one
lent to `wxscan_live` still counts once.

For camera frames, `scanFrame` takes a row stride, a rotation, and a `mirror`
flag that mirrors the returned x coordinates. The frame itself is never
mirrored, because the detector is trained on unmirrored input; the flag exists
so coordinates line up with a preview displayed mirrored.

Mismatched dimensions raise `ArgumentError` rather than returning an empty
result. A buffer that does not match its width and height is a mistake in the
call, and an empty outcome would hide it as a frame with nothing in it.

A scanner can also be lent to
[`wxscan_live`](https://github.com/wilinz/wxscan/tree/main/packages/wxscan_live) — `WxScanController(scanner:
scanner)` — so an application that scans both live and from the photo library
holds one scanner rather than two, with one copy of the weights in memory. The
controller borrows it and never disposes it.

### Tuning detection

`confidenceThreshold`, `nmsThreshold` and `scaleFactor` read and write on the
scanner without contending for its lock, so they can be changed between frames.
The defaults are the ones the upstream algorithm ships and are the right place
to start; lowering `confidenceThreshold` finds fainter symbols at the cost of
more candidates that decode to nothing, which `hasUndecodable` then reports.

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
- Four files have to be served by the application. One ships inside this
  package; the other three are fetched from the releases pinned in
  `tool/web.lock`, checked against the checksums there and cached between
  runs. One command places all four, and nothing has to be built:

  ```sh
  dart run wxscan:fetch_web
  ```

  `web/wxscan` is where they go and where the package looks, so nothing else
  needs configuring. For another directory, pass `--into` and say where with
  `configureWxScanWeb` from `package:wxscan/web.dart`.

  They are files rather than declared assets because declaring Flutter assets
  would make this a Flutter package, and `dart run` and `dart test` would stop
  working.

### Building the scanner yourself

`wxscan_wasm.wasm` is not bundled, and neither is the TensorFlow Lite runtime
beside it. A compiled artifact committed next to the sources it came from goes
out of step with them — this one did, and the live demo served a fixed detector
bug for a while because rebuilding it was a step someone had to remember. So
both are built by CI in wxscan-rs and fetched from its releases, and `fetch_web`
on its own is all an application needs.

Build it yourself to try a change to the Rust without waiting for a release:

```sh
git clone https://github.com/wilinz/wxscan-rs
git clone https://github.com/wilinz/cvlite
git clone https://github.com/wilinz/wxing
cd wxscan-rs
printf '[patch.crates-io]\ncvlite = { path = "../cvlite" }\nwxing = { path = "../wxing" }\n' \
  > .cargo/config.toml
RUSTFLAGS="-C target-feature=+simd128" cargo build -p wxscan-wasm \
  --target wasm32-unknown-unknown --profile wasm
```

Then `--from wxscan-rs/target/wasm32-unknown-unknown/wasm`. Whatever that
directory holds is taken from it and the rest still comes from the releases, so
building only the scanner — the usual case — needs nothing else.

The TensorFlow Lite runtime is an emsdk and a quarter of an hour, and it has a
release of its own under a `tflite-` tag, which many versions of the scanner
point at because it moves only when the pinned TFLite version does.
`tool/check_tflite_web.sh` fails if it has been left behind when that
happened.

**[doc/web_build.md](doc/web_build.md)** is the whole of it: what each of the
four files is, upgrading the runtime, and what CI does differently and why.

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
