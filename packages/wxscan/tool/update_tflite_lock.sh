#!/bin/sh
# Rewrites tool/tflite.lock for new upstream versions.
#
#   usage: update_tflite_lock.sh [litert-version] [desktop-version]
#
# Each argument defaults to what the lock file already holds, so either half can
# be upgraded on its own. Every artifact is downloaded and its checksum recorded;
# nothing is written unless all of them succeed.
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

LITERT_VERSION=${1:-$(value_of LITERT_VERSION)}
DESKTOP_VERSION=${2:-$(value_of DESKTOP_VERSION)}
DESKTOP_REPO=$(value_of DESKTOP_REPO)

litert_sha=$(fetch_sha "https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/litert/${LITERT_VERSION}/litert-${LITERT_VERSION}.aar")

base="https://github.com/${DESKTOP_REPO}/releases/download/${DESKTOP_VERSION}"
darwin_arm64=$(fetch_sha "${base}/tflite_c_${DESKTOP_VERSION}_darwin_arm64.tar.gz")
linux_amd64=$(fetch_sha "${base}/tflite_c_${DESKTOP_VERSION}_linux_amd64.tar.gz")
linux_arm64=$(fetch_sha "${base}/tflite_c_${DESKTOP_VERSION}_linux_arm64.tar.gz")
windows_amd64=$(fetch_sha "${base}/tflite_c_${DESKTOP_VERSION}_windows_amd64.zip")

tmp="${LOCK}.new"
{
  sed -n '1,/^$/p' "$LOCK" | sed '/^LITERT_VERSION=/,$d'
  echo "LITERT_VERSION=${LITERT_VERSION}"
  echo "LITERT_SHA256=${litert_sha}"
  echo
  echo "DESKTOP_VERSION=${DESKTOP_VERSION}"
  echo "DESKTOP_REPO=${DESKTOP_REPO}"
  echo "SHA_darwin_arm64=${darwin_arm64}"
  echo "SHA_linux_amd64=${linux_amd64}"
  echo "SHA_linux_arm64=${linux_arm64}"
  echo "SHA_windows_amd64=${windows_amd64}"
} > "$tmp"
mv "$tmp" "$LOCK"
log "wrote $LOCK"
log "the cached downloads are stale now; remove .tflite-cache and the fetched"
log "libraries to pick up the new ones"
