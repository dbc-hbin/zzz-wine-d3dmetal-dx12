#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)
EVIDENCE="$ROOT/docs/evidence/2026-09-23-regression-fixes/sr-cost"
PRIOR="$ROOT/docs/evidence/2026-09-23-screenshot-analysis/performance"
OUT=${OUT:-/tmp/yaagl-sr-cost-repro}
ARCHIVE="$ROOT/build/release-v1.1.0/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz"
EXTRACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yaagl-repro-wine.XXXXXX")
trap 'rm -rf -- "$EXTRACT_DIR"' EXIT
trap 'exit 1' HUP INT TERM
tar -xJf "$ARCHIVE" -C "$EXTRACT_DIR"
WINE="$EXTRACT_DIR/wine/bin/wine.real"
if [ ! -x "$WINE" ]; then echo "Missing archived Wine executable: $WINE" >&2; exit 2; fi
CXX=/opt/llvm-mingw-20260616-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang++
mkdir -p "$OUT/native" "$OUT/metalfx" "$OUT/runtime/bin" "$OUT/runtime/lib/wine/x86_64-windows"
cp "$EVIDENCE/generated-selection-helper.sh" "$OUT/runtime/bin/yaagl-frame-probe-exec"
cp '/Applications/Zenless Zone Zero/amd_fidelityfx_framegeneration_dx12.dll' "$OUT/runtime/lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12_native.dll"
chmod 755 "$OUT/runtime/bin/yaagl-frame-probe-exec"
cd "$ROOT"
"$CXX" -std=c++20 -O2 -static -I "$PRIOR" -I d3dmetal-pso-cache -iquote . \
  "$PRIOR/fsr-screenshot-bench.cpp" -o "$OUT/fsr-screenshot-bench.exe" -ld3d12 -ldxgi
cp "$OUT/fsr-screenshot-bench.exe" "$OUT/native/" 
cp "$OUT/fsr-screenshot-bench.exe" "$OUT/metalfx/"
cp '/Applications/Zenless Zone Zero/amd_fidelityfx_upscaler_dx12.dll' "$OUT/native/"
cp '/Applications/Zenless Zone Zero/amd_fidelityfx_loader_dx12.dll' "$OUT/native/"
cp '/Applications/Zenless Zone Zero/amd_fidelityfx_framegeneration_dx12.dll' "$OUT/native/"
shasum -a 256 "$OUT/native/amd_fidelityfx_upscaler_dx12.dll"
(
  cd "$OUT/native"
  env -u YAAGL_FSR_LOG -u MTL_DEBUG_LAYER YAAGL_FSR_UPSCALER=native \
    WINEPREFIX="$OUT/native-prefix" D3DM_MTL4=1 CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal \
    D3DM_ENABLE_METALFX=1 "$OUT/runtime/bin/yaagl-frame-probe-exec" "$WINE" \
    fsr-screenshot-bench.exe 3.1.5 amd_fidelityfx_upscaler_dx12.dll off auto
) > "$OUT/canonical-native-auto-off.stdout" 2>&1
(
  cd "$OUT/metalfx"
  env -u YAAGL_FSR_LOG -u MTL_DEBUG_LAYER YAAGL_FSR_UPSCALER=metalfx \
    WINEPREFIX="$OUT/metalfx-prefix" D3DM_MTL4=1 CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal \
    D3DM_ENABLE_METALFX=1 "$OUT/runtime/bin/yaagl-frame-probe-exec" "$WINE" \
    fsr-screenshot-bench.exe mfx amd_fidelityfx_upscaler_dx12.dll off auto
) > "$OUT/canonical-metalfx-auto-off.stdout" 2>&1
python3 - "$ROOT/d3dmetal-pso-cache/fsr-kernels.metal" "$OUT/fsr-kernels.inc" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
if ')YAAGL_METAL"' in source:
    raise SystemExit('FSR Metal source collides with generated raw-string delimiter')
pathlib.Path(sys.argv[2]).write_text(
    'static const char kFsrKernelsSource[] = R"YAAGL_METAL(' + source + ')YAAGL_METAL";\n')
PY
xcrun clang++ -arch x86_64 -std=c++20 -O2 -mmacosx-version-min=26.0 \
  -Wall -Wextra -Werror -pthread -fno-objc-arc -fobjc-exceptions -fblocks \
  -I "$OUT" -I "$ROOT/d3dmetal-pso-cache" \
  "$EVIDENCE/metalfx-backend.counter-instrumented.mm" \
  "$EVIDENCE/native-metal4-counter-pattern-probe.mm" \
  -framework Foundation -framework Metal -framework MetalFX -o "$OUT/native-metal4-counter-probe"
/usr/bin/arch -x86_64 "$OUT/native-metal4-counter-probe" > "$OUT/native-metal4-counter-pattern-auto-reactive-off.stdout" 2>&1
printf 'Outputs: %s\n' "$OUT"
