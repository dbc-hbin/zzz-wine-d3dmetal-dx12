#import "ngx-hooks.hpp"
#import "exposure.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>
#import <objc/runtime.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <fcntl.h>
#include <pthread.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

namespace yaagl::pso::ngx {
namespace {

constexpr std::uint32_t kMissing = 0xbad00000;
using Evaluate = std::uint32_t (*)(void*, void*, void*, std::uintptr_t);
using EvaluateAPI = std::uint32_t (__attribute__((ms_abi)) *)(void*, void*, void*, std::uintptr_t);
using TemporalScale = void (*)(void*, void*, const void*);
using Replay = void (*)(void*, const void*);
using Encode = void (*)(void*, const void*);
using GetFloat = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, float*);
using GetUint = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, std::uint32_t*);
using GetInt = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, std::int32_t*);
using GetResource = std::uint32_t (__attribute__((ms_abi)) *)(const void*, const char*, void**);

std::atomic<Evaluate> gEvaluateMPL;
std::atomic<EvaluateAPI> gEvaluateAPI;
std::atomic<Evaluate> gEvaluateMTL;
std::atomic<TemporalScale> gTemporalScale;
std::atomic<Replay> gReplay;
std::atomic<Encode> gEncode;
GetFloat gGetFloat;
GetUint gGetUint;
GetInt gGetInt;
GetResource gGetResource;
std::atomic<bool> gEnabled;
std::atomic<bool> gExposureEnabled;
std::atomic<std::uint64_t> gSequence;
std::atomic<bool> gLimitWritten;
std::atomic<std::uint64_t> gEventCount;
thread_local std::uint64_t gCurrentEvalID;
thread_local std::uint64_t gCurrentRecordID;
std::atomic<std::uint64_t> gRecordID;
struct ScopedID { ScopedID(std::uint64_t& current, std::uint64_t id) noexcept : current(current), previous(current) { current = id; } ~ScopedID() { current = previous; } std::uint64_t& current; std::uint64_t previous; };
int gLogFd = STDERR_FILENO;
pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;

struct Line {
    char data[8192];
    std::size_t size = 0;
    bool first = true;
    bool limited = false;

    void append(const char* format, ...) {
        if (size >= sizeof(data) - 2) return;
        va_list args;
        va_start(args, format);
        const int n = vsnprintf(data + size, sizeof(data) - size, format, args);
        va_end(args);
        if (n > 0) {
            const auto requested = static_cast<std::size_t>(n);
            limited |= requested >= sizeof(data) - size;
            size += std::min(requested, sizeof(data) - size - 1);
        }
    }
    void key(const char* name) { append("%s\"%s\":", first ? "" : ",", name); first = false; }
    void string(const char* name, const char* value) { key(name); append("\"%s\"", value); }
    void integer(const char* name, std::uint64_t value) { key(name); append("%llu", value); }
    void pointer(const char* name, const void* value) { key(name); value ? append("\"0x%llx\"", static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(value))) : append("null"); }
    void number(const char* name, float value, bool present) { key(name); present && std::isfinite(value) ? append("%.9g", value) : append("null"); }
};

void writeAll(const char* data, std::size_t size) noexcept {
    while (size) {
        const ssize_t written = write(gLogFd, data, size);
        if (written > 0) { data += written; size -= static_cast<std::size_t>(written); continue; }
        if (written < 0 && errno == EINTR) continue;
        break;
    }
}

void emit(Line& line) noexcept {
    pthread_mutex_lock(&gLogLock);
    line.integer("seq", gSequence.fetch_add(1, std::memory_order_relaxed));
    const bool capped = gEventCount.fetch_add(1, std::memory_order_relaxed) >= 8192;
    if ((capped || line.limited) && !gLimitWritten.exchange(true)) {
        static constexpr char marker[] = "{\"source\":\"yaagl-metalfx\",\"limit\":8192}\n";
        writeAll(marker, sizeof(marker) - 1);
    }
    if (!capped && !line.limited) {
        line.data[line.size] = '}';
        line.data[line.size + 1] = '\n';
        writeAll(line.data, line.size + 2);
    }
    pthread_mutex_unlock(&gLogLock);
}

Line begin(const char* source, const char* phase) noexcept {
    Line line;
    line.append("{");
    line.string("source", source);
    line.string("phase", phase);
    line.integer("pid", static_cast<std::uint64_t>(getpid()));
    std::uint64_t tid = 0;
    pthread_threadid_np(nullptr, &tid);
    line.integer("thread", tid);
    timespec now{};
    clock_gettime(CLOCK_MONOTONIC_RAW, &now);
    line.integer("monotonic_ns", static_cast<std::uint64_t>(now.tv_sec) * 1000000000ULL + now.tv_nsec);
    return line;
}

enum class GetterStatus { Ok, Missing, Failure };
const char* statusName(GetterStatus status) noexcept { return status == GetterStatus::Ok ? "ok" : status == GetterStatus::Missing ? "missing" : "failure"; }

GetterStatus getFloat(const void* params, const char* key, float& value, std::uint32_t* raw, bool* returned) noexcept {
    value = 0;
    if (!params) return GetterStatus::Missing;
    try { const auto result = gGetFloat(params, key, &value); *raw = result; *returned = true; return result == 1 ? GetterStatus::Ok : result == kMissing ? GetterStatus::Missing : GetterStatus::Failure; } catch (...) { return GetterStatus::Failure; }
}
GetterStatus getUint(const void* params, const char* key, std::uint32_t& value, std::uint32_t* raw, bool* returned) noexcept {
    value = 0;
    if (!params) return GetterStatus::Missing;
    try { const auto result = gGetUint(params, key, &value); *raw = result; *returned = true; return result == 1 ? GetterStatus::Ok : result == kMissing ? GetterStatus::Missing : GetterStatus::Failure; } catch (...) { return GetterStatus::Failure; }
}
GetterStatus getInt(const void* params, const char* key, std::int32_t& value, std::uint32_t* raw, bool* returned) noexcept {
    value = 0;
    if (!params) return GetterStatus::Missing;
    try { const auto result = gGetInt(params, key, &value); *raw = result; *returned = true; return result == 1 ? GetterStatus::Ok : result == kMissing ? GetterStatus::Missing : GetterStatus::Failure; } catch (...) { return GetterStatus::Failure; }
}
void logEntry(const char* feature, const void* self, const void* commandList, const void* params, std::uint64_t evalID) noexcept {
    const int savedErrno = errno; Line line = begin("ngx-entry", "entered"); line.string("feature", feature); line.pointer("feature_identity", self); line.pointer("command_list", commandList); line.pointer("params", params); line.integer("eval_id", evalID); line.key("exposure_fix_enabled"); line.append("%s", gExposureEnabled.load(std::memory_order_relaxed) ? "true" : "false"); emit(line); errno = savedErrno;
}

void logEvaluate(const char* feature, const char* phase, const void* self, const void* commandList, const void* params, std::uint64_t evalID, std::uint32_t result = 0, bool hasResult = false) noexcept {
    const int savedErrno = errno;
    Line line = begin("ngx-evaluate", phase);
    line.string("feature", feature);
    line.pointer("feature_identity", self);
    line.pointer("command_list", commandList);
    line.pointer("params", params);
    line.integer("eval_id", evalID);
    const char* resources[] = {"Color", "Output", "Depth", "MotionVectors", "ExposureTexture", "DLSS.Input.Bias.Current.Color.Mask", "TransparencyMask"};
    for (const char* key : resources) {
        void* value = nullptr;
        GetterStatus status = GetterStatus::Missing;
        std::uint32_t raw = 0;
        bool returned = false;
        if (params) try { raw = gGetResource(params, key, &value); returned = true; status = raw == 1 ? GetterStatus::Ok : raw == kMissing ? GetterStatus::Missing : GetterStatus::Failure; } catch (...) { status = GetterStatus::Failure; }
        line.key(key);
        status == GetterStatus::Ok && value ? line.append("\"0x%llx\"", static_cast<unsigned long long>(reinterpret_cast<std::uintptr_t>(value))) : line.append("null");
        char field[112]; snprintf(field, sizeof(field), "%s_status", key); line.string(field, status == GetterStatus::Ok ? (value ? "present" : "present_null") : statusName(status));
        snprintf(field, sizeof(field), "%s_is_null", key); line.key(field); line.append("%s", status == GetterStatus::Ok && !value ? "true" : "false");
        snprintf(field, sizeof(field), "%s_getter_result", key); line.key(field); returned ? line.append("%u", raw) : line.append("null");
    }
    float exposureScale = 0;
    std::uint32_t exposureRaw = 0; bool exposureReturned = false; const auto exposureScaleStatus = getFloat(params, "DLSS.Exposure.Scale", exposureScale, &exposureRaw, &exposureReturned);
    line.number("DLSS.Exposure.Scale", exposureScale, exposureScaleStatus == GetterStatus::Ok);
    line.string("DLSS.Exposure.Scale_status", exposureScaleStatus == GetterStatus::Ok && !std::isfinite(exposureScale) ? "nonfinite" : statusName(exposureScaleStatus)); line.key("DLSS.Exposure.Scale_finite"); line.append("%s", exposureScaleStatus == GetterStatus::Ok && std::isfinite(exposureScale) ? "true" : "false"); line.key("DLSS.Exposure.Scale_getter_result"); exposureReturned ? line.append("%u", exposureRaw) : line.append("null");
    const char* floats[] = {"DLSS.Pre.Exposure", "Jitter.Offset.X", "Jitter.Offset.Y", "MV.Scale.X", "MV.Scale.Y", "Sharpness"};
    for (const char* key : floats) { float value = 0; std::uint32_t raw = 0; bool returned = false; const auto status = getFloat(params, key, value, &raw, &returned); line.number(key, value, status == GetterStatus::Ok); char statusKey[96]; snprintf(statusKey, sizeof(statusKey), "%s_status", key); line.string(statusKey, status == GetterStatus::Ok && !std::isfinite(value) ? "nonfinite" : statusName(status)); snprintf(statusKey, sizeof(statusKey), "%s_finite", key); line.key(statusKey); line.append("%s", status == GetterStatus::Ok && std::isfinite(value) ? "true" : "false"); snprintf(statusKey, sizeof(statusKey), "%s_getter_result", key); line.integer(statusKey, raw); }
    const char* uints[] = {"DLSS.Render.Subrect.Dimensions.Width", "DLSS.Render.Subrect.Dimensions.Height", "DLSS.Render.Subrect.Dimensions.X", "DLSS.Render.Subrect.Dimensions.Y", "Width", "Height", "OutWidth", "OutHeight"};
    for (const char* key : uints) { std::uint32_t value = 0, raw = 0; bool returned = false; const auto status = getUint(params, key, value, &raw, &returned); line.key(key); status == GetterStatus::Ok ? line.append("%u", value) : line.append("null"); char statusKey[96]; snprintf(statusKey, sizeof(statusKey), "%s_status", key); line.string(statusKey, statusName(status)); snprintf(statusKey, sizeof(statusKey), "%s_getter_result", key); line.key(statusKey); returned ? line.append("%u", raw) : line.append("null"); }
    const char* ints[] = {"Reset", "DLSS.Feature.Create.Flags"};
    for (const char* key : ints) { std::int32_t value = 0; std::uint32_t raw = 0; bool returned = false; const auto status = getInt(params, key, value, &raw, &returned); line.key(key); status == GetterStatus::Ok ? line.append("%d", value) : line.append("null"); char statusKey[96]; snprintf(statusKey, sizeof(statusKey), "%s_status", key); line.string(statusKey, statusName(status)); snprintf(statusKey, sizeof(statusKey), "%s_getter_result", key); line.key(statusKey); returned ? line.append("%u", raw) : line.append("null"); }
    if (hasResult) { line.key("result"); line.append("%u", result); }
    emit(line);
    errno = savedErrno;
}

template<typename R> R load(const void* base, std::size_t offset) noexcept { R value{}; if (base) memcpy(&value, static_cast<const std::uint8_t*>(base) + offset, sizeof(value)); return value; }

void addTexture(Line& line, const char* name, id texture) noexcept {
    line.pointer(name, (__bridge const void*)texture);
    if (!texture) return;
    @try {
        const auto width = [texture width];
        const auto height = [texture height];
        const auto format = [texture pixelFormat];
        char key[48];
        snprintf(key, sizeof(key), "%s_width", name); line.key(key); line.append("%llu", static_cast<unsigned long long>(width));
        snprintf(key, sizeof(key), "%s_height", name); line.key(key); line.append("%llu", static_cast<unsigned long long>(height));
        snprintf(key, sizeof(key), "%s_format", name); line.key(key); line.append("%llu", static_cast<unsigned long long>(format));
    } @catch (id) {}
}


void addMplSnapshot(Line& line, const void* command) noexcept {
    static constexpr const char* textures[] = {"submitted_color", "submitted_depth", "submitted_motion", "submitted_output", "submitted_exposure", "submitted_reactive"};
    for (std::size_t i = 0; i < 6; ++i) addTexture(line, textures[i], (__bridge id)load<void*>(command, 0x20 + i * 8));
    static constexpr const char* dimensions[] = {"submitted_input_width", "submitted_input_height", "submitted_color_subrect_x", "submitted_color_subrect_y", "submitted_depth_subrect_x", "submitted_depth_subrect_y", "submitted_motion_subrect_x", "submitted_motion_subrect_y", "submitted_reactive_subrect_x", "submitted_reactive_subrect_y", "submitted_output_subrect_x", "submitted_output_subrect_y"};
    for (std::size_t i = 0; i < 12; ++i) { line.key(dimensions[i]); line.append("%u", load<std::uint32_t>(command, 0x50 + i * 4)); }
    static constexpr const char* scalars[] = {"submitted_pre_exposure", "submitted_jitter_x", "submitted_jitter_y", "submitted_mv_scale_x", "submitted_mv_scale_y"};
    for (std::size_t i = 0; i < 5; ++i) line.number(scalars[i], load<float>(command, 0x80 + i * 4), true);
    line.key("submitted_caller_reset"); line.append("%u", load<std::uint32_t>(command, 0x94));
    line.key("submitted_forced_reset"); line.append("%s", load<std::uint8_t>(command, 0x98) ? "true" : "false");
    line.key("submitted_logical_flag_0x1b"); line.append("%s", load<std::uint8_t>(command, 0x1b) ? "true" : "false");
}

void logScaler(const char* source, const char* phase, const void* command, bool isMpl) noexcept {
    Line line = begin(source, phase);
    line.pointer("command", command);
    if (isMpl) { line.string("correlation_key", "command_identity"); line.string("correlation_scope", "record_replay_identity_only_reexecution_possible"); }
    if (isMpl) addMplSnapshot(line, command);
    const void* wrapper = load<void*>(command, 8);
    line.pointer("wrapper", nullptr);
    id scaler = (__bridge id)const_cast<void*>(wrapper);
    line.pointer("scaler", (__bridge const void*)scaler);
    if (scaler) @try {
        struct Property { const char* name; const char* selector; bool texture; };
        static constexpr Property properties[] = {
            {"color", "colorTexture", true}, {"output", "outputTexture", true}, {"depth", "depthTexture", true},
            {"motion", "motionTexture", true}, {"exposure", "exposureTexture", true}, {"reactive", "reactiveMaskTexture", true}
        };
        for (const auto& p : properties) {
            SEL selector = sel_registerName(p.selector);
            if ([scaler respondsToSelector:selector]) addTexture(line, p.name, ((id (*)(id, SEL))objc_msgSend)(scaler, selector));
        }
        struct Scalar { const char* name; const char* selector; };
        static constexpr Scalar scalars[] = {{"jitter_x", "jitterOffsetX"}, {"jitter_y", "jitterOffsetY"}, {"mv_scale_x", "motionVectorScaleX"}, {"mv_scale_y", "motionVectorScaleY"}, {"pre_exposure", "preExposure"}};
        for (const auto& p : scalars) {
            SEL selector = sel_registerName(p.selector);
            if ([scaler respondsToSelector:selector]) {
                const float value = ((float (*)(id, SEL))objc_msgSend)(scaler, selector);
                line.number(p.name, value, true);
            }
        }
        SEL resetSelector = sel_registerName("reset");
        if ([scaler respondsToSelector:resetSelector]) { line.key("reset"); line.append("%s", ((BOOL (*)(id, SEL))objc_msgSend)(scaler, resetSelector) ? "true" : "false"); }
    } @catch (id) {}
    emit(line);
}

__attribute__((ms_abi)) std::uint32_t evaluateAPI(void* commandList, void* handle, void* params, std::uintptr_t callback) {
    if (!gEnabled.load(std::memory_order_relaxed)) return gEvaluateAPI.load()(commandList, handle, params, callback);
    const int incomingErrno = errno; Line entry = begin("ngx-api-entry", "entered"); entry.pointer("command_list", commandList); entry.pointer("handle", handle); entry.pointer("params", params); entry.pointer("callback", reinterpret_cast<const void*>(callback)); emit(entry); errno = incomingErrno;
    const auto result = gEvaluateAPI.load()(commandList, handle, params, callback);
    const int resultErrno = errno; Line returned = begin("ngx-api-entry", "returned"); returned.pointer("command_list", commandList); returned.pointer("handle", handle); returned.pointer("params", params); returned.key("result"); returned.append("%u", result); emit(returned); errno = resultErrno;
    return result;
}

std::uint32_t evaluateMPL(void* self, void* commandList, void* params, std::uintptr_t callback) {
    const bool diagnostics = gEnabled.load(std::memory_order_relaxed);
    const bool correction = gExposureEnabled.load(std::memory_order_relaxed);
    if (!diagnostics && !correction) return gEvaluateMPL.load()(self, commandList, params, callback);
    void* exposureTexture = nullptr; bool hasExposureTexture = false;
    if (correction && params) try { hasExposureTexture = gGetResource(params, "ExposureTexture", &exposureTexture) != kMissing && exposureTexture; } catch (...) {}
    exposure::EvaluationScope exposureScope(load<std::uint8_t>(self, 0x18) != 0, load<std::uint8_t>(self, 0x19) != 0, hasExposureTexture, params);
    if (!diagnostics) return gEvaluateMPL.load()(self, commandList, params, callback);
    const std::uint64_t evalID = gSequence.fetch_add(1, std::memory_order_relaxed);
    const int incomingErrno = errno; logEntry("mpl", self, commandList, params, evalID); logEvaluate("mpl", "before", self, commandList, params, evalID); errno = incomingErrno;
    ScopedID scope(gCurrentEvalID, evalID);
    const auto result = gEvaluateMPL.load()(self, commandList, params, callback);
    const int resultErrno = errno; logEvaluate("mpl", "after", self, commandList, params, evalID, result, true); errno = resultErrno;
    return result;
}
std::uint32_t evaluateMTL(void* self, void* commandList, void* params, std::uintptr_t callback) {
    const bool diagnostics = gEnabled.load(std::memory_order_relaxed);
    const bool correction = gExposureEnabled.load(std::memory_order_relaxed);
    if (!diagnostics && !correction) return gEvaluateMTL.load()(self, commandList, params, callback);
    void* exposureTexture = nullptr; bool hasExposureTexture = false;
    if (correction && params) try { hasExposureTexture = gGetResource(params, "ExposureTexture", &exposureTexture) != kMissing && exposureTexture; } catch (...) {}
    exposure::EvaluationScope exposureScope(load<std::uint8_t>(self, 0x20) != 0, load<std::uint8_t>(self, 0x21) != 0, hasExposureTexture, params);
    if (!diagnostics) return gEvaluateMTL.load()(self, commandList, params, callback);
    const std::uint64_t evalID = gSequence.fetch_add(1, std::memory_order_relaxed);
    const int incomingErrno = errno; logEntry("mtl", self, commandList, params, evalID); logEvaluate("mtl", "before", self, commandList, params, evalID); errno = incomingErrno;
    ScopedID scope(gCurrentEvalID, evalID);
    const auto result = gEvaluateMTL.load()(self, commandList, params, callback);
    const int resultErrno = errno; logEvaluate("mtl", "after", self, commandList, params, evalID, result, true); errno = resultErrno;
    return result;
}
void temporalScale(void* self, void* scaler, const void* desc) {
    const bool diagnostics = gEnabled.load(std::memory_order_relaxed);
    if (!diagnostics && !gExposureEnabled.load(std::memory_order_relaxed)) return gTemporalScale.load()(self, scaler, desc);
    alignas(16) std::uint8_t patched[0x78]; memcpy(patched, desc, sizeof(patched));
    const auto fixResult = exposure::patchMplDescriptor(self, patched);
    const void* submitted = fixResult == exposure::ApplyResult::Applied ? patched : desc;
    if (!diagnostics) return gTemporalScale.load()(self, scaler, submitted);
    const int incomingErrno = errno; Line l = begin("mpl-record", "before"); l.pointer("feature", scaler); l.pointer("descriptor", submitted); l.string("exposure_fix", fixResult == exposure::ApplyResult::Applied ? "applied" : fixResult == exposure::ApplyResult::Failed ? "failed" : "not_applicable"); const auto recordID = gRecordID.fetch_add(1, std::memory_order_relaxed); ScopedID recordScope(gCurrentRecordID, recordID); l.integer("record_id", recordID); if (gCurrentEvalID) l.integer("incoming_eval_id", gCurrentEvalID); else { l.key("incoming_eval_id"); l.append("null"); } emit(l); errno = incomingErrno;
    gTemporalScale.load()(self, scaler, submitted);
}
void replay(void* replayer, const void* command) {
    if (!gEnabled.load(std::memory_order_relaxed)) return gReplay.load()(replayer, command);
    const int incomingErrno = errno; logScaler("mpl-replay", "before", command, true); errno = incomingErrno;
    gReplay.load()(replayer, command);
    const int resultErrno = errno; logScaler("mpl-replay", "after", command, true); errno = resultErrno;
}
void encode(void* encoder, const void* command) {
    const bool diagnostics = gEnabled.load(std::memory_order_relaxed);
    if (!diagnostics && !gExposureEnabled.load(std::memory_order_relaxed)) return gEncode.load()(encoder, command);
    exposure::LegacyEncodeScope scope(encoder, command);
    if (!diagnostics) return gEncode.load()(encoder, scope.handoffCommand());
    const int incomingErrno = errno; logScaler("mtl-encode", "before", command, false); errno = incomingErrno;
    gEncode.load()(encoder, scope.handoffCommand());
    const int resultErrno = errno; logScaler("mtl-encode", "after", command, false); errno = resultErrno;
}

extern "C" std::uintptr_t yaagl_legacy_resume;
extern "C" std::uintptr_t yaagl_mpl_post_resume;
extern "C" void yaagl_patch_legacy(void* command) noexcept {
    const auto result = exposure::recordLegacyScale(command);
    if (!gEnabled.load(std::memory_order_relaxed)) return;
    const int savedErrno = errno; Line line = begin("mtl-record", "post_record"); line.pointer("command", command); line.integer("eval_id", gCurrentEvalID); line.string("exposure_fix", result == exposure::ApplyResult::Applied ? "metadata_recorded" : result == exposure::ApplyResult::Failed ? "metadata_failed" : "not_applicable"); emit(line); errno = savedErrno;
}
extern "C" __attribute__((naked)) void yaagl_legacy_gate() {
    __asm__ volatile(
        "pushfq\n\tpushq %rax\n\tpushq %rcx\n\tpushq %rdx\n\tpushq %rsi\n\tpushq %rdi\n\tpushq %r8\n\tpushq %r9\n\tpushq %r10\n\tpushq %r11\n\t"
        "subq $512, %rsp\n\tfxsave64 (%rsp)\n\t"
        "movq %r15, %rdi\n\tcallq _yaagl_patch_legacy\n\t"
        "fxrstor64 (%rsp)\n\taddq $512, %rsp\n\tpopq %r11\n\tpopq %r10\n\tpopq %r9\n\tpopq %r8\n\tpopq %rdi\n\tpopq %rsi\n\tpopq %rdx\n\tpopq %rcx\n\tpopq %rax\n\tpopfq\n\tjmpq *_yaagl_legacy_resume(%rip)\n\t");
}

extern "C" void yaagl_log_mpl_post(void* command) noexcept {
    if (!gEnabled.load(std::memory_order_relaxed)) return;
    const int savedErrno = errno; Line line = begin("mpl-record", "post_record"); line.pointer("command", command); line.integer("record_id", gCurrentRecordID); if (gCurrentEvalID) line.integer("eval_id", gCurrentEvalID); else { line.key("eval_id"); line.append("null"); } emit(line); errno = savedErrno;
}
extern "C" __attribute__((naked)) void yaagl_mpl_post_gate() {
    __asm__ volatile(
        "pushfq\n\tpushq %rax\n\tpushq %rcx\n\tpushq %rdx\n\tpushq %rsi\n\tpushq %rdi\n\tpushq %r8\n\tpushq %r9\n\tpushq %r10\n\tpushq %r11\n\t"
        "subq $512, %rsp\n\tfxsave64 (%rsp)\n\tmovq 576(%rsp), %rdi\n\tcallq _yaagl_log_mpl_post\n\tfxrstor64 (%rsp)\n\taddq $512, %rsp\n\t"
        "popq %r11\n\tpopq %r10\n\tpopq %r9\n\tpopq %r8\n\tpopq %rdi\n\tpopq %rsi\n\tpopq %rdx\n\tpopq %rcx\n\tpopq %rax\n\tpopfq\n\tjmpq *_yaagl_mpl_post_resume(%rip)\n\t");
}


} // namespace

extern "C" std::uintptr_t yaagl_legacy_resume = 0;
extern "C" std::uintptr_t yaagl_mpl_post_resume = 0;

std::array<std::uintptr_t, kHookCount> initializeHooks(const std::uint8_t* imageBase, const std::array<std::uintptr_t, kHookCount>& originals) noexcept {
    if (!imageBase) return {};
    for (const auto original : originals) if (!original) return {};
    gEvaluateMPL.store(reinterpret_cast<Evaluate>(originals[0]));
    gEvaluateAPI.store(reinterpret_cast<EvaluateAPI>(originals[7]));
    gEvaluateMTL.store(reinterpret_cast<Evaluate>(originals[1]));
    gTemporalScale.store(reinterpret_cast<TemporalScale>(originals[2]));
    gReplay.store(reinterpret_cast<Replay>(originals[3]));
    gEncode.store(reinterpret_cast<Encode>(originals[4]));
    yaagl_legacy_resume = originals[5];
    yaagl_mpl_post_resume = originals[6];
    gGetFloat = reinterpret_cast<GetFloat>(const_cast<std::uint8_t*>(imageBase) + 0xa9a9c);
    gGetUint = reinterpret_cast<GetUint>(const_cast<std::uint8_t*>(imageBase) + 0xa97d2);
    gGetInt = reinterpret_cast<GetInt>(const_cast<std::uint8_t*>(imageBase) + 0xa966e);
    gGetResource = reinterpret_cast<GetResource>(const_cast<std::uint8_t*>(imageBase) + 0xa93a6);
    exposure::initialize(imageBase, gGetFloat);
    const char* exposureEnabled = getenv("YAAGL_METALFX_EXPOSURE_SCALE_FIX");
    gExposureEnabled.store(exposureEnabled && strcmp(exposureEnabled, "1") == 0, std::memory_order_release);
    const char* enabled = getenv("YAAGL_METALFX_DIAGNOSTICS");
    const bool diagnostics = enabled && strcmp(enabled, "1") == 0;
    if (diagnostics) {
        const char* path = getenv("YAAGL_METALFX_LOG");
        if (path && path[0] == '/') {
            const int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
            struct stat info{};
            if (fd >= 0 && fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == geteuid() && (info.st_mode & 0077) == 0) {
                (void)fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
                gLogFd = fd;
            } else if (fd >= 0) {
                close(fd);
            }
        }
    }
    gEnabled.store(diagnostics, std::memory_order_release);
    return {reinterpret_cast<std::uintptr_t>(&evaluateMPL), reinterpret_cast<std::uintptr_t>(&evaluateMTL), reinterpret_cast<std::uintptr_t>(&temporalScale), reinterpret_cast<std::uintptr_t>(&replay), reinterpret_cast<std::uintptr_t>(&encode), diagnostics || gExposureEnabled.load(std::memory_order_acquire) ? reinterpret_cast<std::uintptr_t>(&yaagl_legacy_gate) : originals[5], diagnostics ? reinterpret_cast<std::uintptr_t>(&yaagl_mpl_post_gate) : originals[6], diagnostics ? reinterpret_cast<std::uintptr_t>(&evaluateAPI) : originals[7]};
}

} // namespace yaagl::pso::ngx
