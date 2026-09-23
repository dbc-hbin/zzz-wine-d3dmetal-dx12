#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
OUT=/tmp/yaagl-sr-native-scaler-control
mkdir -p "$OUT"
xcrun clang++ -arch x86_64 -std=c++20 -O2 -mmacosx-version-min=26.0 \
  -Wall -Wextra -Werror -pthread -fno-objc-arc -fobjc-exceptions -fblocks \
  "$ROOT/docs/evidence/2026-09-23-screenshot-analysis/memory/native-scaler-lifetime-control.mm" \
  -framework Foundation -framework Metal -framework MetalFX \
  -o "$OUT/native-scaler-lifetime-control"
if [ "${BUILD_ONLY:-0}" != 1 ]; then
  /usr/bin/arch -x86_64 "$OUT/native-scaler-lifetime-control"
fi
