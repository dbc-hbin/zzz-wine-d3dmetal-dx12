#import <Foundation/Foundation.h>

#include "d3dmetal-replay-hooks.hpp"
#include "d3dmetal-transport.hpp"
#include "d3dmetal-transport-legacy.hpp"

#include <atomic>

namespace yaagl::pso::d3dmetal {
namespace {

using Replay = void (*)(void*, const void*);
using Encode = void (*)(void*, const void*);

std::atomic<Replay> originalReplay;
std::atomic<Encode> originalEncode;

void replayRecorded(void* replayer, const void* command) {
    if (isRecordedCommand(command)) {
        if (!replay(replayer, command))
            [NSException raise:@"YaaglFSRReplayFailure"
                        format:@"FSR MetalFX command failed during Metal4 replay"];
        return;
    }
    originalReplay.load(std::memory_order_acquire)(replayer, command);
}

void encodeRecorded(void* encoder, const void* command) {
    if (legacy::isRecordedCommand(command)) {
        if (!legacy::replay(encoder, command))
            [NSException raise:@"YaaglFSRLegacyEncodeFailure"
                        format:@"FSR MetalFX command failed during legacy Metal encoding"];
        return;
    }
    originalEncode.load(std::memory_order_acquire)(encoder, command);
}

} // namespace

std::array<std::uintptr_t, kReplayHookCount> initializeReplayHooks(
    const std::array<std::uintptr_t, kReplayHookCount>& originals) noexcept {
    if (originals[0] == 0 || originals[1] == 0) return {};
    originalReplay.store(reinterpret_cast<Replay>(originals[0]), std::memory_order_release);
    originalEncode.store(reinterpret_cast<Encode>(originals[1]), std::memory_order_release);
    return {reinterpret_cast<std::uintptr_t>(&replayRecorded),
            reinterpret_cast<std::uintptr_t>(&encodeRecorded)};
}

} // namespace yaagl::pso::d3dmetal
