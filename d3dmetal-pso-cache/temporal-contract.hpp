#pragma once
#include <cstddef>
#include <cstdint>
#include <cmath>
#include <cstring>
#include <type_traits>

namespace yaagl::pso::temporal {
// ONLY the x86_64 D3DMetal build identified by the supplied layout.json.
// Descriptor is copied verbatim to recordedCommand + 0x20 by D3DMetal.
struct Descriptor {
    std::uint64_t color, depth, motion, output, exposure, reactive;
    std::uint32_t width, height;
    std::uint32_t colorX, colorY, depthX, depthY, motionX, motionY;
    std::uint32_t reactiveX, reactiveY, outputX, outputY;
    float preExposure, jitterX, jitterY, motionScaleX, motionScaleY;
    std::uint32_t reset;
};
static_assert(std::is_trivially_copyable_v<Descriptor>);
static_assert(sizeof(Descriptor) == 0x78);
static_assert(offsetof(Descriptor, width) == 0x30);
static_assert(offsetof(Descriptor, preExposure) == 0x60);
static_assert(offsetof(Descriptor, motionScaleX) == 0x6c);
static_assert(offsetof(Descriptor, reset) == 0x74);
constexpr std::uint32_t kMVLowRes = 2, kMVJittered = 4, kDepthInverted = 8;
constexpr std::uint32_t kKnownFlags = 1 | 2 | 4 | 8 | 32 | 64 | 128;

struct Parameters {
    std::uint32_t flags = 0, width = 0, height = 0;
    float motionScaleX = 0, motionScaleY = 0, jitterX = 0, jitterY = 0;
    bool flagsOK = false, sizeOK = false, motionOK = false, jitterOK = false;
};
inline bool supportedFlags(std::uint32_t flags) noexcept {
    // This repair deliberately does not claim support for output-resolution
    // motion, jittered vectors, reserved flags, or alpha upscaling.
    return (flags & kMVLowRes) && !(flags & (kMVJittered | 128)) &&
           !(flags & ~kKnownFlags);
}
inline bool zeroOrigins(const Descriptor& d) noexcept {
    return !(d.colorX | d.colorY | d.depthX | d.depthY | d.motionX |
             d.motionY | d.reactiveX | d.reactiveY | d.outputX | d.outputY);
}
inline bool validScalars(const Descriptor& d) noexcept {
    return std::isfinite(d.motionScaleX) && std::isfinite(d.motionScaleY) &&
           std::isfinite(d.jitterX) && std::isfinite(d.jitterY);
}
// Caller validates resource extents. No resolution-derived normalization,
// depth-derived Y sign, guessed viewport, or exposure modification here.
inline bool repairDescriptor(Descriptor& d, const Parameters& p) noexcept {
    if (!p.flagsOK || !supportedFlags(p.flags) || !zeroOrigins(d)) return false;
    Descriptor fixed = d;
    if (p.sizeOK && p.width && p.height) {
        fixed.width = p.width;
        fixed.height = p.height;
    }
    if (p.motionOK && std::isfinite(p.motionScaleX) && std::isfinite(p.motionScaleY)) {
        fixed.motionScaleX = p.motionScaleX;
        fixed.motionScaleY = p.motionScaleY;
    }
    if (p.jitterOK && std::isfinite(p.jitterX) && std::isfinite(p.jitterY)) {
        fixed.jitterX = p.jitterX;
        fixed.jitterY = p.jitterY;
    }
    if (!validScalars(fixed)) return false;
    const bool changed = std::memcmp(&d, &fixed, sizeof(d)) != 0;
    d = fixed;
    return changed;
}
} // namespace yaagl::pso::temporal
