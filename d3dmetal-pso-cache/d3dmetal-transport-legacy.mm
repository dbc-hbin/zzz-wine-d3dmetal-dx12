#import "d3dmetal-transport-legacy.hpp"

#import "metalfx-backend.hpp"
#import "fsr-framegeneration.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/message.h>

#include <array>
#include <atomic>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <string_view>
#include <vector>

namespace yaagl::pso::d3dmetal::legacy {
namespace {

constexpr std::size_t kMaxResources = 8;
constexpr std::uint64_t kNativeHeader = 0x24060000000000e0ULL;
constexpr std::uint64_t kMagic = 0x59474c4c44534c32ULL; // "YGLLDSL2"
constexpr std::uint64_t kCookie = 0x9ac7e125d155c2b3ULL;

constexpr std::uintptr_t kGetInternalResource = 0x411ae;
constexpr std::uintptr_t kGetMetalTexture = 0x4128c;
constexpr std::uintptr_t kReserveTemporalRecord = 0x103938;
constexpr std::uintptr_t kRetainResource = 0xe1d76;
constexpr std::uintptr_t kInsertSync = 0x179214;
constexpr std::uintptr_t kGetFence = 0x179d70;
constexpr std::uintptr_t kGetExternalCommandBuffer = 0x1815d2;
constexpr std::uintptr_t kGetBlitEncoder = 0x174b18;
constexpr std::uintptr_t kFlushEncoders = 0x174f1c;

constexpr std::uintptr_t kLegacyListVtable = 0x4b16c0;
// DX12 embeds the allocator base inside D3D12CommandAllocator. Its final
// address point is the derived-class table, not a standalone base allocator.
constexpr std::uintptr_t kLegacyAllocatorVtable = 0x4b82b0;
constexpr std::uintptr_t kWaitForFenceSelector = 0x4c6e78;
constexpr std::uintptr_t kUpdateFenceSelector = 0x4c6e90;

constexpr std::size_t kWrapperList = 0x80;
constexpr std::size_t kListDevice = 0x8;
constexpr std::size_t kListAllocator = 0x18;
constexpr std::size_t kD3DMDeviceMetalDevice = 0x40;

struct RecordedCommand {
    std::uint64_t header = kNativeHeader;
    std::uint64_t magic = kMagic;
    void* owner = nullptr;
    std::uint64_t cookie = 0;
    std::array<std::uint8_t, 0xc0> reserved{};
};
static_assert(sizeof(RecordedCommand) == 0xe0);

struct Runtime {
    const std::uint8_t* image = nullptr;
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
        if (hi < 0 || lo < 0 || actual[i] != static_cast<std::uint8_t>((hi << 4) | lo)) {
            std::fprintf(stderr, "yaagl metalfx legacy transport ABI pin mismatch at +0x%lx\n",
                         static_cast<unsigned long>(offset));
            return false;
        }
    }
    return true;
}

bool verifyImage(const std::uint8_t* image) noexcept {
    // D3D12GraphicsCommandListMTL owns D3DMCommandListMTL at +0x80; that list
    // owns D3DMDevice/+0x8 and D3DMCommandAllocator/+0x18.
    if (!pinHex(image, 0xf982c, "4d89ae80000000")) return false;
    if (!pinHex(image, 0x50c51,
                "4889530848b800000000010000004885d2740d488b3a488b7fe8f04801443a10"))
        return false;
    if (!pinHex(image, 0x50c71,
                "894b104c8943184d85c0740d498b08488b49e8f04901440810")) return false;
    if (!pinHex(image, 0x16abc6,
                "488d0d6329350048890f488d0da929350048898f8800000048897708")) return false;
    if (!pinHex(image, 0x104ee9, "488d05c0333b0049894668")) return false;

    // The native temporal reservation helper is transport-only here: it
    // reserves 0xe0 bytes, emits opcode 0x24/flags 0x06 and updates legacy
    // command-category offsets. No frontend parameter parsing or factory is entered.
    if (!pinHex(image, kReserveTemporalRecord,
                "534889fb488b4f70488b5110488b411848f7da4801c24881c2e0000000483b5128"))
        return false;
    if (!pinHex(image, 0x10395b,
                "48bae000000000000624488910488d90e000000048895118808bf800000006c6435001"))
        return false;

    // D3DMCommandAllocator's intrusive resource owner is the legacy analogue
    // of MPL ExtendResourceLifetime: +0x10 += 1 strong ref and vector push;
    // Reset/ReleaseResources subtracts it and calls vtable slot 1 at zero.
    if (!pinHex(image, kRetainResource,
                "4157415641554154534989f648b80000000001000000f0480146104889fb"))
        return false;
    if (!pinHex(image, 0x16aa0e,
                "41574156415453504889fb4c8b77304c8b7f384d39fe743249bc0000000001000000"))
        return false;
    if (!pinHex(image, 0x16aa30,
                "498b3ef04c2967100f95c04885ff0f94c108c17506488b07ff5008")) return false;

    // GetDesc receives the external ID3D12Resource interface at texture+0x10;
    // its +0x18 source therefore means INTERNAL texture+0x28, not +0x18.
    // Verify both the external interface installation and the constructor's
    // actual descriptor copies. Format is internal+0x48; flags are +0x58.
    if (!pinHex(image, 0x14eba0, "48895708488b159d293a0048895710")) return false;
    if (!pinHex(image, 0x14ebff,
                "410f1000410f104810410f105020410f114728410f114f38410f115748498b503049895758"))
        return false;
    if (!pinHex(image, kGetInternalResource,
                "415653504889fb4885f6747d48c7042400000000488b7ef8")) return false;
    if (!pinHex(image, 0x41203,
                "4885ff743b48c704240000000048b80100000001000000f0482987d0010000"))
        return false;
    if (!pinHex(image, kGetMetalTexture,
                "415653504885ff7444488b87c80000004881c7c8000000ff5020")) return false;
    if (!pinHex(image, 0x1505cc,
                "488b070f1040180f1048280f1050380f1147080f114f180f115728488b4048"))
        return false;

    // Native MTL3 temporal replay establishes exactly this boundary: sync,
    // all-encoder flush -> external MTLCommandBuffer, shared fence, scaler
    // encode, new compute encoder waits on fence, sync again.
    if (!pinHex(image, kInsertSync,
                "415653504889fb8bb700010000e8f6bcffff4889dfe832e5ffff4989c648"))
        return false;
    if (!pinHex(image, kGetFence,
                "4157415641554154534889fb4c8ba7d80600004c39a7d0060000")) return false;
    if (!pinHex(image, kGetExternalCommandBuffer,
                "534889fbbe0f000000e83c39ffff4889df31f631d231c941b801000000"))
        return false;
    if (!pinHex(image, kGetBlitEncoder,
                "554157415641554154534883ec284989d64989f74889fbbe0b000000")) return false;
    if (!pinHex(image, kFlushEncoders,
                "55535089f54889fb23af0001000083fd017524")) return false;
    if (!pinHex(image, 0x12fb7e, "e891960400")) return false;
    if (!pinHex(image, 0x12ffc7, "4c89e7be0f000000e8484f04004c89e7e8949d0400")) return false;
    if (!pinHex(image, 0x1303fe,
                "4d8dafc80000004c89f7e8c5110500498b7f08488b35")) return false;
    if (!pinHex(image, 0x13041e,
                "498b064c89f731f631d2ff5020488b35")) return false;
    if (!pinHex(image, 0x130491, "4c89f7e87b8d0400")) return false;

    const char* waitForFence = loadAt<const char*>(image + kWaitForFenceSelector);
    const char* updateFence = loadAt<const char*>(image + kUpdateFenceSelector);
    return waitForFence && std::strcmp(waitForFence, "waitForFence:") == 0 &&
        updateFence && std::strcmp(updateFence, "updateFence:") == 0;
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

void releaseInternalTexture(void* texture) noexcept {
    if (!texture) return;
    auto* refs = reinterpret_cast<std::uint64_t*>(static_cast<std::uint8_t*>(texture) + 0x1d0);
    const std::uint64_t remaining = __atomic_sub_fetch(refs, 0x100000001ULL, __ATOMIC_SEQ_CST);
    if (remaining != 0) return;
    void* embedded = static_cast<std::uint8_t*>(texture) + 0x1c0;
    void** vtable = loadAt<void**>(embedded);
    if (vtable && vtable[1])
        reinterpret_cast<void (*)(void*)>(vtable[1])(embedded);
}

struct State {
    PreparedWork prepared;
    std::shared_ptr<ExecutionLeaseStore> leases = std::make_shared<ExecutionLeaseStore>();
    std::mutex leaseLock;
    std::array<id, kMaxResources> textures{};
    std::size_t textureCount = 0;
    std::uint64_t featureID = 0;
    std::uint64_t evaluationID = 0;

    State(const RecordRequest& request)
        : prepared(request.prepared), featureID(request.featureID), evaluationID(request.evaluationID) {
        if (!request.resources) return;
        for (std::size_t i = 0; i < request.resourceCount && i < kMaxResources; ++i) {
            const MetalResource* resource = request.resources[i].resource;
            if (!resource || !resource->texture) continue;
            id texture = reinterpret_cast<id>(resource->texture);
            bool duplicate = false;
            for (std::size_t j = 0; j < textureCount; ++j)
                duplicate |= textures[j] == texture;
            if (!duplicate) textures[textureCount++] = [texture retain];
        }
    }

    ~State() {
        for (std::size_t i = 0; i < textureCount; ++i) [textures[i] release];
    }

    bool encode(void* command, void* commandBuffer, void* fence) noexcept {
        metalfx::Error error{};
        bool encoded = false;
        try {
            std::lock_guard<std::mutex> lock(leaseLock);
            const metalfx::EncodeIdentity identity{featureID, evaluationID, command};
            std::shared_ptr<ExecutionSlot> slot;
            encoded = std::visit([&](const auto& frame) -> bool {
                using T = std::decay_t<decltype(frame)>;
                if constexpr (std::is_same_v<T, std::monostate>) return false;
                else {
                    using Lease = std::conditional_t<
                        std::is_same_v<T, std::shared_ptr<const metalfx::PreparedFrame>>,
                        std::shared_ptr<const metalfx::ExecutionLease>,
                        std::shared_ptr<const fsr::framegeneration::ExecutionLease>>;
                    slot = std::make_shared<ExecutionSlot>(Lease{}, commandBuffer, leases);
                    leases->retain(slot);
                    // This Objective-C block outlives the visitor; capture an owning local.
                    const auto completionSlot = slot;
                    @try {
                        [reinterpret_cast<id<MTLCommandBuffer>>(commandBuffer)
                            addCompletedHandler:^(id<MTLCommandBuffer>) { completionSlot->retire(); }];
                    } @catch (id) {
                        // The native allocator retains the slot when no handler is installed.
                    }
                    std::lock_guard<std::mutex> slotLock(slot->mutex);
                    Lease& lease = std::get<Lease>(slot->lease);
                    if constexpr (std::is_same_v<T, std::shared_ptr<const metalfx::PreparedFrame>>)
                        return frame && frame->encode(commandBuffer, fence, lease, &error, &identity);
                    else
                        return frame && frame->encode(commandBuffer, fence, lease);
                }
            }, prepared.value);
            if (!slot) return false;
            std::lock_guard<std::mutex> slotLock(slot->mutex);
            if (!std::visit(
                    [](const auto& lease) { return static_cast<bool>(lease); }, slot->lease))
                return false;
        } catch (...) {
            return false;
        }
        return encoded;
    }
};

struct LegacyOwner {
    void** vtable = nullptr;
    std::uint64_t reserved = 0;
    std::uint64_t nativeRefs = 0;
    State state;

    explicit LegacyOwner(const RecordRequest& request) : vtable(ownerVtable()), state(request) {}

    static void destroy(void* pointer) noexcept {
        delete static_cast<LegacyOwner*>(pointer);
    }

    static void** ownerVtable() noexcept {
        static void* table[2] = {nullptr, reinterpret_cast<void*>(&destroy)};
        return table;
    }
};
static_assert(offsetof(LegacyOwner, nativeRefs) == 0x10);

} // namespace

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
    gReady.store(true, std::memory_order_release);
    return true;
}

bool available() noexcept {
    return ensureInitialized();
}

bool resolveCommandList(NativeCommandList& commandList) noexcept {
    if (!ensureInitialized() || commandList.kind != CommandListKind::legacy || !commandList.wrapper)
        return false;
    const std::uint8_t* image = gRuntime.image;
    void* list = loadAt<void*>(commandList.wrapper, kWrapperList);
    void* allocator = loadAt<void*>(list, kListAllocator);
    void* d3dmDevice = loadAt<void*>(list, kListDevice);
    void* metalDevice = loadAt<void*>(d3dmDevice, kD3DMDeviceMetalDevice);
    if (!list || !allocator || !d3dmDevice || !metalDevice ||
        loadAt<void*>(list) != image + kLegacyListVtable ||
        loadAt<void*>(allocator) != image + kLegacyAllocatorVtable)
        return false;
    commandList.list = list;
    commandList.allocator = allocator;
    commandList.device = metalDevice;
    commandList.compiler = nullptr;
    return true;
}

bool queryResourceMetadata(void* d3d12Resource, ResourceMetadata& out) noexcept {
    out = {};
    if (!d3d12Resource || !ensureInitialized()) return false;
    void* internal = nullptr;
    @try {
        using GetInternal = void (*)(void**, void*);
        reinterpret_cast<GetInternal>(const_cast<std::uint8_t*>(gRuntime.image) + kGetInternalResource)(
            &internal, d3d12Resource);
        if (!internal) return false;
        out.dxgiFormat = loadAt<std::uint32_t>(internal, 0x48);
        out.resourceFlags = loadAt<std::uint32_t>(internal, 0x58);
        releaseInternalTexture(internal);
        return true;
    } @catch (id) {
        if (internal) releaseInternalTexture(internal);
        return false;
    }
}

bool record(NativeCommandList& commandList, const RecordRequest& request) noexcept {
    if (!ensureInitialized() || commandList.kind != CommandListKind::legacy ||
        !commandList.list || !commandList.allocator || !request.prepared ||
        std::visit([](const auto& frame) {
            using T = std::decay_t<decltype(frame)>;
            if constexpr (std::is_same_v<T, std::monostate>) return true;
            else return !frame || frame->mode() != metalfx::CommandMode::Legacy;
        }, request.prepared.value) ||
        request.resourceCount > kMaxResources || (request.resourceCount && !request.resources))
        return false;

    const std::uint8_t* image = gRuntime.image;
    if (loadAt<void*>(commandList.list) != image + kLegacyListVtable ||
        loadAt<void*>(commandList.allocator) != image + kLegacyAllocatorVtable)
        return false;

    LegacyOwner* owner = nullptr;
    try {
        owner = new LegacyOwner(request);
    } catch (...) {
        return false;
    }

    using RetainResource = void (*)(void*, const void*);
    try {
        reinterpret_cast<RetainResource>(const_cast<std::uint8_t*>(image) + kRetainResource)(
            commandList.allocator, owner);
    } catch (...) {
        // Pointer insertion is the only throwing operation in RetainResource;
        // std::vector preserves its old state when that allocation fails.
        // Undo the pre-incremented fake D3DMUnknown ref and destroy locally.
        owner->nativeRefs = 0;
        delete owner;
        return false;
    }

    try {
        using ReserveTemporalRecord = void* (*)(void*);
        void* slot = reinterpret_cast<ReserveTemporalRecord>(
            const_cast<std::uint8_t*>(image) + kReserveTemporalRecord)(commandList.list);
        if (!slot || loadAt<std::uint64_t>(slot) != kNativeHeader) return false;

        RecordedCommand command{};
        command.owner = owner;
        command.cookie = kCookie ^ static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(owner));
        std::memcpy(slot, &command, sizeof(command));
        return true;
    } catch (...) {
        // Once RetainResource succeeds the native command allocator owns this
        // object, even when the subsequent reservation fails. It will release
        // the owner at Reset; deleting it here would create a double free.
        return false;
    }
}

bool isRecordedCommand(const void* command) noexcept {
    if (!command || loadAt<std::uint64_t>(command) != kNativeHeader) return false;
    const RecordedCommand value = loadAt<RecordedCommand>(command);
    if (value.magic != kMagic || !value.owner)
        return false;
    const auto ownerBits = static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(value.owner));
    if (value.cookie != (kCookie ^ ownerBits)) return false;
    for (std::uint8_t byte : value.reserved)
        if (byte != 0) return false;
    return true;
}

bool replay(void* d3dmCommandEncoder, const void* command) noexcept {
    if (!d3dmCommandEncoder || !isRecordedCommand(command) || !ensureInitialized()) return false;
    const RecordedCommand value = loadAt<RecordedCommand>(command);
    auto* owner = static_cast<LegacyOwner*>(value.owner);
    const std::uint8_t* image = gRuntime.image;

    using EncoderVoid = void (*)(void*);
    using EncoderObject = void* (*)(void*);
    using FlushEncoders = void (*)(void*, std::uint32_t);
    using GetBlit = void* (*)(void*, const void*, std::size_t);
    const auto insertSync = reinterpret_cast<EncoderVoid>(
        const_cast<std::uint8_t*>(image) + kInsertSync);
    const auto getFence = reinterpret_cast<EncoderObject>(
        const_cast<std::uint8_t*>(image) + kGetFence);
    const auto getExternalCommandBuffer = reinterpret_cast<EncoderObject>(
        const_cast<std::uint8_t*>(image) + kGetExternalCommandBuffer);
    const auto flushEncoders = reinterpret_cast<FlushEncoders>(
        const_cast<std::uint8_t*>(image) + kFlushEncoders);
    const auto getBlit = reinterpret_cast<GetBlit>(
        const_cast<std::uint8_t*>(image) + kGetBlitEncoder);
    void* waitSelector = loadAt<void*>(image + kWaitForFenceSelector);
    void* updateSelector = loadAt<void*>(image + kUpdateFenceSelector);
    if (!waitSelector || !updateSelector) return false;

    bool encoded = false;
    @try {
        // Match D3DMetal's native MTL3 temporal boundary. InsertSync preserves
        // explicit D3D12 barrier ordering; GetExternalCommandBuffer flushes all
        // native encoders before direct MetalFX work is appended.
        insertSync(d3dmCommandEncoder);
        flushEncoders(d3dmCommandEncoder, 0xfu);
        void* fence = getFence(d3dmCommandEncoder);
        if (!fence) return false;

        // Native legacy TemporalScale publishes all prior D3D work through a
        // blit encoder to the scaler fence before its direct MetalFX encode.
        void* preScaleBlit = getBlit(d3dmCommandEncoder, nullptr, 0);
        if (!preScaleBlit) return false;
        using FenceMessage = void (*)(void*, void*, void*);
        reinterpret_cast<FenceMessage>(objc_msgSend)(preScaleBlit, updateSelector, fence);
        flushEncoders(d3dmCommandEncoder, 4u);

        void* commandBuffer = getExternalCommandBuffer(d3dmCommandEncoder);
        if (!commandBuffer) return false;

        encoded = owner->state.encode(const_cast<void*>(command), commandBuffer, fence);

        // Re-enter D3DMetal through its ordinary blit encoder creation path,
        // then wait on the same fence the scaler was given. This is the exact
        // post-MetalFX handoff used by native EncodeTemporallyScaleMTLFX.
        void* postScaleBlit = getBlit(d3dmCommandEncoder, nullptr, 0);
        if (!postScaleBlit) return false;
        reinterpret_cast<FenceMessage>(objc_msgSend)(postScaleBlit, waitSelector, fence);
        insertSync(d3dmCommandEncoder);
        return encoded;
    } @catch (id) {
        return false;
    }
}

} // namespace yaagl::pso::d3dmetal::legacy
