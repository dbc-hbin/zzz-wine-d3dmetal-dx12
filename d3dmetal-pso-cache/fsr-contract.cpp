#include "fsr-contract.hpp"

#include <cmath>

namespace yaagl::pso::fsr {
namespace {
constexpr std::uint32_t kHdr = 1u << 0;
constexpr std::uint32_t kDisplayMotion = 1u << 1;
constexpr std::uint32_t kJitteredMotion = 1u << 2;
constexpr std::uint32_t kDepthInverted = 1u << 3;
constexpr std::uint32_t kAutoExposure = 1u << 5;
constexpr std::uint32_t kKnownCreateFlags = 0x3ffu;
constexpr std::uint32_t kSrgb = 1u << 1;
constexpr std::uint32_t kPq = 1u << 2;
constexpr std::uint32_t kKnownDispatchFlags = 0x7u;
constexpr std::uint32_t kKnownResourceStates = 0x3ffu;

bool finite(float value) noexcept { return std::isfinite(value); }
}

ContractStatus validateCreate(const yaagl_fsr_create_packet& input, CreateContract& output) noexcept {
    if (!input.device || !input.max_render_width || !input.max_render_height ||
        !input.max_upscale_width || !input.max_upscale_height ||
        input.max_render_width > input.max_upscale_width ||
        input.max_render_height > input.max_upscale_height ||
        (input.flags & ~kKnownCreateFlags)) return ContractStatus::InvalidParameter;
    output = {};
    output.apiFlags = input.flags;
    output.backend.input = {input.max_render_width, input.max_render_height};
    output.backend.output = {input.max_upscale_width, input.max_upscale_height};
    std::uint32_t flags = 0;
    if (input.flags & kHdr) flags |= metalfx::FeatureFlagIsHDR;
    if (!(input.flags & kDisplayMotion)) flags |= metalfx::FeatureFlagMVLowRes;
    if (input.flags & kJitteredMotion) flags |= metalfx::FeatureFlagMVJittered;
    if (input.flags & kDepthInverted) flags |= metalfx::FeatureFlagDepthInverted;
    if (input.flags & kAutoExposure) flags |= metalfx::FeatureFlagAutoExposure;
    output.backend.featureFlags = {flags, true};
    return ContractStatus::Ok;
}

ContractStatus validateFrame(const CreateContract& create, const yaagl_fsr_dispatch_packet& input,
                             FrameContract& output, const char** detail) noexcept {
    if (detail) *detail = "ok";
    const auto invalid = [detail](const char* reason) noexcept {
        if (detail) *detail = reason;
        return ContractStatus::InvalidParameter;
    };
    const bool defaultUpscale = input.upscale_width == 0 && input.upscale_height == 0;
    const std::uint32_t upscaleWidth = defaultUpscale ? create.backend.output.width : input.upscale_width;
    const std::uint32_t upscaleHeight = defaultUpscale ? create.backend.output.height : input.upscale_height;
    if (!input.command_list || !input.color || !input.depth || !input.motion_vectors || !input.output)
        return invalid("missing_required_resource");
    if (!input.color_state || !input.depth_state || !input.motion_state || !input.output_state)
        return invalid("missing_required_resource_state");
    if ((input.color_state | input.depth_state | input.motion_state | input.exposure_state |
         input.reactive_state | input.composition_state | input.output_state) & ~kKnownResourceStates)
        return invalid("unknown_resource_state_bits");
    if ((input.exposure && !input.exposure_state) || (input.reactive && !input.reactive_state) ||
        (input.composition && !input.composition_state))
        return invalid("missing_optional_resource_state");
    if (!input.render_width || !input.render_height) return invalid("zero_render_size");
    if (input.render_width > create.backend.input.width || input.render_height > create.backend.input.height)
        return invalid("render_size_exceeds_context");
    if (!defaultUpscale && (!input.upscale_width || !input.upscale_height))
        return invalid("partial_zero_upscale_size");
    if (!upscaleWidth || !upscaleHeight || upscaleWidth > create.backend.output.width ||
        upscaleHeight > create.backend.output.height) return invalid("upscale_size_exceeds_context");
    if (!finite(input.jitter_x) || !finite(input.jitter_y)) return invalid("nonfinite_jitter");
    if (!finite(input.motion_scale_x) || !finite(input.motion_scale_y)) return invalid("nonfinite_motion_scale");
    if (!finite(input.sharpness) || input.sharpness < 0.0f || input.sharpness > 1.0f)
        return invalid("invalid_sharpness");
    if (!finite(input.frame_time_delta) || input.frame_time_delta < 0.0f)
        return invalid("invalid_frame_time_delta");
    if (!finite(input.pre_exposure) || input.pre_exposure <= 0.0f) return invalid("invalid_pre_exposure");
    if (!finite(input.camera_near) || !finite(input.camera_far)) return invalid("nonfinite_camera_planes");
    if (!finite(input.camera_fov_vertical) || input.camera_fov_vertical <= 0.0f ||
        input.camera_fov_vertical > 3.14159265358979323846f) return invalid("invalid_camera_fov");
    // The public API describes this as a diagnostic scale and the pinned provider forwards zero.
    if (!finite(input.view_space_to_meters) || input.view_space_to_meters < 0.0f)
        return invalid("invalid_view_space_scale");
    if (input.reset > 1 || input.enable_sharpening > 1) return invalid("invalid_boolean");
    if (input.flags & ~kKnownDispatchFlags) return invalid("unknown_dispatch_flags");
    if ((input.flags & kSrgb) && (input.flags & kPq)) return invalid("conflicting_color_transfer");
    if (input.flags & 1u) {
        if (detail) *detail = "debug_view_unsupported";
        return ContractStatus::Unsupported;
    }

    output = {};
    output.backend.color = reinterpret_cast<void*>(static_cast<std::uintptr_t>(input.color));
    output.backend.depth = reinterpret_cast<void*>(static_cast<std::uintptr_t>(input.depth));
    output.backend.motionVectors = reinterpret_cast<void*>(static_cast<std::uintptr_t>(input.motion_vectors));
    output.backend.output = reinterpret_cast<void*>(static_cast<std::uintptr_t>(input.output));
    output.backend.exposureTexture = {reinterpret_cast<void*>(static_cast<std::uintptr_t>(input.exposure)), input.exposure != 0};
    output.backend.reactiveMask = {reinterpret_cast<void*>(static_cast<std::uintptr_t>(input.reactive)), input.reactive != 0};
    output.backend.compositionMask = {reinterpret_cast<void*>(static_cast<std::uintptr_t>(input.composition)), input.composition != 0};
    output.backend.inputContent = {input.render_width, input.render_height};
    output.backend.colorRect = {0, 0, input.render_width, input.render_height};
    output.backend.depthRect = output.backend.colorRect;
    output.backend.reactiveRect = output.backend.colorRect;
    const bool lowMotion = create.backend.lowResolutionMotionVectors();
    output.backend.motionRect = {0, 0, lowMotion ? input.render_width : upscaleWidth,
                                      lowMotion ? input.render_height : upscaleHeight};
    output.backend.outputRect = {0, 0, upscaleWidth, upscaleHeight};
    output.backend.jitterOffsetX = {input.jitter_x, true};
    output.backend.jitterOffsetY = {input.jitter_y, true};
    output.backend.motionVectorScaleX = {input.motion_scale_x, true};
    output.backend.motionVectorScaleY = {input.motion_scale_y, true};
    output.backend.preExposure = {input.pre_exposure, true};
    output.backend.resetHistory = {input.reset != 0, true};
    output.backend.exposureMode = (create.apiFlags & kAutoExposure)
        ? metalfx::ExposureMode::Automatic : (input.exposure ? metalfx::ExposureMode::Texture : metalfx::ExposureMode::None);
    output.operations.colorTransfer = (input.flags & kSrgb) ? metalfx::ColorTransfer::SRGB
        : (input.flags & kPq) ? metalfx::ColorTransfer::PQ : metalfx::ColorTransfer::Linear;
    output.operations.combineCompositionMask = input.composition != 0;
    // The backend compares each frame against the actual device descriptor maximum.
    // At or below that maximum this opt-in preserves the existing full-frame path.
    output.operations.capOutputToTemporalMaxScale = true;
    output.operations.sharpening = input.enable_sharpening != 0;
    output.operations.sharpness = input.sharpness;
    output.frameTimeDelta = input.frame_time_delta;
    output.cameraNear = input.camera_near;
    output.cameraFar = input.camera_far;
    output.cameraFovVertical = input.camera_fov_vertical;
    output.viewSpaceToMeters = input.view_space_to_meters;
    return ContractStatus::Ok;
}

const char* contractStatusName(ContractStatus status) noexcept {
    switch (status) {
    case ContractStatus::Ok: return "ok";
    case ContractStatus::InvalidParameter: return "invalid_parameter";
    case ContractStatus::Unsupported: return "unsupported";
    }
    return "invalid_parameter";
}

} // namespace yaagl::pso::fsr
