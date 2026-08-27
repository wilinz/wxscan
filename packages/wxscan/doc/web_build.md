# Building for the browser

Four files have to be served for the scanner to run in a browser. One is
written here; the other three are compiled, and none of them is committed.

| File | Where it comes from | Moves when |
|---|---|---|
| `wxscan_worker.js` | this package, hand-written | it is source, and moves with this package |
| `wxscan_wasm.wasm` | the `SCANNER_TAG` release | the Rust changes |
| `wxscan_tflite.js` | the `TFLITE_TAG` release | the pinned TensorFlow version, or the patches on top of it, move |
| `wxscan_tflite.wasm` | the `TFLITE_TAG` release | as above |

```sh
dart run wxscan:fetch_web
```

places all four in `web/wxscan`, which is where the package looks. The two
releases are pinned by tag and SHA-256 in [`tool/web.lock`](../tool/web.lock),
downloads are refused if they do not match, and what is downloaded is cached
outside the project — a second checkout on the same machine pays nothing.

`--into DIR` puts them somewhere else, `--offline` fails rather than reaching
the network, and `--from DIR` takes whatever a local build directory holds
instead.

## Why nothing here is committed

It was, and it went out of step with the Rust it came from: the live demo
served a detector bug for a while after the fix had landed, because rebuilding
the module was a step someone had to remember. Anything that has to be
remembered eventually is not.

A build hook cannot place them either. Hooks emit code assets, which are
libraries the Dart runtime loads, and a web build declares it wants none, so
the hook returns before reaching Rust; a hook also writes into its own output
directory, never into an application's `web/`. And they are plain files rather
than declared Flutter assets because declaring assets would make this a Flutter
package, and `dart run` and `dart test` would stop working.

So it is either a committed binary that can rot, or a download that cannot.

## Two releases, not one

The scanner and the runtime are pinned separately, because they move on
different rhythms:

* **The scanner** is wxscan-rs's own code. It is rebuilt on every push there,
  and takes seconds.
* **The TensorFlow Lite runtime** is a dependency. Building it is an emsdk, a
  clone of TensorFlow and about a thousand XNNPACK microkernels — ten minutes
  at best — and it changes a few times a year. Many scanner versions point at
  one runtime release rather than each carrying its own 1.3 MB copy.

`TFLITE_TAG` is `tflite-<tensorflow-version>-p<patch>`. The patch revision is
wxscan-rs's own: upstream does not build this configuration, so what comes out
of a given TensorFlow version is decided as much by the patches applied on top
of it as by the version, and those change while the version stays put. Two
runtimes that differ only in patches therefore get different tags rather than
sharing one.

## Building the scanner yourself

To try a change to the Rust without waiting for a release:

```sh
git clone https://github.com/wilinz/wxscan-rs
git clone https://github.com/wilinz/cvlite
git clone https://github.com/wilinz/wxing
cd wxscan-rs

# cvlite and wxing are not on crates.io yet. This is what wxscan-dev/link.sh
# writes for a full development checkout; two lines are enough for this.
printf '[patch.crates-io]\ncvlite = { path = "../cvlite" }\nwxing = { path = "../wxing" }\n' \
  > .cargo/config.toml

RUSTFLAGS="-C target-feature=+simd128" cargo build -p wxscan-wasm \
  --target wasm32-unknown-unknown --profile wasm
```

Then, from your application:

```sh
dart run wxscan:fetch_web --from ../wxscan-rs/target/wasm32-unknown-unknown/wasm
```

`--from` wins wherever it has the file, so this takes the scanner from your
build and the runtime from its release. `rust-toolchain.toml` in wxscan-rs pins
the compiler, so with no local change this is the same module CI publishes.
`simd128` costs nothing in correctness and takes about 28% off scanning time.

## Upgrading the TensorFlow Lite runtime

The browser's runtime has to be the same TensorFlow as every other platform's,
or a browser runs a different one against the same `.tflite` weights. In
wxscan-rs:

```sh
# 1. Raise the pin. build.sh and CI both read this file.
#    A new TensorFlow version resets patch to 1; a change to the patches or to
#    build.sh at the same version raises patch instead.
$EDITOR depversion.toml

# 2. Publish it. The tag has to match what that file says, or the run fails.
git tag tflite-v<version>-p<patch> && git push origin tflite-v<version>-p<patch>
```

Then here:

```sh
# 3. Raise the pin every other platform reads.
tool/update_tflite_lock.sh <litert-version> <desktop-version>

# 4. Re-pin the browser's two files to the new release.
tool/stamp_web.sh <scanner-tag> tflite-v<version>-p<patch>
```

[`tools/tflite-wasm`](https://github.com/wilinz/wxscan-rs/tree/main/tools/tflite-wasm)
in wxscan-rs covers what the build does: the two patches it needs, why `cmake`
is run twice, and why the first pass is expected to fail.

### The check that makes step 4 unavoidable

Skipping it leaves a browser fetching a runtime built from a different
TensorFlow, and nothing about that is visible at run time — it decodes
correctly and differs only where nobody looks. So it is checked instead:

```sh
tool/check_tflite_web.sh
```

It compares the TensorFlow version inside `TFLITE_TAG` in `tool/web.lock`
against `DESKTOP_VERSION` in `tool/tflite.lock`, and fails when they have
drifted apart. CI runs it, so the two cannot reach a release disagreeing.

The checksums are not its business: they guard the download, and `fetch_web`
refuses anything that does not match them.

## What CI does

[`.github/workflows/demo.yml`](../../../.github/workflows/demo.yml) builds the
live demo and is the worked example. It assembles the four files itself rather
than running `fetch_web`, which is worth knowing if you script this yourself:
running any Dart program builds the package's code assets first, and that is
cargo for the **host** — minutes of Rust a web build has no use for, against
path dependencies expecting sibling checkouts. On a developer's machine those
exist and the command is the right one; in a container that only wants a web
build, it is not.

It reads the same `tool/web.lock`, fetches the runtime from the same release
and checks the same checksums. The one thing it does differently is the
scanner: it builds that from the wxscan-rs sources instead of taking the
released one, so the demo follows main.
