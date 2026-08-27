# Building for the browser

Four files have to be served for the scanner to run in a browser. Two of them
are committed in this package, one is hand-written here, and **one you build**.

| File | Where it comes from | Rebuild when |
|---|---|---|
| `wxscan_worker.js` | this package, hand-written | never — it is source, and moves with this package |
| `wxscan_wasm.wasm` | **you build it**, from the Rust sources | every time the Rust changes |
| `wxscan_tflite.js` | committed here | the pinned TensorFlow version moves |
| `wxscan_tflite.wasm` | committed here | the pinned TensorFlow version moves |

`dart run wxscan:fetch_web --from <build output>` places all four in
`web/wxscan`, which is where the package looks. It takes from `--from`
whatever that directory holds and the rest from here, so building only the
scanner — the usual case — needs nothing else. With no `--from` it prints what
follows and exits non-zero.

The split is about cost, not principle. The scanner is seconds; the TensorFlow
runtime is an emsdk and a quarter of an hour. Something rebuilt in seconds
should never be a file someone has to remember to refresh, and something that
takes a quarter of an hour should never be a thing you must do to try a
package.

## The scanner

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

`rust-toolchain.toml` in wxscan-rs pins the compiler, so this is the same
module CI serves. `simd128` costs nothing in correctness and takes about 28%
off scanning time.

**Why it is not shipped built.** It was, and it went out of step with the Rust
it came from: the live demo served a detector bug for a while after the fix had
landed, because rebuilding it was a step someone had to remember. A build hook
cannot do it for you either — hooks emit code assets, which are libraries the
Dart runtime loads, and a web build asks for none, so the hook returns before
reaching Rust; and a hook writes into its own output directory, never into an
application's `web/`. So it is either a committed binary that can rot, or a
command. It is the command.

## The TensorFlow Lite runtime

This pair *is* committed, and most work never touches it. It is the TFLite C
runtime with the XNNPACK delegate compiled to WebAssembly, built by
[`tools/tflite-wasm`](https://github.com/wilinz/wxscan-rs/tree/main/tools/tflite-wasm)
in wxscan-rs, whose README covers the two patches it needs, why `cmake` is run
twice, and why the first pass is expected to fail.

It only ever moves with the pinned TensorFlow version, and then it must:

```sh
# 1. Raise the pin. Every platform reads this.
tool/update_tflite_lock.sh <litert-version> <desktop-version>

# 2. Rebuild the browser pair to match.
source /path/to/emsdk/emsdk_env.sh
TENSORFLOW_VERSION=<desktop-version> wxscan-rs/tools/tflite-wasm/build.sh
cp out/wxscan_tflite.js out/wxscan_tflite.wasm \
   packages/wxscan/lib/src/web/assets/

# 3. Record what they now are.
tool/stamp_tflite_web.sh
```

Expect a quarter of an hour on the first build: it clones TensorFlow, fetches a
dozen dependencies and compiles about a thousand XNNPACK microkernels.

### The check that makes step 2 unavoidable

Skipping the rebuild leaves a browser running a different TFLite from every
other platform, and nothing about that is visible at run time — it decodes
correctly and differs only where nobody looks. So it is checked instead:

```sh
tool/check_tflite_web.sh
```

`tool/tflite_web.lock` records the TensorFlow version the committed pair was
built from and their checksums. The check fails when that version has drifted
from `DESKTOP_VERSION` in `tool/tflite.lock`, and when the files are not the
ones the record describes — someone replacing them without stamping. CI runs
it, so neither can reach a release quietly.

## What CI does

[`.github/workflows/demo.yml`](../../../.github/workflows/demo.yml) builds the
live demo and is the worked example. It checks out wxscan-rs beside cvlite and
wxing, writes the same patch stanza, builds the scanner, and copies the four
files into `web/`.

It copies rather than running `fetch_web`, for a reason worth knowing if you
script this yourself: running any Dart program builds the package's code assets
first, and that is cargo for the **host** — minutes of Rust that a web build
has no use for, against path dependencies expecting sibling checkouts. On a
developer's machine those exist and the command is the right one; in a
container that only wants a web build, copying is.
