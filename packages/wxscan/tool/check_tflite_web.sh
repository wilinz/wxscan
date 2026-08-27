#!/bin/sh
# Checks the committed browser TFLite runtime against what the rest of the
# package pins.
#
# The two files are an emscripten build that is committed rather than built —
# see tool/tflite_web.lock — so nothing else would notice them drifting. Two
# ways they can:
#
#   * tflite.lock moves to a new TensorFlow and nobody rebuilds them, leaving a
#     browser on a different runtime from every other platform; or
#   * they are replaced without the stamp being updated, so the record of what
#     they are stops being true.
#
# Both are silent at run time: a mismatched runtime decodes correctly and
# differs only in the details nobody looks at. So they are caught here.
set -eu

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
ASSETS="${PKG_DIR}/lib/src/web/assets"

value_of() { grep "^$1=" "$2" | head -1 | cut -d= -f2-; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1
  fi
}

fail() { echo "check_tflite_web: $*" >&2; exit 1; }

pinned=$(value_of DESKTOP_VERSION "${PKG_DIR}/tool/tflite.lock")
built=$(value_of TENSORFLOW_VERSION "${PKG_DIR}/tool/tflite_web.lock")

[ -n "$pinned" ] || fail "tflite.lock has no DESKTOP_VERSION"
[ -n "$built" ] || fail "tflite_web.lock has no TENSORFLOW_VERSION"

if [ "$pinned" != "$built" ]; then
  fail "the browser runtime is TensorFlow $built, but this package pins
                    $pinned everywhere else. Rebuild it with
                    wxscan-rs/tools/tflite-wasm/build.sh and run
                    tool/stamp_tflite_web.sh $pinned"
fi

for pair in "js:wxscan_tflite.js" "wasm:wxscan_tflite.wasm"; do
  key="SHA256_${pair%%:*}"
  file="${ASSETS}/${pair#*:}"
  [ -f "$file" ] || fail "$file is missing"
  want=$(value_of "$key" "${PKG_DIR}/tool/tflite_web.lock")
  got=$(sha256_of "$file")
  if [ "$want" != "$got" ]; then
    fail "${pair#*:} is not what tflite_web.lock records.
                    recorded $want
                    found    $got
                    If it was rebuilt on purpose, run tool/stamp_tflite_web.sh"
  fi
done

echo "check_tflite_web: browser runtime is TensorFlow $built, as pinned"
