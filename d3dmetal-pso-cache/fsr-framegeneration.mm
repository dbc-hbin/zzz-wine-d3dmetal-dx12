#include "fsr-framegeneration.hpp"
#include "d3dmetal-transport.hpp"
#include "d3dmetal-transport-legacy.hpp"
#include "../include/yaagl_fsr_fg_bridge.h"
#include "third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api_types.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/message.h>

#include <array>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
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
std::mutex registryMutex;

void logError(const char* text) noexcept {
    if (errorCount.fetch_add(1, std::memory_order_relaxed) < 120)
        std::fprintf(stderr, "yaagl-fsr-framegeneration: %s\n", text);
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
    std::array<transport::MetalResource, 2> values{};
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

struct Configuration {
    Mode mode = Mode::Legacy;
    Object device;
    Object compiler;
    Object descriptor;
    Object factory;
    MTLPixelFormat color = MTLPixelFormatInvalid;
    MTLPixelFormat depth = MTLPixelFormatInvalid;
    MTLPixelFormat motion = MTLPixelFormatInvalid;
    NSUInteger width = 0, height = 0, outputWidth = 0, outputHeight = 0;
    MTLTextureUsage colorUsage = 0, depthUsage = 0, motionUsage = 0, outputUsage = 0;

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
};

struct State {
    std::shared_ptr<Configuration> configuration;
    std::mutex mutex;
    std::mutex executionMutex;
    std::shared_ptr<void> device;
    Luid luid{};
    yaagl_fsr_fg_create_packet creation{};
    bool retired = false;
    bool hasMode = false;
    Mode mode = Mode::Legacy;
    Object metalDevice;
    std::unordered_map<std::uint64_t, std::shared_ptr<Snapshot>> frames;
    Object history;
    std::shared_ptr<Configuration> historyConfiguration;
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
    id<MTLTexture> depth, id<MTLTexture> motion) {
    if (@available(macOS 26.0, *)) {
        auto result = std::make_shared<Configuration>();
        result->mode = command.value.kind == transport::CommandListKind::mpl
                     ? Mode::Metal4 : Mode::Legacy;
        auto device = (id<MTLDevice>)command.value.device;
        if (!supported(device, result->mode, command.value.compiler)) return {};
        result->device = Object(device);
        result->compiler = Object((id)command.value.compiler);
        result->color = colorFormat(state.creation.backbuffer_format);
        result->depth = depth.pixelFormat;
        result->motion = motion.pixelFormat;
        result->width = packet.render_width;
        result->height = packet.render_height;
        result->outputWidth = state.creation.display_width;
        result->outputHeight = state.creation.display_height;
        if (state.configuration && sameConfiguration(*result, *state.configuration))
            return state.configuration;

        MTLFXFrameInterpolatorDescriptor* descriptor =
            [[MTLFXFrameInterpolatorDescriptor alloc] init];
        result->descriptor = Object(descriptor);
        [descriptor release];
        descriptor.colorTextureFormat = result->color;
        descriptor.outputTextureFormat = result->color;
        descriptor.depthTextureFormat = result->depth;
        descriptor.motionTextureFormat = result->motion;
        descriptor.uiTextureFormat = MTLPixelFormatInvalid;
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
        result->depthUsage = interpolator.depthTextureUsage;
        result->motionUsage = interpolator.motionTextureUsage;
        result->outputUsage = interpolator.outputTextureUsage;
        state.configuration = result;
        return result;
    }
    return {};
}

bool mapPair(Resources& resources, const State& state, const Command& command,
             std::uint64_t first, std::uint64_t second, bool output,
             NSUInteger width, NSUInteger height) {
    if (!first || !second || first == second) return false;
    const std::uint64_t addresses[2] = {first, second};
    for (unsigned i = 0; i != 2; ++i) {
        void* resource = pointer(addresses[i]);
        if (!matches(resource, true, state.luid)) return false;
        transport::legacy::ResourceMetadata metadata{};
        if (!transport::legacy::queryResourceMetadata(resource, metadata) ||
            (output && i == 1 && !metadata.allowsUnorderedAccess()) ||
            !transport::mapResource(resource, resources.values[i]))
            return false;
        const auto& view = resources.values[i].view;
        if (view.mipCount != 1 || view.sliceCount != 1 || view.planes != 1)
            return false;
        if (!textureValid((id<MTLTexture>)resources.values[i].texture,
                          (id<MTLDevice>)command.value.device, width, height))
            return false;
    }
    auto a = (id<MTLTexture>)resources.values[0].texture;
    auto b = (id<MTLTexture>)resources.values[1].texture;
    id<MTLTexture> rootA = a;
    id<MTLTexture> rootB = b;
    while (rootA.parentTexture) rootA = rootA.parentTexture;
    while (rootB.parentTexture) rootB = rootB.parentTexture;
    return rootA != rootB;
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
            const std::array<std::uint64_t, 2>& addresses,
            const std::array<std::uint32_t, 2>& states, bool generate) {
    std::array<transport::ResourceUse, 2> uses{{
        {&resources.values[0], transport::ResourceAccess::read},
        {&resources.values[1], generate ? transport::ResourceAccess::write
                                      : transport::ResourceAccess::read}
    }};
    std::array<Barrier, 2> barriers{};
    unsigned count = 0;
    for (unsigned i = 0; i != 2; ++i) {
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
    transport::RecordRequest request{prepared, uses.data(), uses.size(), context, frame};
    bool result = command.value.kind == transport::CommandListKind::legacy
        ? transport::legacy::record(command.value, request)
        : transport::record(command.value, request);
    for (unsigned i = 0; i != count; ++i)
        std::swap(barriers[i].before, barriers[i].after);
    if (count) transition(list, count, barriers.data());
    return result;
}

bool validParameters(const yaagl_fsr_fg_prepare_packet& p) {
    if (!p.render_width || !p.render_height ||
        !std::isfinite(p.jitter_x) || !std::isfinite(p.jitter_y) ||
        !std::isfinite(p.motion_scale_x) || !std::isfinite(p.motion_scale_y) ||
        !std::isfinite(p.frame_time_delta_ms) || p.frame_time_delta_ms <= 0 ||
        !std::isfinite(p.camera_near) || p.camera_near <= 0 ||
        std::isnan(p.camera_far) || p.camera_far <= p.camera_near ||
        !std::isfinite(p.camera_fov_vertical_radians) ||
        p.camera_fov_vertical_radians <= 0 ||
        p.camera_fov_vertical_radians >= 3.14159265358979323846f ||
        !std::isfinite(p.view_space_to_meters) || p.view_space_to_meters < 0)
        return false;
    for (unsigned i = 0; i != 3; ++i)
        if (!std::isfinite(p.camera_position[i]) ||
            !std::isfinite(p.camera_up[i]) ||
            !std::isfinite(p.camera_right[i]) ||
            !std::isfinite(p.camera_forward[i]))
            return false;
    return true;
}

struct Copy {
    id<MTLTexture> source;
    id<MTLTexture> destination;
    NSUInteger width, height;
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
            copy.source, NSUInteger(0), NSUInteger(0), MTLOriginMake(0, 0, 0),
            MTLSizeMake(copy.width, copy.height, 1), copy.destination,
            NSUInteger(0), NSUInteger(0), MTLOriginMake(0, 0, 0));
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

bool sameConfiguration(const Configuration& a, const Configuration& b) {
    return a.device.get() == b.device.get() && a.mode == b.mode &&
           a.color == b.color && a.depth == b.depth && a.motion == b.motion &&
           a.width == b.width && a.height == b.height &&
           a.outputWidth == b.outputWidth && a.outputHeight == b.outputHeight;
}

} // namespace

struct PreparedFrame::Impl {
    enum class Kind { Snapshot, Generate };
    Kind kind = Kind::Snapshot;
    std::shared_ptr<State> state;
    std::shared_ptr<Snapshot> snapshot;
    Object first;
    Object second;
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
    try {
        @try {
            if (@available(macOS 26.0, *)) {
                if (!commandBuffer || !impl_ || !impl_->snapshot) return false;
                id buffer = (id)commandBuffer;
                auto& configuration = *impl_->snapshot->configuration;
                if (configuration.mode == Mode::Metal4) {
                    if (![buffer conformsToProtocol:@protocol(MTL4CommandBuffer)])
                        return false;
                } else {
                    if (![buffer conformsToProtocol:@protocol(MTLCommandBuffer)] ||
                        [(id<MTLCommandBuffer>)buffer device] != configuration.device.get())
                        return false;
                }
                auto execution = std::make_shared<ExecutionLease::Impl>();
                execution->prepared = impl_;
                execution->objects.reserve(16);
                execution->objects.emplace_back((id)fence);
                execution->objects.push_back(impl_->first);
                execution->objects.push_back(impl_->second);
                execution->objects.push_back(impl_->snapshot->depth);
                execution->objects.push_back(impl_->snapshot->motion);

                auto retainedLease = std::shared_ptr<const ExecutionLease>(
                    new ExecutionLease(execution));
                /* Publish ownership before the first command is encoded. */
                lease = retainedLease;

                std::lock_guard executionLock(impl_->state->executionMutex);
                if (impl_->kind == Impl::Kind::Snapshot) {
                    if (!execution->makeResident(buffer, configuration.mode)) return false;
                    const Copy copies[] = {
                        {(id<MTLTexture>)impl_->first.get(),
                         (id<MTLTexture>)impl_->snapshot->depth.get(),
                         configuration.width, configuration.height},
                        {(id<MTLTexture>)impl_->second.get(),
                         (id<MTLTexture>)impl_->snapshot->motion.get(),
                         configuration.width, configuration.height}
                    };
                    return copyTextures(buffer, (id)fence, configuration.mode,
                                        copies, 2, execution->objects);
                }

                Object interpolator = configuration.factory;
                if (!interpolator) return false;
                auto effect = (id<MTLFXFrameInterpolatorBase>)interpolator.get();
                auto device = (id<MTLDevice>)configuration.device.get();
                Object current = privateTexture(device, configuration.color,
                    configuration.outputWidth, configuration.outputHeight,
                    effect.colorTextureUsage);
                Object output = privateTexture(device, configuration.color,
                    configuration.outputWidth, configuration.outputHeight,
                    effect.outputTextureUsage);
                if (!current || !output) return false;

                auto& state = *impl_->state;
                bool reset = impl_->reset || impl_->snapshot->parameters.reset ||
                    !state.history || !state.historyConfiguration ||
                    !sameConfiguration(configuration, *state.historyConfiguration);
                Object previous = reset ? current : state.history;
                execution->objects.push_back(interpolator);
                execution->objects.push_back(current);
                execution->objects.push_back(output);
                execution->objects.push_back(previous);
                if (!execution->makeResident(buffer, configuration.mode)) return false;

                const Copy inputCopy{
                    (id<MTLTexture>)impl_->first.get(), (id<MTLTexture>)current.get(),
                    configuration.outputWidth, configuration.outputHeight};
                if (!copyTextures(buffer, (id)fence, configuration.mode,
                                  &inputCopy, 1, execution->objects))
                    return false;

                const auto& p = impl_->snapshot->parameters;
                effect.colorTexture = (id<MTLTexture>)current.get();
                effect.prevColorTexture = (id<MTLTexture>)previous.get();
                effect.depthTexture = (id<MTLTexture>)impl_->snapshot->depth.get();
                effect.motionTexture = (id<MTLTexture>)impl_->snapshot->motion.get();
                effect.outputTexture = (id<MTLTexture>)output.get();
                effect.fence = (id<MTLFence>)fence;
                effect.shouldResetHistory = reset;
                effect.depthReversed =
                    (state.creation.flags & YAAGL_FSR_FG_DEPTH_INVERTED) != 0;
                effect.motionVectorScaleX = p.motion_scale_x;
                effect.motionVectorScaleY = p.motion_scale_y;
                effect.jitterOffsetX = p.jitter_x;
                effect.jitterOffsetY = p.jitter_y;
                effect.deltaTime = p.frame_time_delta_ms * 0.001f;
                const float worldScale = p.view_space_to_meters > 0 ? p.view_space_to_meters : 1.0f;
                effect.nearPlane = p.camera_near * worldScale;
                effect.farPlane = (state.creation.flags & YAAGL_FSR_FG_DEPTH_INFINITE)
                    ? INFINITY : p.camera_far * worldScale;
                effect.fieldOfView =
                    p.camera_fov_vertical_radians * 57.295779513082320876f;
                effect.aspectRatio = float(p.render_width) / float(p.render_height);

                if (@available(macOS 27.0, *)) {
                    effect.contentWidth = configuration.width;
                    effect.contentHeight = configuration.height;
                    simd_float3 position = {
                        p.camera_position[0] * worldScale,
                        p.camera_position[1] * worldScale,
                        p.camera_position[2] * worldScale};
                    simd_float3 right = {
                        p.camera_right[0], p.camera_right[1], p.camera_right[2]};
                    simd_float3 up = {
                        p.camera_up[0], p.camera_up[1], p.camera_up[2]};
                    simd_float3 forward = {
                        p.camera_forward[0], p.camera_forward[1], p.camera_forward[2]};
                    simd_float4x4 view{};
                    view.columns[0] = {right.x, up.x, forward.x, 0};
                    view.columns[1] = {right.y, up.y, forward.y, 0};
                    view.columns[2] = {right.z, up.z, forward.z, 0};
                    view.columns[3] = {-simd_dot(right, position),
                                       -simd_dot(up, position),
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

                if (configuration.mode == Mode::Metal4)
                    [(id<MTL4FXFrameInterpolator>)interpolator.get()
                        encodeToCommandBuffer:(id<MTL4CommandBuffer>)buffer];
                else
                    [(id<MTLFXFrameInterpolator>)interpolator.get()
                        encodeToCommandBuffer:(id<MTLCommandBuffer>)buffer];

                const Copy outputCopy{
                    (id<MTLTexture>)output.get(), (id<MTLTexture>)impl_->second.get(),
                    configuration.outputWidth, configuration.outputHeight};
                if (!copyTextures(buffer, (id)fence, configuration.mode,
                                  &outputCopy, 1, execution->objects))
                    return false;
                state.history = current;
                state.historyConfiguration = impl_->snapshot->configuration;
                return true;
            }
            return false;
        } @catch (NSException* exception) {
            logError([[exception reason] UTF8String]);
            return false;
        }
    } catch (...) {
        logError("exception during encode");
        return false;
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
    auto finish = [&](std::uint32_t result) {
        header.result = result;
        if (result != Ok) logError(result == Unsupported
            ? "unsupported frame-generation request" : "frame-generation request failed");
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
            std::array<std::uint64_t, 2> addresses{};
            std::array<std::uint32_t, 2> states{};
            std::uint64_t frame = generate ? d->frame_id : p->frame_id;

            if (!generate) {
                if (!validParameters(*p) ||
                    p->render_width > state->creation.max_render_width ||
                    p->render_height > state->creation.max_render_height)
                    return finish(Parameter);
                if (state->frames.count(frame)) return finish(Parameter);
                // Prepare may continue while presentation has FG disabled.
                // Retire unconsumed metadata; recorded work owns its snapshot separately.
                if (state->frames.size() >= 64) {
                    auto oldest = std::min_element(state->frames.begin(), state->frames.end(),
                        [](const auto& a, const auto& b) { return a.first < b.first; });
                    state->frames.erase(oldest);
                }
                addresses = {p->depth, p->motion_vectors};
                states = {p->depth_state, p->motion_vectors_state};
                if (!addresses[0] || !addresses[1] || addresses[0] == addresses[1] ||
                    !matches(pointer(addresses[0]), true, state->luid) ||
                    !matches(pointer(addresses[1]), true, state->luid))
                    return finish(Parameter);
                if (!mapPair(resources, *state, command, addresses[0], addresses[1],
                             false, p->render_width, p->render_height))
                    return finish(Unsupported);
                auto depth = (id<MTLTexture>)resources.values[0].texture;
                auto motion = (id<MTLTexture>)resources.values[1].texture;
                auto configuration = configure(*state, command, *p, depth, motion);
                if (!configuration) return finish(Unsupported);
                auto snapshot = std::make_shared<Snapshot>();
                snapshot->configuration = configuration;
                snapshot->parameters = *p;
                snapshot->depth = privateTexture(
                    (id<MTLDevice>)configuration->device.get(), configuration->depth,
                    configuration->width, configuration->height, configuration->depthUsage);
                snapshot->motion = privateTexture(
                    (id<MTLDevice>)configuration->device.get(), configuration->motion,
                    configuration->width, configuration->height, configuration->motionUsage);
                if (!snapshot->depth || !snapshot->motion) return finish(Unsupported);
                implementation->snapshot = std::move(snapshot);
            } else {
                if (d->num_generated_frames != 1 ||
                    d->generation_rect_left || d->generation_rect_top ||
                    (d->generation_rect_width &&
                     d->generation_rect_width != state->creation.display_width) ||
                    (d->generation_rect_height &&
                     d->generation_rect_height != state->creation.display_height))
                    return finish(Unsupported);
                auto found = state->frames.find(frame);
                if (found == state->frames.end()) return finish(Parameter);
                implementation->snapshot = found->second;
                implementation->kind = PreparedFrame::Impl::Kind::Generate;
                implementation->reset = d->reset != 0;
                addresses = {d->present_color, d->output};
                states = {d->present_color_state, d->output_state};
                if (!addresses[0] || !addresses[1] || addresses[0] == addresses[1] ||
                    !matches(pointer(addresses[0]), true, state->luid) ||
                    !matches(pointer(addresses[1]), true, state->luid))
                    return finish(Parameter);
                auto& configuration = *found->second->configuration;
                if (!mapPair(resources, *state, command, addresses[0], addresses[1],
                             true, configuration.outputWidth, configuration.outputHeight))
                    return finish(Unsupported);
                for (const auto& resource : resources.values) {
                    auto texture = (id<MTLTexture>)resource.texture;
                    if (texture.pixelFormat != configuration.color ||
                        texture.width != configuration.outputWidth ||
                        texture.height != configuration.outputHeight)
                        return finish(Unsupported);
                }
            }
            implementation->first = Object((id)resources.values[0].texture);
            implementation->second = Object((id)resources.values[1].texture);
            auto prepared = std::shared_ptr<const PreparedFrame>(
                new PreparedFrame(implementation));

            /*
             * Insert before recording so allocation failure never leaves an
             * accepted command without its frame-ID registry entry.
             */
            if (!generate)
                state->frames.emplace(frame, implementation->snapshot);
            if (!record(list, command, resources, prepared, header.context,
                        frame, addresses, states, generate)) {
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