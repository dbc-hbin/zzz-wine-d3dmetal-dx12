#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace yaagl::pso::ngx {

inline constexpr std::size_t kHookCount = 8;

// Returns replacement entry points in this fixed order: NGX MPL evaluate,
// NGX MTL evaluate, MPL temporal-scale recording, MPL replay, legacy MTL encode,
// the legacy NGX post-record gate, the MPL post-record gate, and the public
// MS-ABI D3D12 EvaluateFeature entry.
// An all-zero result means the pinned helper entries are unavailable.
std::array<std::uintptr_t, kHookCount> initializeHooks(
    const std::uint8_t* imageBase,
    const std::array<std::uintptr_t, kHookCount>& originals) noexcept;

} // namespace yaagl::pso::ngx
