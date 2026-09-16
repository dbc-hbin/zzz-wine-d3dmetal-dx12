#pragma once
#include "temporal-contract.hpp"
#include <array>
#include <cstdint>
#include <cstring>
#include <map>
#include <mutex>
#include <optional>

namespace yaagl::pso::frameprobe {
using Descriptor = temporal::Descriptor;
using Identity = std::uintptr_t;
struct Evaluation {
    std::uint64_t id = 0;
    Identity feature = 0, commandList = 0, parameters = 0;
    std::uint32_t flags = 0, width = 0, height = 0, outWidth = 0, outHeight = 0;
    std::uint32_t nominalWidth = 0, nominalHeight = 0, reset = 0;
    float jitterX = 0, jitterY = 0, motionX = 0, motionY = 0, preExposure = 0;
    // Each status bit distinguishes missing data from zero.
    std::uint32_t valid = 0;
    std::array<Identity, 6> resources{};
};
enum Valid : std::uint32_t {
    Flags = 1, ActiveExtent = 2, OutputExtent = 4, Jitter = 8,
    Motion = 16, Reset = 32, PreExposure = 64, NominalExtent = 128
};
struct Record {
    std::uint64_t id = 0;
    Evaluation evaluation{};
    Identity scaler = 0;
    Descriptor descriptor{};
    bool forcedReset = false;
};
inline bool sameRecord(const Record& r, Identity scaler, const Descriptor& d, bool forced) noexcept {
    return r.scaler == scaler && r.forcedReset == forced &&
        std::memcmp(&r.descriptor, &d, sizeof(d)) == 0;
}
// A record ID is NOT a GPU frame number. Pointers are NOT resource versions.
// Consume exactly once: repeated command-list replay is explicitly uncorrelated,
// instead of silently attaching an old Evaluate ID to a new execution.
class RecordLedger {
public:
    enum class Match { Exact, Missing, Changed, Reused };
    struct Result { Match match = Match::Missing; std::optional<Record> record; };
    struct Stored { bool replaced = false; bool evicted = false; };
    explicit RecordLedger(std::size_t capacity = 4096) : capacity_(capacity ? capacity : 1) {}
    Stored store(Identity key, const Record& record) {
        std::lock_guard<std::mutex> lock(mutex_);
        Stored result;
        auto old = records_.find(key);
        if (old != records_.end()) {
            order_.erase(old->second.order); records_.erase(old); result.replaced = true;
        }
        if (records_.size() >= capacity_) {
            const auto first = order_.begin(); records_.erase(first->second);
            order_.erase(first); result.evicted = true;
        }
        const auto serial = ++serial_;
        records_.emplace(key, Entry{record, serial, result.replaced}); order_.emplace(serial, key);
        return result;
    }
    Result take(Identity key, Identity scaler, const Descriptor& d, bool forced) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = records_.find(key);
        if (it == records_.end()) return {};
        Record r = it->second.record;
        const bool reused = it->second.reused;
        order_.erase(it->second.order); records_.erase(it);
        return {sameRecord(r, scaler, d, forced) ? (reused ? Match::Reused : Match::Exact) : Match::Changed, r};
    }
    std::size_t size() const { std::lock_guard<std::mutex> lock(mutex_); return records_.size(); }
private:
    struct Entry { Record record; std::uint64_t order; bool reused; };
    std::size_t capacity_;
    std::uint64_t serial_ = 0;
    mutable std::mutex mutex_;
    std::map<Identity, Entry> records_;
    std::map<std::uint64_t, Identity> order_;
};
inline const char* matchName(RecordLedger::Match m) noexcept {
    return m == RecordLedger::Match::Exact ? "record_bytes_match" :
           m == RecordLedger::Match::Changed ? "record_bytes_changed" :
           m == RecordLedger::Match::Reused ? "address_reused_unconsumed" : "untracked_or_repeated";
}
} // namespace yaagl::pso::frameprobe
