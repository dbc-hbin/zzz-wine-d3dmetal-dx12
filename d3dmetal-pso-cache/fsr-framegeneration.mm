#include "fsr-framegeneration.hpp"
#include "d3dmetal-transport.hpp"
#include "d3dmetal-transport-legacy.hpp"
#include "../include/yaagl_fsr_fg_bridge.h"
#include "third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api_types.h"
#include "fsr-kernels.inc"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/message.h>

#include <array>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <unordered_map>
#include <utility>
#include <vector>

namespace yaagl::pso::fsr::framegeneration {
namespace {

namespace transport = d3dmetal;
using Mode = metalfx::CommandMode;

constexpr std::uint32_t Ok = 0;
constexpr std::uint32_t Runtime = 3;
constexpr std::uint32_t Unsupported = 4;
constexpr std::uint32_t Memory = 5;
constexpr std::uint32_t Parameter = 6;

std::atomic<bool> ready{false};
std::atomic<std::uint64_t> nextContext{1};
std::atomic<unsigned> errorCount{0};
std::atomic<bool> firstEncodeLogged{false};
std::mutex registryMutex;
std::mutex logMutex;
FILE* fsrLog = nullptr;

void logFailure(std::uint32_t operation, const char* stage, std::uint32_t result,
                std::uint32_t flags = 0, std::uint32_t width = 0,
                std::uint32_t height = 0, float cameraNear = 0,
                float cameraFar = 0, float fov = 0, float scale = 0) noexcept {
    if (errorCount.fetch_add(1, std::memory_order_relaxed) >= 120) return;
    std::fprintf(stderr,
        "yaagl-fsr-framegeneration: operation=%u stage=%s result=%u flags=0x%x "
        "input=%ux%u camera_near=%.9g camera_far=%.9g fov=%.9g scale=%.9g\n",
        operation, stage, result, flags, width, height, cameraNear, cameraFar, fov, scale);
}

void logFirstEncode(Mode mode, std::uint32_t flags, std::uint32_t width,
                    std::uint32_t height, float nearPlane, float farPlane,
                    float fov, float scale) noexcept {
    if (!fsrLog || firstEncodeLogged.exchange(true, std::memory_order_relaxed)) return;
    std::array<char, 32> farPlaneText{};
    if (std::isfinite(farPlane))
        std::snprintf(farPlaneText.data(), farPlaneText.size(), "%.9g", farPlane);
    else
        std::snprintf(farPlaneText.data(), farPlaneText.size(), "null");
    std::lock_guard lock(logMutex);
    std::fprintf(fsrLog,
        "{\"schema\":1,\"component\":\"fsr-framegeneration\","
        "\"event\":\"first_encode\",\"mode\":\"%s\",\"flags\":%u,"
        "\"input\":[%u,%u],\"nearPlane\":%.9g,\"farPlane\":%s,"
        "\"fovRadians\":%.9g,\"viewSpaceToMeters\":%.9g}\n",
        mode == Mode::Metal4 ? "metal4" : "legacy", flags, width, height,
        nearPlane, farPlaneText.data(), fov, scale);
    std::fflush(fsrLog);
}

template<class R, class... A>
R send(id object, SEL selector, A... arguments) {
    return reinterpret_cast<R (*)(id, SEL, A...)>(objc_msgSend)(
        object, selector, arguments...);
}

class Object {
public:
    Object() noexcept = default;
    explicit Object(id value) noexcept : value_([value retain]) {}
    Object(const Object& other) noexcept : value_([other.value_ retain]) {}
    Object(Object&& other) noexcept : value_(other.value_) { other.value_ = nil; }
    ~Object() { [value_ release]; }
    Object& operator=(Object other) noexcept {
        std::swap(value_, other.value_);
        return *this;
    }
    id get() const noexcept { return value_; }
    explicit operator bool() const noexcept { return value_ != nil; }
private:
    id value_ = nil;
};

struct Guid {
    std::uint32_t a;
    std::uint16_t b, c;
    std::uint8_t d[8];
};
constexpr Guid deviceGuid{0x189819f1, 0x1db6, 0x4b57,
                         {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7}};
struct Luid { std::uint32_t low; std::int32_t high; };

void* pointer(std::uint64_t value) noexcept {
    return reinterpret_cast<void*>(static_cast<std::uintptr_t>(value));
}

void releaseCom(void* object) noexcept {
    if (!object) return;
    using Function = std::uint32_t (__attribute__((ms_abi)) *)(void*);
    reinterpret_cast<Function>((*static_cast<void***>(object))[2])(object);
}

std::shared_ptr<void> owner(void* object, bool child) {
    if (!object) return {};
    using Function = std::int32_t (__attribute__((ms_abi)) *)(
        void*, const Guid*, void**);
    void* result = nullptr;
    auto table = *static_cast<void***>(object);
    if (reinterpret_cast<Function>(table[child ? 7 : 0])(
            object, &deviceGuid, &result) < 0 || !result)
        return {};
    return std::shared_ptr<void>(result, releaseCom);
}

bool getLuid(void* device, Luid& result) noexcept {
    if (!device) return false;
    using Function = Luid* (__attribute__((ms_abi)) *)(void*, Luid*);
    return reinterpret_cast<Function>((*static_cast<void***>(device))[43])(
               device, &result) == &result;
}

bool matches(void* object, bool child, const Luid& expected) {
    auto device = owner(object, child);
    Luid value{};
    return device && getLuid(device.get(), value) &&
           value.low == expected.low && value.high == expected.high;
}

struct Command {
    transport::NativeCommandList value{};
    ~Command() { transport::releaseCommandList(value); }
    bool open(void* list) {
        return transport::unwrapCommandList(list, value) &&
               (value.kind != transport::CommandListKind::legacy ||
                transport::legacy::resolveCommandList(value)) &&
               value.device &&
               (value.kind == transport::CommandListKind::legacy ||
                value.kind == transport::CommandListKind::mpl);
    }
};

struct Resources {
    std::array<transport::MetalResource, 3> values{};
    ~Resources() {
        for (auto& value : values) transport::releaseResource(value);
    }
};

MTLPixelFormat colorFormat(std::uint32_t format) noexcept {
    switch (format) {
    case FFX_API_SURFACE_FORMAT_R16G16B16A16_FLOAT: return MTLPixelFormatRGBA16Float;
    case FFX_API_SURFACE_FORMAT_R10G10B10A2_UNORM: return MTLPixelFormatRGB10A2Unorm;
    case FFX_API_SURFACE_FORMAT_R8G8B8A8_UNORM: return MTLPixelFormatRGBA8Unorm;
    case FFX_API_SURFACE_FORMAT_R8G8B8A8_SRGB: return MTLPixelFormatRGBA8Unorm_sRGB;
    case FFX_API_SURFACE_FORMAT_B8G8R8A8_UNORM: return MTLPixelFormatBGRA8Unorm;
    case FFX_API_SURFACE_FORMAT_B8G8R8A8_SRGB: return MTLPixelFormatBGRA8Unorm_sRGB;
    default: return MTLPixelFormatInvalid;
    }
}

bool textureValid(id<MTLTexture> texture, id<MTLDevice> device,
                  NSUInteger width, NSUInteger height) {
    return texture && texture.device == device &&
           texture.textureType == MTLTextureType2D &&
           texture.sampleCount == 1 && texture.width >= width &&
           texture.height >= height &&
           texture.storageMode != MTLStorageModeMemoryless;
}

Object privateTexture(id<MTLDevice> device, MTLPixelFormat format,
                      NSUInteger width, NSUInteger height, MTLTextureUsage usage) {
    MTLTextureDescriptor* descriptor =
        [[MTLTextureDescriptor alloc] init];
    descriptor.textureType = MTLTextureType2D;
    descriptor.pixelFormat = format;
    descriptor.width = width;
    descriptor.height = height;
    descriptor.depth = 1;
    descriptor.mipmapLevelCount = 1;
    descriptor.arrayLength = 1;
    descriptor.sampleCount = 1;
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = usage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    [descriptor release];
    Object result(texture);
    [texture release];
    return result;
}

Object makePipeline(id<MTLDevice> device, NSString* name) {
    NSError* error = nil;
    NSString* source = [NSString stringWithUTF8String:kFsrKernelsSource];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (!library) return {};
    id<MTLFunction> function = [library newFunctionWithName:name];
    [library release];
    if (!function) return {};
    id<MTLComputePipelineState> pipeline =
        [device newComputePipelineStateWithFunction:function error:&error];
    [function release];
    Object result(pipeline);
    [pipeline release];
    return result;
}

struct Configuration {
    Mode mode = Mode::Legacy;
    Object device;
    Object compiler;
    Object descriptor;
    Object factory;
    MTLPixelFormat color = MTLPixelFormatInvalid;
    MTLPixelFormat ui = MTLPixelFormatInvalid;
    MTLPixelFormat sourceColor = MTLPixelFormatInvalid;
    MTLPixelFormat sourceUi = MTLPixelFormatInvalid;
    std::uint32_t transfer = 0;
    bool cameraPresent = false;
    MTLPixelFormat depth = MTLPixelFormatInvalid;
    MTLPixelFormat motion = MTLPixelFormatRG16Float;
    NSUInteger width = 0, height = 0, outputWidth = 0, outputHeight = 0;
    MTLTextureUsage colorUsage = 0, uiUsage = 0, depthUsage = 0, motionUsage = 0, outputUsage = 0;
    Object decodePipeline;
    Object depthPipeline;
    Object motionPipeline;
    Object encodePipeline;

    Object makeInterpolator() const {
        if (@available(macOS 26.0, *)) {
            auto d = (MTLFXFrameInterpolatorDescriptor*)descriptor.get();
            id instance = mode == Mode::Metal4
                ? (id)[d newFrameInterpolatorWithDevice:(id<MTLDevice>)device.get()
                                               compiler:(id<MTL4Compiler>)compiler.get()]
                : (id)[d newFrameInterpolatorWithDevice:(id<MTLDevice>)device.get()];
            Object result(instance);
            [instance release];
            return result;
        }
        return {};
    }
};

struct Snapshot {
    std::shared_ptr<Configuration> configuration;
    yaagl_fsr_fg_prepare_packet parameters{};
    Object depth;
    Object motion;
    NSUInteger depthWidth = 0;
    NSUInteger depthHeight = 0;
    NSUInteger motionWidth = 0;
    NSUInteger motionHeight = 0;
    bool hasPreviousJitter = false;
    float previousJitterX = 0;
    float previousJitterY = 0;
};

struct State {
    std::vector<std::shared_ptr<Configuration>> configurations;
    std::mutex mutex;
    std::mutex executionMutex;
    std::shared_ptr<void> device;
    Luid luid{};
    yaagl_fsr_fg_create_packet creation{};
    bool retired = false;
    // Pending provider selection records its first Prepare before PE replays Configure.
    bool generationEnabled = true;
    bool hasMode = false;
    Mode mode = Mode::Legacy;
    Object metalDevice;
    std::unordered_map<std::uint64_t, std::shared_ptr<Snapshot>> frames;
    Object history;
    std::shared_ptr<Configuration> historyConfiguration;
    yaagl_fsr_fg_dispatch_packet historyDispatch{};
    std::uint64_t historyFrame = 0;
    bool hasPreparedJitter = false;
    std::uint64_t preparedFrame = 0;
    float preparedJitterX = 0;
    float preparedJitterY = 0;
};

std::unordered_map<std::uint64_t, std::shared_ptr<State>> contexts;

std::shared_ptr<State> lookup(std::uint64_t context) {
    std::lock_guard lock(registryMutex);
    auto found = contexts.find(context);
    return found == contexts.end() ? nullptr : found->second;
}

bool supported(id<MTLDevice> device, Mode mode, void* compiler) {
    if (@available(macOS 26.0, *)) {
        return device && (mode == Mode::Metal4
            ? compiler && [MTLFXFrameInterpolatorDescriptor supportsMetal4FX:device]
            : [MTLFXFrameInterpolatorDescriptor supportsDevice:device]);
    }
    return false;
}

bool sameConfiguration(const Configuration& a, const Configuration& b);

std::shared_ptr<Configuration> configure(
    State& state, const Command& command,
    const yaagl_fsr_fg_prepare_packet& packet,
    id<MTLTexture> depth, MTLPixelFormat sourceColor, MTLPixelFormat sourceUi,
    NSUInteger outputWidth, NSUInteger outputHeight, std::uint32_t transfer) {
    if (@available(macOS 26.0, *)) {
        auto result = std::make_shared<Configuration>();
        result->mode = command.value.kind == transport::CommandListKind::mpl
                     ? Mode::Metal4 : Mode::Legacy;
        auto device = (id<MTLDevice>)command.value.device;
        if (!supported(device, result->mode, command.value.compiler)) return {};
        result->device = Object(device);
        result->compiler = Object((id)command.value.compiler);
        result->color = MTLPixelFormatRGBA16Float;
        result->ui = sourceUi == MTLPixelFormatInvalid ? MTLPixelFormatInvalid : MTLPixelFormatRGBA16Float;
        result->sourceColor = sourceColor;
        result->sourceUi = sourceUi;
        result->transfer = transfer;
        result->cameraPresent = packet.camera_info_present != 0;
        result->depth = depth.pixelFormat;
        result->motion = MTLPixelFormatRG16Float;
        // MetalFX consumes color, depth, and motion in one origin-zero active domain.
        result->width = outputWidth;
        result->height = outputHeight;
        result->outputWidth = outputWidth;
        result->outputHeight = outputHeight;
        for (const auto& cached : state.configurations)
            if (sameConfiguration(*result, *cached)) return cached;

        MTLFXFrameInterpolatorDescriptor* descriptor =
            [[MTLFXFrameInterpolatorDescriptor alloc] init];
        result->descriptor = Object(descriptor);
        [descriptor release];
        descriptor.colorTextureFormat = result->color;
        descriptor.outputTextureFormat = result->color;
        descriptor.depthTextureFormat = result->depth;
        descriptor.motionTextureFormat = result->motion;
        descriptor.uiTextureFormat = result->ui;
        descriptor.inputWidth = result->width;
        descriptor.inputHeight = result->height;
        descriptor.outputWidth = result->outputWidth;
        descriptor.outputHeight = result->outputHeight;
        if (@available(macOS 27.0, *))
            descriptor.requiresPrevColorTexture = YES;

        metalfx::IndependentFactoryScope scope;
        result->factory = result->makeInterpolator();
        if (!result->factory) return {};
        auto interpolator = (id<MTLFXFrameInterpolatorBase>)result->factory.get();
        result->colorUsage = interpolator.colorTextureUsage;
        result->uiUsage = interpolator.uiTextureUsage;
        result->depthUsage = interpolator.depthTextureUsage;
        result->motionUsage = interpolator.motionTextureUsage;
        result->outputUsage = interpolator.outputTextureUsage;
        result->decodePipeline = makePipeline(device, @"yaagl_fg_decode_crop");
        result->depthPipeline = makePipeline(device, @"yaagl_fg_resample_depth");
        result->motionPipeline = makePipeline(device, @"yaagl_fg_normalize_motion");
        result->encodePipeline = makePipeline(device, @"yaagl_fg_encode_scatter");
        if (!result->decodePipeline || !result->depthPipeline || !result->motionPipeline ||
            !result->encodePipeline)
            return {};
        constexpr std::size_t configurationCacheLimit = 8;
        if (state.configurations.size() == configurationCacheLimit)
            state.configurations.erase(state.configurations.begin());
        state.configurations.push_back(result);
        return result;
    }
    return {};
}

bool mapOne(Resources& resources, unsigned index, const State& state,
            const Command& command, std::uint64_t address, bool output,
            NSUInteger width, NSUInteger height) {
    if (!address || index >= resources.values.size()) return false;
    void* resource = pointer(address);
    if (!matches(resource, true, state.luid)) return false;
    transport::legacy::ResourceMetadata metadata{};
    if (!transport::legacy::queryResourceMetadata(resource, metadata) ||
        (output && !metadata.allowsUnorderedAccess()) ||
        !transport::mapResource(resource, resources.values[index]))
        return false;
    const auto& view = resources.values[index].view;
    return view.mipCount == 1 && view.sliceCount == 1 && view.planes == 1 &&
           textureValid((id<MTLTexture>)resources.values[index].texture,
                        (id<MTLDevice>)command.value.device, width, height);
}

id<MTLTexture> rootTexture(id<MTLTexture> texture) {
    while (texture.parentTexture) texture = texture.parentTexture;
    return texture;
}

bool mapPair(Resources& resources, const State& state, const Command& command,
             std::uint64_t first, std::uint64_t second, bool output,
             NSUInteger width, NSUInteger height) {
    if (!first || !second || first == second ||
        !mapOne(resources, 0, state, command, first, false, width, height) ||
        !mapOne(resources, 1, state, command, second, output, width, height))
        return false;
    return rootTexture((id<MTLTexture>)resources.values[0].texture) !=
           rootTexture((id<MTLTexture>)resources.values[1].texture);
}

/* D3D12_RESOURCE_BARRIER, including the eight-byte aligned transition union. */
struct Barrier {
    std::uint32_t type = 0;
    std::uint32_t flags = 0;
    void* resource = nullptr;
    std::uint32_t subresource = 0xffffffffu;
    std::uint32_t before = 0;
    std::uint32_t after = 0;
    std::uint32_t padding = 0;
};
static_assert(sizeof(Barrier) == 32);

bool record(void* list, Command& command, const Resources& resources,
            const std::shared_ptr<const PreparedFrame>& prepared,
            std::uint64_t context, std::uint64_t frame,
            const std::array<std::uint64_t, 3>& addresses,
            const std::array<std::uint32_t, 3>& states, unsigned resourceCount,
            bool generate) {
    std::array<transport::ResourceUse, 3> uses{{
        {&resources.values[0], transport::ResourceAccess::read},
        {&resources.values[1], generate ? transport::ResourceAccess::write
                                      : transport::ResourceAccess::read},
        {&resources.values[2], transport::ResourceAccess::read}
    }};
    std::array<Barrier, 3> barriers{};
    unsigned count = 0;
    for (unsigned i = 0; i != resourceCount; ++i) {
        const std::uint32_t target = generate && i == 1 ? 0x8u : 0x40u;
        if (states[i] == target) continue;
        auto& barrier = barriers[count++];
        barrier.resource = pointer(addresses[i]);
        barrier.before = states[i];
        barrier.after = target;
    }
    using ResourceBarrier = void (__attribute__((ms_abi)) *)(
        void*, std::uint32_t, const Barrier*);
    auto transition = reinterpret_cast<ResourceBarrier>(
        (*static_cast<void***>(list))[26]);
    if (count) transition(list, count, barriers.data());
    transport::RecordRequest request{prepared, uses.data(), resourceCount, context, frame};
    bool result = command.value.kind == transport::CommandListKind::legacy
        ? transport::legacy::record(command.value, request)
        : transport::record(command.value, request);
    for (unsigned i = 0; i != count; ++i)
        std::swap(barriers[i].before, barriers[i].after);
    if (count) transition(list, count, barriers.data());
    return result;
}

struct CameraPlanes {
    float nearPlane;
    float farPlane;
};

bool normalizeCameraPlanes(const yaagl_fsr_fg_prepare_packet& p,
                           std::uint32_t createFlags, CameraPlanes& planes) noexcept {
    if (!std::isfinite(p.camera_near) || p.camera_near <= 0) return false;
    if (createFlags & YAAGL_FSR_FG_DEPTH_INFINITE) {
        planes = {p.camera_near, INFINITY};
        return true;
    }
    if (!std::isfinite(p.camera_far) || p.camera_far <= 0 ||
        p.camera_far == p.camera_near)
        return false;
    planes = {std::min(p.camera_near, p.camera_far),
              std::max(p.camera_near, p.camera_far)};
    return true;
}

bool validParameters(const yaagl_fsr_fg_prepare_packet& p, std::uint32_t createFlags) {
    CameraPlanes planes{};
    if (!p.render_width || !p.render_height ||
        !std::isfinite(p.jitter_x) || !std::isfinite(p.jitter_y) ||
        !std::isfinite(p.motion_scale_x) || !std::isfinite(p.motion_scale_y) ||
        !std::isfinite(p.frame_time_delta_ms) || p.frame_time_delta_ms <= 0 ||
        !std::isfinite(p.view_space_to_meters) ||
        !normalizeCameraPlanes(p, createFlags, planes) ||
        !std::isfinite(p.camera_fov_vertical_radians) ||
        p.camera_fov_vertical_radians <= 0 ||
        p.camera_fov_vertical_radians >= 3.14159265358979323846f)
        return false;
    if (!p.camera_info_present) return true;
    simd_float3 basis[3]{};
    for (unsigned i = 0; i != 3; ++i) {
        if (!std::isfinite(p.camera_position[i]) || !std::isfinite(p.camera_up[i]) ||
            !std::isfinite(p.camera_right[i]) || !std::isfinite(p.camera_forward[i]))
            return false;
        basis[0][i] = p.camera_up[i];
        basis[1][i] = p.camera_right[i];
        basis[2][i] = p.camera_forward[i];
    }
    constexpr float tolerance = 1.0e-3f;
    for (const auto& axis : basis)
        if (std::abs(simd_length(axis) - 1.0f) > tolerance) return false;
    return std::abs(simd_dot(basis[0], basis[1])) <= tolerance &&
           std::abs(simd_dot(basis[0], basis[2])) <= tolerance &&
           std::abs(simd_dot(basis[1], basis[2])) <= tolerance;
}

bool validTransfer(const yaagl_fsr_fg_dispatch_packet& p) {
    if (p.backbuffer_transfer_function > FFX_API_BACKBUFFER_TRANSFER_FUNCTION_SCRGB ||
        !std::isfinite(p.min_luminance) || !std::isfinite(p.max_luminance))
        return false;
    if (p.backbuffer_transfer_function == FFX_API_BACKBUFFER_TRANSFER_FUNCTION_PQ)
        return p.max_luminance > 0;
    if (p.backbuffer_transfer_function == FFX_API_BACKBUFFER_TRANSFER_FUNCTION_SCRGB)
        return p.max_luminance > p.min_luminance;
    return true;
}

bool resolveRect(const yaagl_fsr_fg_dispatch_packet& p, NSUInteger displayWidth,
                 NSUInteger displayHeight, std::int32_t& left, std::int32_t& top,
                 NSUInteger& width, NSUInteger& height) {
    const bool defaultRect = p.generation_rect_width == 0 &&
                             p.generation_rect_height == 0;
    if (defaultRect) {
        if (p.generation_rect_left || p.generation_rect_top) return false;
        left = top = 0; width = displayWidth; height = displayHeight;
        return true;
    }
    if (p.generation_rect_left < 0 || p.generation_rect_top < 0 ||
        p.generation_rect_width <= 0 || p.generation_rect_height <= 0)
        return false;
    const std::uint64_t right = std::uint64_t(p.generation_rect_left) +
                                std::uint64_t(p.generation_rect_width);
    const std::uint64_t bottom = std::uint64_t(p.generation_rect_top) +
                                 std::uint64_t(p.generation_rect_height);
    if (right > displayWidth || bottom > displayHeight) return false;
    left = p.generation_rect_left; top = p.generation_rect_top;
    width = p.generation_rect_width; height = p.generation_rect_height;
    return true;
}

struct Copy {
    id<MTLTexture> source;
    id<MTLTexture> destination;
    NSUInteger width, height;
    NSUInteger sourceX = 0, sourceY = 0;
    NSUInteger destinationX = 0, destinationY = 0;
};

bool copyTextures(id buffer, id fence, Mode mode, const Copy* copies,
                  std::size_t count, std::vector<Object>& retained) {
    if (@available(macOS 26.0, *)) {
    id encoder = mode == Mode::Metal4
        ? send<id>(buffer, sel_registerName("computeCommandEncoder"))
        : (id)[(id<MTLCommandBuffer>)buffer blitCommandEncoder];
    if (!encoder) return false;
    retained.emplace_back(encoder);
    if (fence) {
        if (mode == Mode::Metal4)
            [(id<MTL4ComputeCommandEncoder>)encoder waitForFence:(id<MTLFence>)fence
                                             beforeEncoderStages:MTLStageBlit];
        else
            [(id<MTLBlitCommandEncoder>)encoder waitForFence:(id<MTLFence>)fence];
    }
    for (std::size_t i = 0; i != count; ++i) {
        const auto& copy = copies[i];
        send<void>(encoder,
            sel_registerName("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:"
                             "sourceSize:toTexture:destinationSlice:destinationLevel:"
                             "destinationOrigin:"),
            copy.source, NSUInteger(0), NSUInteger(0),
            MTLOriginMake(copy.sourceX, copy.sourceY, 0),
            MTLSizeMake(copy.width, copy.height, 1), copy.destination,
            NSUInteger(0), NSUInteger(0),
            MTLOriginMake(copy.destinationX, copy.destinationY, 0));
    }
    if (fence) {
        if (mode == Mode::Metal4)
            [(id<MTL4ComputeCommandEncoder>)encoder updateFence:(id<MTLFence>)fence
                                             afterEncoderStages:MTLStageBlit];
        else
            [(id<MTLBlitCommandEncoder>)encoder updateFence:(id<MTLFence>)fence];
    }
    send<void>(encoder, sel_registerName("endEncoding"));
    return true;
    }
    return false;
}

struct alignas(16) FgParams {
    std::int32_t sourceOrigin[2];
    std::uint32_t extent[2];
    std::uint32_t sourceExtent[2];
    std::uint32_t motionTargetExtent[2];
    std::uint32_t outputExtent[2];
    float motionScale[2];
    float jitterCancellation[2];
    float minLuminance;
    float maxLuminance;
    std::uint32_t transfer;
};

Object makeParameterBuffer(id<MTLDevice> device, const FgParams& params) {
    id<MTLBuffer> buffer =
        [device newBufferWithBytes:&params length:sizeof(params)
                           options:MTLResourceStorageModeShared];
    Object result(buffer);
    [buffer release];
    return result;
}

bool computePass(id buffer, id fence, Mode mode, id<MTLDevice> device,
                 id<MTLComputePipelineState> pipeline, id<MTLTexture> source,
                 id<MTLTexture> destination, id<MTLBuffer> parameterBuffer,
                 const FgParams& params, std::vector<Object>& retained) {
    if (!pipeline || !source || !destination || !parameterBuffer) return false;
    if (@available(macOS 26.0, *)) {
        if (mode == Mode::Metal4) {
            MTL4ArgumentTableDescriptor* descriptor = [MTL4ArgumentTableDescriptor new];
            descriptor.maxBufferBindCount = 1;
            descriptor.maxTextureBindCount = 2;
            descriptor.initializeBindings = YES;
            NSError* error = nil;
            id<MTL4ArgumentTable> table =
                [device newArgumentTableWithDescriptor:descriptor error:&error];
            [descriptor release];
            if (!table) return false;
            retained.emplace_back(table);
            [table release];
            [table setAddress:parameterBuffer.gpuAddress atIndex:0];
            [table setTexture:source.gpuResourceID atIndex:0];
            [table setTexture:destination.gpuResourceID atIndex:1];
            id<MTL4ComputeCommandEncoder> encoder =
                [(id<MTL4CommandBuffer>)buffer computeCommandEncoder];
            if (!encoder) return false;
            retained.emplace_back(encoder);
            [encoder waitForFence:(id<MTLFence>)fence beforeEncoderStages:MTLStageDispatch];
            [encoder setComputePipelineState:pipeline];
            [encoder setArgumentTable:table];
            [encoder dispatchThreads:MTLSizeMake(params.extent[0], params.extent[1], 1)
                 threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [encoder updateFence:(id<MTLFence>)fence afterEncoderStages:MTLStageDispatch];
            [encoder endEncoding];
            return true;
        }
        id<MTLComputeCommandEncoder> encoder =
            [(id<MTLCommandBuffer>)buffer computeCommandEncoder];
        if (!encoder) return false;
        retained.emplace_back(encoder);
        [encoder waitForFence:(id<MTLFence>)fence];
        [encoder setComputePipelineState:pipeline];
        [encoder setTexture:source atIndex:0];
        [encoder setTexture:destination atIndex:1];
        [encoder setBuffer:parameterBuffer offset:0 atIndex:0];
        [encoder dispatchThreads:MTLSizeMake(params.extent[0], params.extent[1], 1)
             threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder updateFence:(id<MTLFence>)fence];
        [encoder endEncoding];
        return true;
    }
    return false;
}

bool sameConfiguration(const Configuration& a, const Configuration& b) {
    return a.device.get() == b.device.get() && a.mode == b.mode &&
           a.color == b.color && a.ui == b.ui &&
           a.sourceColor == b.sourceColor && a.sourceUi == b.sourceUi &&
           a.transfer == b.transfer && a.cameraPresent == b.cameraPresent &&
           a.depth == b.depth && a.motion == b.motion &&
           a.width == b.width && a.height == b.height &&
           a.outputWidth == b.outputWidth && a.outputHeight == b.outputHeight;
}

bool sameHistoryValues(const yaagl_fsr_fg_dispatch_packet& a,
                       const yaagl_fsr_fg_dispatch_packet& b) {
    return a.generation_rect_left == b.generation_rect_left &&
           a.generation_rect_top == b.generation_rect_top &&
           a.generation_rect_width == b.generation_rect_width &&
           a.generation_rect_height == b.generation_rect_height &&
           a.backbuffer_transfer_function == b.backbuffer_transfer_function &&
           a.min_luminance == b.min_luminance &&
           a.max_luminance == b.max_luminance;
}

} // namespace

struct PreparedFrame::Impl {
    enum class Kind { Snapshot, Generate };
    Kind kind = Kind::Snapshot;
    std::shared_ptr<State> state;
    std::shared_ptr<Snapshot> snapshot;
    Object first;
    Object second;
    Object third;
    yaagl_fsr_fg_dispatch_packet dispatch{};
    bool reset = false;
};

struct ExecutionLease::Impl {
    std::shared_ptr<PreparedFrame::Impl> prepared;
    std::vector<Object> objects;
    Object residency;

    ~Impl() {
        if (residency) {
            if (@available(macOS 15.0, *))
                [(id<MTLResidencySet>)residency.get() endResidency];
        }
    }

    bool makeResident(id buffer, Mode mode) {
        if (mode != Mode::Metal4) return true;
        if (@available(macOS 26.0, *)) {
            auto device = (id<MTLDevice>)prepared->snapshot->configuration->device.get();
            MTLResidencySetDescriptor* descriptor =
                [[MTLResidencySetDescriptor alloc] init];
            descriptor.initialCapacity = objects.size();
            NSError* error = nil;
            id<MTLResidencySet> set =
                [device newResidencySetWithDescriptor:descriptor error:&error];
            [descriptor release];
            if (!set) return false;
            residency = Object(set);
            [set release];
            for (const auto& object : objects)
                if ([object.get() conformsToProtocol:@protocol(MTLAllocation)])
                    [set addAllocation:(id<MTLAllocation>)object.get()];
            [set commit];
            [set requestResidency];
            [(id<MTL4CommandBuffer>)buffer useResidencySet:set];
            return true;
        }
        return false;
    }
};

PreparedFrame::PreparedFrame(std::shared_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
PreparedFrame::~PreparedFrame() = default;
ExecutionLease::ExecutionLease(std::shared_ptr<Impl> impl) noexcept
    : impl_(std::move(impl)) {}
ExecutionLease::~ExecutionLease() = default;

Mode PreparedFrame::mode() const noexcept {
    return impl_->snapshot->configuration->mode;
}

bool PreparedFrame::encode(
    void* commandBuffer, void* fence,
    std::shared_ptr<const ExecutionLease>& lease) const noexcept {
    lease.reset();
    auto fail = [&](const char* stage) noexcept {
        if (impl_ && impl_->snapshot && impl_->state) {
            const auto& p = impl_->snapshot->parameters;
            logFailure(impl_->kind == Impl::Kind::Snapshot
                           ? YAAGL_FSR_FG_PREPARE : YAAGL_FSR_FG_DISPATCH,
                       stage, Runtime, impl_->state->creation.flags,
                       p.render_width, p.render_height, p.camera_near, p.camera_far,
                       p.camera_fov_vertical_radians, p.view_space_to_meters);
        } else {
            logFailure(YAAGL_FSR_FG_DISPATCH, stage, Runtime);
        }
        return false;
    };
    try {
        @try {
            if (@available(macOS 26.0, *)) {
                if (!commandBuffer || !impl_ || !impl_->snapshot) return fail("encode_arguments");
                id buffer = (id)commandBuffer;
                auto& configuration = *impl_->snapshot->configuration;
                if (configuration.mode == Mode::Metal4) {
                    if (![buffer conformsToProtocol:@protocol(MTL4CommandBuffer)])
                        return fail("encode_command_buffer_type");
                } else {
                    if (![buffer conformsToProtocol:@protocol(MTLCommandBuffer)] ||
                        [(id<MTLCommandBuffer>)buffer device] != configuration.device.get())
                        return fail("encode_command_buffer_device");
                }
                auto execution = std::make_shared<ExecutionLease::Impl>();
                execution->prepared = impl_;
                execution->objects.reserve(16);
                execution->objects.emplace_back((id)fence);
                execution->objects.push_back(impl_->first);
                execution->objects.push_back(impl_->second);
                execution->objects.push_back(impl_->third);
                execution->objects.push_back(impl_->snapshot->depth);
                execution->objects.push_back(impl_->snapshot->motion);

                auto retainedLease = std::shared_ptr<const ExecutionLease>(
                    new ExecutionLease(execution));
                /* Publish ownership before the first command is encoded. */
                lease = retainedLease;

                std::lock_guard executionLock(impl_->state->executionMutex);
                if (impl_->kind == Impl::Kind::Snapshot) {
                    if (!execution->makeResident(buffer, configuration.mode))
                        return fail("snapshot_residency");
                    const std::array<Copy, 2> copies{{
                        {(id<MTLTexture>)impl_->first.get(),
                         (id<MTLTexture>)impl_->snapshot->depth.get(),
                         impl_->snapshot->depthWidth, impl_->snapshot->depthHeight},
                        {(id<MTLTexture>)impl_->second.get(),
                         (id<MTLTexture>)impl_->snapshot->motion.get(),
                         impl_->snapshot->motionWidth, impl_->snapshot->motionHeight}
                    }};
                    if (!copyTextures(buffer, (id)fence, configuration.mode,
                                      copies.data(), copies.size(), execution->objects))
                        return fail("snapshot_copy");
                    return true;
                }

                Object interpolator = configuration.factory;
                if (!interpolator) return fail("encode_interpolator");
                auto effect = (id<MTLFXFrameInterpolatorBase>)interpolator.get();
                auto device = (id<MTLDevice>)configuration.device.get();
                Object current = privateTexture(device, configuration.color,
                    configuration.outputWidth, configuration.outputHeight,
                    effect.colorTextureUsage | MTLTextureUsageShaderWrite);
                Object ui = configuration.ui == MTLPixelFormatInvalid ? Object{} :
                    privateTexture(device, configuration.ui, configuration.outputWidth,
                                   configuration.outputHeight, effect.uiTextureUsage |
                                   MTLTextureUsageShaderWrite);
                Object normalizedDepth = privateTexture(device, configuration.depth,
                    configuration.width, configuration.height,
                    effect.depthTextureUsage | MTLTextureUsageShaderWrite);
                Object normalizedMotion = privateTexture(device, configuration.motion,
                    configuration.width, configuration.height,
                    effect.motionTextureUsage | MTLTextureUsageShaderWrite);
                Object output = privateTexture(device, configuration.color,
                    configuration.outputWidth, configuration.outputHeight,
                    effect.outputTextureUsage | MTLTextureUsageShaderRead);
                if (!current || !normalizedDepth || !normalizedMotion || !output ||
                    (configuration.ui != MTLPixelFormatInvalid && !ui))
                    return fail("encode_intermediate_textures");

                auto& state = *impl_->state;
                const std::uint64_t frame = impl_->dispatch.frame_id;
                bool reset = impl_->reset || impl_->snapshot->parameters.reset ||
                    !state.history || !state.historyConfiguration ||
                    !sameConfiguration(configuration, *state.historyConfiguration) ||
                    !sameHistoryValues(impl_->dispatch, state.historyDispatch) ||
                    state.historyFrame + 1 != frame;
                Object previous = reset ? current : state.history;
                execution->objects.push_back(interpolator);
                execution->objects.push_back(current);
                execution->objects.push_back(ui);
                execution->objects.push_back(normalizedDepth);
                execution->objects.push_back(normalizedMotion);
                execution->objects.push_back(output);
                execution->objects.push_back(previous);

                id<MTLTexture> present = (id<MTLTexture>)impl_->first.get();
                id<MTLTexture> scene = impl_->third
                    ? (id<MTLTexture>)impl_->third.get() : present;
                auto rawView = [&](id<MTLTexture> texture) -> Object {
                    MTLPixelFormat raw = texture.pixelFormat;
                    if (raw == MTLPixelFormatRGBA8Unorm_sRGB) raw = MTLPixelFormatRGBA8Unorm;
                    else if (raw == MTLPixelFormatBGRA8Unorm_sRGB) raw = MTLPixelFormatBGRA8Unorm;
                    if (raw == texture.pixelFormat) return Object(texture);
                    id<MTLTexture> view = [texture newTextureViewWithPixelFormat:raw];
                    Object result(view);
                    [view release];
                    return result;
                };
                Object sceneView = rawView(scene);
                Object presentView = rawView(present);
                Object outputView = rawView((id<MTLTexture>)impl_->second.get());
                if (!sceneView || !presentView || !outputView)
                    return fail("encode_texture_views");
                execution->objects.push_back(sceneView);
                execution->objects.push_back(presentView);
                execution->objects.push_back(outputView);

                const auto& p = impl_->snapshot->parameters;
                const auto& d = impl_->dispatch;
                FgParams colorParams{};
                colorParams.sourceOrigin[0] = d.generation_rect_left;
                colorParams.sourceOrigin[1] = d.generation_rect_top;
                colorParams.extent[0] = configuration.outputWidth;
                colorParams.extent[1] = configuration.outputHeight;
                colorParams.sourceExtent[0] = state.creation.display_width;
                colorParams.sourceExtent[1] = state.creation.display_height;
                colorParams.motionTargetExtent[0] = state.creation.display_width;
                colorParams.motionTargetExtent[1] = state.creation.display_height;
                colorParams.outputExtent[0] = configuration.outputWidth;
                colorParams.outputExtent[1] = configuration.outputHeight;
                colorParams.minLuminance = d.min_luminance;
                colorParams.maxLuminance = d.max_luminance;
                colorParams.transfer = d.backbuffer_transfer_function;

                FgParams depthParams{};
                depthParams.extent[0] = configuration.width;
                depthParams.extent[1] = configuration.height;
                depthParams.sourceExtent[0] = impl_->snapshot->depthWidth;
                depthParams.sourceExtent[1] = impl_->snapshot->depthHeight;

                FgParams motionParams{};
                motionParams.extent[0] = configuration.width;
                motionParams.extent[1] = configuration.height;
                const bool displayMotion = (state.creation.flags &
                    YAAGL_FSR_FG_DISPLAY_RESOLUTION_MOTION_VECTORS) != 0;
                // The generation rectangle is a placement offset, not a source offset.
                // Resample the complete origin-zero motion domain into the active rect.
                motionParams.sourceExtent[0] = impl_->snapshot->motionWidth;
                motionParams.sourceExtent[1] = impl_->snapshot->motionHeight;
                motionParams.motionTargetExtent[0] = displayMotion
                    ? state.creation.display_width : p.render_width;
                motionParams.motionTargetExtent[1] = displayMotion
                    ? state.creation.display_height : p.render_height;
                motionParams.outputExtent[0] = configuration.outputWidth;
                motionParams.outputExtent[1] = configuration.outputHeight;
                motionParams.motionScale[0] = p.motion_scale_x;
                motionParams.motionScale[1] = p.motion_scale_y;
                if ((state.creation.flags & YAAGL_FSR_FG_MOTION_VECTORS_JITTERED) &&
                    impl_->snapshot->hasPreviousJitter && !reset) {
                    motionParams.jitterCancellation[0] =
                        impl_->snapshot->previousJitterX - p.jitter_x;
                    motionParams.jitterCancellation[1] =
                        impl_->snapshot->previousJitterY - p.jitter_y;
                }

                Object colorParameters = makeParameterBuffer(device, colorParams);
                Object depthParameters = makeParameterBuffer(device, depthParams);
                Object motionParameters = makeParameterBuffer(device, motionParams);
                if (!colorParameters || !depthParameters || !motionParameters)
                    return fail("encode_parameter_buffers");
                execution->objects.push_back(colorParameters);
                execution->objects.push_back(depthParameters);
                execution->objects.push_back(motionParameters);
                // Metal4 GPU addresses must be admitted before the residency set commits.
                if (!execution->makeResident(buffer, configuration.mode))
                    return fail("encode_residency");

                const Copy baseline{present, (id<MTLTexture>)impl_->second.get(),
                    state.creation.display_width, state.creation.display_height};
                if (!copyTextures(buffer, (id)fence, configuration.mode, &baseline, 1,
                                  execution->objects))
                    return fail("encode_baseline_copy");
                if (!computePass(buffer, (id)fence, configuration.mode, device,
                                 (id<MTLComputePipelineState>)configuration.decodePipeline.get(),
                                 (id<MTLTexture>)sceneView.get(),
                                 (id<MTLTexture>)current.get(),
                                 (id<MTLBuffer>)colorParameters.get(), colorParams,
                                 execution->objects))
                    return fail("encode_scene_decode");
                if (ui && !computePass(buffer, (id)fence, configuration.mode, device,
                                      (id<MTLComputePipelineState>)configuration.decodePipeline.get(),
                                      (id<MTLTexture>)presentView.get(),
                                      (id<MTLTexture>)ui.get(),
                                      (id<MTLBuffer>)colorParameters.get(), colorParams,
                                      execution->objects))
                    return fail("encode_ui_decode");
                if (!computePass(buffer, (id)fence, configuration.mode, device,
                                 (id<MTLComputePipelineState>)configuration.depthPipeline.get(),
                                 (id<MTLTexture>)impl_->snapshot->depth.get(),
                                 (id<MTLTexture>)normalizedDepth.get(),
                                 (id<MTLBuffer>)depthParameters.get(), depthParams,
                                 execution->objects))
                    return fail("encode_depth_normalize");
                if (!computePass(buffer, (id)fence, configuration.mode, device,
                                 (id<MTLComputePipelineState>)configuration.motionPipeline.get(),
                                 (id<MTLTexture>)impl_->snapshot->motion.get(),
                                 (id<MTLTexture>)normalizedMotion.get(),
                                 (id<MTLBuffer>)motionParameters.get(), motionParams,
                                 execution->objects))
                    return fail("encode_motion_normalize");

                effect.colorTexture = (id<MTLTexture>)current.get();
                effect.prevColorTexture = (id<MTLTexture>)previous.get();
                effect.depthTexture = (id<MTLTexture>)normalizedDepth.get();
                effect.motionTexture = (id<MTLTexture>)normalizedMotion.get();
                effect.uiTexture = (id<MTLTexture>)ui.get();
                effect.uiTextureComposited = bool(ui);
                effect.outputTexture = (id<MTLTexture>)output.get();
                effect.fence = (id<MTLFence>)fence;
                effect.shouldResetHistory = reset;
                effect.depthReversed =
                    (state.creation.flags & YAAGL_FSR_FG_DEPTH_INVERTED) != 0;
                effect.motionVectorScaleX = 1.0f;
                effect.motionVectorScaleY = 1.0f;
                effect.jitterOffsetX = p.jitter_x;
                effect.jitterOffsetY = p.jitter_y;
                effect.deltaTime = p.frame_time_delta_ms * 0.001f;
                effect.aspectRatio = float(p.render_width) / float(p.render_height);

                if (@available(macOS 27.0, *)) {
                    // All interpolator inputs are normalized to the origin-zero
                    // generation-rectangle domain before MetalFX consumes them.
                    effect.contentWidth = configuration.outputWidth;
                    effect.contentHeight = configuration.outputHeight;
                    effect.depthContentOffsetX = 0;
                    effect.depthContentOffsetY = 0;
                    effect.motionContentOffsetX = 0;
                    effect.motionContentOffsetY = 0;
                    effect.outputOffsetX = 0;
                    effect.outputOffsetY = 0;
                }
                CameraPlanes planes{};
                if (!normalizeCameraPlanes(p, state.creation.flags, planes)) {
                    logFailure(YAAGL_FSR_FG_DISPATCH, "encode_camera_planes", Parameter,
                               state.creation.flags, p.render_width, p.render_height,
                               p.camera_near, p.camera_far,
                               p.camera_fov_vertical_radians, p.view_space_to_meters);
                    return false;
                }
                const float worldScale = p.view_space_to_meters > 0
                    ? p.view_space_to_meters : 1.0f;
                effect.nearPlane = planes.nearPlane * worldScale;
                effect.farPlane = planes.farPlane * worldScale;
                effect.fieldOfView =
                    p.camera_fov_vertical_radians * 57.295779513082320876f;
                if (p.camera_info_present) {
                    if (@available(macOS 27.0, *)) {
                        simd_float3 position = {p.camera_position[0] * worldScale,
                            p.camera_position[1] * worldScale, p.camera_position[2] * worldScale};
                        simd_float3 right = {p.camera_right[0], p.camera_right[1], p.camera_right[2]};
                        simd_float3 up = {p.camera_up[0], p.camera_up[1], p.camera_up[2]};
                        simd_float3 forward = {p.camera_forward[0], p.camera_forward[1],
                                               p.camera_forward[2]};
                        simd_float4x4 view{};
                        view.columns[0] = {right.x, up.x, forward.x, 0};
                        view.columns[1] = {right.y, up.y, forward.y, 0};
                        view.columns[2] = {right.z, up.z, forward.z, 0};
                        view.columns[3] = {-simd_dot(right, position), -simd_dot(up, position),
                                           -simd_dot(forward, position), 1};
                        float n = effect.nearPlane, f = effect.farPlane;
                        float y = 1.0f / std::tan(p.camera_fov_vertical_radians * 0.5f);
                        bool reversed = effect.depthReversed;
                        float a = std::isinf(f) ? (reversed ? 0.0f : 1.0f)
                            : (reversed ? n / (n - f) : f / (f - n));
                        float b = std::isinf(f) ? (reversed ? n : -n)
                            : (reversed ? n * f / (f - n) : -n * f / (f - n));
                        simd_float4x4 projection{};
                        projection.columns[0] = {y / effect.aspectRatio, 0, 0, 0};
                        projection.columns[1] = {0, y, 0, 0};
                        projection.columns[2] = {0, 0, a, 1};
                        projection.columns[3] = {0, 0, b, 0};
                        effect.worldToViewMatrix = view;
                        effect.viewToClipMatrix = projection;
                    }
                }

                if (configuration.mode == Mode::Metal4)
                    [(id<MTL4FXFrameInterpolator>)interpolator.get()
                        encodeToCommandBuffer:(id<MTL4CommandBuffer>)buffer];
                else
                    [(id<MTLFXFrameInterpolator>)interpolator.get()
                        encodeToCommandBuffer:(id<MTLCommandBuffer>)buffer];

                if (!computePass(buffer, (id)fence, configuration.mode, device,
                                 (id<MTLComputePipelineState>)configuration.encodePipeline.get(),
                                 (id<MTLTexture>)output.get(),
                                 (id<MTLTexture>)outputView.get(),
                                 (id<MTLBuffer>)colorParameters.get(), colorParams,
                                 execution->objects))
                    return fail("encode_output_scatter");
                state.history = current;
                state.historyConfiguration = impl_->snapshot->configuration;
                state.historyDispatch = impl_->dispatch;
                state.historyFrame = frame;
                logFirstEncode(configuration.mode, state.creation.flags,
                               p.render_width, p.render_height,
                               effect.nearPlane, effect.farPlane,
                               p.camera_fov_vertical_radians, p.view_space_to_meters);
                return true;
            }
            return fail("encode_os_unavailable");
        } @catch (NSException* exception) {
            const char* reason = [[exception reason] UTF8String];
            return fail(reason && *reason ? reason : "encode_objc_exception");
        }
    } catch (...) {
        return fail("encode_cpp_exception");
    }
}

bool initialize(const std::uint8_t* imageBase) noexcept {
    try {
        bool result = transport::initialize(imageBase) &&
                      transport::legacy::initialize(imageBase);
        if (@available(macOS 26.0, *)) {
            result = result && NSClassFromString(@"MTLFXFrameInterpolatorDescriptor");
        } else {
            result = false;
        }
        const char* path = std::getenv("YAAGL_FSR_LOG");
        if (path && path[0] == '/' && !fsrLog) fsrLog = std::fopen(path, "a");
        ready.store(result, std::memory_order_release);
        return result;
    } catch (...) {
        ready.store(false, std::memory_order_release);
        return false;
    }
}

bool available() noexcept {
    return ready.load(std::memory_order_acquire);
}

std::uint32_t api(std::uint32_t operation, void* arguments) noexcept {
    if (!arguments) return Parameter;
    auto& header = *static_cast<yaagl_fsr_fg_packet_header*>(arguments);
    if (header.size < sizeof(header)) return Parameter;
    auto finish = [&](std::uint32_t result, const char* stage = "request",
                      std::uint32_t flags = 0) {
        header.result = result;
        if (result != Ok) {
            if (operation == YAAGL_FSR_FG_PREPARE &&
                header.size == sizeof(yaagl_fsr_fg_prepare_packet)) {
                const auto& p = *static_cast<const yaagl_fsr_fg_prepare_packet*>(arguments);
                logFailure(operation, stage, result, flags, p.render_width, p.render_height,
                           p.camera_near, p.camera_far, p.camera_fov_vertical_radians,
                           p.view_space_to_meters);
            } else {
                logFailure(operation, stage, result, flags);
            }
        }
        return result;
    };
    if (header.operation != operation ||
        header.version != YAAGL_FSR_FG_BRIDGE_VERSION)
        return finish(Parameter);
    try {
        @try {
            if (operation == YAAGL_FSR_FG_DESTROY) {
                if (header.size != sizeof(yaagl_fsr_fg_destroy_packet))
                    return finish(Parameter);
                std::shared_ptr<State> state;
                {
                    std::lock_guard lock(registryMutex);
                    auto found = contexts.find(header.context);
                    if (found == contexts.end()) return finish(Parameter);
                    state = found->second;
                    contexts.erase(found);
                }
                std::lock_guard lock(state->mutex);
                state->retired = true;
                state->frames.clear();
                return finish(Ok);
            }
            if (operation == YAAGL_FSR_FG_CONFIGURE) {
                if (header.size != sizeof(yaagl_fsr_fg_configure_packet))
                    return finish(Parameter);
                auto state = lookup(header.context);
                if (!state) return finish(Parameter);
                std::lock_guard lock(state->mutex);
                if (state->retired) return finish(Parameter);
                auto& config = *static_cast<yaagl_fsr_fg_configure_packet*>(arguments);
                if (config.enabled > 1) return finish(Parameter);
                state->generationEnabled = config.enabled != 0;
                if (!state->generationEnabled) {
                    state->frames.clear();
                    state->hasPreparedJitter = false;
                    // Encode owns history under executionMutex, not the registry lock.
                    std::lock_guard executionLock(state->executionMutex);
                    state->history = {};
                    state->historyConfiguration.reset();
                }
                return finish(Ok);
            }
            if (!available()) return finish(Unsupported);

            if (operation == YAAGL_FSR_FG_PROBE) {
                if (header.size != sizeof(yaagl_fsr_fg_probe_packet))
                    return finish(Parameter);
                auto& p = *static_cast<yaagl_fsr_fg_probe_packet*>(arguments);
                p.legacy_supported = p.metal4_supported = 0;
                auto device = owner(pointer(p.device), false);
                Luid luid{};
                if (!device || !getLuid(device.get(), luid) ||
                    !p.display_width || !p.display_height)
                    return finish(Parameter);
                if (colorFormat(p.backbuffer_format) == MTLPixelFormatInvalid)
                    return finish(Unsupported);
                /*
                 * Probe is advisory. The authoritative device and command mode
                 * are resolved from the caller's command list during Prepare.
                 */
                if (@available(macOS 26.0, *)) {
                    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
                    for (id<MTLDevice> metalDevice in devices) {
                        p.legacy_supported |=
                            [MTLFXFrameInterpolatorDescriptor supportsDevice:metalDevice] ? 1u : 0u;
                        p.metal4_supported |=
                            [MTLFXFrameInterpolatorDescriptor supportsMetal4FX:metalDevice] ? 1u : 0u;
                    }
                    [devices release];
                }
                return finish(p.legacy_supported || p.metal4_supported ? Ok : Unsupported);
            }

            if (operation == YAAGL_FSR_FG_CREATE) {
                if (header.size != sizeof(yaagl_fsr_fg_create_packet))
                    return finish(Parameter);
                auto& p = *static_cast<yaagl_fsr_fg_create_packet*>(arguments);
                if (!p.display_width || !p.display_height ||
                    !p.max_render_width || !p.max_render_height ||
                    p.max_render_width > p.display_width ||
                    p.max_render_height > p.display_height)
                    return finish(Parameter);
                if (colorFormat(p.backbuffer_format) == MTLPixelFormatInvalid)
                    return finish(Unsupported);
                auto state = std::make_shared<State>();
                state->device = owner(pointer(p.device), false);
                if (!state->device || !getLuid(state->device.get(), state->luid))
                    return finish(Parameter);
                state->creation = p;
                auto context = nextContext.fetch_add(1, std::memory_order_relaxed);
                {
                    std::lock_guard lock(registryMutex);
                    contexts.emplace(context, state);
                }
                header.context = context;
                return finish(Ok);
            }

            if (operation != YAAGL_FSR_FG_PREPARE &&
                operation != YAAGL_FSR_FG_DISPATCH)
                return finish(Unsupported);

            const bool generate = operation == YAAGL_FSR_FG_DISPATCH;
            if (header.size != (generate ? sizeof(yaagl_fsr_fg_dispatch_packet)
                                         : sizeof(yaagl_fsr_fg_prepare_packet)))
                return finish(Parameter);
            auto state = lookup(header.context);
            if (!state) return finish(Parameter);
            std::lock_guard lock(state->mutex);
            if (state->retired) return finish(Parameter);

            auto* p = generate ? nullptr
                : static_cast<yaagl_fsr_fg_prepare_packet*>(arguments);
            auto* d = generate
                ? static_cast<yaagl_fsr_fg_dispatch_packet*>(arguments) : nullptr;
            void* list = pointer(generate ? d->command_list : p->command_list);
            if (!matches(list, true, state->luid)) return finish(Parameter);
            Command command;
            if (!command.open(list)) return finish(Unsupported);
            Mode mode = command.value.kind == transport::CommandListKind::mpl
                      ? Mode::Metal4 : Mode::Legacy;
            if (!supported((id<MTLDevice>)command.value.device, mode,
                           command.value.compiler))
                return finish(Unsupported);
            if (state->hasMode &&
                (state->mode != mode || state->metalDevice.get() != (id)command.value.device))
                return finish(Parameter);

            Resources resources;
            auto implementation = std::make_shared<PreparedFrame::Impl>();
            implementation->state = state;
            std::array<std::uint64_t, 3> addresses{};
            std::array<std::uint32_t, 3> states{};
            unsigned resourceCount = 2;
            std::uint64_t frame = generate ? d->frame_id : p->frame_id;

            if (!generate) {
                CameraPlanes planes{};
                if (!normalizeCameraPlanes(*p, state->creation.flags, planes))
                    return finish(Parameter, "prepare_camera_planes", state->creation.flags);
                if (!validParameters(*p, state->creation.flags) ||
                    p->render_width > state->creation.max_render_width ||
                    p->render_height > state->creation.max_render_height)
                    return finish(Parameter, "prepare_parameters", state->creation.flags);
                if (state->frames.count(frame)) return finish(Parameter);
                // Prepare may continue while FG is off. Recorded work owns its snapshot,
                // but disabled presentation cannot consume frame-ID metadata.
                if (state->generationEnabled && state->frames.size() >= 64)
                    return finish(Runtime, "prepare_backpressure");
                addresses = {p->depth, p->motion_vectors, 0};
                states = {p->depth_state, p->motion_vectors_state, 0};
                const bool displayMotion = (state->creation.flags &
                    YAAGL_FSR_FG_DISPLAY_RESOLUTION_MOTION_VECTORS) != 0;
                const NSUInteger motionWidth = displayMotion
                    ? state->creation.display_width : p->render_width;
                const NSUInteger motionHeight = displayMotion
                    ? state->creation.display_height : p->render_height;
                if (!addresses[0] || !addresses[1] || addresses[0] == addresses[1] ||
                    !mapOne(resources, 0, *state, command, addresses[0], false,
                            p->render_width, p->render_height) ||
                    !mapOne(resources, 1, *state, command, addresses[1], false,
                            motionWidth, motionHeight) ||
                    rootTexture((id<MTLTexture>)resources.values[0].texture) ==
                    rootTexture((id<MTLTexture>)resources.values[1].texture))
                    return finish(Unsupported);
                auto depth = (id<MTLTexture>)resources.values[0].texture;
                auto motion = (id<MTLTexture>)resources.values[1].texture;
                auto configuration = configure(*state, command, *p, depth,
                    MTLPixelFormatRGBA16Float, MTLPixelFormatInvalid,
                    p->render_width, p->render_height,
                    FFX_API_BACKBUFFER_TRANSFER_FUNCTION_SRGB);
                if (!configuration) return finish(Unsupported);
                auto snapshot = std::make_shared<Snapshot>();
                snapshot->configuration = configuration;
                snapshot->parameters = *p;
                snapshot->depthWidth = p->render_width;
                snapshot->depthHeight = p->render_height;
                snapshot->motionWidth = motionWidth;
                snapshot->motionHeight = motionHeight;
                snapshot->hasPreviousJitter = state->hasPreparedJitter &&
                    state->preparedFrame + 1 == frame && !p->reset;
                snapshot->previousJitterX = state->preparedJitterX;
                snapshot->previousJitterY = state->preparedJitterY;
                snapshot->depth = privateTexture(
                    (id<MTLDevice>)configuration->device.get(), configuration->depth,
                    p->render_width, p->render_height, MTLTextureUsageShaderRead);
                snapshot->motion = privateTexture(
                    (id<MTLDevice>)configuration->device.get(), motion.pixelFormat,
                    motionWidth, motionHeight, MTLTextureUsageShaderRead);
                if (!snapshot->depth || !snapshot->motion) return finish(Unsupported);
                state->hasPreparedJitter = true;
                state->preparedFrame = frame;
                state->preparedJitterX = p->jitter_x;
                state->preparedJitterY = p->jitter_y;
                implementation->snapshot = std::move(snapshot);
            } else {
                if (d->num_generated_frames != 1) return finish(Unsupported);
                std::int32_t rectLeft = 0, rectTop = 0;
                NSUInteger rectWidth = 0, rectHeight = 0;
                if (!validTransfer(*d) ||
                    !resolveRect(*d, state->creation.display_width,
                                 state->creation.display_height, rectLeft, rectTop,
                                 rectWidth, rectHeight))
                    return finish(Parameter);
                auto found = state->frames.find(frame);
                if (found == state->frames.end()) return finish(Parameter);
                implementation->kind = PreparedFrame::Impl::Kind::Generate;
                implementation->reset = d->reset != 0;
                implementation->dispatch = *d;
                addresses = {d->present_color, d->output, d->hudless_color};
                states = {d->present_color_state, d->output_state, d->hudless_color_state};
                if (!mapPair(resources, *state, command, addresses[0], addresses[1],
                             true, state->creation.display_width,
                             state->creation.display_height))
                    return finish(Unsupported);
                auto present = (id<MTLTexture>)resources.values[0].texture;
                auto output = (id<MTLTexture>)resources.values[1].texture;
                if (present.width != state->creation.display_width ||
                    present.height != state->creation.display_height ||
                    output.width != state->creation.display_width ||
                    output.height != state->creation.display_height ||
                    present.pixelFormat != output.pixelFormat)
                    return finish(Unsupported);
                id<MTLTexture> scene = present;
                MTLPixelFormat uiFormat = MTLPixelFormatInvalid;
                if (d->hudless_color) {
                    resourceCount = 3;
                    if (!mapOne(resources, 2, *state, command, d->hudless_color, false,
                                state->creation.display_width, state->creation.display_height))
                        return finish(Unsupported);
                    scene = (id<MTLTexture>)resources.values[2].texture;
                    if (rootTexture(scene) == rootTexture(output)) return finish(Parameter);
                    uiFormat = present.pixelFormat;
                }
                auto dispatchSnapshot = std::make_shared<Snapshot>(*found->second);
                dispatchSnapshot->configuration = configure(*state, command,
                    dispatchSnapshot->parameters,
                    (id<MTLTexture>)dispatchSnapshot->depth.get(), scene.pixelFormat,
                    uiFormat, rectWidth, rectHeight, d->backbuffer_transfer_function);
                if (!dispatchSnapshot->configuration) return finish(Unsupported);
                implementation->snapshot = std::move(dispatchSnapshot);
            }
            implementation->first = Object((id)resources.values[0].texture);
            implementation->second = Object((id)resources.values[1].texture);
            if (resourceCount == 3)
                implementation->third = Object((id)resources.values[2].texture);
            auto prepared = std::shared_ptr<const PreparedFrame>(
                new PreparedFrame(implementation));

            /*
             * Insert before recording so allocation failure never leaves an
             * accepted command without its frame-ID registry entry.
             */
            if (!generate && state->generationEnabled)
                state->frames.emplace(frame, implementation->snapshot);
            if (!record(list, command, resources, prepared, header.context,
                        frame, addresses, states, resourceCount, generate)) {
                if (!generate) state->frames.erase(frame);
                return finish(Runtime);
            }
            if (generate) state->frames.erase(frame);
            state->hasMode = true;
            state->mode = mode;
            state->metalDevice = Object((id)command.value.device);
            return finish(Ok);
        } @catch (NSException*) {
            return finish(Runtime);
        }
    } catch (const std::bad_alloc&) {
        return finish(Memory);
    } catch (...) {
        return finish(Runtime);
    }
}

} // namespace yaagl::pso::fsr::framegeneration

extern "C" __attribute__((visibility("default"))) std::uint32_t
yaagl_fsr_fg_api(std::uint32_t operation, void* arguments) noexcept {
    return yaagl::pso::fsr::framegeneration::api(operation, arguments);
}