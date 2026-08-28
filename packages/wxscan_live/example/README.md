# wxscan_example

**English** · [简体中文](README.zh-CN.md)

Demo for the [`wxscan`](../) plugin and
[`wxscan`](../../wxscan).

<img src="https://raw.githubusercontent.com/wilinz/wxscan/main/docs/demo.webp" width="300"
     alt="Two QR codes in one camera frame, each marked; tapping one opens its decoded
     text, a Chinese payload read as UTF-8.">

*This application, on a phone: two codes in one frame, one of them turned, and
the result for the marker that was tapped.*

It covers the three paths the packages provide:

- **Live scanning** — the camera preview with detected codes marked, torch and
  zoom control, and a resolution switch.
- **Several codes in one frame** — the picture freezes and the codes become
  tappable, the way a phone camera app does it.
- **Decoding from the photo library** — the same scanner applied to a still
  image, through `wxscan` rather than the camera path.

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

The TFLite models go in `assets/models/`. This checkout has them; the package
published to pub.dev does not, because 1.1 MB of an example's weights is 1.1 MB
every `pub get` of `wxscan_live` pays for. A copy without them still builds and
runs, on plain image processing, and the home screen says so and points at
[`assets/models/README.md`](assets/models/README.md) for where to get them:
[wilinz/wxscan-weights](https://github.com/wilinz/wxscan-weights), which also
holds `tools/convert.py`, the scripts that produce them from the published
Caffe models.

## Something to scan

[`tool/qr_bench.html`](../../../tool/qr_bench.html) in this repository puts two
QR codes on a white page, each with its own length, module size, error
correction and character set, both draggable and rotatable. Open it on a monitor
and point the phone at it.

Module size is the control to reach for. Walking backwards changes the distance,
the angle and the lighting at once; the slider changes how many pixels of camera
a module gets and nothing else, which is what the CNN detector is there for. Two
codes at once exercise the picker, a turned one exercises the corner
coordinates, and the inverted switch is the case the Rust port reads and the
C++ implementation does not.
