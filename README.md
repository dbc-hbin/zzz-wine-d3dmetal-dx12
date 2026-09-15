# zzz-wine-d3dmetal-dx12

**English** | [한국어 (Korean)](README.ko.md)

Optimized Wine 11.17 runtime source code and easy 1-click GUI installer for playing **Zenless Zone Zero (ZZZ)** with **Direct3D 12 (Apple GPTK 4.0b2)** on macOS (Apple Silicon) via **Yaagl ZZZ OS**.

The installer installs the included prebuilt Wine package and registers **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`** in Yaagl's Wine menu.

**Deployment target: macOS 26.0 or later on Apple Silicon, with Rosetta 2.** v1.0.5 rebuilds 45 Wine artifacts from fresh build directories, including the cursor ownership/RawInput separation change; the seven rebuilt native modules target macOS 26.0 using SDK 26.5. The remaining Wine files are inherited from the pinned P3 package. Other tuned patches, native PSO caching, and `D3DM_MTL4=1` are unchanged.

`libdxccontainer.dylib` is required by D3DMetal for DXIL container parsing and DXBC/HLSL conversion. Its original Apple binary is retained byte-for-byte, including its recorded minimum version of 26.4; no 26.4-only imported API was identified. The Wine configuration batch and DX12 graphics/compute/ray-tracing GPU readbacks passed on macOS 27. **Execution on macOS 26 hardware has not yet been verified.**

---

## ⚡ Quick Start (Easy 1-Click GUI Installer)

You do not need to build from source. An easy native macOS GUI installer is included to set up everything automatically.

### Option 1: Native GUI Installer (Recommended)
1. Download [ZZZWineDX12Installer.zip](https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases/latest/download/ZZZWineDX12Installer.zip).
2. Extract the zip and open **`ZZZ Wine DX12 Installer.app`**.
3. The app automatically detects your Yaagl ZZZ OS app and data folders.
4. Quit Yaagl ZZZ OS, then click **`Install Wine 11.17 ZZZ DX12`**. When this Wine is already selected, the action reads **`Reinstall / Update Wine`**.
   - Installs the included prebuilt Wine runtime archive for Yaagl.
   - Registers **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`** in Yaagl's Wine menu.
   - Backs up Yaagl's resources, Wine selection, and Wine directory so the prior configuration can be restored.
5. Launch Yaagl ZZZ OS and select the installed Wine runtime from its Wine menu!

The included archive remains in Yaagl's local runtime storage, so you can select this Wine runtime or switch back to another Wine runtime from Yaagl's Wine menu while offline. The installer does not require Node.js.

**The same Wine name and ID can be reinstalled.** The new installer's bundled archive replaces both the cached archive and the Wine directory; an identical name is not treated as proof that the installed files are current. Replacement does not leave obsolete files behind. If final Wine-selection activation fails, the runtime and selection from immediately before this attempt are restored, while the original restore backup remains intact. Update means **replace with the build bundled in the installer being run**, not an automatic online search for the latest Wine.

### Separate packages for upstream Yaagl

The integration in [Yaagl PR #759](https://github.com/yaagl/yet-another-anime-game-launcher/pull/759) uses two v1.0.5 assets: `wine-11.17-zzz-core-macos26.tar.xz` (root `wine/`) and `d3dmetal-gptk4b2-zzz-v1.0.5.tar.xz` (a relative `lib/` overlay). Yaagl downloads and caches the backend separately and installs it into the extracted Wine directory before Wine initialization. These are a matched pair, not an arbitrary Wine/backend compatibility guarantee. The existing all-in-one archive and GUI installer are unchanged.

Reproduce the split from the verified staged runtime with `bash scripts/package-wine-runtime-split.sh`. The script preserves compiled bytes, permissions, and symlinks, verifies reassembly and signatures, and exercises Wine initialization in a temporary prefix. In the upstream integration, ZZZ has an optional DirectX 12 setting, off by default; it is enabled only for a distribution declaring `supportsD3d12`.

### v1.0.5: rebuilt cursor/RawInput runtime and same-name upgrades

- The bundled Wine now includes `db45a95`: cursor ownership synchronization no longer changes pointer coordinates, and corrected RawInput deltas travel independently. Matching Wine client/server modules were rebuilt together for server protocol **966**.
- The Wine menu name and runtime ID stay unchanged. Run the v1.0.5 installer to replace an existing same-name runtime and cached archive with the new build. Quit Yaagl and its Wine/game processes first.
- Registration preserves other Wine catalog entries, including older D3DMetal builds. Failed final activation restores the runtime and selection from immediately before that install attempt without consuming the original restore backup.
- The extracted release ZIP passed nine installer/update/restore scenarios, three DX12 launch regression checks, and an upgrade from the actual previous protocol-965 archive that replaced all four coupled native modules (`wineserver`, `ntdll`, `winemac`, `win32u`).
- The final archive passed isolated D3D12 graphics, compute, and ray-tracing GPU readbacks on macOS 27. Cold-start cursor requests, layered-window ownership, and the post-Escape capture transition were exercised in real isolated Wine windows. The cursor captures did not establish macOS native activation or custom-cursor pixels, so they are not a first-native-activation pixel pass or a confirmed invisible-cursor regression. Synthetic pointer input produced no physical RawInput callback; native cursor pixels and the first physical mouse delta remain unverified.
- The earlier fix for the macOS arrow remaining instead of the game cursor is retained in v1.0.5. The previously reported native-overlay P2 classification is withdrawn: source-level arrow-setter calls alone did not establish an unintended native cursor overwrite.

### v1.0.4: DX12 launch argument delivery

- Preserve the selected distribution identity in the actual Wine runner and add `-use-d3d12` **only for `Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**. Earlier installers checked an absent runner `id`, so a successfully applied patch could still omit the argument.
- Forward game arguments through both normal and Steam-patch launches. Other D3DMetal Wine distributions are not forced to DX12.
- Replace the old ID guard and the legacy local backend-wide guard with the scoped condition; repeated installation does not duplicate the argument.

**The latest installer includes these launcher fixes; replacing the Wine archive alone does not apply them.** v1.0.4 rebuilt the installer and update helper but retained the v1.0.2/v1.0.3 Wine archive. v1.0.5 replaces that archive with the rebuilt cursor/RawInput runtime. DX12 execution on physical Tahoe hardware remains unverified.

### v1.0.3: launcher updates and restore

v1.0.3 changes the installer only. The bundled macOS 26 Wine archive and tuning are unchanged from v1.0.2.

- Registration patches the active `resources.neu` in Yaagl’s data folder, not the app bundle. App resources and legacy app backups remain untouched; startup synchronization cannot copy the older app resource over the registered frontend.
- A native helper in `.zzz-wine-registration` registers Wine in downloaded in-app updates before they replace the active frontend. It runs only during installation or an in-app update; there is no background service and Node.js is not required. Unsupported frontend layouts or helper failures stop the update before replacement.
- Restore uses the pristine resource for the currently registered generation, never an older whole-resource backup. Preparing another update does not change the active generation’s restore point.

If an earlier installer already downgraded Yaagl, update Yaagl to the desired version first, quit it, then use the latest installer. Full app replacements or externally replaced resources can bypass the in-app hook; run the installer again after those changes.

### Option 2: Terminal CLI
```bash
./installer/zzz-wine-installer --install \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"

# Restore the previous Wine directory
./installer/zzz-wine-installer --restore \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"
```

---

## 🚀 Key Optimizations & Patches

This build integrates several targeted patches into upstream Wine 11.17 to ensure maximum performance and stability for ZZZ on Apple Silicon.

### 1. Direct3D 12 & Apple GPTK 4.0b2 Integration
- Integrated with Apple's Game Porting Toolkit 4.0b2 D3DMetal and Metal IR translation layer.
- Fast, high-accuracy translation of DirectX 12 rendering pipelines into native Metal APIs.

### 2. Apple Silicon Native ARM64 Wineserver (`0002-native-x86-server.patch`)
- Upstream x86_64 Wine runs `wineserver` through Rosetta 2 translation, which introduces significant system-call and IPC latency.
- This build runs `wineserver` natively on Apple Silicon (ARM64), drastically reducing thread synchronization and inter-process communication overhead.

### 3. High-Performance MSync Fast Paths (`0001`, `0003`, `0007`, `0012`)
- Maps Windows synchronization primitives (Mutexes, Events, Semaphores) directly onto low-overhead macOS Mach semaphores and shared memory.
- Minimizes thread wait times and kernel context-switch penalties during heavy multi-threaded rendering.

### 4. Metal PSO Cache & Cache Warmup (`libYaaglNativePsoCache`)
- Dedicated native cache layer to eliminate in-game **micro-stutters** caused by runtime pipeline state object (PSO) and shader compilation.
- Dedupes shader compilation and retains compiled PSOs across the device lifetime.
- Cache warmup ensures smooth combat and scene transitions from the very first run.

#### Experimental NGX exposure correction and diagnostics

`YAAGL_METALFX_EXPOSURE_SCALE_FIX=1` opts in to a narrowly scoped experimental correction. For manual-exposure HDR evaluations with no auto-exposure and no caller-provided exposure texture, a finite positive `DLSS.Exposure.Scale` other than `1` is represented by an internal 1×1 `R16Float` exposure texture. Existing exposure textures and `DLSS.Pre.Exposure` are left untouched; missing scale, `0`, and `1` are skipped. The correction is off by default. It does not claim NVIDIA-equivalent output and is not a jitter fix.

Set `YAAGL_METALFX_DIAGNOSTICS=1` and `YAAGL_METALFX_LOG` to an absolute path to emit bounded JSONL diagnostics. The log is created with mode `0600` and stops after 8,192 events. Events trace public API entry through the internal evaluation, recorded command, and replay/encode stages, with post-encode MetalFX properties where available. Correlation identifiers are diagnostic record/command identities, not engine frame IDs or proof of GPU completion. A legacy `Unsupported feature` warning from the original implementation may remain even when evaluation and GPU output succeed.

### 5. Cursor Ownership & RawInput Separation (`0004-macdrv-reset-rawinput-baseline.patch`)
- Preserves native cursor display and window routing while making ownership synchronization independent of cursor position.
- Sends warp-corrected mouse deltas separately from pointer coordinates, preserving fractional motion and event coalescing without dropping the first real movement.
- The v1.0.5 bundled runtime uses server protocol **966** with matching Wine client/server modules. Do not replace only `winemac` or combine it with the older protocol-965 server.
- Run `node scripts/wine-mac-cursor-input-regression.mjs` for extracted-production input checks. These do not replace native cursor-pixel or in-game camera verification.

### 6. Media, Audio, Window & System Resource Tuning (`0005`, `0006`, `0008` ~ `0014`)
- **Media Playback**: GStreamer and Media Foundation optimizations prevent cutscene stutters.
- **Low-Latency Audio**: Refined CoreAudio buffering reduces audio delay.
- **Window & Network**: Tuned window message queue and socket handling for faster response.

---

## 📂 Repository Structure

```
zzz-wine-d3dmetal-dx12/
├── external/               # Original Apple GPTK 4.0b2 D3DMetal.framework
│   └── D3DMetal.framework  # D3DMetal binary and libmetalirconverter.dylib
├── dlls/                   # Wine 11.17 modified DLL sources
├── server/                 # ARM64 native wineserver & msync implementation
├── include/                # Additional headers (msync.h, server_protocol.h)
├── d3dmetal-pso-cache/     # libYaaglNativePsoCache Objective-C++ source
├── patches/                # Full patch series (0001 ~ 0014)
│   ├── wine-tuned/         # 14 tuned performance and bugfix patches
│   └── wine-p3/            # Baseline host msync & D3DMetal bridge patches
├── scripts/                # Wine build and packaging scripts
└── installer/              # SwiftUI native installer source & build artifacts
    ├── ZZZ Wine DX12 Installer.app  # Pre-built native macOS app bundle
    ├── zzz-wine-installer           # CLI binary
    ├── RuntimePackage.swift         # Prebuilt Wine package metadata
    ├── AsarPatcher.swift            # Yaagl Wine menu registration patcher
    ├── InstallerEngine.swift        # Auto-detect, install, register & restore engine
    ├── ContentView.swift            # SwiftUI interface
    └── resources/typescript.js      # Bundled JavaScript compiler for menu patching
```

---

## 🛠️ Building From Source

### Prerequisites
- macOS 26.0 or later (Apple Silicon M-series), Rosetta 2, and a macOS 26 SDK
- Xcode Command Line Tools (`xcode-select --install`)
- LLVM MinGW toolchain (`/opt/llvm-mingw-...`)
- Bison, Pkg-config, GStreamer dependencies
- Prepared P3 source, host, dependency tree and provenance; a local GPTK overlay and Steam helper payload. These external build inputs are not downloaded by this repository.

### Build Commands
```bash
# Set these to your existing, verified local input directories.
export WINE_P3_ROOT="/absolute/path/to/prepared/wine-p3"
export YAAGL_STEAM_HELPER_DIR="/absolute/path/to/protonextras"
export GPTK_SOURCE="/absolute/path/to/gptk-overlay/wine"
export MACOSX_DEPLOYMENT_TARGET=26.0
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
export WINE_PACKAGE_NAME=wine-11.17-zzz-dx12-gptk4b2-macos26
export WINE_RUNTIME_ID=11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server

# 1. Build the Wine overlay in fresh build/wine-tuned directories.
./scripts/build-wine-tuned.sh all

# 2. Build the native PSO module and package all runtime dependencies.
./scripts/package-wine-p3-runtime.sh build/wine-tuned/host "$GPTK_SOURCE" \
  build/wine-tuned/provenance.json build/wine-tuned/package

# 3. Build GUI Installer
./installer/build.sh
```

### Build and run the NGX smoke fixture

The fixture requires external headers from the official NVIDIA NGX SDK (the include directory containing `nvsdk_ngx.h`) and LLVM-MinGW. The SDK headers are not vendored. The small MSVC-target object is required because the NGX parameter interface uses the Microsoft C++ ABI; the remaining fixture uses the MinGW target for the Windows libraries.

```bash
C=/path/to/llvm-mingw/bin/clang++
NGX_SDK_INCLUDE=/path/to/NVIDIA-NGX-SDK/include

"$C" --target=x86_64-pc-windows-msvc -std=c++20 -fno-exceptions -fno-rtti \
  -Wall -Wextra -Werror -I"$NGX_SDK_INCLUDE" \
  -c d3dmetal-pso-cache/ngx-smoke-msvc.cpp -o build/ngx-smoke-msvc.obj
"$C" --target=x86_64-w64-mingw32 -std=c++20 -Wall -Wextra -Werror \
  -static -Wl,--stack,8388608 -I"$NGX_SDK_INCLUDE" \
  d3dmetal-pso-cache/ngx-smoke.cpp build/ngx-smoke-msvc.obj \
  -ld3d12 -ldxgi -luuid -o build/ngx-smoke.exe
```

Run this executable only with a disposable, isolated Wine prefix and a copied test runtime—never a game or user prefix. Success is exit status 0 plus `NGX_SMOKE_PASS`. The packaged Wine wrapper forces `D3DM_MTL4=1`; when deliberately exercising the legacy path, bypass it with that isolated runtime's `wine.real` and the required legacy environment instead of setting `D3DM_MTL4=0` on the wrapper.

The installer build requires the new `build/wine-tuned/package/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz` archive (or an explicit `RUNTIME_ARCHIVE_SOURCE`). It does not silently bundle an older installed runtime.

### DX12 launch regression tests

```bash
node --test scripts/test-dx12-launch-regression.mjs
```

The checked-in fixture contains excerpts of Yaagl 0.3.18 source; no Wine build output, separate download, or Git history is required. The suite creates runners from the actual transformed catalog and covers normal/Steam launches, preservation of other Wine entries, and migration of both the old ID guard and the backend-wide guard. It does not launch the game or exercise a GPU.

---

## 📄 License

- Wine source code is licensed under the **GNU Lesser General Public License (LGPL v2.1+)**.
- D3DMetal wrapper components and installer tools are licensed under the terms included in this repository.
