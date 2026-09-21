#pragma once

#include <cstdint>

namespace yaagl::pso::metalfx {

using Resource = void*;

template <typename T>
struct ParameterValue {
    T value{};
    bool present = false;
};

struct Extent {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
};

struct Rect {
    std::uint32_t x = 0;
    std::uint32_t y = 0;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
};

enum FeatureFlag : std::uint32_t {
    FeatureFlagIsHDR = 1u << 0,
    FeatureFlagMVLowRes = 1u << 1,
    FeatureFlagMVJittered = 1u << 2,
    FeatureFlagDepthInverted = 1u << 3,
    FeatureFlagAutoExposure = 1u << 6,
};

struct CreateInfo {
    Extent input{};
    Extent output{};
    ParameterValue<std::uint32_t> featureFlags{};
    ParameterValue<bool> outputSubrects{};

    constexpr std::uint32_t flags() const noexcept { return featureFlags.value; }
    constexpr bool hdr() const noexcept { return (flags() & FeatureFlagIsHDR) != 0; }
    constexpr bool lowResolutionMotionVectors() const noexcept {
        return (flags() & FeatureFlagMVLowRes) != 0;
    }
    constexpr bool jitteredMotionVectors() const noexcept {
        return (flags() & FeatureFlagMVJittered) != 0;
    }
    constexpr bool depthInverted() const noexcept {
        return (flags() & FeatureFlagDepthInverted) != 0;
    }
    constexpr bool autoExposure() const noexcept {
        return (flags() & FeatureFlagAutoExposure) != 0;
    }
};

enum class ExposureMode : std::uint8_t {
    None,
    Texture,
    Automatic,
};

struct FrameInfo {
    Resource color = nullptr;
    Resource depth = nullptr;
    Resource motionVectors = nullptr;
    Resource output = nullptr;
    ParameterValue<Resource> exposureTexture{};
    ParameterValue<Resource> reactiveMask{};
    ParameterValue<Resource> compositionMask{};

    Extent inputContent{};
    Rect colorRect{};
    Rect depthRect{};
    Rect motionRect{};
    Rect reactiveRect{};
    Rect outputRect{};

    ParameterValue<float> jitterOffsetX{0.0f, false};
    ParameterValue<float> jitterOffsetY{0.0f, false};
    ParameterValue<float> motionVectorScaleX{1.0f, false};
    ParameterValue<float> motionVectorScaleY{1.0f, false};
    ParameterValue<float> preExposure{1.0f, false};
    ParameterValue<bool> resetHistory{false, false};

    ExposureMode exposureMode = ExposureMode::None;
};

} // namespace yaagl::pso::metalfx
