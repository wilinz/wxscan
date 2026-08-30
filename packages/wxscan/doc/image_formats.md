# Which pictures decode, and where

`scanImage` and `scanPath` take an encoded picture — a file, not pixels — and
work out the format from the bytes. What they can read depends on the platform,
because a decoder is either carried in the library, at a cost in size, or
borrowed from the system, at no cost at all.

| Format | Apple | Android | Windows / Linux | Web |
|---|:---:|:---:|:---:|:---:|
| PNG | ✅ | ✅ | ✅ | ✅ |
| JPEG | ✅ | ✅ | ✅ | ✅ |
| GIF | ✅ | ✅ | ✅ | ✅ |
| WebP | ✅ | ✅ | ✅ | ✅ |
| BMP | ✅ | ✅ | ✅ | ◐ |
| TIFF | ✅ | ✅ | ✅ | ◐ |
| HEIC / HEIF | ✅ | ✅ | ✅ | Safari |
| AVIF | ✅ | ❌ | ❌ | ✅ |
| JPEG 2000, JPEG XL | ✅ | ❌ | ❌ | ❌ |
| RAW (CR2, NEF, ARW, RAF, …) | ✅ | ❌ | ❌ | ❌ |
| PSD, OpenEXR, DICOM, ICO | ✅ | ❌ | ❌ | ❌ |

◐ is the browser's business rather than this package's.

Anything not listed comes back as `PictureUnreadable` with
`PictureReadFailure.unsupportedFormat`, which is a different thing from a
picture with no code in it — that returns an empty `ScanOutcome`. Keeping the
two apart is the point: a file the library never read looks exactly like an
empty picture if the distinction is dropped.

For a format nothing here reads, decode it with the platform's own API and use
`scanPixels`.

## Where each column comes from

The table is what a build carries by default. Each of the seven decoded in
Rust is its own cargo feature, and an application that will never see one can
leave it out; see [Carrying fewer of them](#carrying-fewer-of-them).

**Three formats are carried everywhere.** PNG, JPEG and GIF are what a camera
and a photo picker write — iOS `image_picker` emits those three and nothing
else — and they are decoded in Rust, identically on every platform.

**Three more are carried where nothing can be borrowed.** WebP, BMP and TIFF
arrive from elsewhere rather than from a camera: WebP off the web, BMP out of a
Windows screenshot. They cost 534 KB, which is worth paying on Android, Windows
and Linux, and wasteful on Apple, where ImageIO reads all three already. So the
build hook asks for them everywhere except Apple, and nothing at the call site
has to know which platform needs them.

**Apple borrows the rest.** `CGImageSourceCopyTypeIdentifiers()` reports 62
formats, and every application links ImageIO already, so this costs a few
hundred bytes of glue. Most of the 62 are RAW: 38 camera-maker formats nobody
would carry a decoder for.

**HEIC is carried in Rust everywhere Apple is not.** Android, Windows and Linux
all have to: there is nothing borrowable on any of them. See below.

**A browser decodes its own pictures.** `createImageBitmap` reads everything
the browser can display and the wasm module carries no decoders at all — it
compiles none of `image-io`, which is why the web build stays small. HEIC works
in Safari and nowhere else, because that is where the system decoder is.

## Why HEIC is compiled in off Apple

HEIC is most of a modern photo library, and Apple is the only platform that
hands one over for free. The rest:

* **Android** has two decoders and neither is usable here. `AImageDecoder`, the
  NDK's, is **API 30** against this package's 24 — a large part of the fleet
  would silently keep the old behaviour — and it ignores the orientation a
  photograph records, where the built-in and Apple paths apply it. That last one
  is invisible at run time: the symbol still decodes, only its coordinates are
  wrong. The Java `ImageDecoder` does apply the tag and reaches back to API 28,
  but it is reached through JNI, and the decoder runs on whatever thread
  scanned — no `JNIEnv` in hand, and no `JavaVM` cached, because nothing on
  this path is entered from Java.
* **Linux** has no system image decoder at all. There is no equivalent of
  ImageIO to ask.
* **Windows** has WIC, which reads HEIF only where the user has installed the
  HEIF Image Extension from the Store. A format that works on some machines and
  not others is worse than one that works everywhere, and this is a library
  rather than an application: it cannot ask anyone to install anything.

So `heif-oxide` is compiled in on all three. It is 375 KB of the Android arm64
library — the same decoder on each — and decodes a 320x460 HEIC in about 2 ms.
Apple keeps ImageIO and does not pull it in.

The line is the same one WebP, BMP and TIFF fall on: **borrow from Apple, carry
everywhere else.** Only the web escapes both, decoding its own pictures.

**A note on licences.** The first crate tried for this was `heic`, which is
faster to say and marginally faster to run — and is AGPL-3.0-or-commercial.
Linking it would have put every application shipping wxscan under the AGPL. It
compiled, passed its tests, and nothing about it was visible at build time or
run time. `cargo deny check licenses` now runs in CI in both repositories for
exactly this reason; `deny.toml` is a whitelist, so a new licence fails rather
than passing quietly.

## AVIF, and what it is waiting for

AVIF is the HEIC container with AV1 inside instead of HEVC, which makes it look
like a small addition. It is not: it needs a second decoder, for a codec with
no usable pure-Rust implementation yet.

`oxideav-avif` (MIT) parses the container and hands the bitstream to
`oxideav-av1`, which answers:

```
Unsupported("avif: AV1 decoder unavailable —
  oxideav-av1 clean-room rebuild pending pixel-decode implementation")
```

`rav1d` and `rusty_av1d` (BSD-2-Clause, ports of dav1d) do decode, and pairing
one with `oxideav-avif`'s `obu_bytes` would work — at the cost of an AV1
decoder's size, asm that complicates cross-compiling to three Android ABIs, and
two early crates joined at a seam.

It is left undone deliberately. Apple and browsers read AVIF already, and it is
a format found on the web rather than in a camera roll, so the gap is a picture
saved from a page and then scanned on Android or a desktop. When `oxideav-av1`
implements pixel decode, adding it is a few lines in
`rust/src/heic_decoder.rs`.

## Carrying fewer of them

Every format above that is decoded in Rust is a cargo feature of its own, and
which of them a build carries is the application's to say, in its own
`pubspec.yaml`:

```yaml
hooks:
  user_defines:
    wxscan:
      image_formats: [png, jpeg]
```

The list replaces the default rather than adding to it, so this is a build that
reads a PNG and a JPEG and answers `unsupportedFormat` for everything else —
which is what an application scanning only what its own camera wrote wants, and
what the size is for. Measured on the Android arm64 library, stripped:

| `image_formats` | Size |
|---|---|
| default: all seven | 2.13 MB |
| without `heic` | 1.75 MB |
| `[png, jpeg, gif]` | 1.22 MB |
| `[]` | 866 KB |

On Apple the numbers barely move — the decoders there are ImageIO's, and the
default already carries only three — and the result does not move at all,
since the lent decoder answers for every format either way.

Nothing about the API changes: a format left out returns `PictureUnreadable`
with `unsupportedFormat`, the same as a format nothing here has ever read, and
`scanPixels` still takes whatever the application decoded itself.

## Adding a decoder from outside

The library will take a decoder a host lends it, which is how Apple's ImageIO
is reached. `wxscan_set_image_decoder` in `wxscan-ffi` takes a struct of two
function pointers:

```c
typedef struct WxScanImageDecoder {
  int32_t (*decode)(const uint8_t *data, size_t len,
                    const uint8_t **out_pixels, uint32_t *out_width,
                    uint32_t *out_height, int32_t *out_format, void *ctx);
  void (*release)(const uint8_t *pixels, void *ctx);
  void *ctx;
} WxScanImageDecoder;
```

Three things are worth knowing about it:

* **It is asked second.** The built-in decoders answer first, so lending a
  decoder cannot change how a PNG is read, and lending none leaves the previous
  behaviour exactly.
* **Ownership goes one way.** The buffer stays the host's, and `release` is
  called once per success. Neither side frees the other's memory, which is what
  makes it implementable from a garbage-collected language.
* **The orientation is the host's to apply.** System decoders do it as a matter
  of course, and this library cannot tell whether it happened.
