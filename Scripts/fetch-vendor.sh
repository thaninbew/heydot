#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $(uname -m) == arm64 ]] || { echo 'HeyDot vendor requires arm64 macOS' >&2; exit 1; }
mkdir -p Vendor
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
fetch() {
  local url=$1 sha=$2 dest=$3
  curl --fail --location --retry 3 "$url" -o "$work/archive.tar.bz2"
  echo "$sha  $work/archive.tar.bz2" | shasum -a 256 --check
  mkdir -p "$dest"
  tar -xjf "$work/archive.tar.bz2" -C "$dest"
}
# SHA recorded from the official k2-fsa release asset, first verified download 2026-11-14.
release=sherpa-onnx-v1.13.8-osx-arm64-static-no-tts-lib
if [[ ! -f Vendor/$release/lib/libsherpa-onnx-c-api.a ]]; then
  fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/$release.tar.bz2" \
    3d7f9b8a496694af13d9802c33b8133231e397bdef302f543d19468765e83136 Vendor
fi
source Scripts/model-files.sh
if ! has_model_files "Vendor/models/$MODEL"; then
  fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/kws-models/$MODEL.tar.bz2" \
    f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a "$work/models"
  has_model_files "$work/models/$MODEL"
  mkdir -p "Vendor/models/$MODEL"
  cp -R "$work/models/$MODEL/." "Vendor/models/$MODEL/"
fi

# The static archive contains libraries only; pin the matching official C ABI header too.
mkdir -p Vendor/include
if [[ ! -s Vendor/include/c-api.h ]]; then
  curl --fail --location --retry 3 https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h -o "$work/c-api.h"
  echo "2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce  $work/c-api.h" | shasum -a 256 --check
  mv "$work/c-api.h" Vendor/include/c-api.h
fi
