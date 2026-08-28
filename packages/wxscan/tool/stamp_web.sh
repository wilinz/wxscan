#!/bin/sh
# Records which releases the browser's built artifacts come from, and what they
# must be.
#
#   usage: stamp_web.sh <scanner-tag> <tflite-tag>
#          stamp_web.sh v0.1.0 v2.17.1-b1
#
# Downloads each asset, takes its checksum and rewrites tool/web.lock. Nothing
# is written unless every download succeeds.
#
# The checksums live here rather than being read from the release, because a
# release that could vouch for itself would not be a check at all: this file is
# what says the bytes are the ones this package was tested against.
set -eu

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
LOCK="${PKG_DIR}/tool/web.lock"

# Two repositories, because the two artifacts move on different rhythms: the
# scanner is wxscan-rs's own code, the runtime is a dependency built and
# released on its own.
SCANNER_REPO=wilinz/wxscan-rs
TFLITE_REPO=wilinz/wxscan-litert-wasm

[ $# -eq 2 ] || { echo "usage: stamp_web.sh <scanner-tag> <tflite-tag>" >&2; exit 1; }
SCANNER_TAG=$1
TFLITE_TAG=$2

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1
  fi
}

get() {
  url="https://github.com/$1/releases/download/$2/$3"
  echo "  $url" >&2
  curl -fsSL "$url" -o "${TMP}/$3" || { echo "stamp_web: could not fetch $url" >&2; exit 1; }
  sha256_of "${TMP}/$3"
}

echo "stamp_web: reading the releases" >&2
scanner=$(get "$SCANNER_REPO" "$SCANNER_TAG" wxscan_wasm.wasm)
tflite_js=$(get "$TFLITE_REPO" "$TFLITE_TAG" wxscan_tflite.js)
tflite_wasm=$(get "$TFLITE_REPO" "$TFLITE_TAG" wxscan_tflite.wasm)

cat > "$LOCK" <<EOF
# Where the browser's built artifacts come from, and what they must be.
#
# None of them is committed in this package. A compiled artifact sitting beside
# the sources it came from goes out of step with them, and one here did — the
# live demo served a fixed detector bug for a while, because rebuilding it was
# a step someone had to remember.
#
# So they are built by CI and fetched from releases — the scanner from
# ${SCANNER_REPO}, the runtime from ${TFLITE_REPO}, which are two
# repositories because the two move on different rhythms.
# \`dart run wxscan:fetch_web\` does that, and refuses anything whose checksum
# is not below: a release can be replaced, and a package that trusted whatever
# a URL served would not be pinning anything.
#
# Both tags are immutable. wasm-latest exists and is not used here on purpose —
# it moves, and a lock that moves is not a lock.
#
# To move to newer artifacts: tool/stamp_web.sh <scanner-tag> <tflite-tag>
#
# TFLITE_TAG is <tensorflow-version>-b<revision>. The version has to be the one
# this package pins for every other platform, and tool/check_tflite_web.sh says
# so; the revision is the build repository's own, counting the patches built on
# top of that TensorFlow, which change while the version stays put.

SCANNER_REPO=${SCANNER_REPO}
SCANNER_TAG=${SCANNER_TAG}
SCANNER_SHA256=${scanner}

TFLITE_REPO=${TFLITE_REPO}
TFLITE_TAG=${TFLITE_TAG}
TFLITE_JS_SHA256=${tflite_js}
TFLITE_WASM_SHA256=${tflite_wasm}
EOF

echo "stamp_web: $LOCK" >&2
sed -n '/^SCANNER_REPO=/,$p' "$LOCK"
