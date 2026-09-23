#!/bin/bash
set -euo pipefail
ROOT=/Users/hanbinnoh/Documents/zzz-wine-d3dmetal-dx12
EVIDENCE="$ROOT/docs/evidence/2026-09-23-screenshot-analysis/performance"
TMP=/tmp/yaagl-upscale-cost
CXX=/opt/llvm-mingw-20260616-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang++
WINE="$ROOT/build/release-v1.1.0/wine/bin/wine"
OUTPUT="$TMP/fsr-screenshot-bench-stdout"
mkdir -p "$TMP/native-current-alias" "$TMP/mfx-current-bench" "$OUTPUT"
cd "$ROOT"
"$CXX" -std=c++20 -O2 -static -I d3dmetal-pso-cache -iquote . "$EVIDENCE/fsr-screenshot-bench.cpp" -o "$TMP/fsr-screenshot-bench.exe" -ld3d12 -ldxgi
cp "$TMP/fsr-screenshot-bench.exe" "$TMP/native-current-alias/"
cp "$TMP/fsr-screenshot-bench.exe" "$TMP/mfx-current-bench/"
# A copied noncanonical basename bypasses the Wine builtin-name override.
cp "/Applications/Zenless Zone Zero/amd_fidelityfx_upscaler_dx12.dll" "$TMP/native-current-alias/amd_fidelityfx_upscaler_dx12_original.dll"
cp "/Applications/Zenless Zone Zero/amd_fidelityfx_loader_dx12.dll" "/Applications/Zenless Zone Zero/amd_fidelityfx_framegeneration_dx12.dll" "$TMP/native-current-alias/"
shasum -a 256 "$TMP/native-current-alias/amd_fidelityfx_upscaler_dx12_original.dll"
run_native() {
  (cd "$TMP/native-current-alias" && env -u YAAGL_FSR_LOG -u WINEDLLOVERRIDES -u MTL_DEBUG_LAYER WINEPREFIX="$TMP/native-current-alias-prefix" D3DM_MTL4=1 "$WINE" fsr-screenshot-bench.exe 3.1.5 amd_fidelityfx_upscaler_dx12_original.dll "$1" "$2") 2>&1 | tee "$OUTPUT/native-$1-$2.stdout"
}
run_mfx() {
  (cd "$TMP/mfx-current-bench" && env -u YAAGL_FSR_LOG -u WINEDLLOVERRIDES -u MTL_DEBUG_LAYER WINEPREFIX="$TMP/mfx-current-bench-prefix" D3DM_MTL4=1 "$WINE" fsr-screenshot-bench.exe mfx amd_fidelityfx_upscaler_dx12.dll "$1" "$2") 2>&1 | tee "$OUTPUT/mfx-$1-$2.stdout"
}
run_native on sdr
run_mfx on sdr
run_native off sdr
run_mfx off sdr
run_native on hdr
run_mfx on hdr
run_native on auto
run_mfx on auto
