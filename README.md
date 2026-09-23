# zzz-wine-d3dmetal-dx12

**English** | [한국어 (Korean)](README.ko.md)

Wine 11.17 runtime source and a one-click GUI installer for playing **Zenless Zone Zero (ZZZ)** through **Direct3D 12 (Apple GPTK 4.0b2)** on Apple Silicon with **Yaagl ZZZ OS**.

The v1.1.0 public runtime identifies its graphics adapter as **AMD Radeon RX 9070** (`0x1002:0x7550`) and translates the game's FSR upscaling API to MetalFX. It does not ship a DLSS or NVIDIA NGX translation path. The installer registers **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`** in Yaagl's Wine menu.

**Requirements: macOS 26.0 or later on Apple Silicon and Rosetta 2.** Temporal upscaling uses the system-default MetalFX model on every Mac; the runtime does not force BBR or a private model version.

## Quick start

1. Download [ZZZWineDX12Installer.zip](https://github.com/dbc-hbin/zzz-wine-d3dmetal-dx12/releases/latest/download/ZZZWineDX12Installer.zip).
2. Extract it and open **`ZZZ Wine DX12 Installer.app`**.
3. Quit Yaagl and its Wine processes. Choose your launcher under **`Yaagl Target`**, then select **`Install Wine 11.17 ZZZ DX12`**. If the same runtime is already selected, the button reads **`Reinstall / Update Wine`**.
4. Start the selected Yaagl launcher and select **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`** from its Wine menu.

The installer detects the Yaagl application and support directories, installs its bundled archive, registers the runtime, and backs up Yaagl resources, the selected Wine, and the previous runtime directory. The archive remains in Yaagl's local runtime storage for offline selection, and the installer does not require Node.js.

A same-name runtime can be reinstalled. The bundled archive replaces both the cached archive and runtime directory instead of treating the matching name as proof that the files are current. If final Wine-selection activation fails, the installer restores the runtime and selection from immediately before that attempt without consuming the original restore backup. “Update” means replacing the runtime with the build bundled in the installer being run; it is not an online update check.

The current installer source (not yet included in existing release ZIPs) preserves a provable v1.0.5 forced-DX12 default on upgrade: it saves DX12 ON only when the old forced-launch rule is present, the same target D3DMetal runtime is selected and supports DX12, and no DX12 preference was stored. A saved OFF is never overwritten. Fresh and already settings-driven launchers retain their settings-based behavior; an ambiguous v1.1.x preference is not guessed from its value.

### Terminal installer

The target picker supports **Yaagl ZZZ OS**, **Yaagl ZZZ OS DX12 Beta** (global), and **Yaagl ZZZ DX12 Beta** (CN), including the [DX12 beta release](https://github.com/dbc-hbin/yaagl-ZZZ-DX12/releases). Each target uses its own matching `~/Library/Application Support/<launcher name>` directory; installing into a beta does not replace the stable launcher's Wine. Launch a newly installed Yaagl once to create its support directory, then quit it before using the installer. Stable is selected by default when installed; otherwise an installed beta is detected.

For a beta CLI install, pass `--app-path "/Applications/Yaagl ZZZ OS DX12 Beta.app"` (global) or `--app-path "/Applications/Yaagl ZZZ DX12 Beta.app"` (CN). Recognized app names infer the matching support directory; an explicit `--support-path` takes precedence for custom installations.

```bash
./installer/zzz-wine-installer --install \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"

./installer/zzz-wine-installer --restore \
  --app-path "/Applications/Yaagl ZZZ OS.app" \
  --support-path "$HOME/Library/Application Support/Yaagl ZZZ OS"
```

## v1.1.0 public runtime

### FSR upscaling to MetalFX

- The launch wrapper fixes the public graphics identity to AMD Radeon RX 9070 (`0x1002:0x7550`). It does not spoof an NVIDIA adapter. The FSR staging helper leaves the caller's `MTL_HUD_ENABLED` unchanged (including unset or empty); enable the Metal HUD explicitly when diagnosing a newly staged runtime.
- The builtin `amd_fidelityfx_upscaler_dx12` module implements the public FSR API boundary and translates accepted temporal-upscaling work to MetalFX. It does not execute AMD's FSR4 neural network.
- In newly staged runtimes, `YAAGL_FSR_UPSCALER=metalfx` (also the unset/empty default) selects that builtin upscaler; `YAAGL_FSR_UPSCALER=native` selects the game's original canonical upscaler DLL without a builtin fallback. This explicit SR comparison option survives the launch wrapper; it does not change the frame-generation provider policy. Other values stop before Wine launches. Existing release archives do not gain this option until rebuilt.
- Native AA and the Quality, Balanced, Performance, and Ultra Performance modes remain explicit game/provider choices. The translator does not silently select a quality mode. When a request exceeds MetalFX's maximum temporal scale, the MetalFX output is capped to a single uniform scale, centered in the caller's own output texture, and the surrounding texels are preserved.
- The game remains the source of truth for an explicit OFF selection. The runtime does not auto-enable upscaling or frame generation.
- All Macs use the system-default MetalFX temporal model. There is no hardware-name heuristic, mandatory BBR policy, or private model-version override.
- FSR exposure, reactive/composition masks, transfer functions, sharpening, reset, jitter, motion-vector scale, and active input/output extents are translated explicitly. Invalid or unsupported contracts return an error instead of becoming successful no-ops.

### Frame generation and native fallback

- The automatic frame-generation provider selects MetalFX interpolation only when the actual command-buffer mode and Apple's matching support checks accept the request.
- The original FSR provider continues to own swapchain creation and wrapping, presentation timing, pacing, registered UI resources, custom present callbacks, and delegated swapchain queries.
- Explicit native-provider selection stays native. Unsupported translation contracts fall back to the original provider before MetalFX records work. Once MetalFX has recorded work for a frame, an error does not run a second native interpolation pass.
- The packaged runtime binds its private, read-only native fallback by absolute path, preventing recursive canonical DLL loading. The original loader and native fallback are not overridden.
- An explicit OFF state remains off. A lingering HUD label is not evidence that frame generation continued.

### Translation contract details

- A logical D3D12 device is identified by `ID3D12Device::GetAdapterLuid`, not raw COM tear-off pointer equality. The command list and every resource must report the same adapter LUID; this validates the single-adapter runtime, not physical multi-adapter hardware.
- Backing textures larger than the current active input/output are accepted. MetalFX receives exact active-sized resources, GPU staging is used only when required, and output writes preserve texels outside the caller's active rectangle. Both low-resolution and display-resolution motion vectors follow this rule.
- Prepare V1 may omit camera information or supply its single optional camera extension; Prepare V2 carries camera data directly. Non-consecutive frame IDs and explicit resets reset history. Generation rectangles keep signed coordinates: only width and height both zero select the full display, and a partial rectangle maps its top-left to depth/motion coordinate (0,0).
- Frame-generation Prepare follows the pinned SDK camera defaults. Finite nonpositive `viewSpaceToMetersFactor` values use a scale of `1.0`, and `cameraFar` is ignored when infinite depth was selected at context creation. Finite-depth planes must be positive, finite, and distinct; their order is normalized with min/max. Reversed depth stays a separate flag, so inputs such as `cameraNear=5000`, `cameraFar=0.1` are valid without inverting the depth texture. Non-finite scales remain invalid.
- sRGB, PQ, and scRGB transfers preserve their defined luminance conversions and reject non-finite or invalid ranges. Disabled sharpening accepts an unused finite sharpness in `[0,1]` without running RCAS. Jitter phase queries use the pinned SDK's truncation (1600→2000 yields 12), and a null dispatch descriptor returns `FFX_API_RETURN_ERROR_PARAMETER`.
- Distortion fields, AMD debug shader views and tear/reset overlays, custom DX12 backend allocation callbacks, and more than one generated output per frame remain unsupported and return an error.
- Metal4 compute parameter buffers are included in residency before encoding. The configuration cache holds at most eight variants; luminance and rectangle-origin changes reset history without creating new factories, and evicted configurations are retained until in-flight work completes.
- Configure calls that only notify the swapchain reuse the immutable binding while the application callbacks and user contexts are unchanged, so they avoid unnecessary presenter drains; real callback changes retire the old binding through the native swapchain, and pending per-frame HUD-less snapshots survive ordinary Configure calls. This is a pacing/lifetime correction, not a measured FPS or image-quality improvement.

### Frame-generation verification boundaries

These items remain unverified risks; the path carries no FPS or image-quality guarantee until they are closed.

- Current synthetic coverage uses uniform depth and a single global motion vector. It does not exercise disocclusion or mixed foreground/background motion, and it does not reproduce the game's observed 2256×1272 render-resolution motion vectors feeding a 3840×2160 output.
- Depth and motion vectors are currently expanded with nearest sampling before interpolation. Whether this is better or worse than giving MetalFX its native low-resolution inputs requires an A/B comparison; it is not a known quality bug.
- The descriptor's nullable `scaler` is not linked. Apple's WWDC25 session 211 sample links a scaler, but that is an architectural difference, not proof of a quality defect here.
- Jitter units remain unresolved when the input color is already temporally upscaled. Do not blindly rescale the jitter or replace it with zero; first capture the producer's actual convention and compare temporally stable scenes.
- Logical scratch allocated per Generate is approximately 190 MiB without UI and 253 MiB with UI at 4K, based on the RGBA16F, R32F, and RG16F texture dimensions. These are logical allocation sizes, not measured resident memory, bandwidth, latency, or frame-time cost.
- Generation and generated-frame present logs each stop after 120 callbacks, not 120 game frames. They do not record the OFF transition or prove that generation stopped after it.

Next verification should use game captures with disocclusion and mixed motion at 2256×1272→3840×2160, A/B nearest-expanded versus native low-resolution depth/MV inputs, record the actual jitter convention, profile resident memory and GPU time, and explicitly observe OFF transitions and subsequent generation activity beyond the callback log limit.

### Optional, bounded logging

`YAAGL_FSR_LOG` is optional and must name an absolute path.

- Upscaling logs lifecycle/query/error events and successful dispatch metadata only for global dispatch IDs 1 through 120. Failed-frame detail has an independent cap of 120.
- Frame generation writes one `first_encode` JSON record to `YAAGL_FSR_LOG`. Frame-generation failures written to stderr stop after 120 records.
- The opt-in `WINEDEBUG=trace+yaagl_fsr_fg` channel records generation and generated-frame present callback results, each stopping after 120 entries.
- There is no unbounded normal per-frame log.
- Log entries report API, encode, or callback progress. They do not prove GPU completion, image quality, FPS, or an OFF transition.

The removed DLSS-only path is not a hidden compatibility option: the production bridge and build inventory no longer include NGX entry hooks, NGX reprojection helpers or smoke fixtures, DLSS exposure correction, temporal interception, or the old frame-probe implementation and controls. The two shared command-replay hooks required by FSR are isolated in `d3dmetal-replay-hooks.{hpp,mm}`; layout v9 contains 17 PSO/cache hooks plus these two replay hooks, without restoring DLSS translation.

**Unreleased source:** layout v10 adds a Metal4 queue-commit hook for GPU-completion retirement, bringing the dispatch table to 20 entries (17 PSO/cache, two replay, one commit). This requires rebuilding the paired D3DMetal patch and native sidecar; the existing release archives are unchanged.

The current source retires completed execution leases without waiting for allocator Reset, while retaining owner-based fallback for unsubmitted work or failed callback registration. SR also reuses compatible scaler capacity for smaller active inputs, with history resets and synchronized edge staging. [Measured memory results and limits](docs/screenshot-sr-analysis-2026-09-23.ko.md) distinguish bounded allocation reuse from immediate physical release and from the unverified game-wide memory difference.

### Verification status

Verified on macOS 27 / Apple M5 Pro:

- **v1.1.1 fixes a registration failure** where a Yaagl frontend this installer had already registered, but whose hash-keyed restore backup was missing, was rejected with “changed without a matching backup”. Registration now recovers a marker-free restore baseline from that frontend by removing only this installer's own updater hook and catalog entry; unrelated catalog entries, the frontend version, and the local-archive install path are preserved. Unrecognized or modified hooks still fail closed without touching the frontend. The Wine runtime bytes are unchanged from v1.1.0.
- Reproduction on a copy of the reported state: the v1.1.0 helper exited 1 with the reported message and changed nothing; the v1.1.1 helper completed, recorded the recovered baseline, and left the registered frontend byte-identical. Re-registering published bytes is idempotent; a mutated hook argument still exits 1 with the frontend preserved.
- The re-extracted full runtime passed FSR upscaling and frame-generation GPU checks in both Metal4 and legacy command-buffer modes, with Metal API Validation enabled.
- Normal-production DX12 graphics, compute, and ray-tracing GPU readbacks passed, including direct/indirect draws, blending, logic operations, MSAA, and duplicate/distinct D3D12 objects.
- MetalFX backend, quality, transport, and legacy-transport native suites passed. Native cache/stage-cache/key tests verified single-flight and object reuse, including graphics, compute, and RT key paths; production hit counters are not exposed or claimed measured. Actual DXGI enumeration of the production launcher reported `0x1002:0x7550`, **AMD Radeon RX 9070**.
- Core/backend archive reassembly matched the staged file inventory, bytes, modes, and symlinks. Signatures and isolated Wine initialization passed. The 45 declared tuned Wine core artifacts remain byte-identical to the verified v1.0.5 base; the FSR/native overlay was rebuilt.
- The re-extracted v1.1.0 installer ZIP passed deep/strict signature checks and all nine installer/update/restore/activation-failure scenarios using the actual preserved v1.0.5 archive. Three DX12 launch regressions and the relocated FSR launcher regression passed.
- The v1.1.1 installer ZIP passed deep/strict signature checks, bundles the unchanged v1.1.0 runtime, and passed all ten resource lifecycle scenarios, including the new lost-backup recovery scenario.
- The cursor ownership/RawInput source harness and isolated Win32 cold-start/layered-window cursor metadata checks passed. These are not native cursor-pixel or physical RawInput measurements.

**Limits:** Physical macOS 26 execution, native cursor pixels, and the first physical RawInput delta remain unverified. Apple’s original `libdxccontainer.dylib` is unchanged and still records minimum macOS 26.4. With optional Metal API Validation enabled, the generic MSAA resolve control triggers the same render-target-usage assertion in both untouched v1.0.5 and v1.1.0; this baseline validation limitation is not claimed fixed. Normal-production GPU readbacks pass. The frame-generation quality/performance limits above still apply.

## Historical release notes

### v1.0.5: rebuilt cursor/RawInput runtime and same-name upgrades

- v1.0.5 rebuilt 45 Wine artifacts from fresh build directories, including the cursor ownership/RawInput separation change. Seven rebuilt native modules targeted macOS 26.0 using SDK 26.5; the remaining Wine files came from the pinned P3 package. Other tuned patches, native PSO caching, and `D3DM_MTL4=1` were unchanged.
- Apple’s original `libdxccontainer.dylib` was retained byte-for-byte for D3DMetal DXIL container parsing and DXBC/HLSL conversion, including its recorded minimum version of 26.4. No 26.4-only imported API was identified. Wine configuration and isolated DX12 graphics, compute, and ray-tracing GPU readbacks passed on macOS 27; execution on macOS 26 hardware was not verified.
- The bundled Wine included `db45a95`: cursor ownership synchronization no longer changed pointer coordinates, and corrected RawInput deltas traveled independently. Matching Wine client/server modules were rebuilt together for server protocol **966**.
- The Wine menu name and runtime ID stayed unchanged. The v1.0.5 installer replaced an existing same-name runtime and cached archive with the new build while preserving other Wine catalog entries.
- Failed final activation restored the runtime and selection from immediately before the attempt without consuming the original restore backup.
- The extracted release ZIP passed nine installer/update/restore scenarios, three DX12 launch regression checks, and an upgrade from the previous protocol-965 archive that replaced all four coupled native modules (`wineserver`, `ntdll`, `winemac`, `win32u`).
- Cold-start cursor requests, layered-window ownership, and the post-Escape capture transition were exercised in isolated Wine windows. Those captures did not establish macOS native activation or custom-cursor pixels. Synthetic pointer input produced no physical RawInput callback, so native cursor pixels and the first physical mouse delta remained unverified.
- The earlier game-cursor fix remained present. The previously reported native-overlay P2 classification was withdrawn because source-level arrow-setter calls alone did not establish an unintended native cursor overwrite.

### v1.0.4: DX12 launch argument delivery

- v1.0.4 preserved the selected distribution identity in the actual Wine runner and added `-use-d3d12` only for **`Wine 11.17 ZZZ DX12 (GPTK4.0b2)`**. Earlier installers checked an absent runner `id`, so a successfully applied patch could still omit the argument.
- Game arguments were forwarded through both normal and Steam-patch launches. Other D3DMetal Wine distributions were not forced to DX12.
- The old ID guard and legacy backend-wide guard were replaced with the scoped condition; repeated installation did not duplicate the argument.
- These launcher fixes required the installer/update helper, not only the Wine archive. v1.0.4 retained the v1.0.2/v1.0.3 archive; v1.0.5 later replaced it with the rebuilt cursor/RawInput runtime. Physical Tahoe DX12 execution was not verified for those releases.

### v1.0.3: launcher updates and restore

v1.0.3 changed the installer only; its macOS 26 Wine archive and tuning were unchanged from v1.0.2.

- Registration patched the active `resources.neu` in Yaagl's data directory, not the app bundle. App resources and legacy app backups remained untouched.
- A native helper in `.zzz-wine-registration` registered the Wine in downloaded in-app updates before they replaced the active frontend. It ran only during installation or an in-app update; there was no background service and Node.js was not required.
- Restore used the pristine resource matching the currently registered generation instead of an older whole-resource backup.

If an older installer downgraded Yaagl, update Yaagl to the desired version, quit it, and run the current installer. Full app replacements or externally replaced resources can bypass the in-app hook, so run the installer again after those changes.

## Key runtime components

1. **Direct3D 12 and GPTK 4.0b2** — D3DMetal and Metal IR translate Direct3D 12 rendering to Metal.
2. **Native ARM64 wineserver** — avoids running the server through Rosetta and reduces synchronization/IPC overhead.
3. **MSync fast paths** — map Windows synchronization primitives to lower-overhead macOS mechanisms.
4. **Native PSO cache** — deduplicates shader compilation and retains compiled pipeline state objects across the device lifetime.
5. **Cursor ownership and RawInput separation** — keeps ownership synchronization independent from pointer coordinates and carries corrected motion deltas separately.
6. **Media, audio, window, and resource tuning** — retains the repository's GStreamer, Media Foundation, CoreAudio, window, and network patches.

## Repository structure

```text
zzz-wine-d3dmetal-dx12/
├── dlls/                   # Wine sources, including FSR upscaler/FG builtins
├── d3dmetal-pso-cache/     # Native PSO cache and FSR → MetalFX backend
├── external/               # Local GPTK framework input
├── include/                # Shared Wine/FSR bridge headers
├── installer/              # SwiftUI installer and CLI source
├── patches/                # Wine tuned and P3 patch series
├── scripts/                # Build, verification, staging, and packaging tools
└── server/                 # Native wineserver and MSync implementation
```

## Building from source

### Prerequisites

- macOS 26.0 or later on Apple Silicon, Rosetta 2, and a macOS 26 SDK
- Xcode Command Line Tools
- LLVM MinGW toolchain
- Bison, pkg-config, and GStreamer dependencies
- Prepared P3 source/host/dependency/provenance inputs, a local GPTK overlay, and the Steam helper payload; this repository does not download those external inputs

### Runtime and installer

```bash
export WINE_P3_ROOT="/absolute/path/to/prepared/wine-p3"
export YAAGL_STEAM_HELPER_DIR="/absolute/path/to/protonextras"
export GPTK_SOURCE="/absolute/path/to/gptk-overlay/wine"
export MACOSX_DEPLOYMENT_TARGET=26.0
export SDKROOT="/path/to/MacOSX26.sdk"
export WINE_PACKAGE_NAME=wine-11.17-zzz-dx12-gptk4b2-macos26
export WINE_RUNTIME_ID=11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server

./scripts/build-wine-tuned.sh all
./scripts/package-wine-p3-runtime.sh build/wine-tuned/host "$GPTK_SOURCE" \
  build/wine-tuned/provenance.json build/wine-tuned/package
./installer/build.sh
```

### Upstream Yaagl integration

The [Yaagl PR #759](https://github.com/yaagl/yet-another-anime-game-launcher/pull/759) integration consumes the split pair: Yaagl downloads and caches the backend separately and installs it into the extracted core `wine/` directory before Wine initialization. The pair is matched; it is not a general Wine/backend compatibility guarantee. The all-in-one archive and GUI installer remain the supported self-contained path. In the upstream integration, ZZZ's DirectX 12 option is off by default and is enabled only for a distribution that declares `supportsD3d12`.

### v1.1.0 release assets

v1.1.1 republishes the v1.1.0 runtime unchanged; only `ZZZWineDX12Installer.zip` differs. The runtime archive names below are therefore still used in the v1.1.1 release.

|Asset|Contents|
|---|---|
|`ZZZWineDX12Installer.zip`|GUI installer and the full runtime archive below|
|`wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz`|All-in-one runtime (`wine/` root)|
|`wine-11.17-zzz-core-macos26.tar.xz`|Split core archive (`wine/` root)|
|`d3dmetal-gptk4b2-zzz-v1.1.0.tar.xz`|Split backend overlay (relative `lib/`)|

Each archive has a `.sha256` sidecar. The installer build expects the full runtime archive at `build/release-v1.1.0/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz`.

```bash
# Stage a private runtime from a base Wine tree and a validated patched D3DMetal.
python3 scripts/stage-runtime.py --wine-source <base> --wine-dest <wine-root> \
  --patched-d3dmetal <patched-D3DMetal> --build-dir <native> --play --fsr-translator

# Refresh inherited P3 metadata for the final staged bytes.
python3 scripts/refresh-staged-runtime-metadata.py \
  --tree <wine-root> \
  --base build/release-v1.1.0/v1.0.5-base/wine \
  --native-manifest build/release-v1.1.0/native-v3/build-manifest.json

# Split a staged runtime into the core and backend archives.
sh scripts/package-wine-runtime-split.sh <wine-root> <output-dir>
```

The exact archive hashes belong to the parent release notes and are not asserted here.

### Focused checks

```bash
python3 scripts/test-metalfx-native.py --out <native-evidence>
python3 scripts/test-fsr-launch-profile.py
python3 scripts/test-fsr-translator.py --runtime <runtime> --out <upscaler-evidence>
python3 scripts/test-fsr-translator.py --frame-generation --command-buffer metal4 \
  --runtime <runtime> --out <fg-metal4-evidence>
python3 scripts/test-fsr-translator.py --frame-generation --command-buffer legacy \
  --runtime <runtime> --out <fg-legacy-evidence>
node --test scripts/test-dx12-launch-regression.mjs
```

`scripts/test-metalfx-native.py` runs its native suites and needs `--d3dmetal <verified D3DMetal binary>` when the `transport` suite is selected. `scripts/test-fsr-translator.py` compiles and runs the DX12 fixtures against a runtime passed with `--runtime`.

These commands describe the focused checks; their presence is not a claim that the final release artifacts passed them.

## License

- Wine source code is licensed under the **GNU Lesser General Public License (LGPL v2.1+)**.
- D3DMetal bridge components and installer tools use the terms included in this repository.
- The vendored FidelityFX SDK headers under `d3dmetal-pso-cache/third-party/fidelityfx/` retain AMD's MIT license text and copyright notice.
