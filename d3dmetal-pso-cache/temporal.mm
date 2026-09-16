#import "temporal.hpp"
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <unordered_set>

namespace yaagl::pso::temporal {
namespace {
struct Config {
    bool enabled = false, repair = false;
    float testMotionX = 1, testMotionY = 1;
    float testJitterX = 1, testJitterY = 1;
    int testDepth = -1;
    bool testReset = false;
} gConfig;
GetFloat gFloat = nullptr;
GetUint gUint = nullptr;
GetInt gInt = nullptr;
Logger gLogger = nullptr;
thread_local const Parameters* gEvaluation = nullptr;
thread_local ReplayScope* gReplay = nullptr;
std::mutex gLock;
std::unordered_set<Class> gHookedClasses;
char gFlagAssociation;
char gCreationAssociation;
bool gFactoryHooked = false;
constexpr std::uint64_t kAmbiguous = UINT64_MAX;
std::atomic<std::uint64_t> gEncodeID{0};

template<class T> T loadAt(const void* p, std::size_t offset) noexcept {
    T value{};
    if (p) std::memcpy(&value, static_cast<const char*>(p) + offset, sizeof(value));
    return value;
}
void emit(const char* s) noexcept {
    if (gLogger) gLogger(s, std::strlen(s));
}
void event(const char* reason, const void* object) noexcept {
    char line[320];
    std::snprintf(line, sizeof(line),
        "{\"source\":\"temporal-contract\",\"event\":\"%s\",\"object\":\"%p\"}\n", reason, object);
    emit(line);
}
SEL selector(const char* name) noexcept { return sel_registerName(name); }
bool responds(id obj, const char* name) { return [obj respondsToSelector:selector(name)]; }
float getFloat(id obj, const char* name) {
    if (!responds(obj, name)) return NAN;
    return reinterpret_cast<float(*)(id, SEL)>(objc_msgSend)(obj, selector(name));
}
std::uint64_t getSize(id obj, const char* name) {
    if (!responds(obj, name)) return 0;
    return reinterpret_cast<NSUInteger(*)(id, SEL)>(objc_msgSend)(obj, selector(name));
}
int getBool(id obj, const char* name) {
    if (!responds(obj, name)) return -1;
    return reinterpret_cast<BOOL(*)(id, SEL)>(objc_msgSend)(obj, selector(name)) ? 1 : 0;
}
id getObject(id obj, const char* name) {
    if (!responds(obj, name)) return nil;
    return reinterpret_cast<id(*)(id, SEL)>(objc_msgSend)(obj, selector(name));
}
void setFloat(id obj, const char* name, float value) {
    reinterpret_cast<void(*)(id, SEL, float)>(objc_msgSend)(obj, selector(name), value);
}
void setSize(id obj, const char* name, std::uint32_t value) {
    reinterpret_cast<void(*)(id, SEL, NSUInteger)>(objc_msgSend)(obj, selector(name), value);
}
void setBool(id obj, const char* name, bool value) {
    reinterpret_cast<void(*)(id, SEL, BOOL)>(objc_msgSend)(obj, selector(name), value ? YES : NO);
}
const char* jsonFloat(float x, char (&buffer)[48]) noexcept {
    if (!std::isfinite(x)) return "null";
    std::snprintf(buffer, sizeof(buffer), "%.9g", static_cast<double>(x));
    return buffer;
}
bool fitsTexture(std::uint64_t pointer, std::uint32_t w, std::uint32_t h) {
    id texture = reinterpret_cast<id>(static_cast<std::uintptr_t>(pointer));
    return texture && w && h && getSize(texture, "width") >= w && getSize(texture, "height") >= h;
}
bool fitsInputs(const Descriptor& d) {
    return zeroOrigins(d) && fitsTexture(d.color, d.width, d.height) &&
        fitsTexture(d.depth, d.width, d.height) && fitsTexture(d.motion, d.width, d.height);
}
bool haveSetters(id obj) {
    static constexpr const char* names[] = {
        "setMotionVectorScaleX:", "setMotionVectorScaleY:", "setJitterOffsetX:",
        "setJitterOffsetY:", "setInputContentWidth:", "setInputContentHeight:",
        "setDepthReversed:", "setReset:"
    };
    for (const char* name : names) if (!responds(obj, name)) return false;
    return true;
}
void installEncodeHook(id object) {
    Class cls = object_getClass(object);
    std::lock_guard<std::mutex> lock(gLock);
    if (gHookedClasses.count(cls)) return;
    SEL sel = selector("encodeToCommandBuffer:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != 3) {
        event("encode_selector_unavailable", object); return;
    }
    char* ret = method_copyReturnType(method);
    char* arg = method_copyArgumentType(method, 2);
    const bool signatureOK = ret && ret[0] == 'v' && arg && arg[0] == '@';
    std::free(ret); std::free(arg);
    if (!signatureOK) { event("encode_signature_unexpected", object); return; }
    using EncodeIMP = void(*)(id, SEL, id);
    const EncodeIMP previous = reinterpret_cast<EncodeIMP>(method_getImplementation(method));
    // Blocks capture the preceding implementation, including inherited IMPs.
    // Install only on the concrete class; never overwrite a superclass IMP.
    IMP replacement = imp_implementationWithBlock(^void(id self, id commandBuffer) {
        ReplayScope* scope = gReplay;
        if (!scope || scope->scaler != reinterpret_cast<void*>(self) || scope->inEncode) {
            previous(self, sel, commandBuffer); return;
        }
        scope->inEncode = true;
        @try {
            scope->beforeEncode(reinterpret_cast<void*>(self));
            previous(self, sel, commandBuffer);
        } @finally {
            scope->inEncode = false;
        }
    });
    if (!replacement) { event("encode_imp_allocation_failed", object); return; }
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method))) {
        class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    }
    gHookedClasses.insert(cls);
    event("encode_hook_installed", object);
}
// Read creation-only settings from the PUBLIC descriptor factory. Do not
// infer these settings from NGX flags or an unavailable scaler getter.
void installFactoryHook() {
    std::lock_guard<std::mutex> lock(gLock);
    if (gFactoryHooked) return;
    Class cls = objc_getClass("MTLFXTemporalScalerDescriptor");
    if (!cls) return; // Retry when EvaluationScope runs; coverage stays explicit.
    SEL sel = selector("newTemporalScalerWithDevice:compiler:");
    Method method = class_getInstanceMethod(cls, sel);
    if (!method || method_getNumberOfArguments(method) != 4) return;
    char* ret = method_copyReturnType(method);
    const bool signatureOK = ret && ret[0] == '@';
    std::free(ret);
    if (!signatureOK) return;
    using Factory = id(*)(id, SEL, id, id);
    const Factory previous = reinterpret_cast<Factory>(method_getImplementation(method));
    IMP replacement = imp_implementationWithBlock(^id(id descriptor, id device, id compiler) {
        const int ae = getBool(descriptor, "isAutoExposureEnabled");
        const int jm = getBool(descriptor, "isJitteredMotionVectorsEnabled");
        const int om = getBool(descriptor, "isOutputResolutionMotionVectorsEnabled");
        const int cp = getBool(descriptor, "isInputContentPropertiesEnabled");
        const auto w = getSize(descriptor, "inputWidth");
        const auto h = getSize(descriptor, "inputHeight");
        id result = previous(descriptor, sel, device, compiler);
        if (result) {
            // Associated with object lifetime, not a recycled command address.
            NSDictionary* data = @{@"auto": @(ae), @"jittered": @(jm), @"output_motion": @(om), @"content": @(cp)};
            objc_setAssociatedObject(result, &gCreationAssociation, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            char line[640];
            std::snprintf(line, sizeof(line),
                "{\"source\":\"temporal-contract\",\"event\":\"created\",\"scaler\":\"%p\","
                "\"auto_exposure\":%d,\"jittered_motion\":%d,\"output_resolution_motion\":%d,\"input_content_properties\":%d,"
                "\"input_width\":%llu,\"input_height\":%llu}\n",
                reinterpret_cast<void*>(result), ae, jm, om, cp,
                static_cast<unsigned long long>(w), static_cast<unsigned long long>(h));
            emit(line);
        }
        return result; // Preserve +1 ownership of newTemporalScaler... exactly.
    });
    if (!replacement) return;
    if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(method)))
        class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
    gFactoryHooked = true;
    event("factory_hook_installed", reinterpret_cast<void*>(cls));
}
int creationValue(id object, NSString* key) {
    NSDictionary* data = reinterpret_cast<NSDictionary*>(objc_getAssociatedObject(object, &gCreationAssociation));
    NSNumber* value = [data objectForKey:key];
    return value ? [value intValue] : -1;
}

float envMultiplier(const char* name) noexcept {
    const char* value = std::getenv(name);
    if (!value) return 1;
    char* end = nullptr;
    const float number = std::strtof(value, &end);
    if (!end || *end || !std::isfinite(number)) { event("invalid_test_multiplier", nullptr); return 1; }
    return number;
}
} // namespace

void initialize(GetFloat f, GetUint u, GetInt i, Logger log) noexcept {
    gFloat = f; gUint = u; gInt = i; gLogger = log;
    const char* mode = std::getenv("YAAGL_METALFX_TEMPORAL");
    if (!mode) return;
    gConfig.enabled = !std::strcmp(mode, "observe") || !std::strcmp(mode, "repair");
    gConfig.repair = !std::strcmp(mode, "repair");
    if (!gConfig.enabled) { event("invalid_mode", nullptr); return; }
    // Test perturbations require a separate explicit opt-in. Never set these
    // in a shipped default environment. Restart between test conditions.
    const char* tests = std::getenv("YAAGL_METALFX_TEMPORAL_TESTS");
    if (tests && !std::strcmp(tests, "1")) {
        gConfig.testMotionX = envMultiplier("YAAGL_METALFX_TEST_MV_X");
        gConfig.testMotionY = envMultiplier("YAAGL_METALFX_TEST_MV_Y");
        gConfig.testJitterX = envMultiplier("YAAGL_METALFX_TEST_JITTER_X");
        gConfig.testJitterY = envMultiplier("YAAGL_METALFX_TEST_JITTER_Y");
        const char* depth = std::getenv("YAAGL_METALFX_TEST_DEPTH");
        if (depth && (!std::strcmp(depth, "0") || !std::strcmp(depth, "1"))) gConfig.testDepth = depth[0] - '0';
        const char* reset = std::getenv("YAAGL_METALFX_TEST_RESET");
        gConfig.testReset = reset && !std::strcmp(reset, "1");
        event("test_controls_enabled", nullptr);
    }
    @try { installFactoryHook(); } @catch (id) { event("factory_install_exception", nullptr); }
    event(gConfig.repair ? "repair_enabled" : "observe_enabled", nullptr);
}
bool enabled() noexcept { return gConfig.enabled; }

EvaluationScope::EvaluationScope(const void* params) noexcept {
    if (!enabled()) return;
    const int saved = errno;
    @try { installFactoryHook(); } @catch (id) { event("factory_install_exception", nullptr); }
    active_ = true; previous_ = gEvaluation; gEvaluation = &value_;
    if (params) try {
        std::int32_t flags = 0;
        value_.flagsOK = gInt(params, "DLSS.Feature.Create.Flags", &flags) == 1;
        value_.flags = static_cast<std::uint32_t>(flags);
        // Size fallback is intentionally NOT nominal Width/Height. Unknown
        // active extent means retain the translator's native descriptor.
        value_.sizeOK = gUint(params, "DLSS.Render.Subrect.Dimensions.Width", &value_.width) == 1 &&
            gUint(params, "DLSS.Render.Subrect.Dimensions.Height", &value_.height) == 1;
        value_.motionOK = gFloat(params, "MV.Scale.X", &value_.motionScaleX) == 1 &&
            gFloat(params, "MV.Scale.Y", &value_.motionScaleY) == 1;
        value_.jitterOK = gFloat(params, "Jitter.Offset.X", &value_.jitterX) == 1 &&
            gFloat(params, "Jitter.Offset.Y", &value_.jitterY) == 1;
    } catch (...) { event("parameter_getter_exception", params); }
    errno = saved;
}
EvaluationScope::~EvaluationScope() { if (active_) gEvaluation = previous_; }

bool patchDescriptor(void* bytes) noexcept {
    if (!enabled() || !gConfig.repair || !gEvaluation || !bytes) return false;
    const int saved = errno;
    bool changed = false;
    @try {
        Descriptor d = loadAt<Descriptor>(bytes, 0);
        Descriptor candidate = d;
        changed = repairDescriptor(candidate, *gEvaluation);
        if (changed && fitsInputs(candidate)) std::memcpy(bytes, &candidate, sizeof(candidate));
        else changed = false;
    } @catch (id) { event("descriptor_validation_exception", bytes); }
    errno = saved;
    return changed;
}

void recordComplete(const void* command) noexcept {
    if (!enabled() || !command || !gEvaluation || !gEvaluation->flagsOK) return;
    const int saved = errno;
    @try {
        id object = reinterpret_cast<id>(loadAt<void*>(command, 8));
        if (object) {
            std::lock_guard<std::mutex> lock(gLock);
            NSNumber* old = reinterpret_cast<NSNumber*>(objc_getAssociatedObject(object, &gFlagAssociation));
            const auto flags = static_cast<unsigned long long>(gEvaluation->flags);
            if (!old) {
                objc_setAssociatedObject(object, &gFlagAssociation,
                    [NSNumber numberWithUnsignedLongLong:flags], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else if ([old unsignedLongLongValue] != flags && [old unsignedLongLongValue] != kAmbiguous) {
                // Creation flags must be immutable for a scaler. Ambiguity
                // permanently disables automatic repair for this object.
                objc_setAssociatedObject(object, &gFlagAssociation,
                    [NSNumber numberWithUnsignedLongLong:kAmbiguous], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                event("conflicting_feature_flags", object);
            }
        }
    } @catch (id) { event("flag_association_exception", command); }
    errno = saved;
}

ReplayScope::ReplayScope(const void* command) noexcept {
    if (!enabled() || !command) return;
    const int saved = errno;
    command_ = command; descriptor_ = loadAt<Descriptor>(command, 0x20);
    scaler = loadAt<void*>(command, 8);
    forcedReset_ = loadAt<std::uint8_t>(command, 0x98) != 0;
    previous_ = gReplay; gReplay = this; active_ = true;
    @try {
        id object = reinterpret_cast<id>(scaler);
        if (object) {
            {
                std::lock_guard<std::mutex> lock(gLock);
                NSNumber* stored = reinterpret_cast<NSNumber*>(objc_getAssociatedObject(object, &gFlagAssociation));
                if (stored && [stored unsignedLongLongValue] != kAmbiguous) {
                    flags_ = static_cast<std::uint32_t>([stored unsignedLongLongValue]);
                    flagsOK_ = true;
                }
            }
            installEncodeHook(object);
        }
    } @catch (id) { event("replay_setup_exception", command); }
    errno = saved;
}
ReplayScope::~ReplayScope() {
    if (!active_) return;
    const int saved = errno;
    if (!encodes_) event("NO_ENCODE_OBSERVED", command_);
    gReplay = previous_;
    errno = saved;
}

void ReplayScope::beforeEncode(void* pointer) noexcept {
    ++encodes_;
    const int saved = errno;
    @try {
        id object = reinterpret_cast<id>(pointer);
        const float beforeX = getFloat(object, "motionVectorScaleX");
        const float beforeY = getFloat(object, "motionVectorScaleY");
        const int beforeDepth = getBool(object, "isDepthReversed");
        const int beforeReset = getBool(object, "reset");
        const auto beforeW = getSize(object, "inputContentWidth");
        const auto beforeH = getSize(object, "inputContentHeight");
        const auto capacityW = getSize(object, "inputWidth");
        const auto capacityH = getSize(object, "inputHeight");
        const int createdAuto = creationValue(object, @"auto");
        const int createdJittered = creationValue(object, @"jittered");
        const int createdOutputMotion = creationValue(object, @"output_motion");
        const int createdContent = creationValue(object, @"content");
        const bool capacityOK = capacityW >= descriptor_.width && capacityH >= descriptor_.height;
        const bool contentOK = (capacityW == descriptor_.width && capacityH == descriptor_.height) || createdContent == 1;
        const bool eligible = flagsOK_ && supportedFlags(flags_) && validScalars(descriptor_) &&
            fitsInputs(descriptor_) && capacityOK && contentOK && haveSetters(object);
        if (gConfig.repair && eligible) {
            setFloat(object, "setMotionVectorScaleX:", descriptor_.motionScaleX);
            setFloat(object, "setMotionVectorScaleY:", descriptor_.motionScaleY);
            setFloat(object, "setJitterOffsetX:", descriptor_.jitterX);
            setFloat(object, "setJitterOffsetY:", descriptor_.jitterY);
            setSize(object, "setInputContentWidth:", descriptor_.width);
            setSize(object, "setInputContentHeight:", descriptor_.height);
            setBool(object, "setDepthReversed:", (flags_ & kDepthInverted) != 0);
            // Never erase an additional reset chosen by the native scaler.
            if (descriptor_.reset || forcedReset_) setBool(object, "setReset:", true);
        }
        if (haveSetters(object)) {
            // Perturb the values actually about to be encoded; do not apply
            // multipliers at both record and replay.
            if (gConfig.testMotionX != 1) setFloat(object, "setMotionVectorScaleX:", getFloat(object, "motionVectorScaleX") * gConfig.testMotionX);
            if (gConfig.testMotionY != 1) setFloat(object, "setMotionVectorScaleY:", getFloat(object, "motionVectorScaleY") * gConfig.testMotionY);
            if (gConfig.testJitterX != 1) setFloat(object, "setJitterOffsetX:", getFloat(object, "jitterOffsetX") * gConfig.testJitterX);
            if (gConfig.testJitterY != 1) setFloat(object, "setJitterOffsetY:", getFloat(object, "jitterOffsetY") * gConfig.testJitterY);
            if (gConfig.testDepth >= 0) setBool(object, "setDepthReversed:", gConfig.testDepth != 0);
            if (gConfig.testReset) setBool(object, "setReset:", true);
        }
        const float actualX = getFloat(object, "motionVectorScaleX");
        const float actualY = getFloat(object, "motionVectorScaleY");
        const float jitterX = getFloat(object, "jitterOffsetX");
        const float jitterY = getFloat(object, "jitterOffsetY");
        const int depth = getBool(object, "isDepthReversed");
        const int reset = getBool(object, "reset");
        const auto width = getSize(object, "inputContentWidth");
        const auto height = getSize(object, "inputContentHeight");
        const bool mismatch = flagsOK_ && (
            (createdAuto >= 0 && createdAuto != static_cast<int>((flags_ & 64) != 0)) ||
            (createdJittered >= 0 && createdJittered != static_cast<int>((flags_ & kMVJittered) != 0)) ||
            (createdOutputMotion >= 0 && createdOutputMotion != static_cast<int>((flags_ & kMVLowRes) == 0)) ||
            (createdContent == 0 && (descriptor_.width != capacityW || descriptor_.height != capacityH)) ||
            actualX != descriptor_.motionScaleX || actualY != descriptor_.motionScaleY ||
            jitterX != descriptor_.jitterX || jitterY != descriptor_.jitterY ||
            width != descriptor_.width || height != descriptor_.height ||
            depth != static_cast<int>((flags_ & kDepthInverted) != 0) ||
            ((descriptor_.reset || forcedReset_) && reset != 1));
        char f[9][48];
        char line[2600];
        const int n = std::snprintf(line, sizeof(line),
          "{\"source\":\"temporal-contract\",\"event\":\"encode\",\"id\":%llu,"
          "\"command\":\"%p\",\"scaler\":\"%p\",\"flags_known\":%s,\"flags\":%u,"
          "\"repair_eligible\":%s,\"repair_enabled\":%s,\"contract_mismatch\":%s,"
          "\"before_mv_x\":%s,\"before_mv_y\":%s,\"before_depth_reversed\":%d,\"before_reset\":%d,"
          "\"before_width\":%llu,\"before_height\":%llu,"
          "\"expected_mv_x\":%s,\"expected_mv_y\":%s,\"expected_width\":%u,\"expected_height\":%u,"
          "\"mv_x\":%s,\"mv_y\":%s,\"jitter_x\":%s,\"jitter_y\":%s,"
          "\"input_width\":%llu,\"input_height\":%llu,\"capacity_width\":%llu,\"capacity_height\":%llu,"
          "\"depth_reversed\":%d,\"reset\":%d,\"caller_reset\":%u,\"forced_reset\":%s,"
          "\"pre_exposure\":%s,\"exposure\":\"%p\",\"auto_exposure_getter\":%d,\"created_auto_exposure\":%d,\"created_jittered_motion\":%d,\"created_output_resolution_motion\":%d,\"created_content_properties\":%d}\n",
          static_cast<unsigned long long>(gEncodeID.fetch_add(1)), command_, pointer,
          flagsOK_ ? "true" : "false", flags_, eligible ? "true" : "false",
          gConfig.repair ? "true" : "false", mismatch ? "true" : "false",
          jsonFloat(beforeX, f[0]), jsonFloat(beforeY, f[1]), beforeDepth, beforeReset,
          static_cast<unsigned long long>(beforeW), static_cast<unsigned long long>(beforeH),
          jsonFloat(descriptor_.motionScaleX, f[2]), jsonFloat(descriptor_.motionScaleY, f[3]), descriptor_.width, descriptor_.height,
          jsonFloat(actualX, f[4]), jsonFloat(actualY, f[5]), jsonFloat(jitterX, f[6]), jsonFloat(jitterY, f[7]),
          static_cast<unsigned long long>(width), static_cast<unsigned long long>(height),
          static_cast<unsigned long long>(capacityW), static_cast<unsigned long long>(capacityH),
          depth, reset, descriptor_.reset, forcedReset_ ? "true" : "false",
          jsonFloat(getFloat(object, "preExposure"), f[8]), reinterpret_cast<void*>(getObject(object, "exposureTexture")),
          getBool(object, "isAutoExposureEnabled"), createdAuto, createdJittered, createdOutputMotion, createdContent);
        if (n > 0 && static_cast<std::size_t>(n) < sizeof(line)) emit(line);
        else event("encode_log_overflow", pointer);
    } @catch (id) { event("encode_audit_exception", pointer); }
    errno = saved;
}
} // namespace yaagl::pso::temporal
