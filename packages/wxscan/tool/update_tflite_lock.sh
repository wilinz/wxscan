#!/bin/sh
# Rewrites tool/tflite.lock for a new release.
#
#   usage: update_tflite_lock.sh [tag]
#
# The tag defaults to what the lock file already holds. Every archive of the
# release is downloaded and its checksum recorded; nothing is written unless
# all of them succeed.
set -eu

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)
LOCK="${PKG_DIR}/tool/tflite.lock"
CACHE="${PKG_DIR}/.tflite-cache"

log() { echo "update_tflite_lock: $*" >&2; }

value_of() { grep "^$1=" "$LOCK" | head -1 | cut -d= -f2-; }

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else sha256sum "$1" | cut -d' ' -f1
  fi
}

fetch_sha() {
  out="${CACHE}/update-$(basename "$1")"
  mkdir -p "$CACHE"
  log "fetching $(basename "$1")"
  curl -fsSL --retry 3 -o "$out" "$1"
  sha256_of "$out"
}

TAG=${1:-$(value_of TFLITE_VERSION)}
REPO=$(value_of TFLITE_REPO)
base="https://github.com/${REPO}/releases/download/${TAG}"

android_arm64=$(fetch_sha "${base}/tflite_c_${TAG}_android_arm64.tar.gz")
android_arm=$(fetch_sha "${base}/tflite_c_${TAG}_android_arm.tar.gz")
android_x64=$(fetch_sha "${base}/tflite_c_${TAG}_android_x64.tar.gz")
ios_device=$(fetch_sha "${base}/tflite_c_${TAG}_ios_device.tar.gz")
ios_simulator=$(fetch_sha "${base}/tflite_c_${TAG}_ios_simulator.tar.gz")
darwin_universal=$(fetch_sha "${base}/tflite_c_${TAG}_darwin_universal.tar.gz")
linux_amd64=$(fetch_sha "${base}/tflite_c_${TAG}_linux_amd64.tar.gz")
linux_arm64=$(fetch_sha "${base}/tflite_c_${TAG}_linux_arm64.tar.gz")
windows_amd64=$(fetch_sha "${base}/tflite_c_${TAG}_windows_amd64.zip")

tmp="${LOCK}.new"
{
  sed -n '1,/^$/p' "$LOCK" | sed '/^TFLITE_VERSION=/,$d'
  echo "TFLITE_VERSION=${TAG}"
  echo "TFLITE_REPO=${REPO}"
  echo "SHA_android_arm64=${android_arm64}"
  echo "SHA_android_arm=${android_arm}"
  echo "SHA_android_x64=${android_x64}"
  echo "SHA_ios_device=${ios_device}"
  echo "SHA_ios_simulator=${ios_simulator}"
  echo "SHA_darwin_universal=${darwin_universal}"
  echo "SHA_linux_amd64=${linux_amd64}"
  echo "SHA_linux_arm64=${linux_arm64}"
  echo "SHA_windows_amd64=${windows_amd64}"
} > "$tmp"
mv "$tmp" "$LOCK"
log "wrote $LOCK"
log "the cached downloads are stale now; remove .tflite-cache and the fetched"
log "libraries to pick up the new ones"

# The browser gets its runtime from a release of its own, pinned in web.lock,
# and raising the pin here is what leaves that one behind. Say so now rather
# than leaving check_tflite_web.sh to be the first to mention it in CI.
if ! "${PKG_DIR}/tool/check_tflite_web.sh" >/dev/null 2>&1; then
  log ""
  log "the browser TFLite runtime no longer matches this pin."
  log "publish one built from this version in wxscan-litert-wasm - see"
  log "doc/web_build.md:"
  log "  raise [tensorflow] version in its tflite.toml, reset revision to 1"
  log "  git tag <version>-b1 && git push origin <version>-b1"
  log "then re-pin it here:"
  log "  tool/stamp_web.sh <scanner-tag> <version>-b1"
fi
