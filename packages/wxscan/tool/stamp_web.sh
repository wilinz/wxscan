#!/bin/sh
# Records which releases the browser's built artifacts come from, and what they
# must be.
#
#   usage: stamp_web.sh <scanner-tag> <tflite-tag>
#          stamp_web.sh v0.1.0 tflite-v2.17.1
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
REPO=wilinz/wxscan-rs

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
  url="https://github.com/${REPO}/releases/download/$1/$2"
  echo "  $url" >&2
  curl -fsSL "$url" -o "${TMP}/$2" || { echo "stamp_web: could not fetch $url" >&2; exit 1; }
  sha256_of "${TMP}/$2"
}

echo "stamp_web: reading the releases" >&2
scanner=$(get "$SCANNER_TAG" wxscan_wasm.wasm)
tflite_js=$(get "$TFLITE_TAG" wxscan_tflite.js)
tflite_wasm=$(get "$TFLITE_TAG" wxscan_tflite.wasm)

cat > "$LOCK" <<EOF
# Where the browser's built artifacts come from, and what they must be.
#
# None of them is committed in this package. A compiled artifact sitting beside
# the sources it came from goes out of step with them, and one here did — the
# live demo served a fixed detector bug for a while, because rebuilding it was
# a step someone had to remember.
#
# So they are built by CI in ${REPO} and fetched from its releases.
# \`dart run wxscan:fetch_web\` does that, and refuses anything whose checksum
# is not below: a release can be replaced, and a package that trusted whatever
# a URL served would not be pinning anything.
#
# Both tags are immutable. wasm-latest exists and is not used here on purpose —
# it moves, and a lock that moves is not a lock.
#
# To move to newer artifacts: tool/stamp_web.sh <scanner-tag> <tflite-tag>
#
# TFLITE_TAG is tflite-<tensorflow-version>-p<patch>. The version has to be the
# one this package pins for every other platform, and tool/check_tflite_web.sh
# says so; the patch revision is wxscan-rs's own, counting the patches built on
# top of that TensorFlow, which change while the version stays put.

REPO=${REPO}

SCANNER_TAG=${SCANNER_TAG}
SCANNER_SHA256=${scanner}

TFLITE_TAG=${TFLITE_TAG}
TFLITE_JS_SHA256=${tflite_js}
TFLITE_WASM_SHA256=${tflite_wasm}
EOF

echo "stamp_web: $LOCK" >&2
sed -n '/^REPO=/,$p' "$LOCK"
