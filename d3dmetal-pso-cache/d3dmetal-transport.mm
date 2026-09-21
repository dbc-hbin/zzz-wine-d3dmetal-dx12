#import "d3dmetal-transport.hpp"
#import "metalfx-backend.hpp"
#import "fsr-framegeneration.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>

#include <dlfcn.h>

#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <string_view>
#include <vector>

namespace yaagl::pso::d3dmetal {
namespace {

constexpr std::size_t kMaxResources = 8;
constexpr std::uint32_t kDispatchHeader = 0x0b000020u;
constexpr std::uint32_t kRecordedHeader = 0x3e000020u;
constexpr std::uint32_t kRecordedMagic = 0x32534459u; // "YDS2"
constexpr std::uint64_t kRecordedCookie = 0xd1557a9e46c20b31ULL;
constexpr std::uint64_t kInternalStrongRef = 0x100000001ULL;

constexpr std::uintptr_t kGetInternalResource = 0x411ae;
constexpr std::uintptr_t kGetMetalTexture = 0x4128c;
constexpr std::uintptr_t kDispatch = 0x14d92;
constexpr std::uintptr_t kEndEncoder = 0xea08;
constexpr std::uintptr_t kBeginUseTexture = 0x1c416;
constexpr std::uintptr_t kEndUseTexture = 0x1c682;
constexpr std::uintptr_t kExtendResourceLifetime = 0x1dbf4;
constexpr std::uintptr_t kDynamicCastThunk = 0x37067e;

constexpr std::uintptr_t kMplCommandListVtable = 0x4af010;
constexpr std::uintptr_t kMplCommandAllocatorVtable = 0x4af478;
constexpr std::uintptr_t kPrivateCommandListIidPointer = 0x4aeba0;
constexpr std::uintptr_t kPrivateCommandListSourceTypePointer = 0x4aed80;
constexpr std::uintptr_t kD3D12CommandListMtlType = 0x4be7c0;
constexpr std::uintptr_t kD3D12CommandListMplType = 0x4be808;
constexpr std::uintptr_t kGfxTosIUnknownIface = 0x523fc0;

constexpr std::size_t kD3D12ActiveCommandList = 0x78;
constexpr std::size_t kD3DMOrderedEncode = 0x50;
constexpr std::size_t kD3DMAllocator = 0x18;
constexpr std::size_t kD3DMMplList = 0x58;
constexpr std::size_t kMplAllocator = 0x80;
constexpr std::size_t kMplContext = 0x8;
constexpr std::size_t kMplContextDevice = 0x8;
constexpr std::size_t kMplContextCompiler = 0x18;
constexpr std::size_t kMplComputeCursor = 0x23f8;
constexpr std::size_t kMplIndirectDispatchState = 0x2c60;
constexpr std::size_t kReplayerCommandBuffer = 0x90;
constexpr std::size_t kReplayerComputeEncoder = 0x288;
constexpr std::size_t kReplayerArgumentTable = 0x290;
constexpr std::size_t kReplayerUpdateFenceImp = 0x338;
constexpr std::size_t kReplayerWaitFenceImp = 0x340;
constexpr std::size_t kReplayerFence = 0x6d0;

constexpr std::uintptr_t kSelComputeCommandEncoder = 0x4c64d0;
constexpr std::uintptr_t kSelEndEncoding = 0x4c6518;
constexpr std::uintptr_t kSelSetArgumentTable = 0x4c62a8;
constexpr std::uintptr_t kSelUpdateFenceAfterStages = 0x4c72d8;
constexpr std::uintptr_t kSelWaitFenceBeforeStages = 0x4c72e8;
constexpr std::uint64_t kComputeStage = 0x08000000ULL;

struct RecordedCommand {
    std::uint32_t header;
    std::uint32_t magic;
    void* owner;
    std::uint64_t cookie;
    std::uint64_t reserved;
};
static_assert(sizeof(RecordedCommand) == 0x20);

struct Runtime {
    const std::uint8_t* image = nullptr;
    bool ready = false;
};

Runtime gRuntime;
std::mutex gRuntimeLock;
std::atomic<bool> gReady{false};

template<class T>
T loadAt(const void* pointer, std::size_t offset = 0) noexcept {
    T value{};
    if (pointer)
        std::memcpy(&value, static_cast<const std::uint8_t*>(pointer) + offset, sizeof(value));
    return value;
}

template<class T>
void storeAt(void* pointer, std::size_t offset, const T& value) noexcept {
    if (pointer)
        std::memcpy(static_cast<std::uint8_t*>(pointer) + offset, &value, sizeof(value));
}

int hexDigit(char c) noexcept {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool pinHex(const std::uint8_t* image, std::uintptr_t offset, std::string_view hex) noexcept {
    if (!image || (hex.size() & 1u)) return false;
    const std::uint8_t* actual = image + offset;
    for (std::size_t i = 0; i < hex.size() / 2; ++i) {
        const int hi = hexDigit(hex[i * 2]);
        const int lo = hexDigit(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0 || actual[i] != static_cast<std::uint8_t>((hi << 4) | lo))
            return false;
    }
    return true;
}

bool verifyImage(const std::uint8_t* image) noexcept {
    // Resource bridge and balanced temporary ComPtr release.
    if (!pinHex(image, 0x411ae, "415653504889fb4885f6747d48c7042400000000488b7ef8")) return false;
    if (!pinHex(image, 0x41203, "4885ff743b48c704240000000048b80100000001000000f0482987d0010000")) return false;
    if (!pinHex(image, 0x4128c, "415653504885ff7444488b87c80000004881c7c8000000ff5020")) return false;

    // Generic compute scheduler path used to create the custom command slot.
    if (!pinHex(image, 0x14d92, "554889e54157415641554154534883ec284c8b65104c8b7d18")) return false;
    if (!pinHex(image, 0x14f4e, "488b83f8230000c7002000000b488383f823000020498b4c2410")) return false;
    if (!pinHex(image, 0x1a654, "554889e54839b7b8020000740b4889b7b8020000804f1802")) return false;
    if (!pinHex(image, 0xea08, "83fe040f840c020000554889e54157415641554154534883ec28")) return false;
    if (!pinHex(image, 0xebc4, "488b8bf823000048ba08000003ffffffff488911488383f823000008")) return false;
    if (!pinHex(image, 0x1c416, "554889e54157415641554154534883ec4844894dd0894dcc8955ac")) return false;
    if (!pinHex(image, 0x1c682, "554889e54157415641554154534883ec4844894dd0894dcc8955ac")) return false;

    // Temporal history is mutable during CPU encoding, not only on the GPU.
    // The native temporal path marks its enclosing D3DM list for the native serial encode
    // queue. A mutex around the scaler alone cannot preserve submission order
    // when generic command lists are replayed concurrently (e.g. 2,3,1).
    if (!pinHex(image, 0xa61af, "488b4378c6405001")) return false;
    if (!pinHex(image, 0x1585a3, "498b3c364531c0448647200a47504883c6084839f175e9")) return false;
    if (!pinHex(image, 0x1585d3, "0fb6c083e0018904244c89f64d89e1e829030000")) return false;
    if (!pinHex(image, 0x158a6d, "803de4e23b00000f94c04008c5488b542408488b4210400fb6cd488b84c8e0190000")) return false;
    // Base Reset clears +0x50 with its final 16-byte zero store at +0x41.
    if (!pinHex(image, 0xfb3fb, "4c8973180f57c00f1143280f1143380f114341")) return false;

    // Command allocator lifetime ownership and its balancing objc_release loop.
    if (!pinHex(image, 0x1dbf4, "554889e5415741564155415453504989f64889fb4c8b6778488b8780000000")) return false;
    if (!pinHex(image, 0x38f74, "554889e54156534889fbb8ffffffff48894710e852000000")) return false;
    if (!pinHex(image, 0x391b1, "488b5f704c8b77784c39f3741e4c8b3d93514700488b3b41ffd7")) return false;

    // Public Evaluate's private-IUnknown routing, RTTI cast, and balanced release.
    if (!pinHex(image, 0x193036, "48833d820f3900007438488b79f8488b07488b3552bb3100ff5018")) return false;
    if (!pinHex(image, 0x1930ab, "488b35cebc3100488d1507b73200b9680000004c89e7e8b8d51d00")) return false;
    if (!pinHex(image, 0x19305f,
                "4989c4488b00488b40e84c89e74801c7498b0404ff5020")) return false;
    if (!pinHex(image, 0x193123, "48c744242000000000498b0424488b40e8498d3c04498b0404ff5028")) return false;
    if (!pinHex(image, kDynamicCastThunk, "ff255ce01300")) return false;

    // D3DMCommandListMPL owns IMPLCommandList at +0x58 and resets it with
    // D3DMCommandAllocator's IMPLCommandAllocator at +0x80.
    if (!pinHex(image, 0x51eca, "488bbe480b0000488b07ff5020488943584d85f67410498bb680000000")) return false;
    if (!pinHex(image, 0x51cc8, "498b7e58488bb380000000488b07488b40104883c4085b415effe0")) return false;
    if (!pinHex(image, 0xdb78,
                "488d0591144a004889074889770848c74710000000004883c718")) return false;
    if (!pinHex(image, 0x3126e,
                "488b3d83644900e8ccf533004889c3488b353c5049004c8b2d9dd047004c8b75c84c89f74889c231c941ffd549894718"))
        return false;

    // Replayer owns a device-created MTLFence at +0x6d0 and receives the exact
    // MTL4CommandBuffer at +0x90 for each EncodeToMTL4CommandBuffer call.
    if (!pinHex(image, 0x2b4ba, "498b7e08488b35abb94900ff155d2e4800488983d0060000")) return false;
    if (!pinHex(image, 0x2b724, "e85f4e34004d89be900000004c89f74c89ee4489e2")) return false;

    // Generic ComputeEncoder initialization pins the cached fence IMP slots;
    // Begin pins current encoder +0x288, argument table +0x290, and CB +0x90.
    if (!pinHex(image, 0x29675,
                "488d87b0000000488945a8488b0551dc4900488945b0488d87b8000000488945b8488b054bdc4900"))
        return false;
    if (!pinHex(image, 0x29747,
                "488bb890000000488b357bcd4900ff15cd4b48004989460849837e5000750c4c89f7e8acfdffff"))
        return false;

    struct SelectorPin { std::uintptr_t offset; const char* name; };
    constexpr SelectorPin selectors[] = {
        {0x4c6e70, "newFence"},
        {kSelComputeCommandEncoder, "computeCommandEncoder"},
        {kSelEndEncoding, "endEncoding"},
        {kSelSetArgumentTable, "setArgumentTable:"},
        {kSelUpdateFenceAfterStages, "updateFence:afterEncoderStages:"},
        {kSelWaitFenceBeforeStages, "waitForFence:beforeEncoderStages:"},
    };
    for (const auto& pin : selectors) {
        const char* selector = loadAt<const char*>(image + pin.offset);
        if (!selector || std::strcmp(selector, pin.name) != 0) return false;
    }
    return true;
}

const std::uint8_t* locateImage() noexcept {
    void* symbol = dlsym(RTLD_DEFAULT, "MPLCreateContext");
    Dl_info info{};
    if (!symbol || !dladdr(symbol, &info) || !info.dli_fbase) return nullptr;
    return static_cast<const std::uint8_t*>(info.dli_fbase);
}

bool ensureInitialized() noexcept {
    if (gReady.load(std::memory_order_acquire)) return true;
    return initialize(nullptr);
}

void releasePrivateOwner(void* owner) noexcept {
    if (!owner) return;
    void** vtable = loadAt<void**>(owner);
    if (!vtable) return;
    std::ptrdiff_t adjustment = 0;
    std::memcpy(&adjustment, reinterpret_cast<const std::uint8_t*>(vtable) - 0x18,
                sizeof(adjustment));
    void* adjusted = static_cast<std::uint8_t*>(owner) + adjustment;
    void** adjustedVtable = loadAt<void**>(adjusted);
    if (!adjustedVtable || !adjustedVtable[5]) return;
    using Release = void (*)(void*);
    reinterpret_cast<Release>(adjustedVtable[5])(adjusted);
}

bool addRefPrivateOwner(void* owner) noexcept {
    if (!owner) return false;
    void** vtable = loadAt<void**>(owner);
    if (!vtable) return false;
    std::ptrdiff_t adjustment = 0;
    std::memcpy(&adjustment, reinterpret_cast<const std::uint8_t*>(vtable) - 0x18,
                sizeof(adjustment));
    void* adjusted = static_cast<std::uint8_t*>(owner) + adjustment;
    void** adjustedVtable = loadAt<void**>(adjusted);
    if (!adjustedVtable || !adjustedVtable[4]) return false;
    using AddRef = void (*)(void*);
    reinterpret_cast<AddRef>(adjustedVtable[4])(adjusted);
    return true;
}

void releaseInternalTexture(void* texture) noexcept {
    if (!texture) return;
    auto* refs = reinterpret_cast<std::uint64_t*>(static_cast<std::uint8_t*>(texture) + 0x1d0);
    const std::uint64_t remaining = __atomic_sub_fetch(refs, kInternalStrongRef, __ATOMIC_SEQ_CST);
    if (remaining != 0) return;

    void* embedded = static_cast<std::uint8_t*>(texture) + 0x1c0;
    void** vtable = loadAt<void**>(embedded);
    if (!vtable || !vtable[1]) return;
    using Destroy = void (*)(void*);
    reinterpret_cast<Destroy>(vtable[1])(embedded);
}

bool supportedPlaneView(id<MTLTexture> texture, TextureView& view) noexcept {
    if (!texture) return false;
    const NSUInteger format = texture.pixelFormat;
    // These are the exact depth/depth-stencil format cases already used by
    // D3DMetal's MPL resource tracker for temporal resources.
    if (format == 253 || format == 261 || format == 262) return false;
    view = {};
    if (format == 250 || format == 252 || format == 255 || format == 260)
        view.planes = 2;
    return true;
}

struct UseEntry {
    id<MTLTexture> texture = nil;
    TextureView view{};
    ResourceAccess access = ResourceAccess::read;
};

bool sameView(const TextureView& a, const TextureView& b) noexcept {
    return std::memcmp(&a, &b, sizeof(a)) == 0;
}

bool prepareUses(const RecordRequest& request,
                 std::array<UseEntry, kMaxResources>& uses,
                 std::size_t& count) noexcept {
    count = 0;
    if (request.resourceCount > kMaxResources) return false;
    if (request.resourceCount && !request.resources) return false;
    for (std::size_t i = 0; i < request.resourceCount; ++i) {
        const ResourceUse& source = request.resources[i];
        if (!source.resource || !source.resource->texture) return false;
        id<MTLTexture> texture = reinterpret_cast<id<MTLTexture>>(source.resource->texture);
        bool duplicate = false;
        for (std::size_t j = 0; j < count; ++j) {
            if (uses[j].texture != texture || !sameView(uses[j].view, source.resource->view)) continue;
            if (uses[j].access != source.access) return false;
            duplicate = true;
            break;
        }
        if (duplicate) continue;
        uses[count++] = {texture, source.resource->view, source.access};
    }
    return true;
}

struct OwnerState {
    PreparedWork prepared;
    using Lease = std::variant<
        std::shared_ptr<const metalfx::ExecutionLease>,
        std::shared_ptr<const fsr::framegeneration::ExecutionLease>>;
    std::vector<Lease> leases;
    std::mutex leaseLock;
    std::array<id, kMaxResources> textures{};
    std::size_t textureCount = 0;
    std::uint64_t featureID = 0;
    std::uint64_t evaluationID = 0;

    OwnerState(PreparedWork frame,
               const std::array<UseEntry, kMaxResources>& uses,
               std::size_t count,
               std::uint64_t feature,
               std::uint64_t evaluation)
        : prepared(std::move(frame)), textureCount(count),
          featureID(feature), evaluationID(evaluation) {
        for (std::size_t i = 0; i < count; ++i)
            textures[i] = [uses[i].texture retain];
    }

    ~OwnerState() {
        for (std::size_t i = 0; i < textureCount; ++i)
            [textures[i] release];
    }

    bool encode(void* command, void* commandBuffer, void* fence) noexcept {
        if (!prepared) return false;
        metalfx::Error error{};
        bool encoded = false;
        try {
            std::lock_guard<std::mutex> lock(leaseLock);
            // Allocate the owner slot before the backend can append GPU work.
            // PreparedFrame publishes its ExecutionLease before any command;
            // keeping this slot through a false return preserves partially
            // encoded resource ownership as well.
            const metalfx::EncodeIdentity identity{featureID, evaluationID, command};
            encoded = std::visit([&](const auto& frame) -> bool {
                using T = std::decay_t<decltype(frame)>;
                if constexpr (std::is_same_v<T, std::monostate>) return false;
                else if constexpr (std::is_same_v<T, std::shared_ptr<const metalfx::PreparedFrame>>) {
                    std::shared_ptr<const metalfx::ExecutionLease> lease;
                    const bool result = frame && frame->encode(commandBuffer, fence, lease, &error, &identity);
                    leases.emplace_back(std::move(lease));
                    return result;
                } else {
                    std::shared_ptr<const fsr::framegeneration::ExecutionLease> lease;
                    const bool result = frame && frame->encode(commandBuffer, fence, lease);
                    leases.emplace_back(std::move(lease));
                    return result;
                }
            }, prepared.value);
            const bool hasLease = !leases.empty() && std::visit(
                [](const auto& lease) { return static_cast<bool>(lease); }, leases.back());
            if (!hasLease) return false;
        } catch (...) {
            return false;
        }
        return encoded;
    }
};

} // namespace
} // namespace yaagl::pso::d3dmetal

@interface YAAGLMetalFXRecordedOwner : NSObject {
@public
    void* _state;
}
- (instancetype)initWithState:(void*)state;
@end

@implementation YAAGLMetalFXRecordedOwner
- (instancetype)initWithState:(void*)state {
    self = [super init];
    if (!self) return nil;
    _state = state;
    return self;
}

- (void)dealloc {
    delete reinterpret_cast<yaagl::pso::d3dmetal::OwnerState*>(_state);
    [super dealloc];
}
@end

namespace yaagl::pso::d3dmetal {

bool initialize(const void* d3dmetalImageBase) noexcept {
    std::lock_guard<std::mutex> lock(gRuntimeLock);
    const auto* image = d3dmetalImageBase
        ? static_cast<const std::uint8_t*>(d3dmetalImageBase)
        : locateImage();
    if (!image || !verifyImage(image)) {
        gRuntime = {};
        gReady.store(false, std::memory_order_release);
        return false;
    }
    gRuntime.image = image;
    gRuntime.ready = true;
    gReady.store(true, std::memory_order_release);
    return true;
}

bool available() noexcept {
    return ensureInitialized();
}

bool unwrapCommandList(void* d3d12CommandList, NativeCommandList& out) noexcept {
    releaseCommandList(out);
    if (!d3d12CommandList || !ensureInitialized()) return false;
    const std::uint8_t* image = gRuntime.image;
    void* owner = nullptr;

    @try {
        const void* iid = loadAt<const void*>(image + kPrivateCommandListIidPointer);
        if (!iid) return false;
        if (loadAt<void*>(image + kGfxTosIUnknownIface)) {
            void* bridge = loadAt<void*>(static_cast<std::uint8_t*>(d3d12CommandList) - 8);
            void** vtable = loadAt<void**>(bridge);
            if (!bridge || !vtable || !vtable[3]) return false;
            using GetInterface = void* (*)(void*, const void*);
            owner = reinterpret_cast<GetInterface>(vtable[3])(bridge, iid);
            // GFXTOS bridge slot 3 returns a borrowed interface. Native
            // Evaluate immediately takes an adjusted IUnknown AddRef before it
            // enters the common dynamic-cast path; mirror that ownership.
            if (owner && !addRefPrivateOwner(owner)) return false;
        } else {
            void** vtable = loadAt<void**>(d3d12CommandList);
            if (!vtable || !vtable[0]) return false;
            using QueryInterface = std::int32_t (__attribute__((ms_abi)) *)(void*, const void*, void**);
            void* queried = nullptr;
            const std::int32_t status =
                reinterpret_cast<QueryInterface>(vtable[0])(d3d12CommandList, iid, &queried);
            if (status < 0) return false;
            owner = queried;
        }
    } @catch (id) {
        if (owner) releasePrivateOwner(owner);
        owner = nullptr;
    }
    if (!owner) return false;

    const void* sourceType = loadAt<const void*>(image + kPrivateCommandListSourceTypePointer);
    const void* mplType = image + kD3D12CommandListMplType;
    const void* mtlType = image + kD3D12CommandListMtlType;
    if (!sourceType) {
        releasePrivateOwner(owner);
        return false;
    }

    using DynamicCast = void* (*)(void*, const void*, const void*, std::ptrdiff_t);
    const auto dynamicCast = reinterpret_cast<DynamicCast>(
        const_cast<std::uint8_t*>(image) + kDynamicCastThunk);
    void* mpl = dynamicCast(owner, sourceType, mplType, 0x68);
    if (!mpl) {
        void* legacy = dynamicCast(owner, sourceType, mtlType, 0x68);
        if (!legacy) {
            releasePrivateOwner(owner);
            return false;
        }
        out.kind = CommandListKind::legacy;
        out.wrapper = legacy;
        out.qiOwner = owner;
        return true;
    }

    void* active = loadAt<void*>(mpl, kD3D12ActiveCommandList);
    void* list = loadAt<void*>(active, kD3DMMplList);
    void* allocatorWrapper = loadAt<void*>(active, kD3DMAllocator);
    void* allocator = loadAt<void*>(allocatorWrapper, kMplAllocator);
    void* context = loadAt<void*>(list, kMplContext);
    void* device = loadAt<void*>(context, kMplContextDevice);
    void* compiler = loadAt<void*>(context, kMplContextCompiler);
    if (!active || !list || !allocatorWrapper || !allocator ||
        !context || !device || !compiler ||
        loadAt<void*>(list) != image + kMplCommandListVtable ||
        loadAt<void*>(allocator) != image + kMplCommandAllocatorVtable) {
        releasePrivateOwner(owner);
        return false;
    }

    out.kind = CommandListKind::mpl;
    out.wrapper = mpl;
    out.list = list;
    out.allocator = allocator;
    out.device = device;
    out.compiler = compiler;
    out.qiOwner = owner;
    return true;
}

void releaseCommandList(NativeCommandList& commandList) noexcept {
    if (commandList.qiOwner)
        releasePrivateOwner(commandList.qiOwner);
    commandList = {};
}

bool mapResource(void* d3d12Resource, MetalResource& out) noexcept {
    releaseResource(out);
    if (!d3d12Resource || !ensureInitialized()) return false;
    const std::uint8_t* image = gRuntime.image;
    void* internal = nullptr;
    id<MTLTexture> metal = nil;

    @try {
        using GetInternal = void (*)(void**, void*);
        reinterpret_cast<GetInternal>(const_cast<std::uint8_t*>(image) + kGetInternalResource)(
            &internal, d3d12Resource);
        if (!internal) return false;
        using GetMetal = void* (*)(void*);
        metal = reinterpret_cast<id<MTLTexture>>(
            reinterpret_cast<GetMetal>(const_cast<std::uint8_t*>(image) + kGetMetalTexture)(internal));
        if (!metal) {
            releaseInternalTexture(internal);
            return false;
        }
        TextureView view{};
        if (!supportedPlaneView(metal, view)) {
            releaseInternalTexture(internal);
            return false;
        }
        [metal retain];
        releaseInternalTexture(internal);
        out.texture = reinterpret_cast<void*>(metal);
        out.view = view;
        return true;
    } @catch (id) {
        if (internal) releaseInternalTexture(internal);
        return false;
    }
}

void releaseResource(MetalResource& resource) noexcept {
    if (resource.texture) {
        @try {
            [reinterpret_cast<id>(resource.texture) release];
        } @catch (id) {
        }
    }
    resource = {};
}

bool record(NativeCommandList& commandList, const RecordRequest& request) noexcept {
    if (!ensureInitialized() || commandList.kind != CommandListKind::mpl ||
        !commandList.wrapper || !commandList.list || !commandList.allocator || !request.prepared)
        return false;

    const std::uint8_t* image = gRuntime.image;
    void* active = loadAt<void*>(commandList.wrapper, kD3D12ActiveCommandList);
    void* allocatorWrapper = loadAt<void*>(active, kD3DMAllocator);
    if (!active || loadAt<void*>(active, kD3DMMplList) != commandList.list ||
        !allocatorWrapper || loadAt<void*>(allocatorWrapper, kMplAllocator) != commandList.allocator)
        return false;
    if (loadAt<void*>(commandList.list) != image + kMplCommandListVtable ||
        loadAt<void*>(commandList.allocator) != image + kMplCommandAllocatorVtable ||
        loadAt<void*>(commandList.list, kMplIndirectDispatchState) != nullptr)
        return false;

    std::array<UseEntry, kMaxResources> uses{};
    std::size_t useCount = 0;
    if (!prepareUses(request, uses, useCount)) return false;

    using UseTexture = void (*)(void*, void*, unsigned, unsigned, TextureView);
    using Dispatch = void (*)(void*, MTLSize);
    using EndEncoder = void (*)(void*, unsigned);
    using ExtendLifetime = void (*)(void*, void*);
    const auto beginUse = reinterpret_cast<UseTexture>(
        const_cast<std::uint8_t*>(image) + kBeginUseTexture);
    const auto endUse = reinterpret_cast<UseTexture>(
        const_cast<std::uint8_t*>(image) + kEndUseTexture);
    const auto dispatch = reinterpret_cast<Dispatch>(const_cast<std::uint8_t*>(image) + kDispatch);
    const auto endEncoder = reinterpret_cast<EndEncoder>(
        const_cast<std::uint8_t*>(image) + kEndEncoder);
    const auto extendLifetime = reinterpret_cast<ExtendLifetime>(
        const_cast<std::uint8_t*>(image) + kExtendResourceLifetime);

    YAAGLMetalFXRecordedOwner* owner = nil;
    std::size_t begun = 0;
    bool transferred = false;
    bool success = false;

    try {
        @try {
            auto* state = new OwnerState(request.prepared, uses, useCount,
                                         request.featureID, request.evaluationID);
            owner = [[YAAGLMetalFXRecordedOwner alloc] initWithState:state];
            if (!owner) delete state;
            if (!owner) return false;

            // Transfer the +1 from alloc/init to the native command allocator.
            // ExtendResourceLifetime itself does not retain; allocator Reset is
            // the matching objc_release, proven by the pinned spans above.
            extendLifetime(commandList.allocator, owner);
            transferred = true;

            for (; begun < useCount; ++begun) {
                beginUse(commandList.list,
                         reinterpret_cast<void*>(uses[begun].texture),
                         4u,
                         uses[begun].access == ResourceAccess::write ? 1u : 0u,
                         uses[begun].view);
            }

            dispatch(commandList.list, MTLSizeMake(1, 1, 1));
            std::uint8_t* after = loadAt<std::uint8_t*>(commandList.list, kMplComputeCursor);
            if (!after)
                @throw [NSException exceptionWithName:@"YAAGLMetalFXRecordContract"
                                               reason:@"MPL dispatch produced no compute cursor"
                                             userInfo:nil];
            auto* slot = reinterpret_cast<RecordedCommand*>(after - sizeof(RecordedCommand));
            if (loadAt<std::uint32_t>(slot) != kDispatchHeader)
                @throw [NSException exceptionWithName:@"YAAGLMetalFXRecordContract"
                                               reason:@"MPL dispatch tail contract changed"
                                             userInfo:nil];

            const auto ownerBits = static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(owner));
            const RecordedCommand custom{
                kRecordedHeader,
                kRecordedMagic,
                owner,
                kRecordedCookie ^ ownerBits,
                0,
            };
            std::memcpy(slot, &custom, sizeof(custom));
            // Type 1 is the compute stream.  This emits the exact range end
            // marker used by native TemporalScale and dirties state for the
            // following D3D12 compute work, preserving root-state semantics.
            endEncoder(commandList.list, 1u);
            for (std::size_t i = useCount; i != 0; --i) {
                const UseEntry& use = uses[i - 1];
                endUse(commandList.list,
                       reinterpret_cast<void*>(use.texture),
                       4u,
                       use.access == ResourceAccess::write ? 1u : 0u,
                       use.view);
            }
            begun = 0;
            // Mirror the native temporal path's list-local submission policy. This does not
            // wait on the GPU, disable parallel recording globally, or order by
            // Evaluate ID: D3DMetal's native queue keeps actual submission order.
            storeAt<std::uint8_t>(active, kD3DMOrderedEncode, 1u);
            success = true;
        } @catch (id) {
            success = false;
        }
    } catch (...) {
        success = false;
    }

    if (!success && begun) {
        @try {
            while (begun) {
                const UseEntry& use = uses[--begun];
                endUse(commandList.list,
                       reinterpret_cast<void*>(use.texture),
                       4u,
                       use.access == ResourceAccess::write ? 1u : 0u,
                       use.view);
            }
        } @catch (id) {
        }
    }
    if (owner && !transferred)
        [owner release];
    return success;
}

bool isRecordedCommand(const void* command) noexcept {
    if (!command) return false;
    const RecordedCommand value = loadAt<RecordedCommand>(command);
    if (value.header != kRecordedHeader || value.magic != kRecordedMagic || !value.owner)
        return false;
    const auto ownerBits = static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(value.owner));
    return value.cookie == (kRecordedCookie ^ ownerBits) && value.reserved == 0;
}

bool replay(void* mplReplayer, const void* command) noexcept {
    if (!mplReplayer || !isRecordedCommand(command) || !ensureInitialized()) return false;
    const RecordedCommand value = loadAt<RecordedCommand>(command);
    auto* owner = reinterpret_cast<YAAGLMetalFXRecordedOwner*>(value.owner);
    auto* state = reinterpret_cast<OwnerState*>(owner->_state);
    void* commandBuffer = loadAt<void*>(mplReplayer, kReplayerCommandBuffer);
    void* encoder = loadAt<void*>(mplReplayer, kReplayerComputeEncoder);
    void* argumentTable = loadAt<void*>(mplReplayer, kReplayerArgumentTable);
    void* fence = loadAt<void*>(mplReplayer, kReplayerFence);
    void* updateFenceImp = loadAt<void*>(mplReplayer, kReplayerUpdateFenceImp);
    void* waitFenceImp = loadAt<void*>(mplReplayer, kReplayerWaitFenceImp);
    if (!commandBuffer || !encoder || !argumentTable || !fence || !updateFenceImp ||
        !waitFenceImp || !state)
        return false;

    const std::uint8_t* image = gRuntime.image;
    void* updateSelector = loadAt<void*>(image + kSelUpdateFenceAfterStages);
    void* waitSelector = loadAt<void*>(image + kSelWaitFenceBeforeStages);
    void* endSelector = loadAt<void*>(image + kSelEndEncoding);
    void* computeSelector = loadAt<void*>(image + kSelComputeCommandEncoder);
    void* tableSelector = loadAt<void*>(image + kSelSetArgumentTable);
    if (!updateSelector || !waitSelector || !endSelector || !computeSelector || !tableSelector)
        return false;

    using FenceBoundary = void (*)(void*, void*, void*, std::uint64_t);
    using MsgVoid = void (*)(void*, void*);
    using MsgObject = void* (*)(void*, void*);
    using MsgSetObject = void (*)(void*, void*, void*);
    const auto updateFence = reinterpret_cast<FenceBoundary>(updateFenceImp);
    const auto waitFence = reinterpret_cast<FenceBoundary>(waitFenceImp);
    const auto sendVoid = reinterpret_cast<MsgVoid>(objc_msgSend);
    const auto sendObject = reinterpret_cast<MsgObject>(objc_msgSend);
    const auto sendSetObject = reinterpret_cast<MsgSetObject>(objc_msgSend);

    bool encoded = false;
    void* replacement = nullptr;
    @try {
        // The native compute stream is live when opcode 0x3e is replayed. Hand
        // its writes to the exact fence, end that encoder, then let the backend
        // append MetalFX work directly to the same MTL4CommandBuffer.
        updateFence(encoder, updateSelector, fence, kComputeStage);
        sendVoid(encoder, endSelector);
        storeAt<void*>(mplReplayer, kReplayerComputeEncoder, nullptr);

        encoded = state->encode(const_cast<void*>(command), commandBuffer, fence);

        // Re-enter the ordinary MPL compute stream exactly as ComputeEncoder::
        // Begin does: create a fresh encoder, restore its shared argument table,
        // then wait on the fence MetalFX publishes before subsequent D3D work.
        replacement = sendObject(commandBuffer, computeSelector);
        if (!replacement) return false;
        storeAt<void*>(mplReplayer, kReplayerComputeEncoder, replacement);
        sendSetObject(replacement, tableSelector, argumentTable);
        waitFence(replacement, waitSelector, fence, kComputeStage);
        return encoded;
    } @catch (id) {
        // If the backend or an Objective-C boundary raised after the old encoder
        // was ended, make one best-effort attempt to restore an MPL compute
        // encoder so ReplayEncoders can continue to its range-end command.
        if (!replacement) {
            @try {
                replacement = sendObject(commandBuffer, computeSelector);
                if (replacement) {
                    storeAt<void*>(mplReplayer, kReplayerComputeEncoder, replacement);
                    sendSetObject(replacement, tableSelector, argumentTable);
                    waitFence(replacement, waitSelector, fence, kComputeStage);
                }
            } @catch (id) {
            }
        }
        return false;
    }
}

} // namespace yaagl::pso::d3dmetal
