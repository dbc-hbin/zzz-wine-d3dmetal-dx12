#pragma once

#include "metalfx-contract.hpp"
#include "metalfx-backend.hpp"
#include "../include/yaagl_fsr_bridge.h"

#include <cstdint>

namespace yaagl::pso::fsr {

enum class ContractStatus : std::uint8_t {
    Ok,
    InvalidParameter,
    Unsupported,
};

struct CreateContract {
    metalfx::CreateInfo backend;
    std::uint32_t apiFlags = 0;
};

struct FrameContract {
    metalfx::FrameInfo backend;
    metalfx::FrameOperations operations;
    float frameTimeDelta = 0.0f;
    float cameraNear = 0.0f;
    float cameraFar = 0.0f;
    float cameraFovVertical = 0.0f;
    float viewSpaceToMeters = 0.0f;
};

ContractStatus validateCreate(const yaagl_fsr_create_packet&, CreateContract&) noexcept;
ContractStatus validateFrame(const CreateContract&, const yaagl_fsr_dispatch_packet&, FrameContract&,
                             const char** detail = nullptr) noexcept;
const char* contractStatusName(ContractStatus) noexcept;

} // namespace yaagl::pso::fsr
