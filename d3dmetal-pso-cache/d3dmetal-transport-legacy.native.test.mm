#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include "metalfx-contract.hpp"
#include "d3dmetal-transport-legacy.hpp"
#include "metalfx-backend.hpp"

#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace {

const std::uint8_t* gImage = nullptr;

[[noreturn]] void fail(const char* message) {
    std::fprintf(stderr, "FAIL %s\n", message);
    std::exit(1);
}

void require(bool condition, const char* message) {
    if (!condition) fail(message);
}

template<class T>
T load(const void* pointer, std::size_t offset = 0) {
    T value{};
    std::memcpy(&value, static_cast<const std::uint8_t*>(pointer) + offset, sizeof(value));
    return value;
}

template<class T>
void store(void* pointer, std::size_t offset, const T& value) {
    std::memcpy(static_cast<std::uint8_t*>(pointer) + offset, &value, sizeof(value));
}

struct ResourceFixture {
    struct Dispatch { void** vtable = nullptr; ResourceFixture* owner = nullptr; };
    alignas(16) std::array<std::uint8_t, 0x220> texture{};
    std::array<void*, 5> textureVtable{};
    std::array<void*, 4> bridgeVtable{};
    std::array<void*, 3> queryVtable{};
    Dispatch bridge{}, query{};
    std::array<void*, 2> exported{};

    static void* getInterface(Dispatch* self, const void*) { return &self->owner->query; }
    static std::int32_t queryInterface(Dispatch* self, const void*, void** result) {
        *result = self->owner->texture.data();
        store(*result, 0x1d0, load<std::uint64_t>(*result, 0x1d0) + 0x100000001ULL);
        return 0;
    }
    static void* current(void* self) { return static_cast<std::uint8_t*>(self) - 0xc8 + 0x198; }

    ResourceFixture(id<MTLTexture> metal, std::uint32_t format, std::uint32_t flags) {
        textureVtable[4] = reinterpret_cast<void*>(&current);
        store(texture.data(), 0xc8, textureVtable.data());
        store(texture.data(), 0x198, metal);
        store(texture.data(), 0x1d0, std::uint64_t{0x200000002ULL});
        store(texture.data(), 0x38, std::uint64_t{16}); // descriptor Width
        store(texture.data(), 0x48, format);
        store(texture.data(), 0x58, flags);
        bridgeVtable[3] = reinterpret_cast<void*>(&getInterface);
        queryVtable[2] = reinterpret_cast<void*>(&queryInterface);
        bridge = {bridgeVtable.data(), this};
        query = {queryVtable.data(), this};
        exported[0] = &bridge;
    }
    void* external() { return &exported[1]; }
    bool refsBalanced() const { return load<std::uint64_t>(texture.data(), 0x1d0) == 0x200000002ULL; }
};

id<MTLTexture> makeTexture(id<MTLDevice> device, MTLPixelFormat format,
                           NSUInteger width, NSUInteger height, MTLTextureUsage usage) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                 width:width
                                                                                height:height
                                                                             mipmapped:NO];
    d.storageMode = MTLStorageModePrivate;
    d.hazardTrackingMode = MTLHazardTrackingModeTracked;
    d.usage = usage;
    id<MTLTexture> result = [device newTextureWithDescriptor:d];
    require(result != nil, "texture allocation");
    return result;
}

} // namespace

int main(int argc, char** argv) { @autoreleasepool {
    using namespace yaagl::pso::metalfx;
    using namespace yaagl::pso::d3dmetal;
    namespace metalfx = yaagl::pso::metalfx;
    namespace legacy = yaagl::pso::d3dmetal::legacy;

    require(argc == 2, "usage: d3dmetal-transport-legacy-native-test <D3DMetal>");
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    require(library != nullptr, "dlopen D3DMetal");
    void* mplCreate = dlsym(library, "MPLCreateContext");
    Dl_info info{};
    require(mplCreate && dladdr(mplCreate, &info), "D3DMetal image base");
    gImage = static_cast<const std::uint8_t*>(info.dli_fbase);
    require(legacy::initialize(gImage) && legacy::available(), "legacy private ABI pins");

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, "Metal device");

    // DXGI metadata must survive independently from Metal view selection. In
    // particular ALLOW_UNORDERED_ACCESS (0x4) remains observable for frontend
    // contract rejection/selection before any MetalFX object is created.
    id<MTLTexture> metadataTexture = makeTexture(device, MTLPixelFormatRGBA8Unorm, 16, 16,
                                                 MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    ResourceFixture metadataFixture(metadataTexture, 28u, 0x5u);
    legacy::ResourceMetadata metadata{};
    require(legacy::queryResourceMetadata(metadataFixture.external(), metadata),
            "query original DXGI resource metadata");
    require(metadata.dxgiFormat == 28u && metadata.resourceFlags == 0x5u,
            "DXGI format/flags exact");
    alignas(8) std::array<std::uint8_t, 0x38> publicDescription{};
    using NativeGetDesc = void* (__attribute__((ms_abi)) *)(void*, void*);
    reinterpret_cast<NativeGetDesc>(const_cast<std::uint8_t*>(gImage) + 0x14e3af)(
        metadataFixture.texture.data() + 0x10, publicDescription.data());
    require(metadata.dxgiFormat == load<std::uint32_t>(publicDescription.data(), 0x20) &&
            metadata.resourceFlags == load<std::uint32_t>(publicDescription.data(), 0x30),
            "metadata agrees with native external-interface GetDesc");
    require(metadata.allowsUnorderedAccess(), "UAV flag exact");
    require(metadataFixture.refsBalanced(), "metadata temporary native resource ref balanced");
    [metadataTexture release];

    // Build one real Legacy PreparedFrame. The command-stream/allocator below
    // are exact-layout native fixtures so the private reserve and RetainResource
    // functions execute against the same offsets as D3DMCommandListMTL.
    constexpr std::uint32_t W = 64, H = 64;
    id<MTLTexture> color = makeTexture(device, MTLPixelFormatRGBA8Unorm, W, H,
                                       MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    id<MTLTexture> depth = makeTexture(device, MTLPixelFormatDepth32Float_Stencil8, W, H,
                                       MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    id<MTLTexture> motion = makeTexture(device, MTLPixelFormatRG16Float, W, H,
                                        MTLTextureUsageShaderRead);
    id<MTLTexture> output = makeTexture(device, MTLPixelFormatRGBA8Unorm, W, H,
                                        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                                        MTLTextureUsageRenderTarget);

    CreateInfo create{};
    create.input = {W, H};
    create.output = {W, H};
    create.featureFlags = {FeatureFlagMVLowRes | FeatureFlagAutoExposure, true};
    metalfx::CreateContext backendContext{
        reinterpret_cast<void*>(device), nullptr, metalfx::CommandMode::Legacy};
    metalfx::Error error{};
    auto feature = metalfx::Feature::create(backendContext, create, &error);
    if (!feature) std::fprintf(stderr, "legacy feature create: %s\n", error.message.c_str());
    require(feature != nullptr, "legacy backend feature");

    FrameInfo frame{};
    frame.color = reinterpret_cast<void*>(0x1);
    frame.depth = reinterpret_cast<void*>(0x2);
    frame.motionVectors = reinterpret_cast<void*>(0x3);
    frame.output = reinterpret_cast<void*>(0x4);
    frame.inputContent = {W, H};
    frame.colorRect = {0, 0, W, H};
    frame.depthRect = {0, 0, W, H};
    frame.motionRect = {0, 0, W, H};
    frame.outputRect = {0, 0, W, H};
    frame.exposureMode = ExposureMode::Automatic;
    metalfx::TextureSet textures{reinterpret_cast<void*>(color), reinterpret_cast<void*>(depth),
                                 reinterpret_cast<void*>(motion), reinterpret_cast<void*>(output),
                                 nullptr, nullptr};
    auto prepared = feature->prepare(frame, textures, &error);
    if (!prepared) std::fprintf(stderr, "legacy prepare: %s\n", error.message.c_str());
    require(prepared && prepared->mode() == metalfx::CommandMode::Legacy,
            "legacy immutable prepared frame");

    alignas(16) std::array<std::uint8_t, 0x900> wrapper{};
    alignas(16) std::array<std::uint8_t, 0x180> list{};
    alignas(16) std::array<std::uint8_t, 0xb0> allocator{};
    alignas(16) std::array<std::uint8_t, 0x80> d3dmDevice{};
    alignas(16) std::array<std::uint8_t, 0x30> chunk{};
    alignas(16) std::array<std::uint8_t, 0x400> stream{};
    std::array<void*, 1> retainedResources{};

    store(wrapper.data(), 0x80, list.data());
    store(list.data(), 0, const_cast<std::uint8_t*>(gImage) + 0x4b16c0);
    store(list.data(), 0x8, d3dmDevice.data());
    store(list.data(), 0x18, allocator.data());
    store(list.data(), 0x68, std::uint64_t{1});
    store(list.data(), 0x70, chunk.data());
    store(list.data(), 0x100, std::uint64_t{~0ULL});
    store(list.data(), 0x108, std::uint64_t{~0ULL});
    store(list.data(), 0x110, std::uint64_t{~0ULL});
    store(allocator.data(), 0, const_cast<std::uint8_t*>(gImage) + 0x4b82b0);
    store(allocator.data(), 0x30, retainedResources.data());
    store(allocator.data(), 0x38, retainedResources.data());
    store(allocator.data(), 0x40, retainedResources.data() + retainedResources.size());
    store(d3dmDevice.data(), 0x40, reinterpret_cast<void*>(device));
    store(chunk.data(), 0x10, stream.data());
    store(chunk.data(), 0x18, stream.data());
    store(chunk.data(), 0x28, std::uint64_t{stream.size()});

    NativeCommandList native{};
    native.kind = CommandListKind::legacy;
    native.wrapper = wrapper.data();
    require(legacy::resolveCommandList(native), "resolve legacy wrapper/list/allocator/device");
    require(native.list == list.data() && native.allocator == allocator.data() &&
            native.device == reinterpret_cast<void*>(device) && native.compiler == nullptr,
            "legacy command metadata exact");

    MetalResource colorResource{reinterpret_cast<void*>(color), {}};
    MetalResource depthResource{reinterpret_cast<void*>(depth), {0, 1, 0, 1, 2, {}}};
    MetalResource motionResource{reinterpret_cast<void*>(motion), {}};
    MetalResource outputResource{reinterpret_cast<void*>(output), {}};
    const std::array<ResourceUse, 4> uses{{
        {&colorResource, ResourceAccess::read},
        {&depthResource, ResourceAccess::read},
        {&motionResource, ResourceAccess::read},
        {&outputResource, ResourceAccess::write},
    }};
    constexpr std::uint64_t FeatureID = 0x7777;
    constexpr std::uint64_t EvaluationID = 0x8888;
    RecordRequest request{prepared, uses.data(), uses.size(), FeatureID, EvaluationID};
    require(legacy::record(native, request), "legacy native command carrier record");
    require(load<void*>(chunk.data(), 0x18) == stream.data() + 0xe0,
            "legacy native reserve advances exactly 0xe0 bytes");
    require(legacy::isRecordedCommand(stream.data()), "legacy custom command tag");
    require(load<std::uint64_t>(stream.data()) == 0x24060000000000e0ULL,
            "legacy native opcode/flags/size unchanged");
    require(load<std::uint64_t>(list.data(), 0x100) == ~0ULL &&
            load<std::uint64_t>(list.data(), 0x108) == 0 &&
            load<std::uint64_t>(list.data(), 0x110) == 0,
            "legacy native category offsets updated");

    // Drop all frontend/backend owners. D3DMCommandAllocator's native resource
    // list is now the only recorded-command owner, and its ReleaseResources
    // path must destroy our proxy exactly at allocator lifetime end.
    request.prepared.reset();
    prepared.reset();
    feature.reset();
    require(retainedResources[0] != nullptr, "legacy allocator retained custom owner");
    reinterpret_cast<void (*)(void*)>(const_cast<std::uint8_t*>(gImage) + 0x16aa0e)(allocator.data());
    require(load<void*>(allocator.data(), 0x38) == retainedResources.data(),
            "legacy allocator resource vector reset");

    [output release];
    [motion release];
    [depth release];
    [color release];
    [device release];
    dlclose(library);

    std::fprintf(stderr,
                 "PASS legacy pins=1 dxgi_metadata=1 uav_flag=1 resource_ref_balance=1 "
                 "resolve=1 native_record=1 allocator_owner=1\n");
    return 0;
}}
