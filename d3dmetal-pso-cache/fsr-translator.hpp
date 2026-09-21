#pragma once

#include <cstdint>

namespace yaagl::pso::fsr {

bool initialize(const std::uint8_t* d3dmetalImageBase) noexcept;
bool available() noexcept;

} // namespace yaagl::pso::fsr

extern "C" std::uint32_t yaagl_fsr_api(std::uint32_t operation, void* arguments) noexcept;
