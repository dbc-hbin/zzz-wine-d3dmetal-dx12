#include "fsr-translator.hpp"
#include "fsr-contract.hpp"
#include "d3dmetal-transport.hpp"
#include "d3dmetal-transport-legacy.hpp"
#include "metalfx-backend.hpp"
#include "../include/yaagl_fsr_bridge.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <array>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <unordered_map>
#include <utility>

namespace yaagl::pso::fsr {
namespace {
constexpr std::uint32_t kOk = 0;
constexpr std::uint32_t kRuntime = 3;
constexpr std::uint32_t kNoProvider = 4;
constexpr std::uint32_t kMemory = 5;
constexpr std::uint32_t kParameter = 6;
constexpr std::uint64_t kProvider = 0x4d46580000000001ull;

std::atomic<bool> gAvailable{false};
std::atomic<std::uint64_t> gNextContext{1};
std::atomic<std::uint64_t> gNextDispatch{1};
std::atomic<std::uint32_t> gFailedFrameLogs{0};
std::mutex gRegistryMutex;
std::mutex gLogMutex;
FILE* gLog;

struct ComGuid { std::uint32_t a; std::uint16_t b, c; std::uint8_t d[8]; };
constexpr ComGuid kD3D12Device{0x189819f1, 0x1db6, 0x4b57,
    {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7}};

void releaseCom(void* object) noexcept {
    if (!object) return;
    using Release = std::uint32_t (__attribute__((ms_abi)) *)(void*);
    reinterpret_cast<Release>((*static_cast<void***>(object))[2])(object);
}


struct AdapterLuid { std::uint32_t low; std::int32_t high; };

bool adapterLuid(void* device, AdapterLuid& output) noexcept {
    if (!device) return false;
    using GetAdapterLuid = AdapterLuid* (__attribute__((ms_abi)) *)(void*, AdapterLuid*);
    AdapterLuid value{};
    const auto table = *static_cast<void***>(device);
    if (reinterpret_cast<GetAdapterLuid>(table[43])(device, &value) != &value) return false;
    output = value;
    return true;
}

bool sameAdapter(const AdapterLuid& a, const AdapterLuid& b) noexcept {
    return a.low == b.low && a.high == b.high;
}

std::shared_ptr<void> deviceOwner(void* object, bool child, std::string& error) {
    if (!object) { error = "null D3D12 object"; return {}; }
    using Query = std::int32_t (__attribute__((ms_abi)) *)(void*, const ComGuid*, void**);
    void* identity = nullptr;
    const auto table = *static_cast<void***>(object);
    const auto status = reinterpret_cast<Query>(table[child ? 7 : 0])(object, &kD3D12Device, &identity);
    if (status < 0 || !identity) { error = "D3D12 device identity query failed"; return {}; }
    return std::shared_ptr<void>(identity, &releaseCom);
}

struct State {
    std::mutex mutex;
    std::uint64_t id = 0;
    CreateContract create;
    std::shared_ptr<void> device;
    AdapterLuid adapter{};
    std::shared_ptr<void> executionDevice;
    std::shared_ptr<metalfx::Feature> backend;
    metalfx::Extent generationOutput{};
    void* generationDevice = nullptr;
    void* generationCompiler = nullptr;
    bool generationNeedsReset = false;
    struct CachedBackend {
        metalfx::Extent output{};
        void* device = nullptr;
        void* compiler = nullptr;
        std::shared_ptr<metalfx::Feature> backend;
    };
    // Only this context owns cached features: immutable create parameters are shared,
    // while exact native device/compiler/mode and output dimensions are checked on reuse.
    // Recorded PreparedFrames retain evicted features independently through GPU work.
    std::array<CachedBackend, 3> inactiveBackends{};
    std::size_t nextEviction = 0;
    bool retired = false;
    std::uint32_t debugLevel = 0;
};
std::unordered_map<std::uint64_t, std::shared_ptr<State>> gContexts;

void logEvent(const char* event, const State* state, std::uint64_t dispatch,
              std::uint32_t result, const char* detail = nullptr) noexcept {
    if (!gLog) return;
    try {
        std::lock_guard lock(gLogMutex);
        std::fprintf(gLog, "{\"schema\":1,\"component\":\"fsr-metalfx\",\"event\":\"%s\","
                           "\"context\":%llu,\"dispatch\":%llu,\"result\":%u",
                     event, static_cast<unsigned long long>(state ? state->id : 0),
                     static_cast<unsigned long long>(dispatch), result);
        if (detail) {
            std::fputs(",\"detail\":\"", gLog);
            for (const unsigned char* p = reinterpret_cast<const unsigned char*>(detail); *p; ++p) {
                if (*p == '\"' || *p == '\\') std::fputc('\\', gLog);
                if (*p >= 32) std::fputc(*p, gLog);
            }
            std::fputc('\"', gLog);
        }
        std::fputs("}\n", gLog); std::fflush(gLog);
    } catch (...) {}
}

void logFrame(const char* event, const State* state, std::uint64_t dispatch, std::uint32_t result,
              const char* detail, const yaagl_fsr_dispatch_packet& input,
              const metalfx::TemporalOutputInfo* temporal = nullptr) noexcept {
    if (!gLog) return;
    try {
        std::lock_guard lock(gLogMutex);
        std::fprintf(gLog,
            "{\"schema\":1,\"component\":\"fsr-metalfx\",\"event\":\"%s\","
            "\"context\":%llu,\"dispatch\":%llu,\"result\":%u,\"detail\":\"%s\","
            "\"resources\":{\"command\":%llu,\"color\":%llu,\"depth\":%llu,\"motion\":%llu,"
            "\"exposure\":%llu,\"reactive\":%llu,\"composition\":%llu,\"output\":%llu},"
            "\"states\":[%u,%u,%u,%u,%u,%u,%u],\"render\":[%u,%u],\"upscale\":[%u,%u],"
            "\"createRender\":[%u,%u],\"createOutput\":[%u,%u],"
            "\"temporalOutput\":[%u,%u],\"placement\":[%u,%u],\"temporallyCapped\":%u,"
            "\"jitter\":[%.9g,%.9g],\"motionScale\":[%.9g,%.9g],\"sharpness\":%.9g,"
            "\"frameTimeDelta\":%.9g,\"preExposure\":%.9g,\"camera\":[%.9g,%.9g,%.9g,%.9g],"
            "\"reset\":%u,\"sharpening\":%u,\"flags\":%u}\n",
            event, static_cast<unsigned long long>(state ? state->id : 0),
            static_cast<unsigned long long>(dispatch), result, detail,
            static_cast<unsigned long long>(input.command_list), static_cast<unsigned long long>(input.color),
            static_cast<unsigned long long>(input.depth), static_cast<unsigned long long>(input.motion_vectors),
            static_cast<unsigned long long>(input.exposure), static_cast<unsigned long long>(input.reactive),
            static_cast<unsigned long long>(input.composition), static_cast<unsigned long long>(input.output),
            input.color_state, input.depth_state, input.motion_state, input.exposure_state,
            input.reactive_state, input.composition_state, input.output_state,
            input.render_width, input.render_height, input.upscale_width, input.upscale_height,
            state ? state->create.backend.input.width : 0, state ? state->create.backend.input.height : 0,
            state ? state->create.backend.output.width : 0, state ? state->create.backend.output.height : 0,
            temporal ? temporal->width : input.upscale_width,
            temporal ? temporal->height : input.upscale_height,
            temporal ? temporal->placementX : 0, temporal ? temporal->placementY : 0,
            static_cast<unsigned>(temporal && temporal->capped),
            input.jitter_x, input.jitter_y, input.motion_scale_x, input.motion_scale_y, input.sharpness,
            input.frame_time_delta, input.pre_exposure, input.camera_near, input.camera_far,
            input.camera_fov_vertical, input.view_space_to_meters, input.reset,
            input.enable_sharpening, input.flags);
        std::fflush(gLog);
    } catch (...) {}
}

void logFailedFrame(const State* state, std::uint64_t dispatch, std::uint32_t result,
                    const char* detail, const yaagl_fsr_dispatch_packet& input) noexcept {
    if (gFailedFrameLogs.fetch_add(1, std::memory_order_relaxed) >= 120) return;
    logFrame("error", state, dispatch, result, detail, input);
}

std::shared_ptr<State> find(std::uint64_t id) {
    std::lock_guard lock(gRegistryMutex);
    const auto it = gContexts.find(id);
    return it == gContexts.end() ? nullptr : it->second;
}

std::uint32_t backendResult(metalfx::ErrorCode code) noexcept {
    switch (code) {
    case metalfx::ErrorCode::InvalidContext:
    case metalfx::ErrorCode::InvalidFrame: return kParameter;
    case metalfx::ErrorCode::UnsupportedFeature:
    case metalfx::ErrorCode::IncompatibleTexture: return kNoProvider;
    case metalfx::ErrorCode::ResourceCreationFailed: return kMemory;
    default: return kRuntime;
    }
}

struct CommandScope {
    d3dmetal::NativeCommandList native{};
    ~CommandScope() { d3dmetal::releaseCommandList(native); }
    bool open(void* list) noexcept {
        return d3dmetal::unwrapCommandList(list, native) &&
            (native.kind != d3dmetal::CommandListKind::legacy ||
             d3dmetal::legacy::resolveCommandList(native));
    }
};

struct ResourceScope {
    std::array<d3dmetal::MetalResource, 7> values{};
    ~ResourceScope() { for (auto& value : values) d3dmetal::releaseResource(value); }
};

std::uint32_t create(yaagl_fsr_create_packet& packet) {
    CreateContract contract;
    if (packet.header.size != sizeof(packet) || packet.provider_version != kProvider)
        return kParameter;
    const auto validated = validateCreate(packet, contract);
    if (validated != ContractStatus::Ok) return kParameter;
    std::string error;
    auto owner = deviceOwner(reinterpret_cast<void*>(static_cast<std::uintptr_t>(packet.device)), false, error);
    if (!owner) return kParameter;
    auto state = std::make_shared<State>();
    state->id = gNextContext.fetch_add(1, std::memory_order_relaxed);
    state->create = contract;
    if (!adapterLuid(owner.get(), state->adapter)) return kParameter;
    state->device = std::move(owner);
    {
        std::lock_guard lock(gRegistryMutex);
        gContexts.emplace(state->id, state);
    }
    packet.header.context = state->id;
    logEvent("create", state.get(), 0, kOk);
    return kOk;
}

std::uint32_t destroy(yaagl_fsr_packet_header& packet) {
    std::shared_ptr<State> state;
    {
        std::lock_guard lock(gRegistryMutex);
        const auto it = gContexts.find(packet.context);
        if (it == gContexts.end()) return kParameter;
        state = it->second; gContexts.erase(it);
    }
    {
        std::lock_guard lock(state->mutex);
        state->retired = true;
        state->backend.reset();
        for (auto& cached : state->inactiveBackends) cached.backend.reset();
        state->executionDevice.reset();
        state->device.reset();
    }
    logEvent("destroy", state.get(), 0, kOk);
    return kOk;
}

std::uint32_t configure(yaagl_fsr_configure_packet& packet) {
    if (packet.header.size != sizeof(packet)) return kParameter;
    if (!packet.header.context) return kOk;
    auto state = find(packet.header.context);
    if (!state) return kParameter;
    std::lock_guard lock(state->mutex);
    state->debugLevel = packet.debug_level;
    return kOk;
}

std::uint32_t dispatch(yaagl_fsr_dispatch_packet& packet) {
    if (packet.header.size != sizeof(packet)) return kParameter;
    auto state = find(packet.header.context);
    if (!state) return kParameter;
    const auto dispatchID = gNextDispatch.fetch_add(1, std::memory_order_relaxed);
    FrameContract frame;
    const char* validationDetail = nullptr;
    const auto validation = validateFrame(state->create, packet, frame, &validationDetail);
    if (validation != ContractStatus::Ok) {
        const auto result = validation == ContractStatus::Unsupported ? kNoProvider : kParameter;
        logFailedFrame(state.get(), dispatchID, result, validationDetail, packet);
        return result;
    }

    std::lock_guard stateLock(state->mutex);
    if (state->retired) { logEvent("error", state.get(), dispatchID, kParameter, "context_retired"); return kParameter; }
    CommandScope command;
    auto commandList = reinterpret_cast<void*>(static_cast<std::uintptr_t>(packet.command_list));
    if (!command.open(commandList)) { logEvent("error", state.get(), dispatchID, kParameter, "command_list_unwrap_failed"); return kParameter; }
    std::string error;
    auto commandDevice = deviceOwner(commandList, true, error);
    AdapterLuid commandAdapter{};
    if (!commandDevice || !adapterLuid(commandDevice.get(), commandAdapter) ||
        !sameAdapter(commandAdapter, state->adapter)) {
        logEvent("error", state.get(), dispatchID, kParameter, "command_list_device_mismatch");
        return kParameter;
    }
    if (!state->executionDevice) state->executionDevice = commandDevice;
    const auto mode = command.native.kind == d3dmetal::CommandListKind::mpl
        ? metalfx::CommandMode::Metal4 : metalfx::CommandMode::Legacy;
    const metalfx::Extent output{frame.backend.outputRect.width, frame.backend.outputRect.height};
    const bool newGeneration = !state->backend || state->generationOutput.width != output.width ||
                               state->generationOutput.height != output.height ||
                               state->generationDevice != command.native.device ||
                               state->generationCompiler != command.native.compiler;
    if (state->backend && state->backend->mode() != mode) {
        logEvent("error", state.get(), dispatchID, kParameter, "command_mode_changed");
        return kParameter;
    }
    if (newGeneration) {
        bool reused = false;
        for (auto& cached : state->inactiveBackends) {
            if (!cached.backend || cached.output.width != output.width ||
                cached.output.height != output.height ||
                cached.device != command.native.device ||
                cached.compiler != command.native.compiler || cached.backend->mode() != mode) continue;
            state->backend.swap(cached.backend);
            std::swap(state->generationOutput, cached.output);
            std::swap(state->generationDevice, cached.device);
            std::swap(state->generationCompiler, cached.compiler);
            reused = true;
            break;
        }
        if (!reused) {
            auto createInfo = state->create.backend;
            createInfo.output = output;
            metalfx::CreateContext context{command.native.device, command.native.compiler, mode};
            metalfx::Error backendError;
            metalfx::IndependentFactoryScope scope;
            auto backend = metalfx::Feature::create(context, createInfo, &backendError);
            if (!backend) {
                const auto result = backendResult(backendError.code);
                logFailedFrame(state.get(), dispatchID, result, backendError.message.c_str(), packet);
                return result;
            }
            if (state->backend) {
                state->inactiveBackends[state->nextEviction] =
                    {state->generationOutput, state->generationDevice,
                     state->generationCompiler, std::move(state->backend)};
                state->nextEviction = (state->nextEviction + 1) % state->inactiveBackends.size();
            }
            state->backend = std::move(backend);
            state->generationOutput = output;
            state->generationDevice = command.native.device;
            state->generationCompiler = command.native.compiler;
        }
        // A retained scaler's history belongs to its previous output run.
        state->generationNeedsReset = true;
    }
    if (state->generationNeedsReset) frame.backend.resetHistory = {true, true};

    ResourceScope mapped;
    const std::array<void*, 7> resources{
        frame.backend.color, frame.backend.depth, frame.backend.motionVectors, frame.backend.output,
        frame.backend.exposureMode == metalfx::ExposureMode::Texture ? frame.backend.exposureTexture.value : nullptr,
        frame.backend.reactiveMask.value, frame.backend.compositionMask.value};
    std::array<d3dmetal::ResourceUse, 7> uses{};
    std::array<d3dmetal::legacy::ResourceMetadata, 7> metadata{};
    std::size_t useCount = 0;
    for (std::size_t i = 0; i < resources.size(); ++i) {
        if (!resources[i]) continue;
        auto resourceDevice = deviceOwner(resources[i], true, error);
        AdapterLuid resourceAdapter{};
        if (!resourceDevice || !adapterLuid(resourceDevice.get(), resourceAdapter) ||
            !sameAdapter(resourceAdapter, state->adapter)) {
            logEvent("error", state.get(), dispatchID, kParameter, "resource_device_mismatch");
            return kParameter;
        }
        if (!d3dmetal::legacy::queryResourceMetadata(resources[i], metadata[i])) { logEvent("error", state.get(), dispatchID, kNoProvider, "resource_metadata_unavailable"); return kNoProvider; }
        if (i == 3 && !metadata[i].allowsUnorderedAccess()) { logEvent("error", state.get(), dispatchID, kParameter, "output_not_uav"); return kParameter; }
        if (!d3dmetal::mapResource(resources[i], mapped.values[i])) { logEvent("error", state.get(), dispatchID, kNoProvider, "resource_map_failed"); return kNoProvider; }
        uses[useCount++] = {&mapped.values[i], i == 3 ? d3dmetal::ResourceAccess::write
                                                      : d3dmetal::ResourceAccess::read};
    }
    for (std::size_t i = 0; i < mapped.values.size(); ++i) {
        if (i == 3 || !mapped.values[i].texture) continue;
        if (mapped.values[i].texture == mapped.values[3].texture &&
            std::memcmp(&mapped.values[i].view, &mapped.values[3].view,
                        sizeof(d3dmetal::TextureView)) == 0) { logEvent("error", state.get(), dispatchID, kParameter, "input_output_alias"); return kParameter; }
    }
    metalfx::TextureSet textures{
        mapped.values[0].texture, mapped.values[1].texture, mapped.values[2].texture,
        mapped.values[3].texture, mapped.values[4].texture, mapped.values[5].texture,
        mapped.values[6].texture};
    metalfx::Error backendError;
    std::shared_ptr<const metalfx::PreparedFrame> prepared;
    {
        metalfx::IndependentFactoryScope scope;
        prepared = state->backend->prepare(frame.backend, textures, &backendError, frame.operations);
    }
    if (!prepared) {
        const auto result = backendResult(backendError.code);
        logFailedFrame(state.get(), dispatchID, result, backendError.message.c_str(), packet);
        return result;
    }
    const d3dmetal::RecordRequest request{prepared, uses.data(), useCount, state->id, dispatchID};
    const bool recorded = command.native.kind == d3dmetal::CommandListKind::legacy
        ? d3dmetal::legacy::record(command.native, request)
        : d3dmetal::record(command.native, request);
    if (!recorded) { logEvent("error", state.get(), dispatchID, kRuntime, "command_record_failed"); return kRuntime; }
    state->generationNeedsReset = false;
    if (dispatchID <= 120) {
        const auto temporal = prepared->temporalOutputInfo();
        logFrame("dispatch", state.get(), dispatchID, kOk, "ok", packet, &temporal);
    }
    return kOk;
}
} // namespace

bool initialize(const std::uint8_t* imageBase) noexcept {
    try {
        const bool ready = d3dmetal::initialize(imageBase) &&
                           d3dmetal::legacy::initialize(imageBase);
        gAvailable.store(ready, std::memory_order_release);
        const char* path = std::getenv("YAAGL_FSR_LOG");
        if (path && path[0] == '/' && !gLog) gLog = std::fopen(path, "a");
        return ready;
    } catch (...) { return false; }
}

bool available() noexcept { return gAvailable.load(std::memory_order_acquire); }

} // namespace yaagl::pso::fsr

extern "C" __attribute__((visibility("default"))) std::uint32_t
yaagl_fsr_api(std::uint32_t operation, void* arguments) noexcept {
    using namespace yaagl::pso::fsr;
    if (!arguments) return 6;
    auto& header = *static_cast<yaagl_fsr_packet_header*>(arguments);
    if (header.operation != operation || header.size < sizeof(header)) return 6;
    if (!available() && operation != YAAGL_FSR_CONFIGURE) return 3;
    try {
        @try {
            switch (operation) {
            case YAAGL_FSR_CREATE: return create(*static_cast<yaagl_fsr_create_packet*>(arguments));
            case YAAGL_FSR_DESTROY: return destroy(header);
            case YAAGL_FSR_CONFIGURE: return configure(*static_cast<yaagl_fsr_configure_packet*>(arguments));
            case YAAGL_FSR_QUERY: return 2;
            case YAAGL_FSR_DISPATCH: return dispatch(*static_cast<yaagl_fsr_dispatch_packet*>(arguments));
            default: return 2;
            }
        } @catch (NSException*) { return 3; }
    } catch (const std::bad_alloc&) { return 5; }
    catch (...) { return 3; }
}
