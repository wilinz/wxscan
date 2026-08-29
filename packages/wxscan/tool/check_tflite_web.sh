#!/bin/sh
# Checks that the browser's TensorFlow Lite runtime is the same TensorFlow as
# every other platform's.
#
# Two files pin it, and nothing connects them on its own:
#
#   tool/tflite.lock  TFLITE_VERSION — the release Android, iOS and the
#                     desktops link against
#   tool/web.lock     TFLITE_TAG     — the release a browser fetches
#
# Move one and not the other and a browser runs a different runtime, against
# the same .tflite weights, from everything else. That is silent at run time:
# it decodes correctly and differs only in the details nobody looks at. So it
# is caught here, and CI runs this.
#
# The checksums in web.lock are not re-checked here. They guard the download,
# and `dart run wxscan:fetch_web` refuses anything that does not match them —
# there is nothing committed left for this to verify.
set -eu

PKG_DIR=$(cd "$(dirname "$0")/.." && pwd)

value_of() { grep "^$1=" "$2" | head -1 | cut -d= -f2-; }
fail() { echo "check_tflite_web: $*" >&2; exit 1; }

pinned=$(value_of TFLITE_VERSION "${PKG_DIR}/tool/tflite.lock")
tag=$(value_of TFLITE_TAG "${PKG_DIR}/tool/web.lock")

[ -n "$pinned" ] || fail "tflite.lock has no TFLITE_VERSION"
[ -n "$tag" ] || fail "web.lock has no TFLITE_TAG"

# <tensorflow-version>-b<revision>. The revision is the build repository's own —
# it counts the build changes applied on top of that TensorFlow, which change
# while the version stays put — so only the version is compared, on both sides.
case "$tag" in
  v*-b*) ;;
  *) fail "TFLITE_TAG is '$tag', which is not
                    <version>-b<revision>. web.lock is written by
                    tool/stamp_web.sh; do not edit it by hand." ;;
esac

web=${tag%-b*}
pinned=${pinned%-b*}

if [ "$pinned" != "$web" ]; then
  fail "the browser fetches TensorFlow $web ($tag), but this package pins
                    $pinned everywhere else. Publish a runtime built from
                    $pinned in wxscan-litert-wasm, then re-pin it here with
                    tool/stamp_web.sh <scanner-tag> <tflite-tag>"
fi

echo "check_tflite_web: the browser runtime is TensorFlow $web ($tag), as pinned"
