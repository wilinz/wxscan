#!/bin/sh
# Records what the browser TFLite runtime in lib/src/web/assets was built from.
#
#   usage: stamp_tflite_web.sh [tensorflow-version]
#
# The version defaults to what tflite.lock pins, which is the value it should
# have: the browser is meant to run the same runtime as every other platform.
# Run this after replacing the two files, and tool/check_tflite_web.sh will
# agree again.
set -eu

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
ASSETS="${PKG_DIR}/lib/src/web/assets"
LOCK="${PKG_DIR}/tool/tflite_web.lock"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1
  fi
}

version="${1:-$(grep '^DESKTOP_VERSION=' "${PKG_DIR}/tool/tflite.lock" | cut -d= -f2-)}"
js=$(sha256_of "${ASSETS}/wxscan_tflite.js")
wasm=$(sha256_of "${ASSETS}/wxscan_tflite.wasm")

# The header is kept and only the three values are rewritten, so the reasoning
# in it does not have to live in two places.
tmp=$(mktemp)
sed '/^TENSORFLOW_VERSION=/,$d' "$LOCK" > "$tmp"
{
  echo "TENSORFLOW_VERSION=$version"
  echo "SHA256_js=$js"
  echo "SHA256_wasm=$wasm"
} >> "$tmp"
mv "$tmp" "$LOCK"

echo "stamp_tflite_web: $version"
