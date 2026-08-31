# wxscan example

[`main.dart`](main.dart) scans image files from the command line and prints
every QR code it decodes, with the version, error correction level, charset and
corner coordinates.

```sh
dart run example/main.dart test/data/code.png
```

The CNN weights are optional and are not bundled with the package. Without them
the detector falls back to image processing, which reads clean pictures but
fewer awkward ones. Download `detect.tflite` and `sr.tflite` from
[wxscan-weights](https://github.com/wilinz/wxscan-weights) and point the example
at the folder holding them:

```sh
dart run example/main.dart --models=assets/models photo.jpg
```

In Flutter the weights are assets rather than files, so there is no path to
open: load them with `rootBundle` and pass the bytes to `WxScanner.create` as
`detectModel` and `srModel`. See the [README](../README.md) for that form.
