#pragma once
#include "frame-probe-core.hpp"
namespace yaagl::pso::frameprobe {
using GetFloat = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, float*);
using GetUint = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, std::uint32_t*);
using GetInt = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, std::int32_t*);
using GetResource = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, void**);
void initialize(GetFloat, GetUint, GetInt, GetResource) noexcept;
bool enabled() noexcept;
class EvaluationScope {
public:
    EvaluationScope(const void* feature, const void* commandList, const void* params) noexcept;
    ~EvaluationScope();
    EvaluationScope(const EvaluationScope&) = delete;
    EvaluationScope& operator=(const EvaluationScope&) = delete;
private:
    Evaluation value_{};
    const Evaluation* previous_ = nullptr;
    bool active_ = false;
};
void recordComplete(const void* command) noexcept;
class ReplayScope {
public:
    explicit ReplayScope(const void* command) noexcept;
    ~ReplayScope();
    ReplayScope(const ReplayScope&) = delete;
    ReplayScope& operator=(const ReplayScope&) = delete;
    void* scaler = nullptr;
    bool inEncode = false;
    std::uint64_t beforeEncode(void* object, void* commandBuffer) noexcept;
    void afterEncode(void* object, void* commandBuffer, std::uint64_t encodeID, bool completedNormally) noexcept;
private:
    ReplayScope* previous_ = nullptr;
    bool active_ = false, forcedReset_ = false, pushed_ = false;
    unsigned encodes_ = 0;
    const void* command_ = nullptr;
    Descriptor descriptor_{};
    RecordLedger::Result match_{};
};
#ifdef YAAGL_FRAME_PROBE_TESTS
void flushForTests() noexcept;
#endif
} // namespace yaagl::pso::frameprobe
