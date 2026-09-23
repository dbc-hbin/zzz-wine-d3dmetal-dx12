#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
EVIDENCE="$ROOT/docs/evidence/2026-09-23-regression-fixes/sr-cost"
OUT=${OUT:-/tmp/yaagl-sr-native-aligned}
LAYOUT_DIR=${LAYOUT_DIR:-/tmp/yaagl-lease-commit-build}
PROBE_SOURCE="$EVIDENCE/native-metal4-counter-pattern-probe.mm"
for file in "$LAYOUT_DIR/fsr-kernels.inc" "$ROOT/d3dmetal-pso-cache/metalfx-backend.mm" "$PROBE_SOURCE"; do
  if [ ! -e "$file" ]; then echo "Missing required native probe input: $file" >&2; exit 2; fi
done
mkdir -p "$OUT/instrumented"
python3 "$EVIDENCE/instrument-sr-timing.py" "$ROOT" "$OUT/instrumented"
python3 "$EVIDENCE/prepare-matched-native-probe.py" \
  "$PROBE_SOURCE" "$OUT/native-metal4-counter-pattern-matched.mm"
cd "$ROOT"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang++ -arch x86_64 -std=c++20 -fno-objc-arc -fobjc-exceptions -fblocks -pthread \
  -isysroot "$SDK" -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror \
  -framework Foundation -framework Metal -framework MetalFX \
  -I "$ROOT/d3dmetal-pso-cache" -I "$LAYOUT_DIR" \
  "$OUT/instrumented/metalfx-backend.timing.mm" \
  "$OUT/native-metal4-counter-pattern-matched.mm" \
  -o "$OUT/native-metal4-counter-pattern-matched"
{
  printf 'standalone_input_sha256: '; shasum -a 256 "$PROBE_SOURCE"
  printf 'matched_standalone_sha256: '; shasum -a 256 "$OUT/native-metal4-counter-pattern-matched.mm"
  printf 'instrumented_backend_sha256: '; shasum -a 256 "$OUT/instrumented/metalfx-backend.timing.mm"
  printf 'layout_header_sha256: '; shasum -a 256 "$LAYOUT_DIR/fsr-kernels.inc" "$LAYOUT_DIR/layout.hpp"
  printf 'source/transform hashes:\n'
  shasum -a 256 "$ROOT/d3dmetal-pso-cache/metalfx-backend.mm" \
    "$EVIDENCE/instrument-sr-timing.py" "$EVIDENCE/prepare-matched-native-probe.py" \
    "$EVIDENCE/run-matched-native-probe.sh"
  printf 'variant: FFX jitter/cap + D3D Shared usage/hazard/backing; preserve Blit-stage readback wait\n'
} > "$OUT/build-inputs.txt"
MTL_HUD_ENABLED=0 MTL_CAPTURE_ENABLED=0 METALFX_SR_CONFIG_PROBE=1 \
  /usr/bin/arch -x86_64 "$OUT/native-metal4-counter-pattern-matched" \
  > "$OUT/native-metal4-counter-pattern-matched.stdout" 2>&1
printf 'Raw backing-matched standalone output: %s\n' "$OUT/native-metal4-counter-pattern-matched.stdout"
