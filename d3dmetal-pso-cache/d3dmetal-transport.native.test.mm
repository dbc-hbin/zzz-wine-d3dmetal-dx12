// Native transport contract for the shared MetalFX backend.
// It exercises the pinned D3DMetal resource bridge, the generic MPL compute
// scheduler used to carry the custom command, replay against real Metal4, and
// allocator-owned lifetime across feature release and repeated execution.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include "metalfx-contract.hpp"
#include "d3dmetal-transport.hpp"
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
T fn(std::uintptr_t offset) {
    return reinterpret_cast<T>(const_cast<std::uint8_t*>(gImage) + offset);
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

void destroyNative(void* object) {
    if (!object) return;
    auto* vtable = load<std::uintptr_t*>(object);
    require(vtable && vtable[1], "native object destructor");
    reinterpret_cast<void (*)(void*)>(vtable[1])(object);
}

struct NativeList {
    void* list = nullptr;
    void* allocator = nullptr;

    explicit NativeList(void* context) {
        list = fn<void* (*)(void*)>(0x31c10)(context);
        allocator = fn<void* (*)(void*)>(0x327a0)(context);
        require(list && allocator, "native MPL list/allocator creation");
        fn<void (*)(void*, void*)>(0xe2ec)(list, allocator);
    }

    ~NativeList() {
        destroyNative(list);
        destroyNative(allocator);
    }

    void close() {
        void* error = nullptr;
        fn<void (*)(void*, void**)>(0xe5f2)(list, &error);
        require(error == nullptr, "MPLCommandList::Close returned nil error");
    }

    void resetAllocator() {
        fn<void (*)(void*)>(0x38fde)(allocator);
    }
};

// The native test owns an IMPL list directly. Model only its enclosing,
// byte-pinned D3D12/D3DM links here; real queue policy execution is covered by
// nameplate-frame-age.d3d12.test.cpp, not claimed from this layout fixture.
struct SubmissionFixture {
    std::array<std::uint8_t, 0x80> wrapper{};
    std::array<std::uint8_t, 0x60> active{};
    std::array<std::uint8_t, 0x88> allocatorWrapper{};

    explicit SubmissionFixture(const NativeList& native) {
        store(wrapper.data(), 0x78, active.data());
        store(active.data(), 0x58, native.list);
        store(active.data(), 0x18, allocatorWrapper.data());
        store(allocatorWrapper.data(), 0x80, native.allocator);
    }
    bool ordered() const { return load<std::uint8_t>(active.data(), 0x50) == 1; }
    void verifyNativeReset() {
        // No fake COM owner is passed to Reset: null out the optional allocator
        // before invoking the real base Reset that clears its policy bytes.
        store<void*>(active.data(), 0x18, nullptr);
        fn<void (*)(void*, void*)>(0xfb3b4)(active.data(), nullptr);
        require(!ordered(), "native list Reset retires ordered-encode policy");
    }
};

// Exact public-resource fixture already proven against ngx::GetInternalResource.
// The fake D3D12Texture uses D3DMetal's real current-texture virtual ABI, while
// keeping a non-zero baseline refcount so a mismatch cannot silently delete it.
struct ResourceFixture {
    struct Dispatch {
        void** vtable = nullptr;
        ResourceFixture* owner = nullptr;
    };

    alignas(16) std::array<std::uint8_t, 0x220> texture{};
    std::array<void*, 5> textureVtable{};
    std::array<void*, 4> bridgeVtable{};
    std::array<void*, 3> queryVtable{};
    Dispatch bridge{}, query{};
    std::array<void*, 2> exported{};

    static void* getInterface(Dispatch* self, const void*) {
        return &self->owner->query;
    }

    static std::int32_t queryInterface(Dispatch* self, const void*, void** result) {
        *result = self->owner->texture.data();
        const auto refs = load<std::uint64_t>(*result, 0x1d0);
        store(*result, 0x1d0, refs + 0x100000001ULL);
        return 0;
    }

    static void* current(void* self) {
        return static_cast<std::uint8_t*>(self) - 0xc8 + 0x198;
    }

    explicit ResourceFixture(id<MTLTexture> metal) {
        textureVtable[4] = reinterpret_cast<void*>(&current);
        store(texture.data(), 0xc8, textureVtable.data());
        store(texture.data(), 0x198, metal);
        store(texture.data(), 0x1d0, std::uint64_t{0x200000002ULL});
        bridgeVtable[3] = reinterpret_cast<void*>(&getInterface);
        queryVtable[2] = reinterpret_cast<void*>(&queryInterface);
        bridge = {bridgeVtable.data(), this};
        query = {queryVtable.data(), this};
        exported[0] = &bridge;
    }

    void* external() { return &exported[1]; }

    bool refsBalanced() const {
        return load<std::uint64_t>(texture.data(), 0x1d0) == 0x200000002ULL;
    }
};

id<MTLTexture> makeTexture(id<MTLDevice> device, MTLPixelFormat format,
                           NSUInteger width, NSUInteger height, MTLTextureUsage usage) {
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
    descriptor.usage = usage;
    id<MTLTexture> result = [device newTextureWithDescriptor:descriptor];
    require(result != nil, "Metal texture allocation");
    return result;
}

const void* findRecordedCommand(void* list) {
    const auto first = load<std::uintptr_t>(list, 0x23f0);
    const auto last = load<std::uintptr_t>(list, 0x23f8);
    require(first && first <= last && last - first < 1024 * 1024,
            "bounded MPL compute command stream");
    const void* found = nullptr;
    for (std::uintptr_t cursor = first; cursor < last;) {
        const std::uint32_t header = load<std::uint32_t>(reinterpret_cast<void*>(cursor));
        const std::uint32_t size = header & 0x00ffffffu;
        require(size >= 8 && (size & 7u) == 0 && cursor + size <= last,
                "valid MPL command record");
        const void* command = reinterpret_cast<const void*>(cursor);
        if (yaagl::pso::d3dmetal::isRecordedCommand(command)) {
            require(found == nullptr, "exactly one custom MetalFX command");
            require((header >> 24) == 0x3e && size == 0x20,
                    "custom command reuses temporal opcode with private 0x20 layout");
            found = command;
        }
        cursor += size;
    }
    require(found != nullptr, "custom MetalFX command present in compute stream");
    return found;
}

void submit(id<MTL4CommandQueue> queue, id<MTL4CommandBuffer> command, const char* label)
    API_AVAILABLE(macos(26.0)) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    require(done != nullptr, "MTL4 completion semaphore");
    __block NSError* gpuError = nil;
    MTL4CommitOptions* options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        gpuError = [feedback.error retain];
        dispatch_semaphore_signal(done);
    }];
    id<MTL4CommandBuffer> commands[] = {command};
    [queue commit:commands count:1 options:options];
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
            "MTL4 GPU completion");
    if (gpuError) NSLog(@"%s GPU error: %@", label, gpuError);
    require(gpuError == nil, "MTL4 feedback reports success");
    [gpuError release];
    [options release];
    dispatch_release(done);
}

} // namespace

int runTransportTest(int argc, char** argv) API_AVAILABLE(macos(26.0));
int runTransportTest(int argc, char** argv) { @autoreleasepool {
    using namespace yaagl::pso::metalfx;
    using namespace yaagl::pso::d3dmetal;
    namespace metalfx = yaagl::pso::metalfx;

    require(argc == 2, "usage: d3dmetal-transport-native-test <D3DMetal>");
    void* library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) {
        std::fprintf(stderr, "dlopen: %s\n", dlerror());
        return 2;
    }
    void* createContext = dlsym(library, "MPLCreateContext");
    Dl_info info{};
    require(createContext && dladdr(createContext, &info), "MPLCreateContext + image base");
    gImage = static_cast<const std::uint8_t*>(info.dli_fbase);
    require(reinterpret_cast<const std::uint8_t*>(createContext) - gImage == 0x2791a,
            "expected GPTK 4.0b2 MPLCreateContext offset");
    require(initialize(gImage) && available(), "all private D3DMetal transport pins match");

    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device && [MTLFXTemporalScalerDescriptor supportsMetal4FX:device],
            "Metal4FX-capable device");

    // Resource transport: exact D3D12 bridge, exact current Metal view, and no
    // leaked temporary D3D12Texture reference.
    id<MTLTexture> mappedTexture = makeTexture(device, MTLPixelFormatRGBA8Unorm, 32, 32,
                                               MTLTextureUsageShaderRead);
    ResourceFixture fixture(mappedTexture);
    MetalResource mapped{};
    require(mapResource(fixture.external(), mapped), "D3D12 resource -> Metal view mapping");
    require(mapped.texture == reinterpret_cast<void*>(mappedTexture),
            "resource mapping returns exact current Metal texture");
    require(fixture.refsBalanced(), "temporary internal D3D12Texture reference balanced");
    require(mapped.view.firstMip == 0 && mapped.view.mipCount == 1 &&
            mapped.view.firstSlice == 0 && mapped.view.sliceCount == 1 && mapped.view.planes == 1,
            "mapped single-plane view contract");
    releaseResource(mapped);
    [mappedTexture release];

    NSError* error = nil;
    MTL4CompilerDescriptor* compilerDescriptor = [MTL4CompilerDescriptor new];
    id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:compilerDescriptor error:&error];
    [compilerDescriptor release];
    if (error) NSLog(@"compiler: %@", error);
    require(compiler != nil, "Metal4 compiler");
    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
    require(queue != nil, "Metal4 command queue");

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
        reinterpret_cast<void*>(device), reinterpret_cast<void*>(compiler), metalfx::CommandMode::Metal4};
    metalfx::Error backendError{};
    auto feature = metalfx::Feature::create(backendContext, create, &backendError);
    if (!feature) std::fprintf(stderr, "backend create: %s\n", backendError.message.c_str());
    require(feature != nullptr, "independent MetalFX feature creation");

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
    metalfx::TextureSet textures{
        reinterpret_cast<void*>(color), reinterpret_cast<void*>(depth),
        reinterpret_cast<void*>(motion), reinterpret_cast<void*>(output), nullptr, nullptr};
    auto prepared = feature->prepare(frame, textures, &backendError);
    if (!prepared) std::fprintf(stderr, "backend prepare: %s\n", backendError.message.c_str());
    require(prepared != nullptr, "immutable independent backend frame preparation");

    void* context = reinterpret_cast<void* (*)(id, void*, unsigned)>(createContext)(device, nullptr, 0);
    require(context != nullptr, "MPL context");
    auto native = std::make_unique<NativeList>(context);
    SubmissionFixture submission(*native);
    NativeCommandList transport{};
    transport.kind = CommandListKind::mpl;
    transport.wrapper = submission.wrapper.data();
    transport.list = native->list;
    transport.allocator = native->allocator;

    MetalResource nativeColor{reinterpret_cast<void*>(color), {}};
    MetalResource nativeDepth{reinterpret_cast<void*>(depth), {0, 1, 0, 1, 2, {}}};
    MetalResource nativeMotion{reinterpret_cast<void*>(motion), {}};
    MetalResource nativeOutput{reinterpret_cast<void*>(output), {}};
    const std::array<ResourceUse, 4> uses{{
        {&nativeColor, ResourceAccess::read},
        {&nativeDepth, ResourceAccess::read},
        {&nativeMotion, ResourceAccess::read},
        {&nativeOutput, ResourceAccess::write},
    }};
    constexpr std::uint64_t FeatureID = 0x1234;
    constexpr std::uint64_t EvaluationID = 0x5678;
    RecordRequest request{prepared, uses.data(), uses.size(), FeatureID, EvaluationID};
    NativeCommandList missingSubmission = transport;
    missingSubmission.wrapper = nullptr;
    require(!record(missingSubmission, request), "record rejects missing submission-policy owner");
    require(!submission.ordered(), "failed recording does not mark submission policy");
    require(record(transport, request), "custom MetalFX command record through native MPL scheduler");
    require(submission.ordered(), "custom temporal list selects native ordered CPU encoding");
    const void* command = findRecordedCommand(native->list);
    native->close();

    // Repeat with graphics-only dirty state and no compute PSO/root state. This
    // is the internal list state reached from a D3D12 list that has only seen
    // graphics commands, and proves the generic Dispatch carrier itself does
    // not require an application compute pipeline.
    auto graphicsNative = std::make_unique<NativeList>(context);
    SubmissionFixture graphicsSubmission(*graphicsNative);
    fn<void (*)(void*, MTLPrimitiveType)>(0x1a654)(graphicsNative->list, MTLPrimitiveTypeTriangle);
    NativeCommandList graphicsTransport{};
    graphicsTransport.kind = CommandListKind::mpl;
    graphicsTransport.wrapper = graphicsSubmission.wrapper.data();
    graphicsTransport.list = graphicsNative->list;
    graphicsTransport.allocator = graphicsNative->allocator;
    constexpr std::uint64_t GraphicsEvaluationID = EvaluationID + 1;
    RecordRequest graphicsRequest{prepared, uses.data(), uses.size(), FeatureID, GraphicsEvaluationID};
    require(record(graphicsTransport, graphicsRequest),
            "custom record with graphics-only state and no compute PSO");
    require(graphicsSubmission.ordered(), "graphics-only temporal list requests ordered CPU encoding");
    require(findRecordedCommand(graphicsNative->list) != nullptr,
            "graphics-only stream contains custom command");
    graphicsNative->close();
    graphicsNative->resetAllocator();
    graphicsSubmission.verifyNativeReset();
    graphicsNative.reset();

    // The allocator-owned recorded owner is now the sole owner of PreparedFrame.
    request.prepared.reset();
    prepared.reset();
    feature.reset();

    void* replayer = fn<void* (*)(void*)>(0x31be6)(context);
    require(replayer != nullptr, "native MPL command replayer");
    void* fence = load<void*>(replayer, 0x6d0);
    require(fence != nullptr, "native replayer fence");
    for (unsigned replayIndex = 0; replayIndex < 2; ++replayIndex) {
        id<MTL4CommandAllocator> commandAllocator = [device newCommandAllocator];
        id<MTL4CommandBuffer> commandBuffer = [device newCommandBuffer];
        require(commandAllocator && commandBuffer, "Metal4 replay allocator/buffer");
        [commandBuffer beginCommandBufferWithAllocator:commandAllocator];

        id<MTL4ComputeCommandEncoder> initialEncoder = [commandBuffer computeCommandEncoder];
        require(initialEncoder != nil, "native-style initial compute encoder");
        store(replayer, 0x90, reinterpret_cast<void*>(commandBuffer));
        store(replayer, 0x288, reinterpret_cast<void*>(initialEncoder));
        if (replayIndex == 0)
            fn<void (*)(void*)>(0x2951a)(static_cast<std::uint8_t*>(replayer) + 0x280);
        id<MTL4ArgumentTable> argumentTable = load<id<MTL4ArgumentTable>>(replayer, 0x290);
        require(argumentTable != nil, "native compute argument table");
        [initialEncoder setArgumentTable:argumentTable];

        require(replay(replayer, command),
                "custom replay brackets exact native compute encoder state");
        id<MTL4ComputeCommandEncoder> replacement =
            load<id<MTL4ComputeCommandEncoder>>(replayer, 0x288);
        require(replacement != nil && replacement != initialEncoder,
                "custom replay restores a fresh MPL compute encoder");
        [replacement endEncoding];
        store<void*>(replayer, 0x288, nullptr);
        [commandBuffer endCommandBuffer];
        submit(queue, commandBuffer, replayIndex == 0 ? "translator replay 0" : "translator replay 1");
        [commandBuffer release];
        [commandAllocator release];
    }


    // GPU has completed both executions. Native command-allocator reset is the
    // point D3DMetal itself releases ExtendResourceLifetime objects.
    native->resetAllocator();
    submission.verifyNativeReset();
    native.reset();

    destroyNative(replayer);
    [output release];
    [motion release];
    [depth release];
    [color release];
    [queue release];
    [compiler release];
    fn<void (*)(void*)>(0x31bca)(context);
    [device release];
    dlclose(library);

    std::fprintf(stderr,
                 "PASS transport pins=1 resource_ref_balance=1 mpl_scheduler=1 "
                 "empty_list=1 graphics_only_list=1 encoder_boundary=1 ordered_encode_policy=1 policy_reset=1 "
                 "feature_release_before_replay=1 replays=2 leases_until_allocator_reset=2\n");
    return 0;
}}

int main(int argc, char** argv) { @autoreleasepool {
    if (@available(macOS 26.0, *))
        return runTransportTest(argc, argv);
    std::fprintf(stderr, "FAIL Metal4 transport test requires macOS 26 or newer\n");
    return 1;
}}
