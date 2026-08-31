# Changelog

## 0.1.4

- **iOS simulator builds work.** Three things were wrong at once, and each hid
  the next. The hook picked the device TFLite archive for a simulator build,
  because it read Xcode's `SDKROOT` out of an environment the hook runner
  scrubs; it now takes `IOSSdk` from the build configuration, which is where
  the answer actually is. The simulator archive is universal, and rustc stops
  at `Unsupported archive identifier` on one, so it is thinned to the slice
  being built, as the macOS library already was. And `rust-toolchain.toml` was
  missing `x86_64-apple-ios`, which `flutter build ios --simulator` asks for
  alongside the arm64 slice.
- `example/` now holds a runnable command-line example, which is also what
  pub.dev shows on the package page.
- The `description` fits the 60-180 characters pub.dev asks for, and every file
  is `dart format` clean.
- `code_assets` is allowed up to 2.0.0. Its one breaking change is that `OS` and
  `Architecture` override `==`, which disqualifies them as constant patterns, so
  the build hook matches on `os.name` and `architecture.name` instead. Which
  major is actually resolved is `native_toolchain_rust`'s call, and it still asks
  for 1.x.
- The library doc pointed at `wxscan` for live scanning where it meant
  `wxscan_live`.

## 0.1.3

- Documentation only. The build configuration added in 0.1.2 is now linked
  from the places the question is actually asked: the list of formats that
  decode says it is a default rather than a fact, and the repository's map of
  where things live has a row for making the library smaller.

## 0.1.2

- The image formats the native library carries decoders for, and the cargo
  release profile it is built with, are now the application's to set, in its
  own `pubspec.yaml` under `hooks: user_defines: wxscan:`. Both were fixed
  here before, and neither is this package's business: which formats an
  application will ever be handed is something only it knows, and a decoder
  for a format it never sees is pure size — 2.13 MB of Android library becomes
  866 KB when the answer is "none of them, I scan camera frames".

  ```yaml
  hooks:
    user_defines:
      wxscan:
        image_formats: [png, jpeg]
        cargo_profile:
          strip: symbols
  ```

  `image_formats` takes any of `png`, `jpeg`, `gif`, `webp`, `bmp`, `tiff` and
  `heic`, and defaults to all of them except on Apple, where ImageIO is lent to
  the library and reads them already. A format left out answers
  `unsupportedFormat`, the same as a format nothing here ever read.
  `cargo_profile` takes `opt_level`, `lto`, `codegen_units`, `strip` and
  `panic`. Both are validated: a misspelled format or key stops the build
  rather than quietly shipping a library missing a decoder. `doc/image_formats.md`
  and the README carry the measured sizes, including what `opt_level: z` costs
  per frame, which is more than it saves.

## 0.1.1

- macOS builds for Intel as well as Apple Silicon. The `darwin_universal`
  archive the build hook pins holds both slices and the hook already thinned it
  to the one each build asked for; what stopped an x86_64 build was a check
  written when no x86_64 library existed to fetch. A macOS release build is
  universal by default, so this is what a release build wanted all along —
  `ARCHS` no longer has to be pinned to arm64 in
  `macos/Runner/Configs/Release.xcconfig`, and an application that wants one
  architecture alone still sets it.

## 0.1.0

First release.

- Decodes images and raw pixel buffers through a Rust port of the
  `wechat_qrcode` algorithm: CNN detection, super resolution and decoding, with
  no OpenCV.
- A plain Dart package rather than a Flutter plugin. `hook/build.dart` builds
  the native library and bundles it, together with the TFLite C library, as
  code assets, so `dart run` and `dart test` work as well as Flutter does and
  there are no platform build files.
- Runs in a browser too, as WebAssembly on a worker, against the same TFLite
  weights and the same runtime as every other platform. The four files an
  application serves are placed by `dart run wxscan:fetch_web`, which fetches
  the compiled three from pinned releases rather than carrying them here; see
  `doc/web_build.md`.
- Decodes pictures as well as pixels: `scanPath` for a file, `scanImage` for
  bytes already in hand — a picked image, a download, or a browser, which has
  no paths. PNG, JPEG and GIF everywhere; WebP, BMP and TIFF where the platform
  lends nothing; HEIC on Apple, Android and in Safari. `doc/image_formats.md`
  is the matrix, and the platform can be lent a decoder for the rest.
- `WxScanner.create` takes the weights as bytes or as paths —
  `detectModelPath` and `srModelPath` — and the path form is read by the native
  library on the worker isolate, so the megabyte is never held on the isolate
  that asked. Flutter assets have no path and still go as bytes; a browser has
  no filesystem and refuses a path outright.
- Scanning runs on a worker isolate owned by the scanner, so a stream costs one
  message round trip per frame rather than an isolate spawn.
- `scanPixels` takes RGB, RGBA, BGR or BGRA and converts natively, so a caller
  decoding a PNG or a JPEG does not convert pixels in Dart.
- Detection is configurable: `confidenceThreshold`, `nmsThreshold` and
  `scaleFactor` read and write without contending for the scanner's lock.
- A scanner can be lent to `wxscan_live`, so an application that scans both
  live and from the photo library holds one scanner and one copy of the
  weights. The two sides may be disposed in either order: the native handle is
  a counted reference rather than a pointer, so whichever lets go last frees
  it, and one left over from an isolate that is gone names nothing rather than
  being followed.
- `WxScanner.use` creates a scanner for one piece of work and disposes it
  however that ends, and `WxScanner.liveCount` says how many exist — enough to
  assert in a test that nothing leaked, which from the outside was previously
  invisible.
- Mismatched dimensions raise `ArgumentError` instead of returning an empty
  result that looks like a frame with nothing in it.
