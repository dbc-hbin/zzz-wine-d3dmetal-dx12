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

#### FSR → MetalFX private runtime with MetalFX frame interpolation

The FSR translator development profile exposes an AMD Radeon RX 9070 (`0x1002:0x7550`) and overrides the canonical upscaler and frame-generation DLLs with builtins. Upscaling remains the existing FSR API → MetalFX path. Frame-generation effect `0x20000` is translated to MetalFX frame interpolation when the actual command-buffer mode and Apple support predicate allow it; swapchain effect `0x30000`, explicit native-version selection, and unsupported conditions are forwarded to the original AMD implementation. The original loader is unchanged.

```bash
python3 scripts/stage-runtime.py --wine-source <seed-wine> --wine-dest <private-wine> \
  --patched-d3dmetal <validated-patched-D3DMetal> --build-dir <private-build> --play --fsr-translator
python3 scripts/stage-runtime.py --verify-runtime <private-wine> --current-sources
```

Staging reads the installed original `amd_fidelityfx_framegeneration_dx12.dll` without modifying it, verifies its pinned SHA-256, x86-64 PE architecture, and five exports, then copies it read-only under the private non-canonical name `amd_fidelityfx_framegeneration_dx12_native.dll`. The last-hop helper binds `YAAGL_FSR_FG_NATIVE_DLL` to that runtime’s absolute path; the proxy loads it explicitly, not via its virtual `C:\windows\system32` builtin module name. This prevents recursive canonical loading. The manifest records source provenance and signed hashes. `WINEDLLOVERRIDES` selects only the canonical upscaler and frame-generation builtins; it does not override the loader or the renamed native fallback.

Frame interpolation requires macOS 26 or newer. Selection is deferred until the first Prepare resolves the real Metal device and command-buffer mode: legacy uses Apple’s `supportsDevice:` and device-only factory; Metal4 uses `supportsMetal4FX:` and the compiler-taking factory. A Metal4 command buffer is never passed to the legacy effect. Unsupported matching-mode support/factory creation or unsupported FSR input contracts select the original FSR provider before translation is active. Explicit original-provider IDs remain available. Once translation has recorded work, errors do not trigger a second, native interpolation pass.

The original FSR swapchain continues to own swapchain creation/wrapping, presentation timing, registered UI resources, custom present callbacks, pacing, and delegated swapchain queries. Prepare snapshots depth and motion on the caller’s command list; interpolation keeps private previous-color history and writes back on the supplied interpolation command list. With HUD-less input, the HUD-less resource is the MetalFX scene color and the composited presentation color supplies the UI relationship; MetalFX decomposes and recomposites that UI, while a separately registered swapchain UI remains in the original post-composition path and is not submitted twice. Per-frame HUD-less resources are retained across asynchronous Configure/Prepare/Dispatch work.

Prepare retains raw active depth/motion snapshots; generation normalizes their complete domains into rectangle-sized MetalFX inputs, rather than cropping a display-sized intermediate. Metal4 compute parameter buffers are included in residency before encoding. The configuration cache holds at most eight variants; luminance and rectangle-origin changes reset history without creating new factories, and in-flight work retains evicted configurations until completion.

Frame-generation Prepare follows the pinned SDK camera defaults: finite nonpositive `viewSpaceToMetersFactor` values use a scale of `1.0`, and `cameraFar` is ignored when infinite depth was selected at context creation. Finite-depth planes must be positive, finite, and distinct; their order is normalized with min/max before both MetalFX and projection-matrix construction. Reversed depth remains a separate flag, so inputs such as `cameraNear=5000`, `cameraFar=0.1` are valid without inverting the depth texture. Non-finite scales remain invalid. Both Prepare V1 and V2 use this contract.

FG failures include a bounded operation/stage and input summary. `YAAGL_FSR_LOG=<absolute path>` records the first MetalFX encode with its actual command mode and normalized planes (`farPlane: null` for infinite depth). Opt-in `WINEDEBUG=trace+yaagl_fsr_fg` records up to 120 generation and generated-frame present callback results each; these report encoding/callback progress, not GPU completion or a performance measurement.

Self-contained verification (does not launch the game):

```bash
python3 scripts/test-metalfx-native.py --out <native-evidence>
python3 scripts/test-fsr-launch-profile.py
python3 scripts/test-fsr-translator.py --runtime <private-wine> --out <upscaler-evidence>
python3 scripts/test-fsr-translator.py --frame-generation --command-buffer metal4 \
  --runtime <private-wine> --out <fg-metal4-evidence>
python3 scripts/test-fsr-translator.py --frame-generation --command-buffer legacy \
  --runtime <private-wine> --out <fg-legacy-evidence>
```

The isolated FG smoke passes in both actual Metal4 and legacy command-buffer modes. It checks GPU-readback intermediates against moving-pattern midpoints, Prepare V1 with absent or extended camera information, Prepare V2 embedded camera data, explicit resets and frame-ID gaps, pending-state rejection stability, display-resolution and jittered motion-vector normalization, signed partial generation rectangles, HUD-less scene/UI composition, sRGB/PQ/scRGB transfer handling, native-provider override and native-only fallback, create-time debug checking with the configured callback, and a real DXGI swapchain with 70 disabled frames followed by interpolation callbacks. It also drains presents before context destruction. These isolated checks did not launch the game and do not establish game-specific visual quality or support on untested older hardware.

Frame generation accepts display-resolution and jittered motion vectors with the pinned FidelityFX normalization and jitter-cancellation sign. Prepare V1 may omit CameraInfo or carry its single optional extension; Prepare V2 carries camera data directly. Non-consecutive frame IDs and explicit resets reset history. Generation rectangles retain signed coordinates: only width and height both zero select the full display, while a partial rectangle maps its top-left to depth/motion coordinate (0,0). sRGB, PQ, and scRGB transfers preserve their defined luminance conversions and reject non-finite or invalid ranges. Distortion fields, AMD debug shader views/tear/reset overlays, custom DX12 backend allocation callbacks, more than one generated output in the MetalFX path, and exact translated GPU-memory accounting remain unsupported. Before MetalFX selection these native-only features may select the original provider; after selection they return an explicit error rather than being ignored or double-dispatched.

On every Mac, temporal scaling uses the system-default MetalFX model. Private BBR forcing, BBR fallback policy, and V4 model overrides are not used. The FSR API adapter follows the pinned provider's null-output query no-op behavior and identifies a logical D3D12 device by `ID3D12Device::GetAdapterLuid`, not raw COM tear-off pointer equality; command lists and resources must report the same adapter LUID. This validates the available single-adapter runtime but is not a physical multi-adapter test. The translator runs MetalFX rather than AMD's FSR4 neural network. For Ultra Performance only when the requested output exceeds MetalFX's 3× temporal limit, the translator keeps the caller's output texture and computes one uniform scale `s = min(device maximum, output width / input width, output height / input height)`, uses `floor(input width × s)` by `floor(input height × s)` for MetalFX, then centers that result and clears the unused margins to black (an odd remainder stays on the opposite edge). This applies dynamically to 1080p, 1440p, 4K, odd-sized outputs, and resolution changes; for example, 1248×696 into 3840×2160 runs MetalFX at 3744×2088 at (48,36), leaving 48-pixel horizontal and 36-pixel vertical borders. The current 4K display is the only physical monitor exercised; 1080p, 1440p, odd dimensions, and resolution switching are GPU/backend scenario checks, not claims about other physical monitors. It does not expose an input-size control or add a spatial scaling pass; dispatches at or below 3× keep the existing full-frame path. Existing releases and installed runtimes are not updated automatically; stage and run only a private copy.

Upscaling accepts backing textures larger than the current active input/output. MetalFX receives exact active-sized resources; GPU staging is used only when needed, and output writes preserve texels outside the caller’s active rectangle. Both low-resolution and display-resolution motion vectors follow this rule. Disabled sharpening accepts an unused finite sharpness in `[0,1]` without running RCAS. Jitter phase queries use the pinned SDK’s truncation (1600→2000 yields 12), and a null dispatch descriptor returns `FFX_API_RETURN_ERROR_PARAMETER`.

#### Remaining frame-generation verification boundaries

**P2 fix:** notifying Configure calls reuse the immutable binding while the application callback functions and user contexts are unchanged, avoiding unnecessary presenter drains. Actual callback changes still retire the old binding through the native swapchain, and pending per-frame HUD-less snapshots survive ordinary Configure calls. This is a pacing/lifetime correction, not a measured FPS or image-quality improvement. The remaining items below are unverified risks.

The real DXGI regression holds an active generation callback while submitting the next frame configuration: unchanged callbacks must configure without draining that frame. It also checks callback handoff and queued HUD-less resource lifetime with steady-state GPU midpoint readback. The same fixture reproduces the old drain and passes on the corrected Metal4 and legacy runtimes; reset/warm-up frames are not mistaken for steady-state interpolation.

- Current synthetic coverage uses uniform depth and a single global motion vector. It does not exercise disocclusion or mixed foreground/background motion, and it does not reproduce the game's observed 2256×1272 render-resolution motion vectors feeding a 3840×2160 output.
- Depth and motion vectors are currently expanded with nearest sampling before interpolation. Whether this is better or worse than giving MetalFX its native low-resolution inputs requires an A/B comparison; it is not a known quality bug.
- The descriptor's nullable `scaler` is not linked. Apple's WWDC25 session 211 sample at 8:35 links a scaler, but that is an architectural difference, not proof of a quality defect here.
- Jitter units remain unresolved when the input color is already temporally upscaled. Do not blindly rescale the jitter or replace it with zero; first capture the producer's actual convention and compare temporally stable scenes.
- Logical scratch allocated per Generate is approximately 190 MiB without UI and 253 MiB with UI at 4K, based on the RGBA16F, R32F, and RG16F texture dimensions. These are logical allocation sizes, not measured resident memory, bandwidth, latency, or frame-time cost.
- Generation and generated-frame present logs each stop after 120 callbacks, not 120 game frames. They do not record the OFF transition or prove that generation stopped after that transition; a lingering HUD label is not proof that generation continued.

Next verification should use game captures with disocclusion and mixed motion at 2256×1272→3840×2160, A/B nearest-expanded versus native low-resolution depth/MV inputs, record the actual jitter convention, profile resident memory and GPU time, and explicitly observe OFF transitions and subsequent generation activity beyond the callback log limit. Until those checks are complete, this path carries no FPS or image-quality guarantee.

#### Experimental NGX exposure correction and diagnostics

`YAAGL_METALFX_EXPOSURE_SCALE_FIX=1` opts in to a narrowly scoped experimental correction. For manual-exposure HDR evaluations with no auto-exposure and no caller-provided exposure texture, a finite positive `DLSS.Exposure.Scale` other than `1` is represented by an internal 1×1 `R16Float` exposure texture. Existing exposure textures and `DLSS.Pre.Exposure` are left untouched; missing scale, `0`, and `1` are skipped. The correction is off by default. It does not claim NVIDIA-equivalent output and is not a jitter fix.

Set `YAAGL_METALFX_DIAGNOSTICS=1` and `YAAGL_METALFX_LOG` to an absolute path to emit bounded JSONL diagnostics. The log is created with mode `0600` and stops after 8,192 events. Events trace public API entry through the internal evaluation, recorded command, and replay/encode stages, with post-encode MetalFX properties where available. Correlation identifiers are diagnostic record/command identities, not engine frame IDs or proof of GPU completion. A legacy `Unsupported feature` warning from the original implementation may remain even when evaluation and GPU output succeed.

#### Experimental MetalFX frame probe (nameplate/NPC lag observation)

An opt-in, observation-only probe for the nameplate/NPC mismatch that appears around MetalFX temporal scaling. It hooks NGX evaluation, the completed MPL record, replay, and the native MetalFX encode, and emits `YAAGL.MFX`, `YAAGL.PASS`, and `YAAGL.draw` debug groups for GPU capture. It is off by default, changes no global jitter sign, motion scale, depth convention, or UI composition order, and does not modify shader or camera state. The older `YAAGL_METALFX_TEMPORAL` repair is not enabled in probe runs.

- `YAAGL_METALFX_FRAME_PROBE=1` — enable the probe.
- `YAAGL_METALFX_PROBE_DIR=<absolute private 0700 directory>` — output directory. It must be absolute, owned by you, mode `0700`, and not a symlink; anything else is refused.
- `YAAGL_METALFX_PROBE_RESET_HISTORY=1` — second, separate A/B run only; default off; not a fix.
- `MTL_CAPTURE_ENABLED=1` — required before Wine starts, and it needs full Xcode GPU tools, not Command Line Tools alone.

Stage the probe into an isolated copy. Never target the installed runtime, a game, or a user prefix:

```bash
python3 scripts/stage-runtime.py \
  --wine-source "$HOME/path/to/current/wine" \
  --wine-dest "$HOME/zzz-wine-frame-probe" \
  --pristine-d3dmetal <pristine GPTK 4.0b2 D3DMetal binary> \
  --probe-dir "$HOME/zzz-metalfx-probe" \
  --check
```

`--pristine-d3dmetal` must be a pristine GPTK 4.0b2 D3DMetal binary. The tool refuses anything whose SHA-256 is not `source.sha256` in `d3dmetal-pso-cache/layout.json` (`f8640e6b0974277068821d44bd398dcc0f42cbb730d07f3afad97843e72a6ea3`, Mach-O UUID `674e662b-6b5c-3fd9-9a8a-f415609d2f6a`), so never pass an already-patched binary or the installed runtime's own D3DMetal. After `--check` succeeds, run the same command without `--check`. It builds the x86_64 dylib, copies the runtime into a new directory, applies the existing 29-hook patch layout to that pristine binary, installs and signs the result, and writes a helper that sets the probe environment before `wine.real`. The installed Wine, game files, and remote repositories are not modified; an unsupported …

With DLSS enabled and the lagging NPC on screen:

```bash
python3 scripts/probe-control.py "$PROBE_DIR" list
python3 scripts/probe-control.py "$PROBE_DIR" capture --presentations 8 --timeout 15
python3 scripts/probe-control.py "$PROBE_DIR" stop

python3 scripts/analyze-probe.py "$PROBE_DIR/probe-<pid>-SESSION.jsonl"
```

`ready-<pid>.json` is written only for a process that actually observed MPL NGX evaluation; pass `--pid` when several candidates exist rather than letting a PID be guessed. Capture targets the whole device and slows frames while it runs. `capture requested` means the request was written only: require `capture_started` and `capture_stopped` in the log, and treat `capture_unavailable`, `NO_NATIVE_ENCODE`, and timeout exits as failures. The 8 presentations are presentation callbacks on the device, not a confirmed `Present[N]` count, so discard the first one or two frames and the last incomplete segment. The analyzer is run on exactly one process/run and writes `<log>.report.json` and `<log>.report.encodes.csv`; the writer is asynchronous and bounded at 64 Mi…

Open the `.gputrace` in Xcode and locate the `YAAGL.MFX` groups first; the matching JSON `encode_before` shows the actually bound color/output/depth/motion objects. Follow A, B, and C: **A** is the color the real MetalFX reads, **B** is the real MetalFX output, and **C** is the drawable texture actually used for presentation. `YAAGL.PASS` marks attachment/command-buffer linkage and `YAAGL.draw` marks candidate nameplate draws. Compare A/B/C resource state at those events in the native trace; the JSON does not carry texels.

Limits, stated explicitly:

- `eval_id`, `record_id`, `encode_id`, `object oid`, and `acquisition_id` are diagnostic identities, not engine frame IDs and not proof of GPU completion. `record_bytes_match` means the CPU command bytes agree only.
- The JSON proves CPU-side command bytes and bindings only. It cannot show MetalFX input texels, what a buffer means as a camera matrix, or which scene frame is late; repeated addresses do not mean identical image content.
- Capture changes timing, so a capture run is not an FPS benchmark and not a performance baseline.
- The probe does not fix or verify the nameplate lag and must not be presented as a fix. A requested capture is not a successful one.

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

Run this executable only with a disposable, isolated Wine prefix and a copied test runtime—never a game or user prefix. The GPU output check requires exit status 0 plus `NGX_SMOKE_PASS`, but this alone does not prove correct exposure binding. The packaged Wine wrapper forces `D3DM_MTL4=1`; to exercise Legacy, use the isolated runtime's `wine.real` with `D3DM_MTL4=0` and the same package-relative library environment rather than setting that variable on the wrapper.

For exposure regression checks, run with `YAAGL_METALFX_EXPOSURE_SCALE_FIX=1`, `YAAGL_METALFX_DIAGNOSTICS=1`, and `YAAGL_METALFX_LOG` pointing to a fresh absolute log path. Capture fixture stdout separately, then check the actual post-encode scaler bindings:

```bash
python3 scripts/check-ngx-exposure-log.py legacy "$LEGACY_LOG" "$LEGACY_STDOUT"
python3 scripts/check-ngx-exposure-log.py mpl "$MPL_LOG" "$MPL_STDOUT"
```

The checker is specific to the serialized smoke fixture. It verifies 1×1 R16Float fallback exposure, unchanged explicit exposure textures, no override for automatic/neutral exposure, and no invented reactive mask. The old Legacy `+0xb0/+0xb8` injection fails this check despite `NGX_SMOKE_PASS`; the corrected `+0x58` exposure binding passes. MPL must pass with both modules. Correction and diagnostics remain off by default.

The installer build requires the new `build/wine-tuned/package/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz` archive (or an explicit `RUNTIME_ARCHIVE_SOURCE`). It does not silently bundle an older installed runtime.

### Build and run the frame probe host tests

```bash
bash scripts/test-frame-probe-native.sh
python3 scripts/test-frame-probe-tools.py
```

`scripts/test-frame-probe-native.sh` builds and runs the portable C++ ledger test under ASan/UBSan and, on macOS, a CPU-only Objective-C mock of the probe's runtime hooks. The mock checks probe state transitions only; GPU capture and ZZZ are not covered. `scripts/test-frame-probe-tools.py` covers the analyzer, the capture control CLI, and the staging guards. The module build itself is the normal `node scripts/build-d3dmetal-pso-cache.mjs <out-dir>`, which now also compiles `d3dmetal-pso-cache/frame-probe.mm` and links QuartzCore.

### DX12 launch regression tests

```bash
node --test scripts/test-dx12-launch-regression.mjs
```

The checked-in fixture contains excerpts of Yaagl 0.3.18 source; no Wine build output, separate download, or Git history is required. The suite creates runners from the actual transformed catalog and covers normal/Steam launches, preservation of other Wine entries, and migration of both the old ID guard and the backend-wide guard. It does not launch the game or exercise a GPU.

---

## 📄 License

- Wine source code is licensed under the **GNU Lesser General Public License (LGPL v2.1+)**.
- D3DMetal wrapper components and installer tools are licensed under the terms included in this repository.


Wall time: 0.04 seconds

[Some lines truncated to 768 bytes. Read artifact://4289 for full output]