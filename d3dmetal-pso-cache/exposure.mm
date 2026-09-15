#import "exposure.hpp"

#import <Metal/Metal.h>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace yaagl::pso::exposure {
namespace {

constexpr std::uint32_t kMissing = 0xbad00000;
constexpr std::size_t kGetFloatOffset = 0xa9a9c;
constexpr std::size_t kExtendResourceLifetimeOffset = 0x1dbf4;
constexpr std::array<std::byte, 3> kLegacyMagic{std::byte{0x59}, std::byte{0x45}, std::byte{0x58}};
using ExtendResourceLifetime = void (*)(void*, id<MTLResource>);

std::atomic<bool> gEnabled;
const std::uint8_t* gImageBase;
GetFloat gGetFloat;
ExtendResourceLifetime gExtendResourceLifetime;
thread_local float gScale = 1.0f;
thread_local bool gApplicable = false;

template<typename T>
T load(const void* base, std::size_t offset) noexcept {
    T value{};
    if (base != nullptr) std::memcpy(&value, static_cast<const std::uint8_t*>(base) + offset, sizeof(value));
    return value;
}

void store(void* base, std::size_t offset, const void* value, std::size_t size) noexcept {
    std::memcpy(static_cast<std::uint8_t*>(base) + offset, value, size);
}

id<MTLTexture> makeTexture(id<MTLTexture> reference, float scale) {
    @autoreleasepool {
        if (reference == nil || reference.device == nil) return nil;
        MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float width:1 height:1 mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [reference.device newTextureWithDescriptor:descriptor];
        if (texture == nil) return nil;
        @try {
            const _Float16 half = static_cast<_Float16>(scale);
            std::uint16_t bits;
            static_assert(sizeof(bits) == sizeof(half));
            std::memcpy(&bits, &half, sizeof(bits));
            [texture replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0
                          withBytes:&bits bytesPerRow:sizeof(bits)];
            return texture;
        } @catch (id exception) {
            [texture release];
            @throw exception;
        }
    }
}

} // namespace

void initialize(const std::uint8_t* imageBase, GetFloat getFloat) noexcept {
    const char* value = std::getenv("YAAGL_METALFX_EXPOSURE_SCALE_FIX");
    const bool enabled = value != nullptr && std::strcmp(value, "1") == 0;
    gImageBase = imageBase;
    gGetFloat = getFloat != nullptr ? getFloat :
        (imageBase != nullptr ? reinterpret_cast<GetFloat>(const_cast<std::uint8_t*>(imageBase) + kGetFloatOffset) : nullptr);
    gExtendResourceLifetime = imageBase != nullptr ?
        reinterpret_cast<ExtendResourceLifetime>(const_cast<std::uint8_t*>(imageBase) + kExtendResourceLifetimeOffset) : nullptr;
    gEnabled.store(enabled && gGetFloat != nullptr, std::memory_order_release);
}

EvaluationScope::EvaluationScope(bool hdr, bool autoExposure, bool hasExposureTexture,
                                 const void* params) noexcept
    : previousScale_(gScale), previousApplicable_(gApplicable) {
    gScale = 1.0f;
    gApplicable = false;
    if (!gEnabled.load(std::memory_order_acquire) || !hdr || autoExposure ||
        hasExposureTexture || params == nullptr) return;
    float scale = 0.0f;
    try {
        if (gGetFloat(params, "DLSS.Exposure.Scale", &scale) == kMissing) return;
    } catch (...) { return; }
    if (scale == 0.0f) scale = 1.0f;
    if (!std::isfinite(scale) || scale <= 0.0f || scale == 1.0f) return;
    const float decoded = static_cast<float>(static_cast<_Float16>(scale));
    if (!std::isfinite(decoded) || decoded <= 0.0f) return;
    gScale = decoded;
    gApplicable = true;
}

EvaluationScope::~EvaluationScope() {
    gScale = previousScale_;
    gApplicable = previousApplicable_;
}

ApplyResult recordLegacyScale(void* command) noexcept {
    if (command == nullptr) return ApplyResult::Failed;
    const std::array<std::byte, 7> clear{};
    store(command, 0x11, clear.data(), clear.size());
    if (!gApplicable) return ApplyResult::NotApplicable;
    store(command, 0x11, kLegacyMagic.data(), kLegacyMagic.size());
    store(command, 0x14, &gScale, sizeof(gScale));
    return ApplyResult::Applied;
}

LegacyEncodeScope::LegacyEncodeScope(void* encoder, const void* command) noexcept : original_(command) {
    if (!gEnabled.load(std::memory_order_acquire) || encoder == nullptr || command == nullptr ||
        gImageBase == nullptr || load<std::array<std::byte, 3>>(command, 0x11) != kLegacyMagic) return;
    const float scale = load<float>(command, 0x14);
    if (!std::isfinite(scale) || scale <= 0.0f) { result_ = ApplyResult::Failed; return; }
    std::memcpy(local_.data(), command, local_.size());
    void* reference = load<void*>(command, 0x20);
    if (reference == nullptr) reference = load<void*>(command, 0x18);
    id<MTLTexture> texture = nil;
    @try {
        texture = makeTexture((__bridge id<MTLTexture>)reference, scale);
        if (texture == nil) { result_ = ApplyResult::Failed; return; }
        // The original +0xb0 path registers this texture with encoder+0x2c0
        // and immediately releases the incoming creation reference. Transfer
        // this +1 exactly once; pre-registering would duplicate the owner entry.
        texture_ = (__bridge void*)texture;
        void* borrowed = texture_;
        store(local_.data(), 0xb0, &borrowed, sizeof(borrowed));
        const void* nullTexture = nullptr;
        store(local_.data(), 0xb8, &nullTexture, sizeof(nullTexture));
        result_ = ApplyResult::Applied;
    } @catch (id) {
        if (texture != nil && texture_ == nullptr) [texture release];
        result_ = ApplyResult::Failed;
    }
}

LegacyEncodeScope::~LegacyEncodeScope() {
    if (texture_ != nullptr && !handedOff_) [(__bridge id)texture_ release];
}

const void* LegacyEncodeScope::handoffCommand() noexcept {
    if (result_ != ApplyResult::Applied) return original_;
    handedOff_ = true;
    return local_.data();
}

ApplyResult patchMplDescriptor(void* commandList, void* descriptor) noexcept {
    if (!gApplicable) return ApplyResult::NotApplicable;
    if (commandList == nullptr || descriptor == nullptr || gExtendResourceLifetime == nullptr)
        return ApplyResult::Failed;
    if (load<void*>(descriptor, 0x20) != nullptr) return ApplyResult::NotApplicable;
    @try {
        id<MTLTexture> texture = makeTexture((__bridge id<MTLTexture>)load<void*>(descriptor, 0), gScale);
        if (texture == nil) return ApplyResult::Failed;
        void* allocator = load<void*>(commandList, 0x10);
        if (allocator == nullptr) { [texture release]; return ApplyResult::Failed; }
        try { gExtendResourceLifetime(allocator, texture); }
        catch (...) { [texture release]; return ApplyResult::Failed; }
        void* raw = (__bridge void*)texture;
        store(descriptor, 0x20, &raw, sizeof(raw));
        return ApplyResult::Applied;
    } @catch (id) { return ApplyResult::Failed; }
}

} // namespace yaagl::pso::exposure
