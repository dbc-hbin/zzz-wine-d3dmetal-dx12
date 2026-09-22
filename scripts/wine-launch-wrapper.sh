#!/bin/sh
set -u

wrapper_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
real_wine="$wrapper_dir/wine.real"
if [ ! -x "$real_wine" ]; then
  echo "YAAGL local D3DMetal runtime: missing $real_wine" >&2
  exit 126
fi

wine_root=$(CDPATH= cd -- "$wrapper_dir/.." && pwd)

# Fixed public profile: GPTK D3DMetal, Metal 4/DXR/MetalFX, RX 9070 identity.
# Keep WINE_ENABLE_TIMEOUT_FIX aligned with src/wine/d3dmetal.ts launch contract.
export WINE_ENABLE_TIMEOUT_FIX=1
export CX_ACTIVE_GRAPHICS_BACKEND=d3dmetal
export D3DM_MTL4=1
export D3DM_ENABLE_METALFX=1
export D3DM_SUPPORT_DXR=1
export D3DM_VENDOR_ID=0x1002
export D3DM_DEVICE_ID=0x7550
export D3DM_DEVICE_DESCRIPTION="AMD Radeon RX 9070"
export WINEMSYNC=1
unset WINEDLLOVERRIDES WINEDLLPATH_PREPEND DXMT_CONFIG DXMT_CONFIG_FILE
unset DXVK_CONFIG_FILE DXVK_STATE_CACHE_PATH VK_ICD_FILENAMES VK_DRIVER_FILES
unset DYLD_INSERT_LIBRARIES

# P3 packaged runtime only: load bundled MacDeps/GStreamer without build/deps paths.
# Legacy (non-P3) wrappers must keep prior env behavior unchanged.
if [ -f "$wine_root/yaagl-wine-p3-runtime.txt" ]; then
  wine_lib="$wine_root/lib"
  export CX_APPLEGPTK_LIBD3DSHARED_PATH="$wine_lib/external/libd3dshared.dylib"
  gst_root="$wine_lib/GStreamer.framework/Versions/1.0"
  dyld_fallback="$wine_lib"
  if [ -d "$gst_root/lib" ]; then
    dyld_fallback="$gst_root/lib:$dyld_fallback"
  fi
  if [ -n "${DYLD_FALLBACK_LIBRARY_PATH:-}" ]; then
    export DYLD_FALLBACK_LIBRARY_PATH="$dyld_fallback:$DYLD_FALLBACK_LIBRARY_PATH"
  else
    export DYLD_FALLBACK_LIBRARY_PATH="$dyld_fallback"
  fi
  if [ -d "$gst_root/lib/gstreamer-1.0" ]; then
    export GST_PLUGIN_SYSTEM_PATH_1_0="$gst_root/lib/gstreamer-1.0"
  fi
  if [ -x "$gst_root/libexec/gstreamer-1.0/gst-plugin-scanner" ]; then
    export GST_PLUGIN_SCANNER="$gst_root/libexec/gstreamer-1.0/gst-plugin-scanner"
  fi
fi

has_zzz=0
has_config_batch=0
for argument in "$@"; do
  case "$argument" in
    *ZenlessZoneZero.exe*) has_zzz=1 ;;
    *config.bat*) has_config_batch=1 ;;
  esac
done

restore_d3dmetal_modules() {
  module_dir="$wrapper_dir/../lib/wine/x86_64-windows"
  for module in d3d10core.dll d3d11.dll dxgi.dll; do
    # Original Yaagl temporarily moves the packaged module to .bak and installs
    # DXMT before launching. Copy the saved D3DMetal module back for this run;
    # keep .bak so Yaagl's normal patchRevertProgram remains valid afterwards.
    if [ -f "$module_dir/$module.bak" ]; then
      cp "$module_dir/$module.bak" "$module_dir/$module" || return 1
    fi
  done
}

# Direct and steam-wrapper launches expose the game executable in argv.
if [ "$has_zzz" -eq 1 ]; then
  restore_d3dmetal_modules || exit 124
  exec "$real_wine" "$@"
fi

# Original Yaagl launches `cmd /c Z:\...\config.bat`; inspect its standard
# generated file only to select the D3DMetal modules. Renderer arguments remain
# entirely owned by the launcher configuration.
if [ "$has_config_batch" -eq 1 ] && [ -n "${WINEPREFIX:-}" ]; then
  support_root=$(dirname -- "$WINEPREFIX")
  source_batch="$support_root/config.bat"
  if [ -f "$source_batch" ] && grep -q 'ZenlessZoneZero\.exe' "$source_batch"; then
    restore_d3dmetal_modules || exit 124
    exec "$real_wine" "$@"
  fi
fi

exec "$real_wine" "$@"
