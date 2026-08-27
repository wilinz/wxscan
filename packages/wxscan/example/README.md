# wxscan_example

Demo for the [`wxscan`](../) plugin and
[`wxscan_core`](../../wxscan_core).

It covers the three paths the packages provide:

- **Live scanning** — the camera preview with detected codes marked, torch and
  zoom control, and a resolution switch.
- **Several codes in one frame** — the picture freezes and the codes become
  tappable, the way a phone camera app does it.
- **Decoding from the photo library** — the same scanner applied to a still
  image, through `wxscan_core` rather than the camera path.

On startup it runs two self-tests against a bundled sample image, one through
the FFI bindings and one through the native camera path, and logs the results.
That is the quickest way to tell on a device whether the library, the models and
the platform binding are all wired up.

## Running

```sh
flutter run              # -d macos, an attached device, ...
```

The first build compiles the Rust sources and downloads the TFLite library, so
it takes a few minutes; later builds are incremental.

The TFLite models are in `assets/models/`, converted from the published Caffe
weights by `tools/model_conversion` in
[wxscan-rs](https://github.com/wilinz/wxscan-rs).
