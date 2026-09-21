#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: scripts/build-fsr-translator.sh <output-dir>" >&2
  exit 64
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=$1
case "$out" in
  /*) ;;
  *) out="$PWD/$out" ;;
esac
build="$out/build"
upscaler=amd_fidelityfx_upscaler_dx12
framegeneration=amd_fidelityfx_framegeneration_dx12
mingw=/opt/llvm-mingw-20260616-ucrt-macos-universal/bin
PATH="$mingw:$PATH"
export PATH
cc=$(xcrun --find clang)
cxx=$(xcrun --find clang++)
sdk=$(xcrun --sdk macosx --show-sdk-path)
jobs=$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)

for tool in "$cc" "$cxx" "$mingw/x86_64-w64-mingw32-clang" "$mingw/x86_64-w64-mingw32-clang++"; do
  if [ ! -x "$tool" ]; then
    echo "missing required compiler: $tool" >&2
    exit 69
  fi
done
for module in "$upscaler" "$framegeneration"; do
  if [ ! -f "$root/dlls/$module/Makefile.in" ]; then
    echo "missing Wine builtin source: dlls/$module/Makefile.in" >&2
    exit 66
  fi
done
mkdir -p "$build"

if [ ! -f "$build/config.status" ]; then
  (
    cd "$build"
    SDKROOT="$sdk" MACOSX_DEPLOYMENT_TARGET=14.0 \
    CFLAGS="-arch x86_64 -isysroot $sdk" CXXFLAGS="-arch x86_64 -isysroot $sdk" \
    LDFLAGS="-arch x86_64 -isysroot $sdk" \
    CC="$cc" CXX="$cxx" \
    CROSSCC="$mingw/x86_64-w64-mingw32-clang" \
    CROSSCXX="$mingw/x86_64-w64-mingw32-clang++" \
    "$root/configure" --build=x86_64-apple-darwin --enable-win64 \
      --enable-archs=x86_64 --disable-tests --without-x --without-freetype
  )
fi
( cd "$build" && ./config.status Makefile )

make -C "$build" -j"$jobs" "dlls/$upscaler/all" "dlls/$framegeneration/all"

mkdir -p "$out/lib/wine/x86_64-windows" "$out/lib/wine/x86_64-unix"
for module in "$upscaler" "$framegeneration"; do
  pe="$build/dlls/$module/x86_64-windows/$module.dll"
  unix="$build/dlls/$module/$module.so"
  if [ ! -f "$pe" ] || [ ! -f "$unix" ]; then
    echo "Wine target did not produce the expected $module PE and Unix modules" >&2
    exit 65
  fi
  pe_dest="$out/lib/wine/x86_64-windows/$module.dll"
  unix_dest="$out/lib/wine/x86_64-unix/$module.so"
  cp "$pe" "$pe_dest"
  cp "$unix" "$unix_dest"
  file "$pe_dest" | grep -q 'x86-64' || { echo "$module PE module is not x86_64" >&2; exit 65; }
  file "$unix_dest" | grep -q 'x86_64' || { echo "$module Unix module is not x86_64" >&2; exit 65; }
  exports=$($mingw/llvm-readobj --coff-exports "$pe_dest")
  printf '%s\n' "$exports" | python3 -c '
import re, sys
expected = [(1, "ffxConfigure"), (2, "ffxCreateContext"), (3, "ffxDestroyContext"),
            (4, "ffxDispatch"), (5, "ffxQuery")]
actual = [(int(ordinal), name) for ordinal, name in re.findall(
    r"Ordinal: (\d+)\s+Name: (\w+)", sys.stdin.read())]
if actual != expected:
    raise SystemExit(f"unexpected FSR PE exports: {actual!r}")
'
done
upscaler_pe="$out/lib/wine/x86_64-windows/$upscaler.dll"
upscaler_unix="$out/lib/wine/x86_64-unix/$upscaler.so"
fg_pe="$out/lib/wine/x86_64-windows/$framegeneration.dll"
fg_unix="$out/lib/wine/x86_64-unix/$framegeneration.so"

python3 - "$root" "$upscaler_pe" "$upscaler_unix" "$fg_pe" "$fg_unix" "$out/build-manifest.json" <<'PY'
import hashlib, json, pathlib, sys
root, upscaler_pe, upscaler_unix, fg_pe, fg_unix, manifest = map(pathlib.Path, sys.argv[1:])
sources = [
    root/'configure.ac', root/'dlls/amd_fidelityfx_upscaler_dx12/Makefile.in',
    root/'dlls/amd_fidelityfx_upscaler_dx12/amd_fidelityfx_upscaler_dx12.spec',
    root/'dlls/amd_fidelityfx_upscaler_dx12/main.c',
    root/'dlls/amd_fidelityfx_upscaler_dx12/unixlib.h',
    root/'dlls/amd_fidelityfx_upscaler_dx12/unixlib.c',
    root/'include/yaagl_fsr_bridge.h', root/'include/yaagl_fsr_fg_bridge.h',
    root/'dlls/amd_fidelityfx_framegeneration_dx12/Makefile.in',
    root/'dlls/amd_fidelityfx_framegeneration_dx12/amd_fidelityfx_framegeneration_dx12.spec',
    root/'dlls/amd_fidelityfx_framegeneration_dx12/main.c',
    root/'dlls/amd_fidelityfx_framegeneration_dx12/unixlib.h',
    root/'dlls/amd_fidelityfx_framegeneration_dx12/unixlib.c',
    root/'d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api.h',
    root/'d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api_types.h',
    root/'d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/api/include/dx12/ffx_api_dx12.h',
    root/'d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/upscalers/include/ffx_upscale.h',
    root/'scripts/build-fsr-translator.sh',
]
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
data = {
    'schemaVersion': 1,
    'architecture': 'x86_64',
    'deploymentTarget': '14.0',
    'sources': [{'path': str(path.relative_to(root)), 'sha256': sha(path)} for path in sources],
    'artifacts': {
        'upscaler_pe': {'path': str(upscaler_pe), 'sha256': sha(upscaler_pe)},
        'upscaler_unix': {'path': str(upscaler_unix), 'sha256': sha(upscaler_unix)},
        'framegeneration_pe': {'path': str(fg_pe), 'sha256': sha(fg_pe)},
        'framegeneration_unix': {'path': str(fg_unix), 'sha256': sha(fg_unix)},
    },
}
manifest.write_text(json.dumps(data, indent=2) + '\n')
PY

printf '%s\n' "$upscaler_pe" "$upscaler_unix" "$fg_pe" "$fg_unix"
