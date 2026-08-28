# Weights

`detect.tflite` (the CNN detector) and `sr.tflite` (super resolution) belong in
this directory. They are in the repository, but **not in the package published
to pub.dev** — 1.1 MB of an example's weights is 1.1 MB every `pub get` of
`wxscan_live` pays for, and the weights are not part of the library either way.

`model-version.txt` sits beside them and records what each one should be. The
application copies the weights out of the bundle into its sandbox and opens
them by path from then on, and that file is how it knows the copy is still the
right one — replace a weight and its size there has to move with it, or the old
copy goes on being used. See `lib/model_files_io.dart`.

Without them the example still runs. Decoding falls back to plain image
processing, which reads ordinary codes and misses small or distant ones; the
home screen says as much, and points here.

To get them:

```sh
curl -L -O https://github.com/wilinz/wxscan-weights/raw/main/models/detect.tflite
curl -L -O https://github.com/wilinz/wxscan-weights/raw/main/models/sr.tflite
```

Or clone [wilinz/wxscan-weights](https://github.com/wilinz/wxscan-weights),
which also holds `tools/convert.py` — the scripts that regenerate them from the
published Caffe models.
