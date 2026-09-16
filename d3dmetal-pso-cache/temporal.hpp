#pragma once
#include "temporal-contract.hpp"
namespace yaagl::pso::temporal {
using GetFloat = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, float*);
using GetUint = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, std::uint32_t*);
using GetInt = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, std::int32_t*);
using Logger = void (*)(const char*, std::size_t) noexcept;
void initialize(GetFloat, GetUint, GetInt, Logger) noexcept;
bool enabled() noexcept;
class EvaluationScope {
public:
    explicit EvaluationScope(const void* params) noexcept;
    ~EvaluationScope();
    EvaluationScope(const EvaluationScope&) = delete;
    EvaluationScope& operator=(const EvaluationScope&) = delete;
private:
    Parameters value_{};
    const Parameters* previous_ = nullptr;
    bool active_ = false;
};
// Called synchronously inside EvaluateMPL, before original TemporalScaleMPL.
bool patchDescriptor(void* descriptor) noexcept;
// Called at the already verified MplRecordComplete inline gate.
void recordComplete(const void* command) noexcept;
class ReplayScope {
public:
    explicit ReplayScope(const void* command) noexcept;
    ~ReplayScope();
    ReplayScope(const ReplayScope&) = delete;
    ReplayScope& operator=(const ReplayScope&) = delete;
    // Called only by our class-local ObjC IMP wrapper.
    void beforeEncode(void* object) noexcept;
    void* scaler = nullptr;
    bool inEncode = false;
private:
    ReplayScope* previous_ = nullptr;
    const void* command_ = nullptr;
    Descriptor descriptor_{};
    std::uint32_t flags_ = 0;
    bool flagsOK_ = false, forcedReset_ = false, active_ = false;
    unsigned encodes_ = 0;
};
} // namespace yaagl::pso::temporal
