#pragma once

#include "metalfx-backend.hpp"

#include <cstdint>
#include <memory>

struct yaagl_fsr_fg_packet_header;

namespace yaagl::pso::fsr::framegeneration {

class ExecutionLease;

class PreparedFrame final {
public:
    struct Impl;

    ~PreparedFrame();
    PreparedFrame(const PreparedFrame&) = delete;
    PreparedFrame& operator=(const PreparedFrame&) = delete;

    bool encode(void* commandBuffer, void* fence,
                std::shared_ptr<const ExecutionLease>& lease) const noexcept;
    metalfx::CommandMode mode() const noexcept;

private:
    friend std::uint32_t api(std::uint32_t, void*) noexcept;
    explicit PreparedFrame(std::shared_ptr<Impl> impl) noexcept;
    std::shared_ptr<Impl> impl_;
};

class ExecutionLease final {
public:
    struct Impl;

    ~ExecutionLease();
    ExecutionLease(const ExecutionLease&) = delete;
    ExecutionLease& operator=(const ExecutionLease&) = delete;

private:
    friend class PreparedFrame;
    explicit ExecutionLease(std::shared_ptr<Impl> impl) noexcept;
    std::shared_ptr<Impl> impl_;
};

bool initialize(const std::uint8_t* d3dmetalImageBase) noexcept;
bool available() noexcept;
std::uint32_t api(std::uint32_t operation, void* arguments) noexcept;

} // namespace yaagl::pso::fsr::framegeneration

extern "C" std::uint32_t yaagl_fsr_fg_api(std::uint32_t operation, void* arguments) noexcept;
