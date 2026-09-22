#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace yaagl::pso::d3dmetal {

inline constexpr std::size_t kReplayHookCount = 2;

// Returns replacement entry points for Metal4 replay and legacy Metal encode.
// An all-zero result means the original entry points are unavailable.
std::array<std::uintptr_t, kReplayHookCount> initializeReplayHooks(
    const std::array<std::uintptr_t, kReplayHookCount>& originals) noexcept;

} // namespace yaagl::pso::d3dmetal
