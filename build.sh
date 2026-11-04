#!/bin/sh
# Packs APLADX for a platform into dist/.   Usage: ./build.sh <platform>     (platforms: muos)
#
# Expects (relative to this script):
#   src/ap.sh  src/host.yaml  src/apladx_icon.png  src/platforms/<platform>/...
#   Archipelago*.tar.gz        optional; the newest one is included if present
set -eu
cd "$(dirname "$0")"

APP="APLADX"

usage() { echo "usage: $0 <platform>   (supported: muos)" >&2; exit 1; }

PLATFORM="${1:-}"
[ -n "$PLATFORM" ] || usage
[ -d "src/platforms/$PLATFORM" ] || { echo "unknown platform: $PLATFORM" >&2; usage; }
command -v zip >/dev/null 2>&1 || { echo "error: the zip command is required" >&2; exit 1; }

# require_files <file>...: stop with a clear message if any required file is missing
require_files() {
  for f in "$@"; do
    [ -f "$f" ] || { echo "error: missing $f" >&2; exit 1; }
  done
}

# the newest Archipelago*.tar.gz next to this script, if there is one
find_tarball() { ls -t Archipelago*.tar.gz 2>/dev/null | head -n 1 || true; }

build_muos() {
  p="src/platforms/muos"
  require_files src/ap.sh src/host.yaml src/apladx_icon.png "$p/mux_launch.sh" "$p/mux_lang.ini" "$p/platform.conf"

  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' EXIT
  d="$stage/$APP"            # muOS extracts the archive's application/ folder into its apps folder
  mkdir -p "$d/glyph"

  cp src/ap.sh src/host.yaml "$d/"
  cp "$p/mux_launch.sh" "$p/mux_lang.ini" "$p/platform.conf" "$d/"
  cp src/apladx_icon.png "$d/glyph/apladx_icon.png"

  tarball=$(find_tarball)
  if [ -n "$tarball" ]; then
    cp "$tarball" "$d/"
    echo "including $tarball"
  else
    echo "note: no Archipelago*.tar.gz found, building without it"
  fi

  chmod +x "$d/ap.sh" "$d/mux_launch.sh"

  mkdir -p dist
  out="$PWD/dist/$APP.muxapp"
  rm -f "$out"
  (cd "$stage" && zip -q -r -0 "$out" "$APP")     # -0: stored, the usual muxapp format
  echo "built dist/$APP.muxapp"
}

case "$PLATFORM" in
  muos) build_muos ;;
  *)    usage ;;
esac
