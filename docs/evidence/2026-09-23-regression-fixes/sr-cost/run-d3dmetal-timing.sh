#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
EVIDENCE="$ROOT/docs/evidence/2026-09-23-regression-fixes/sr-cost"
PRIOR="$ROOT/docs/evidence/2026-09-23-screenshot-analysis/performance"
OUT=${OUT:-/tmp/yaagl-sr-d3dmetal-timing}
RUN_CONTROL=${RUN_CONTROL:-1}
DEFAULT_COMPILER=${DEFAULT_COMPILER:-0}
CONFIG_PROBE=${CONFIG_PROBE:-0}
VARIANT=${VARIANT:-timing}
TIMED_PREFIX=${TIMED_PREFIX:-$OUT/metalfx-$VARIANT-prefix}
TIMING_OUTPUT=${TIMING_OUTPUT:-$OUT/metalfx-d3dmetal-$VARIANT.stdout}
PATCHED_D3DMETAL=${PATCHED_D3DMETAL:-/tmp/yaagl-lease-commit-D3DMetal}
LAYOUT_DIR=${LAYOUT_DIR:-/tmp/yaagl-lease-commit-build}
BASE_WINE="$ROOT/build/release-v1.1.0/wine"
RUNTIME="$OUT/runtime/wine"
CXX=/opt/llvm-mingw-20260616-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang++

for file in "$PATCHED_D3DMETAL" "$LAYOUT_DIR/layout.hpp" "$LAYOUT_DIR/fsr-kernels.inc" "$BASE_WINE/bin/wine.real"; do
  if [ ! -e "$file" ]; then echo "Missing required isolated timing input: $file" >&2; exit 2; fi
done
mkdir -p "$OUT/instrumented" "$OUT/runtime"
python3 "$EVIDENCE/instrument-sr-timing.py" "$ROOT" "$OUT/instrumented"

cd "$ROOT"
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang++ -arch x86_64 -std=c++20 -fno-objc-arc -fobjc-exceptions -fblocks \
  -isysroot "$SDK" -mmacosx-version-min=26.0 -O2 -Wall -Wextra -Werror \
  -dynamiclib -pthread -framework Foundation -framework Metal -framework QuartzCore -framework MetalFX \
  -I "$ROOT/d3dmetal-pso-cache" -I "$LAYOUT_DIR" \
  "$ROOT/d3dmetal-pso-cache/cache.mm" \
  "$ROOT/d3dmetal-pso-cache/function-cache.mm" \
  "$ROOT/d3dmetal-pso-cache/function-hooks.mm" \
  "$ROOT/d3dmetal-pso-cache/key.mm" \
  "$OUT/instrumented/metalfx-backend.timing.mm" \
  "$OUT/instrumented/d3dmetal-transport.timing.mm" \
  "$EVIDENCE/inprocess-native-sr-probe.mm" \
  "$ROOT/d3dmetal-pso-cache/d3dmetal-transport-legacy.mm" \
  "$ROOT/d3dmetal-pso-cache/d3dmetal-replay-hooks.mm" \
  "$ROOT/d3dmetal-pso-cache/fsr-contract.cpp" \
  "$ROOT/d3dmetal-pso-cache/fsr-translator.mm" \
  "$ROOT/d3dmetal-pso-cache/fsr-framegeneration.mm" \
  "$ROOT/d3dmetal-pso-cache/persistent-cache.mm" \
  "$ROOT/d3dmetal-pso-cache/rt-key.mm" \
  "$ROOT/d3dmetal-pso-cache/stage-cache.mm" \
  "$ROOT/d3dmetal-pso-cache/bridge.mm" \
  -o "$OUT/instrumented/libYaaglNativePsoCache.dylib"

if [ ! -x "$RUNTIME/bin/wine.real" ]; then
  mkdir -p "$(dirname -- "$RUNTIME")"
  cp -cR "$BASE_WINE" "$RUNTIME"
fi
D3DMETAL_DEST="$RUNTIME/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
SIDECAR_DIR="$RUNTIME/lib/external/D3DMetal.framework/Versions/A/Resources"
if [ ! -e "$D3DMETAL_DEST" ]; then echo "Missing isolated runtime D3DMetal: $D3DMETAL_DEST" >&2; exit 2; fi
mkdir -p "$SIDECAR_DIR"
cp -f "$PATCHED_D3DMETAL" "$D3DMETAL_DEST"
cp -f "$OUT/instrumented/libYaaglNativePsoCache.dylib" "$SIDECAR_DIR/libYaaglNativePsoCache.dylib"
codesign --force --deep --sign - --timestamp=none "$RUNTIME/lib/external/D3DMetal.framework"
codesign --verify --deep --strict "$RUNTIME/lib/external/D3DMetal.framework"
cp "$EVIDENCE/generated-selection-helper.sh" "$RUNTIME/bin/yaagl-frame-probe-exec"
FG_FALLBACK="$RUNTIME/lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12_native.dll"
if [ -e "$FG_FALLBACK" ]; then chmod u+w "$FG_FALLBACK"; fi
cp -f '/Applications/Zenless Zone Zero/amd_fidelityfx_framegeneration_dx12.dll' "$FG_FALLBACK"
chmod 755 "$RUNTIME/bin/yaagl-frame-probe-exec"

"$CXX" -std=c++20 -O2 -static -I "$PRIOR" -I "$ROOT/d3dmetal-pso-cache" -iquote . \
  "$PRIOR/fsr-screenshot-bench.cpp" -o "$OUT/fsr-screenshot-bench.exe" -ld3d12 -ldxgi
{
  printf "MTL_HUD_ENABLED=0; RUN_CONTROL=%s; DEFAULT_COMPILER=%s; CONFIG_PROBE=%s; VARIANT=%s\n" "$RUN_CONTROL" "$DEFAULT_COMPILER" "$CONFIG_PROBE" "$VARIANT"
  printf "TIMED_PREFIX=%s; TIMING_OUTPUT=%s\n" "$TIMED_PREFIX" "$TIMING_OUTPUT"
  printf "YAAGL_FSR_UPSCALER=metalfx; D3DM_MTL4=1; D3DM_ENABLE_METALFX=1; MTL_CAPTURE_ENABLED=0\n"
  printf "helper_sha256: "; shasum -a 256 "$RUNTIME/bin/yaagl-frame-probe-exec"
  printf "patched_D3DMetal_sha256: "; shasum -a 256 "$D3DMETAL_DEST"
  printf "instrumented_sidecar_sha256: "; shasum -a 256 "$SIDECAR_DIR/libYaaglNativePsoCache.dylib"
  printf 'test-only transformed source and generated-header hashes:\n'
  shasum -a 256 "$EVIDENCE/inprocess-native-sr-probe.mm"
  shasum -a 256 "$OUT/instrumented/d3dmetal-transport.timing.mm" \
    "$OUT/instrumented/metalfx-backend.timing.mm" "$LAYOUT_DIR/layout.hpp" \
    "$LAYOUT_DIR/fsr-kernels.inc" "$ROOT/d3dmetal-pso-cache/layout.json" \
    "$PATCHED_D3DMETAL"
  printf "production source and instrumentation transform hashes:\n"
  shasum -a 256 "$ROOT/d3dmetal-pso-cache/cache.mm" \
    "$ROOT/d3dmetal-pso-cache/function-cache.mm" "$ROOT/d3dmetal-pso-cache/function-hooks.mm" \
    "$ROOT/d3dmetal-pso-cache/key.mm" "$ROOT/d3dmetal-pso-cache/d3dmetal-transport.mm" \
    "$ROOT/d3dmetal-pso-cache/d3dmetal-transport-legacy.mm" \
    "$ROOT/d3dmetal-pso-cache/d3dmetal-replay-hooks.mm" \
    "$ROOT/d3dmetal-pso-cache/fsr-contract.cpp" "$ROOT/d3dmetal-pso-cache/fsr-translator.mm" \
    "$ROOT/d3dmetal-pso-cache/fsr-framegeneration.mm" "$ROOT/d3dmetal-pso-cache/persistent-cache.mm" \
    "$ROOT/d3dmetal-pso-cache/rt-key.mm" "$ROOT/d3dmetal-pso-cache/stage-cache.mm" \
    "$ROOT/d3dmetal-pso-cache/bridge.mm" \
    "$EVIDENCE/instrument-sr-timing.py" "$EVIDENCE/run-d3dmetal-timing.sh"
} > "$OUT/run-environment.txt"
mkdir -p "$OUT/metalfx-workload"
cp "$OUT/fsr-screenshot-bench.exe" "$OUT/metalfx-workload/"
cp '/Applications/Zenless Zone Zero/amd_fidelityfx_upscaler_dx12.dll' "$OUT/metalfx-workload/"
cp '/Applications/Zenless Zone Zero/amd_fidelityfx_loader_dx12.dll' "$OUT/metalfx-workload/"
if [ "$RUN_CONTROL" = 1 ]; then
(
  cd "$OUT/metalfx-workload"
  env -u YAAGL_FSR_LOG -u MTL_DEBUG_LAYER -u METALFX_SR_TIMING_PROBE \
    -u METALFX_SR_CONFIG_PROBE -u METALFX_SR_DEFAULT_COMPILER \
    YAAGL_FSR_UPSCALER=metalfx MTL_HUD_ENABLED=0 MTL_CAPTURE_ENABLED=0 WINEPREFIX="$OUT/metalfx-control-prefix" \
    D3DM_MTL4=1 CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1 \
    DYLD_FALLBACK_LIBRARY_PATH="$SIDECAR_DIR:$RUNTIME/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}" \
    "$RUNTIME/bin/wine" fsr-screenshot-bench.exe mfx amd_fidelityfx_upscaler_dx12.dll off auto
) > "$OUT/metalfx-d3dmetal-control.stdout" 2>&1
fi
(
  cd "$OUT/metalfx-workload"
  env -u YAAGL_FSR_LOG -u MTL_DEBUG_LAYER YAAGL_FSR_UPSCALER=metalfx \
    MTL_HUD_ENABLED=0 MTL_CAPTURE_ENABLED=0 METALFX_SR_INPROCESS_OUTPUT="$OUT/inprocess-native.stdout" METALFX_SR_TIMING_PROBE=1 METALFX_SR_CONFIG_PROBE="$CONFIG_PROBE" METALFX_SR_DEFAULT_COMPILER="$DEFAULT_COMPILER" WINEPREFIX="$TIMED_PREFIX" \
    D3DM_MTL4=1 CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1 \
    DYLD_FALLBACK_LIBRARY_PATH="$SIDECAR_DIR:$RUNTIME/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}" \
    "$RUNTIME/bin/wine" fsr-screenshot-bench.exe mfx amd_fidelityfx_upscaler_dx12.dll off auto
) > "$TIMING_OUTPUT" 2>&1
python3 - "$TIMING_OUTPUT" "$OUT/inprocess-native.stdout" <<'PY'
import math
import pathlib
import re
import statistics
import sys
text = pathlib.Path(sys.argv[1]).read_text(errors='replace')
rows = []
for line in text.splitlines():
    if 'YAAGL_TIMING index=' not in line:
        continue
    fields = dict(re.findall(r'([a-z_]+)=([^ ]+)', line))
    rows.append(fields)
valid_all = [r for r in rows if r.get('counter_valid') == '1' and r.get('result') == 'PASS']
valid = valid_all[8:]  # The in-process probe consumes counter indices before FFX starts.
print(f'TIMING_ROWS={len(rows)} COUNTER_VALID={len(valid_all)} MEASURED_VALID={len(valid)}')
for key in ('replay_host_wall_ms', 'commit_to_feedback_host_ms', 'backend_pre_gpu_ms',
            'metalfx_fence_span_ms', 'backend_post_gpu_ms', 'sr_gpu_ms', 'feedback_gpu_ms'):
    values = [float(r[key]) for r in valid if key in r and math.isfinite(float(r[key])) and float(r[key]) >= 0]
    if values:
        ordered = sorted(values)
        p90 = ordered[min(len(ordered)-1, math.ceil(.9 * len(ordered))-1)]
        print(f'{key}: n={len(values)} p50={statistics.median(values):.4f}ms p90={p90:.4f}ms')
if len(rows) != 32 or len(valid_all) != 32 or len(valid) != 24:
    raise SystemExit(f'expected 8+24 valid FFX frames; got {len(rows)} rows, {len(valid_all)} valid')
if 'output_mean=' not in text or 'result=PASS' not in text.splitlines()[-1]:
    raise SystemExit('FFX output readback did not pass')
native = pathlib.Path(sys.argv[2]).read_text()
native_rows = [line for line in native.splitlines() if line.startswith('INPROCESS_NATIVE_FRAME ')]
if len(native_rows) != 32 or any('counter_valid=1 result=PASS' not in line for line in native_rows):
    raise SystemExit(f'expected 8+24 valid in-process native frames; got {len(native_rows)}')
if 'INPROCESS_NATIVE_VALIDATION output_mean=' not in native or 'INPROCESS_NATIVE_PROBE_ERROR' in native:
    raise SystemExit('native output readback did not pass')
PY
printf 'Raw D3DMetal timing output: %s\n' "$TIMING_OUTPUT"
