#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace yaagl::pso::exposure {

enum class ApplyResult : std::uint8_t {
    NotApplicable,
    Applied,
    Failed,
};

using GetFloat = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, float*);

// Initializes the opt-in correction. The feature is enabled only when
// YAAGL_METALFX_EXPOSURE_SCALE_FIX is exactly "1".
void initialize(const std::uint8_t* imageBase, GetFloat getFloat = nullptr) noexcept;

// Carries an applicable evaluation's scale only through its synchronous record
// calls. Scopes nest without losing the caller's state.
class EvaluationScope final {
public:
    EvaluationScope(bool hdr, bool autoExposure, bool hasExposureTexture,
                    const void* params) noexcept;
    ~EvaluationScope();

    EvaluationScope(const EvaluationScope&) = delete;
    EvaluationScope& operator=(const EvaluationScope&) = delete;

private:
    float previousScale_;
    bool previousApplicable_;
};

// Replaces the null exposure field at +0x20 in a 0x78-byte MPL temporal-scale
// descriptor. The texture's owned reference is transferred to the command
// list allocator through D3DMetal's native lifetime helper.
ApplyResult patchMplDescriptor(void* commandList, void* descriptor) noexcept;

// Clears and, when applicable, records immutable scalar metadata in the proven
// unused +0x11..+0x17 bytes of a completed 0xe0-byte legacy command.
ApplyResult recordLegacyScale(void* command) noexcept;

// Builds an execution-local legacy command and fresh exposure texture.
// The native +0xb0 path transfers the creation reference into its GPU resource
// owner. handoffCommand() returns the original on every no-op or
// failure path, avoiding allocation when no valid metadata was recorded.
class LegacyEncodeScope final {
public:
    LegacyEncodeScope(void* encoder, const void* command) noexcept;
    ~LegacyEncodeScope();

    LegacyEncodeScope(const LegacyEncodeScope&) = delete;
    LegacyEncodeScope& operator=(const LegacyEncodeScope&) = delete;

    // Transfers the fresh texture's +1 to native Encode. Call only as the
    // immediate argument to the original Encode function.
    [[nodiscard]] const void* handoffCommand() noexcept;
    [[nodiscard]] ApplyResult result() const noexcept { return result_; }

private:
    const void* original_;
    void* texture_ = nullptr;
    bool handedOff_ = false;
    ApplyResult result_ = ApplyResult::NotApplicable;
    alignas(16) std::array<std::byte, 0xe0> local_{};
};

} // namespace yaagl::pso::exposure
