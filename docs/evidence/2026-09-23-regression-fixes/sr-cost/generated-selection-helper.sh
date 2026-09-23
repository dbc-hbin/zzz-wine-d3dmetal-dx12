#!/bin/sh
set -eu
case "${YAAGL_FSR_UPSCALER:-metalfx}" in
  metalfx) export WINEDLLOVERRIDES=amd_fidelityfx_upscaler_dx12,amd_fidelityfx_framegeneration_dx12=b ;;
  native) export WINEDLLOVERRIDES="amd_fidelityfx_upscaler_dx12=n;amd_fidelityfx_framegeneration_dx12=b" ;;
  *) echo "YAAGL_FSR_UPSCALER must be metalfx or native" >&2; exit 64 ;;
esac
export MTL_CAPTURE_ENABLED=0
runtime_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
export YAAGL_FSR_FG_NATIVE_DLL="Z:$runtime_root/lib/wine/x86_64-windows/amd_fidelityfx_framegeneration_dx12_native.dll"
exec "$@"

