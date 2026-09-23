#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
SRC="$ROOT/d3dmetal-pso-cache"
OUT=/tmp/yaagl-sr-memory-probe
mkdir -p "$OUT"
python3 - "$SRC/fsr-kernels.metal" "$OUT/fsr-kernels.inc" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
if ')YAAGL_METAL"' in source:
    raise SystemExit('FSR Metal source collides with generated raw-string delimiter')
pathlib.Path(sys.argv[2]).write_text(
    'static const char kFsrKernelsSource[] = R"YAAGL_METAL(' + source + ')YAAGL_METAL";\n')
PY
# Instrument a temporary source copy to prove scaler-generation destruction.
python3 - "$SRC/metalfx-backend.mm" "$OUT/metalfx-backend.instrumented.mm" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
needle = """    ~ScalerGeneration() {
        releaseObject(scaler);
    }"""
replacement = r"""    ~ScalerGeneration() {
        if (scaler) std::fprintf(stderr,
            "SCALER_DESTROY input=%lux%lu output=%lux%lu\\n",
            static_cast<unsigned long>(inputCapacityWidth),
            static_cast<unsigned long>(inputCapacityHeight),
            static_cast<unsigned long>(outputWidth),
            static_cast<unsigned long>(outputHeight));
        releaseObject(scaler);
    }"""
if source.count(needle) != 1:
    raise SystemExit('expected one ScalerGeneration destructor')
pathlib.Path(sys.argv[2]).write_text(source.replace(needle, replacement))
PY
xcrun clang++ -arch x86_64 -std=c++20 -O2 -mmacosx-version-min=26.0 \
  -Wall -Wextra -Werror -pthread -fno-objc-arc -fobjc-exceptions -fblocks \
  -I "$OUT" -I "$SRC" \
  "$OUT/metalfx-backend.instrumented.mm" \
  "$ROOT/docs/evidence/2026-09-23-screenshot-analysis/memory/sr-memory-probe.mm" \
  -framework Foundation -framework Metal -framework MetalFX \
  -o "$OUT/sr-memory-probe"
if [ "${BUILD_ONLY:-0}" != 1 ]; then
  /usr/bin/arch -x86_64 "$OUT/sr-memory-probe"
fi
