#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../../../.." && pwd)"
SRC="$ROOT/d3dmetal-pso-cache"
OUT=/tmp/yaagl-sr-transport-memory
ARCHIVE="$ROOT/build/release-v1.1.0/wine-11.17-zzz-dx12-gptk4b2-macos26.tar.xz"
EXTRACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/yaagl-memory-wine.XXXXXX")
trap 'rm -rf -- "$EXTRACT_DIR"' EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$OUT"
python3 - "$SRC/fsr-kernels.metal" "$OUT/fsr-kernels.inc" "$SRC/d3dmetal-transport.native.test.mm" "$OUT/transport-memory-probe.mm" <<'PY'
import pathlib, sys
kernel = pathlib.Path(sys.argv[1]).read_text()
if ')YAAGL_METAL"' in kernel:
    raise SystemExit('FSR Metal source collides with generated raw-string delimiter')
pathlib.Path(sys.argv[2]).write_text(
    'static const char kFsrKernelsSource[] = R"YAAGL_METAL(' + kernel + ')YAAGL_METAL";\n')
source = pathlib.Path(sys.argv[3]).read_text()
def replace_once(old, new):
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f'expected one source anchor, found {count}: {old[:100]!r}')
    source = source.replace(old, new, 1)
replace_once('#include <cstring>\n', '#include <cstring>\n#include <mach/mach.h>\n')
replace_once('namespace {\n\nconst std::uint8_t* gImage = nullptr;', '''namespace {

void sampleMemory(id<MTLDevice> device, const char* label) {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO,
                                           reinterpret_cast<task_info_t>(&info), &count);
    const double mib = 1024.0 * 1024.0;
    std::fprintf(stderr, "MEM %-25s metal=%.2f MiB footprint=%.2f MiB\\n",
                 label, static_cast<double>(device.currentAllocatedSize) / mib,
                 status == KERN_SUCCESS ? static_cast<double>(info.phys_footprint) / mib : -1.0);
}

const std::uint8_t* gImage = nullptr;''')
replace_once('    constexpr std::uint32_t W = 64, H = 64;\n',
             '    constexpr std::uint32_t W = 1128, H = 624;\n    constexpr std::uint32_t OW = 1920, OH = 1080;\n')
replace_once('    id<MTLTexture> color = makeTexture(device, MTLPixelFormatRGBA8Unorm, W, H,',
             '    sampleMemory(device, "pre-resources");\n    id<MTLTexture> color = makeTexture(device, MTLPixelFormatRGBA16Float, W, H,')
replace_once('    id<MTLTexture> output = makeTexture(device, MTLPixelFormatRGBA8Unorm, W, H,',
             '    id<MTLTexture> output = makeTexture(device, MTLPixelFormatRGBA16Float, OW, OH,')
replace_once('    CreateInfo create{};\n    create.input = {W, H};\n    create.output = {W, H};',
             '    CreateInfo create{};\n    create.input = {W, H};\n    create.output = {OW, OH};')
replace_once('    frame.outputRect = {0, 0, W, H};', '    frame.outputRect = {0, 0, OW, OH};')
replace_once('    auto prepared = feature->prepare(frame, textures, &backendError);',
             '    FrameOperations operations{};\n    operations.sharpening = true;\n    auto prepared = feature->prepare(frame, textures, &backendError, operations);\n    sampleMemory(device, "prepared owner draft");')
replace_once('    require(record(transport, request), "custom MetalFX command record through native MPL scheduler");',
             '    require(record(transport, request), "custom MetalFX command record through native MPL scheduler");\n    sampleMemory(device, "recorded before replay");')
replace_once('    feature.reset();\n\n    void* replayer',
             '    feature.reset();\n    sampleMemory(device, "feature released owner live");\n\n    void* replayer')
replace_once('    for (unsigned replayIndex = 0; replayIndex < 2; ++replayIndex) {',
             '    constexpr unsigned ReplayCount = 16;\n    for (unsigned replayIndex = 0; replayIndex < ReplayCount; ++replayIndex) {')
replace_once('        submit(queue, commandBuffer, replayIndex == 0 ? "translator replay 0" : "translator replay 1");',
             '        char replayLabel[64];\n        std::snprintf(replayLabel, sizeof(replayLabel), "translator replay %u", replayIndex);\n        submit(queue, commandBuffer, replayLabel);')
replace_once('        [commandAllocator release];\n    }\n\n\n    // GPU has completed both executions.',
             '        [commandAllocator release];\n        if (replayIndex == 0 || replayIndex == 3 || replayIndex == 15) sampleMemory(device, replayLabel);\n    }\n\n    sampleMemory(device, "all GPU work complete");\n    // GPU has completed all executions.')
replace_once('    native.reset();\n\n    destroyNative(replayer);',
             '    native.reset();\n    sampleMemory(device, "allocator reset retired");\n\n    destroyNative(replayer);')
replace_once('                 "feature_release_before_replay=1 replays=2 leases_until_allocator_reset=2\\n");',
             '                 "feature_release_before_replay=1 replays=%u leases_until_allocator_reset=%u\\n",\n                 ReplayCount, ReplayCount);')
pathlib.Path(sys.argv[4]).write_text(source)
PY
python3 - "$SRC/d3dmetal-transport.mm" "$OUT/d3dmetal-transport.memory.mm" <<'PY'
import pathlib, sys
source = pathlib.Path(sys.argv[1]).read_text()
name = 'YAAGLMetalFXRecordedOwner'
if source.count(name) < 4:
    raise SystemExit('expected recorded-owner implementation and casts')
pathlib.Path(sys.argv[2]).write_text(source.replace(name, 'YAAGLMemoryProbeRecordedOwner'))
PY
xcrun clang++ -arch x86_64 -std=c++20 -O2 -mmacosx-version-min=14.0 \
  -Wall -Wextra -Werror -pthread -fno-objc-arc -fobjc-exceptions -fblocks \
  -I "$OUT" -I "$SRC" \
  "$SRC/metalfx-backend.mm" \
  "$OUT/d3dmetal-transport.memory.mm" \
  "$SRC/d3dmetal-transport-legacy.mm" \
  "$SRC/fsr-framegeneration.mm" \
  "$OUT/transport-memory-probe.mm" \
  -framework Foundation -framework Metal -framework MetalFX \
  -o "$OUT/transport-memory-probe"
if [ "${BUILD_ONLY:-0}" != 1 ]; then
  tar -xJf "$ARCHIVE" -C "$EXTRACT_DIR"
  D3DMETAL="$EXTRACT_DIR/wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal"
  if [ ! -f "$D3DMETAL" ]; then echo "Missing archived D3DMetal: $D3DMETAL" >&2; exit 2; fi
  /usr/bin/arch -x86_64 "$OUT/transport-memory-probe" "$D3DMETAL"
fi
