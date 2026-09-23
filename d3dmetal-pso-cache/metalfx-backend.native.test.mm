#import "metalfx-backend.hpp"
#import "metalfx-contract.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

using namespace yaagl::pso::metalfx;

namespace {

constexpr NSUInteger kContent = 64;
constexpr NSUInteger kOutput = 128;
constexpr NSUInteger kOutputBacking = 140;
constexpr NSUInteger kColorX = 8;
constexpr NSUInteger kColorY = 7;
constexpr NSUInteger kOutputX = 6;
constexpr NSUInteger kOutputY = 5;
constexpr unsigned kSequenceFrames = 3;
constexpr std::array<unsigned char, 4> kSentinel = {13, 29, 47, 61};

void require(bool ok, const char* message) {
    if (ok) return;
    std::fprintf(stderr, "FAIL %s\n", message);
    std::exit(1);
}

bool closeFloat(float a, float b, float epsilon = 0.0005f) {
    return std::fabs(a - b) <= epsilon;
}

EncodeIdentity gExpectedObservationIdentity{};
unsigned gObservationBegins = 0, gObservationEnds = 0, gObservationRejected = 0;
bool gObservationActive = false, gRejectNextObservation = false;
struct ObservedInputState { void* scaler; std::uint32_t width; std::uint32_t height; };
std::array<ObservedInputState, 64> gObservedInputs{};
std::size_t gObservedInputCount = 0;
int gObservationToken = 0;

void* observeEncodeBegin(const EncodeObservation& observation) noexcept {
    ++gObservationBegins;
    require(!gObservationActive, "observation begin is not duplicated or reentrant");
    require(observation.prepared && observation.create && observation.frame &&
            observation.scaler && observation.commandBuffer && observation.fence,
            "observer receives typed immutable metadata and actual encode objects");
    require(observation.featureID == gExpectedObservationIdentity.featureID &&
            observation.evaluationID == gExpectedObservationIdentity.evaluationID &&
            observation.recordedCommand == gExpectedObservationIdentity.recordedCommand,
            "immutable transport identity reaches observer unchanged");
    id<MTLFXTemporalScalerBase> scaler =
        reinterpret_cast<id<MTLFXTemporalScalerBase>>(observation.scaler);
    require(observation.callerTextures.output == observation.frame->output,
            "observer receives the original caller output");
    require(scaler.inputContentWidth == observation.frame->inputContent.width &&
            closeFloat(scaler.jitterOffsetX, observation.frame->jitterOffsetX.value) &&
            closeFloat(scaler.preExposure, observation.frame->preExposure.value),
            "observer begins after public scaler values have been configured");
    bool inputExtentChanged = false;
    ObservedInputState* priorInput = nullptr;
    for (std::size_t i = 0; i < gObservedInputCount; ++i) {
        if (gObservedInputs[i].scaler == observation.scaler) {
            priorInput = &gObservedInputs[i];
            inputExtentChanged = priorInput->width != observation.frame->inputContent.width ||
                                 priorInput->height != observation.frame->inputContent.height;
            break;
        }
    }
    const bool expectedReset = observation.frame->resetHistory.value ||
                               !observation.generationInitialized || inputExtentChanged;
    require(observation.effectiveReset == expectedReset &&
            static_cast<bool>(scaler.reset) == observation.effectiveReset,
            "observer reports caller, fresh-generation, and input-size reset");
    if (priorInput) {
        priorInput->width = observation.frame->inputContent.width;
        priorInput->height = observation.frame->inputContent.height;
    } else {
        require(gObservedInputCount < gObservedInputs.size(), "observer input-state capacity");
        gObservedInputs[gObservedInputCount++] = {observation.scaler,
            observation.frame->inputContent.width, observation.frame->inputContent.height};
    }
    if (gRejectNextObservation) {
        gRejectNextObservation = false;
        ++gObservationRejected;
        return nullptr; // Declining diagnostics must not fail GPU rendering.
    }
    gObservationActive = true;
    return &gObservationToken;
}

void observeEncodeEnd(void* token, bool normal) noexcept {
    require(token == &gObservationToken && gObservationActive,
            "accepted observation has exactly one paired end");
    require(normal, "successful backend encode reports completed CPU encoding");
    gObservationActive = false;
    ++gObservationEnds;
}

const EncodeObserver gTestEncodeObserver{&observeEncodeBegin, &observeEncodeEnd};

EncodeIdentity nextObservationIdentity() {
    gExpectedObservationIdentity = {17, gExpectedObservationIdentity.evaluationID + 1,
                                    &gExpectedObservationIdentity};
    return gExpectedObservationIdentity;
}

struct FactoryCapture {
    id scaler = nil;
    bool metal4 = false;
    NSUInteger inputWidth = 0;
    NSUInteger inputHeight = 0;
    NSUInteger outputWidth = 0;
    NSUInteger outputHeight = 0;
    bool synchronous = false;
    bool dynamicContent = false;
    bool autoExposure = false;
    bool outputMotion = false;
    bool jitteredMotion = false;
};

std::mutex gCaptureMutex;
std::vector<FactoryCapture> gCaptures;

using LegacyFactory = id (*)(id, SEL, id);
using Metal4Factory = id (*)(id, SEL, id, id);
LegacyFactory gLegacyFactory = nullptr;
Metal4Factory gMetal4Factory = nullptr;

using BoolSetter = void (*)(id, SEL, BOOL);
std::mutex gSetterMutex;
std::unordered_map<Class, BoolSetter> gResetSetters;
std::unordered_map<Class, BoolSetter> gDepthSetters;
char gObservedResetKey;
char gObservedDepthKey;

void observedSetReset(id object, SEL selector, BOOL value) {
    objc_setAssociatedObject(object, &gObservedResetKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BoolSetter original = nullptr;
    {
        std::lock_guard<std::mutex> lock(gSetterMutex);
        const auto found = gResetSetters.find(object_getClass(object));
        if (found != gResetSetters.end()) original = found->second;
    }
    require(original != nullptr, "reset observer original setter");
    original(object, selector, value);
}

void observedSetDepth(id object, SEL selector, BOOL value) {
    objc_setAssociatedObject(object, &gObservedDepthKey, @(value), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BoolSetter original = nullptr;
    {
        std::lock_guard<std::mutex> lock(gSetterMutex);
        const auto found = gDepthSetters.find(object_getClass(object));
        if (found != gDepthSetters.end()) original = found->second;
    }
    require(original != nullptr, "depth observer original setter");
    original(object, selector, value);
}

void installBoolSetterObserver(id object, const char* selectorName,
                               IMP replacement,
                               std::unordered_map<Class, BoolSetter>& originals) {
    Class cls = object_getClass(object);
    std::lock_guard<std::mutex> lock(gSetterMutex);
    if (originals.find(cls) != originals.end()) return;
    SEL selector = sel_registerName(selectorName);
    Method method = class_getInstanceMethod(cls, selector);
    require(method != nullptr, "public scaler bool setter");
    IMP originalIMP = method_getImplementation(method);
    BoolSetter original = nullptr;
    std::memcpy(&original, &originalIMP, sizeof(original));
    originals.emplace(cls, original);
    const char* types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, selector, replacement, types))
        class_replaceMethod(cls, selector, replacement, types);
}

void installScalerObservers(id scaler) {
    installBoolSetterObserver(scaler, "setReset:", reinterpret_cast<IMP>(&observedSetReset),
                              gResetSetters);
    installBoolSetterObserver(scaler, "setDepthReversed:", reinterpret_cast<IMP>(&observedSetDepth),
                              gDepthSetters);
}

bool observedBool(id scaler, const void* key, bool& value) {
    NSNumber* number = reinterpret_cast<NSNumber*>(objc_getAssociatedObject(scaler, key));
    if (!number) return false;
    value = number.boolValue;
    return true;
}

FactoryCapture snapshotDescriptor(MTLFXTemporalScalerDescriptor* descriptor,
                                  id scaler, bool metal4) {
    FactoryCapture capture{};
    capture.scaler = scaler ? [scaler retain] : nil;
    capture.metal4 = metal4;
    capture.inputWidth = descriptor.inputWidth;
    capture.inputHeight = descriptor.inputHeight;
    capture.outputWidth = descriptor.outputWidth;
    capture.outputHeight = descriptor.outputHeight;
    capture.synchronous = descriptor.requiresSynchronousInitialization;
    capture.dynamicContent = descriptor.inputContentPropertiesEnabled;
    capture.autoExposure = descriptor.autoExposureEnabled;
    if (@available(macOS 27.0, *)) {
        capture.outputMotion = descriptor.outputResolutionMotionVectorsEnabled;
        capture.jitteredMotion = descriptor.jitteredMotionVectorsEnabled;
    }
    return capture;
}

void storeCapture(MTLFXTemporalScalerDescriptor* descriptor, id scaler, bool metal4) {
    FactoryCapture capture = snapshotDescriptor(descriptor, scaler, metal4);
    std::lock_guard<std::mutex> lock(gCaptureMutex);
    gCaptures.push_back(capture);
}

std::size_t captureCount() {
    std::lock_guard<std::mutex> lock(gCaptureMutex);
    return gCaptures.size();
}

FactoryCapture captureAt(std::size_t index) {
    std::lock_guard<std::mutex> lock(gCaptureMutex);
    require(index < gCaptures.size(), "factory capture index");
    return gCaptures[index];
}

void installFactoryCapture() {
    Class cls = objc_getClass("MTLFXTemporalScalerDescriptor");
    require(cls != Nil, "MTLFXTemporalScalerDescriptor runtime class");

    SEL legacySelector = sel_registerName("newTemporalScalerWithDevice:");
    Method legacyMethod = class_getInstanceMethod(cls, legacySelector);
    require(legacyMethod != nullptr, "legacy MetalFX factory method");
    IMP legacyIMP = method_getImplementation(legacyMethod);
    std::memcpy(&gLegacyFactory, &legacyIMP, sizeof(gLegacyFactory));
    require(gLegacyFactory != nullptr, "legacy MetalFX factory IMP");
    IMP legacyReplacement = imp_implementationWithBlock(^id(
        MTLFXTemporalScalerDescriptor* descriptor, id device) {
        id scaler = gLegacyFactory(descriptor, legacySelector, device);
        storeCapture(descriptor, scaler, false);
        return scaler;
    });
    method_setImplementation(legacyMethod, legacyReplacement);

    if (@available(macOS 26.0, *)) {
        SEL metal4Selector = sel_registerName("newTemporalScalerWithDevice:compiler:");
        Method metal4Method = class_getInstanceMethod(cls, metal4Selector);
        require(metal4Method != nullptr, "Metal4FX factory method");
        IMP metal4IMP = method_getImplementation(metal4Method);
        std::memcpy(&gMetal4Factory, &metal4IMP, sizeof(gMetal4Factory));
        require(gMetal4Factory != nullptr, "Metal4FX factory IMP");
        IMP metal4Replacement = imp_implementationWithBlock(^id(
            MTLFXTemporalScalerDescriptor* descriptor, id device, id compiler) {
            id scaler = gMetal4Factory(descriptor, metal4Selector, device, compiler);
            storeCapture(descriptor, scaler, true);
            return scaler;
        });
        method_setImplementation(metal4Method, metal4Replacement);
    }
}

id<MTLTexture> makeTexture(id<MTLDevice> device, MTLPixelFormat format,
                           NSUInteger width, NSUInteger height,
                           MTLStorageMode storage, MTLTextureUsage usage) {
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.storageMode = storage;
    descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
    descriptor.usage = usage;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    require(texture != nil, "texture creation");
    return texture;
}

void completeLegacy(id<MTLCommandBuffer> command, const char* message) {
    [command commit];
    [command waitUntilCompleted];
    if (command.error) NSLog(@"legacy GPU error: %@", command.error);
    require(command.status == MTLCommandBufferStatusCompleted && command.error == nil, message);
}

void writeRGBA8(id<MTLDevice> device, id<MTLCommandQueue> transfer,
                id<MTLTexture> texture, const std::vector<unsigned char>& bytes) {
    const NSUInteger width = texture.width;
    const NSUInteger height = texture.height;
    require(bytes.size() == width * height * 4, "RGBA write byte count");
    if (texture.storageMode == MTLStorageModeShared) {
        [texture replaceRegion:MTLRegionMake2D(0, 0, width, height)
                   mipmapLevel:0
                     withBytes:bytes.data()
                   bytesPerRow:width * 4];
        return;
    }
    id<MTLBuffer> staging =
        [device newBufferWithBytes:bytes.data()
                           length:bytes.size()
                          options:MTLResourceStorageModeShared];
    require(staging != nil, "RGBA staging buffer");
    id<MTLCommandBuffer> command = [transfer commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    [encoder copyFromBuffer:staging
               sourceOffset:0
          sourceBytesPerRow:width * 4
        sourceBytesPerImage:bytes.size()
                 sourceSize:MTLSizeMake(width, height, 1)
                  toTexture:texture
           destinationSlice:0
           destinationLevel:0
          destinationOrigin:MTLOriginMake(0, 0, 0)];
    [encoder endEncoding];
    completeLegacy(command, "RGBA private upload");
    [staging release];
}

std::vector<unsigned char> readRGBA8(id<MTLDevice> device,
                                     id<MTLCommandQueue> transfer,
                                     id<MTLTexture> texture) {
    const NSUInteger width = texture.width;
    const NSUInteger height = texture.height;
    std::vector<unsigned char> bytes(width * height * 4);
    if (texture.storageMode == MTLStorageModeShared) {
        [texture getBytes:bytes.data()
              bytesPerRow:width * 4
               fromRegion:MTLRegionMake2D(0, 0, width, height)
              mipmapLevel:0];
        return bytes;
    }
    id<MTLBuffer> staging =
        [device newBufferWithLength:bytes.size() options:MTLResourceStorageModeShared];
    require(staging != nil, "RGBA readback buffer");
    id<MTLCommandBuffer> command = [transfer commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    [encoder copyFromTexture:texture
                 sourceSlice:0
                 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(width, height, 1)
                    toBuffer:staging
           destinationOffset:0
      destinationBytesPerRow:width * 4
    destinationBytesPerImage:bytes.size()];
    [encoder endEncoding];
    completeLegacy(command, "RGBA private readback");
    std::memcpy(bytes.data(), staging.contents, bytes.size());
    [staging release];
    return bytes;
}

std::vector<unsigned char> readTextureBytes(id<MTLDevice> device,
                                           id<MTLCommandQueue> transfer,
                                           id<MTLTexture> texture,
                                           NSUInteger bytesPerPixel) {
    const NSUInteger width = texture.width;
    const NSUInteger height = texture.height;
    const NSUInteger rowBytes = width * bytesPerPixel;
    std::vector<unsigned char> bytes(rowBytes * height);
    if (texture.storageMode == MTLStorageModeShared) {
        [texture getBytes:bytes.data() bytesPerRow:rowBytes
               fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        return bytes;
    }
    id<MTLBuffer> staging =
        [device newBufferWithLength:bytes.size() options:MTLResourceStorageModeShared];
    require(staging != nil, "texture byte readback buffer");
    id<MTLCommandBuffer> command = [transfer commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(width, height, 1)
                    toBuffer:staging destinationOffset:0
      destinationBytesPerRow:rowBytes destinationBytesPerImage:bytes.size()];
    [encoder endEncoding];
    completeLegacy(command, "texture byte readback");
    std::memcpy(bytes.data(), staging.contents, bytes.size());
    [staging release];
    return bytes;
}

float readR16(id<MTLDevice> device, id<MTLCommandQueue> transfer, id<MTLTexture> texture) {
    require(texture && texture.pixelFormat == MTLPixelFormatR16Float &&
            texture.width == 1 && texture.height == 1, "converted R16 exposure texture shape");
    constexpr NSUInteger rowBytes = 256;
    id<MTLBuffer> staging =
        [device newBufferWithLength:rowBytes options:MTLResourceStorageModeShared];
    require(staging != nil, "R16 readback buffer");
    id<MTLCommandBuffer> command = [transfer commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    [encoder copyFromTexture:texture
                 sourceSlice:0
                 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(1, 1, 1)
                    toBuffer:staging
           destinationOffset:0
      destinationBytesPerRow:rowBytes
    destinationBytesPerImage:rowBytes];
    [encoder endEncoding];
    completeLegacy(command, "R16 exposure readback");
    const _Float16 value = *static_cast<const _Float16*>(staging.contents);
    [staging release];
    return static_cast<float>(value);
}

std::uint64_t hashBytes(const std::vector<unsigned char>& bytes) {
    std::uint64_t hash = 1469598103934665603ull;
    for (unsigned char byte : bytes) {
        hash ^= byte;
        hash *= 1099511628211ull;
    }
    return hash;
}

void verifyOutputSentinel(const std::vector<unsigned char>& bytes,
                          NSUInteger width, NSUInteger height) {
    require(bytes.size() == width * height * 4, "output byte shape");
    std::size_t changedInside = 0;
    for (NSUInteger y = 0; y < height; ++y) {
        for (NSUInteger x = 0; x < width; ++x) {
            const bool inside = x >= kOutputX && x < kOutputX + kOutput &&
                                y >= kOutputY && y < kOutputY + kOutput;
            const std::size_t offset = (y * width + x) * 4;
            const bool sentinel =
                bytes[offset + 0] == kSentinel[0] && bytes[offset + 1] == kSentinel[1] &&
                bytes[offset + 2] == kSentinel[2] && bytes[offset + 3] == kSentinel[3];
            if (!inside) require(sentinel, "pixels outside output subrect remain sentinel");
            if (inside && !sentinel) ++changedInside;
        }
    }
    require(changedInside > kOutput * kOutput / 2, "MetalFX changed the requested output subrect");
}

std::vector<unsigned char> sentinelBytes() {
    std::vector<unsigned char> bytes(kOutputBacking * kOutputBacking * 4);
    for (std::size_t i = 0; i < bytes.size(); i += 4) {
        std::copy(kSentinel.begin(), kSentinel.end(), bytes.begin() + i);
    }
    return bytes;
}

struct Resources {
    id<MTLTexture> color = nil;
    id<MTLTexture> depth = nil;
    id<MTLTexture> motion = nil;
    id<MTLTexture> output = nil;
    id<MTLTexture> exposure = nil;
    NSUInteger capacity = 0;

    Resources() = default;
    Resources(const Resources&) = delete;
    Resources& operator=(const Resources&) = delete;
    Resources(Resources&& other) noexcept { *this = std::move(other); }
    Resources& operator=(Resources&& other) noexcept {
        if (this == &other) return *this;
        release();
        color = other.color; other.color = nil;
        depth = other.depth; other.depth = nil;
        motion = other.motion; other.motion = nil;
        output = other.output; other.output = nil;
        exposure = other.exposure; other.exposure = nil;
        capacity = other.capacity; other.capacity = 0;
        return *this;
    }
    ~Resources() { release(); }

    void release() {
        [exposure release]; exposure = nil;
        [output release]; output = nil;
        [motion release]; motion = nil;
        [depth release]; depth = nil;
        [color release]; color = nil;
    }
};

Resources makeResources(id<MTLDevice> device, NSUInteger capacity,
                        MTLStorageMode outputStorage) {
    Resources resources;
    resources.capacity = capacity;
    resources.color = makeTexture(device, MTLPixelFormatRGBA8Unorm, capacity, capacity,
                                  MTLStorageModeShared, MTLTextureUsageShaderRead);
    resources.depth = makeTexture(device, MTLPixelFormatR32Float, capacity, capacity,
                                  MTLStorageModeShared, MTLTextureUsageShaderRead);
    resources.motion = makeTexture(device, MTLPixelFormatRG16Float, capacity, capacity,
                                   MTLStorageModeShared, MTLTextureUsageShaderRead);
    const MTLTextureUsage outputUsage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                                        MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
    resources.output = makeTexture(device, MTLPixelFormatRGBA8Unorm,
                                   kOutputBacking, kOutputBacking,
                                   outputStorage, outputUsage);
    resources.exposure = makeTexture(device, MTLPixelFormatR32Float, 1, 1,
                                     MTLStorageModeShared, MTLTextureUsageShaderRead);
    return resources;
}

float exposureValue(unsigned frameIndex) {
    return 0.5f + 0.0625f * static_cast<float>(frameIndex % kSequenceFrames);
}

void fillInputs(Resources& resources, unsigned frameIndex) {
    const NSUInteger pixels = resources.capacity * resources.capacity;
    std::vector<unsigned char> color(pixels * 4, 0);
    std::vector<float> depth(pixels, 0.1f);
    std::vector<_Float16> motion(pixels * 2, _Float16(0));
    for (NSUInteger y = 0; y < resources.capacity; ++y) {
        for (NSUInteger x = 0; x < resources.capacity; ++x) {
            const double wave = 0.48 + 0.24 * std::sin((double(x) + frameIndex * 0.31) * 0.55) +
                                0.16 * std::cos((double(y) - frameIndex * 0.23) * 0.31);
            const unsigned char v = static_cast<unsigned char>(
                std::lround(std::clamp(wave, 0.0, 1.0) * 255.0));
            const std::size_t offset = (y * resources.capacity + x) * 4;
            color[offset + 0] = v;
            color[offset + 1] = static_cast<unsigned char>(255 - v);
            color[offset + 2] = static_cast<unsigned char>((v + 37 * frameIndex) & 0xffu);
            color[offset + 3] = 255;
        }
    }
    [resources.color replaceRegion:MTLRegionMake2D(0, 0, resources.capacity, resources.capacity)
                       mipmapLevel:0 withBytes:color.data() bytesPerRow:resources.capacity * 4];
    [resources.depth replaceRegion:MTLRegionMake2D(0, 0, resources.capacity, resources.capacity)
                       mipmapLevel:0 withBytes:depth.data() bytesPerRow:resources.capacity * sizeof(float)];
    [resources.motion replaceRegion:MTLRegionMake2D(0, 0, resources.capacity, resources.capacity)
                        mipmapLevel:0 withBytes:motion.data()
                        bytesPerRow:resources.capacity * sizeof(_Float16) * 2];
    const float exposure = exposureValue(frameIndex);
    [resources.exposure replaceRegion:MTLRegionMake2D(0, 0, 1, 1)
                          mipmapLevel:0 withBytes:&exposure bytesPerRow:sizeof(exposure)];
}

CreateInfo makeCreateInfo() {
    CreateInfo create{};
    create.input = {static_cast<std::uint32_t>(kContent), static_cast<std::uint32_t>(kContent)};
    create.output = {static_cast<std::uint32_t>(kOutput), static_cast<std::uint32_t>(kOutput)};
    create.featureFlags = {
        static_cast<std::uint32_t>(FeatureFlagMVLowRes | FeatureFlagMVJittered | FeatureFlagDepthInverted),
        true};
    create.outputSubrects = {true, true};
    return create;
}

FrameInfo makeFrame(Resources& resources, unsigned frameIndex, bool reset) {
    FrameInfo frame{};
    frame.color = reinterpret_cast<void*>(resources.color);
    frame.depth = reinterpret_cast<void*>(resources.depth);
    frame.motionVectors = reinterpret_cast<void*>(resources.motion);
    frame.output = reinterpret_cast<void*>(resources.output);
    frame.exposureTexture = {reinterpret_cast<void*>(resources.exposure), true};
    frame.inputContent = {static_cast<std::uint32_t>(kContent), static_cast<std::uint32_t>(kContent)};
    frame.colorRect = {static_cast<std::uint32_t>(kColorX), static_cast<std::uint32_t>(kColorY),
                       static_cast<std::uint32_t>(kContent), static_cast<std::uint32_t>(kContent)};
    frame.depthRect = frame.colorRect;
    frame.motionRect = frame.colorRect;
    frame.reactiveRect = frame.colorRect;
    frame.outputRect = {static_cast<std::uint32_t>(kOutputX), static_cast<std::uint32_t>(kOutputY),
                        static_cast<std::uint32_t>(kOutput), static_cast<std::uint32_t>(kOutput)};
    static constexpr float jitterX[kSequenceFrames] = {0.125f, -0.25f, 0.375f};
    static constexpr float jitterY[kSequenceFrames] = {-0.375f, 0.125f, 0.25f};
    frame.jitterOffsetX = {jitterX[frameIndex % kSequenceFrames], true};
    frame.jitterOffsetY = {jitterY[frameIndex % kSequenceFrames], true};
    frame.motionVectorScaleX = {static_cast<float>(kContent), true};
    frame.motionVectorScaleY = {static_cast<float>(kContent), true};
    frame.preExposure = {1.25f + 0.125f * static_cast<float>(frameIndex % kSequenceFrames), true};
    frame.resetHistory = {reset, true};
    frame.exposureMode = ExposureMode::Texture;
    return frame;
}

TextureSet makeTextureSet(Resources& resources) {
    return {
        reinterpret_cast<void*>(resources.color),
        reinterpret_cast<void*>(resources.depth),
        reinterpret_cast<void*>(resources.motion),
        reinterpret_cast<void*>(resources.output),
        reinterpret_cast<void*>(resources.exposure),
        nullptr,
    };
}

void verifyDescriptorCapture(const FactoryCapture& capture, CommandMode mode) {
    require(capture.scaler != nil, "captured scaler exists");
    require(capture.metal4 == (mode == CommandMode::Metal4), "captured factory mode");
    require(capture.outputWidth == kOutput && capture.outputHeight == kOutput,
            "descriptor output dimensions");
    require(capture.synchronous, "descriptor requests synchronous MetalFX initialization");
    require(capture.dynamicContent, "descriptor enables dynamic input content");
    require(!capture.autoExposure, "manual exposure descriptor preserved");
    if (@available(macOS 27.0, *)) {
        require(!capture.outputMotion, "low-resolution motion-vector flag preserved");
        require(capture.jitteredMotion, "jittered-motion-vector flag preserved");
    }
}

void verifyScalerFrame(id captured, const FrameInfo& frame) {
    id<MTLFXTemporalScalerBase> scaler = reinterpret_cast<id<MTLFXTemporalScalerBase>>(captured);
    require(scaler.inputContentWidth == frame.inputContent.width &&
            scaler.inputContentHeight == frame.inputContent.height,
            "dynamic input content captured");
    require(closeFloat(scaler.jitterOffsetX, frame.jitterOffsetX.value) &&
            closeFloat(scaler.jitterOffsetY, frame.jitterOffsetY.value),
            "jitter scalar captured without sign/scale rewrite");
    require(closeFloat(scaler.motionVectorScaleX, frame.motionVectorScaleX.value) &&
            closeFloat(scaler.motionVectorScaleY, frame.motionVectorScaleY.value),
            "motion scale captured without rewrite");
    require(closeFloat(scaler.preExposure, frame.preExposure.value), "preExposure preserved");
    require(scaler.exposureTexture != nil &&
            scaler.exposureTexture.pixelFormat == MTLPixelFormatR16Float &&
            scaler.exposureTexture.width == 1 && scaler.exposureTexture.height == 1,
            "manual exposure converted to documented MetalFX R16Float texture");
}

struct LegacyRunner {
    id<MTLCommandQueue> queue = nil;
    explicit LegacyRunner(id<MTLDevice> device) : queue([device newCommandQueue]) {
        require(queue != nil, "legacy queue");
    }
    ~LegacyRunner() { [queue release]; }

    std::shared_ptr<const ExecutionLease> run(const std::shared_ptr<const PreparedFrame>& prepared,
                                              Error* error) {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLFence> fence = [queue.device newFence];
        require(command && fence, "legacy command/fence");
        id<MTLBlitCommandEncoder> producer = [command blitCommandEncoder];
        [producer updateFence:fence];
        [producer endEncoding];

        std::shared_ptr<const ExecutionLease> lease;
        const EncodeIdentity identity = nextObservationIdentity();
        const bool encoded = prepared->encode(reinterpret_cast<void*>(command),
                                              reinterpret_cast<void*>(fence), lease, error, &identity);
        require(encoded, error && !error->message.empty() ? error->message.c_str() : "legacy backend encode");
        require(lease != nullptr, "legacy execution lease published");

        id<MTLBlitCommandEncoder> consumer = [command blitCommandEncoder];
        [consumer waitForFence:fence];
        [consumer endEncoding];
        completeLegacy(command, "legacy backend GPU completion");
        [fence release];
        return lease;
    }
};

struct Metal4Runner {
    id<MTLDevice> device = nil;
    id queue = nil;
    id allocator = nil;
    id command = nil;
    bool used = false;

    explicit Metal4Runner(id<MTLDevice> input) : device(input) {
        if (@available(macOS 26.0, *)) {
            queue = [device newMTL4CommandQueue];
            allocator = [device newCommandAllocator];
            command = [device newCommandBuffer];
        }
        require(queue && allocator && command, "Metal4 queue/allocator/command");
    }
    ~Metal4Runner() {
        [command release];
        [allocator release];
        [queue release];
    }

    std::shared_ptr<const ExecutionLease> run(const std::shared_ptr<const PreparedFrame>& prepared,
                                              Error* error) API_AVAILABLE(macos(26.0)) {
        id<MTL4CommandAllocator> typedAllocator =
            reinterpret_cast<id<MTL4CommandAllocator>>(allocator);
        id<MTL4CommandBuffer> typedCommand = reinterpret_cast<id<MTL4CommandBuffer>>(command);
        id<MTL4CommandQueue> typedQueue = reinterpret_cast<id<MTL4CommandQueue>>(queue);
        if (used) [typedAllocator reset];
        used = true;
        id<MTLFence> fence = [device newFence];
        require(fence != nil, "Metal4 fence");
        [typedCommand beginCommandBufferWithAllocator:typedAllocator];
        id<MTL4ComputeCommandEncoder> producer = [typedCommand computeCommandEncoder];
        [producer updateFence:fence afterEncoderStages:MTLStageDispatch];
        [producer endEncoding];

        std::shared_ptr<const ExecutionLease> lease;
        const EncodeIdentity identity = nextObservationIdentity();
        const bool encoded = prepared->encode(reinterpret_cast<void*>(typedCommand),
                                              reinterpret_cast<void*>(fence), lease, error, &identity);
        require(encoded, error && !error->message.empty() ? error->message.c_str() : "Metal4 backend encode");
        require(lease != nullptr, "Metal4 execution lease published");
        id<MTL4ComputeCommandEncoder> consumer = [typedCommand computeCommandEncoder];
        [consumer waitForFence:fence beforeEncoderStages:MTLStageBlit];
        [consumer endEncoding];
        [typedCommand endCommandBuffer];

        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError* gpuError = nil;
        MTL4CommitOptions* options = [MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            gpuError = [feedback.error retain];
            dispatch_semaphore_signal(done);
        }];
        id<MTL4CommandBuffer> batch[] = {typedCommand};
        [typedQueue commit:batch count:1 options:options];
        require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
                "Metal4 feedback timeout");
        if (gpuError) NSLog(@"Metal4 backend GPU error: %@", gpuError);
        require(gpuError == nil, "Metal4 backend GPU completion");
        [gpuError release];
        [options release];
        dispatch_release(done);
        [fence release];
        return lease;
    }
};

std::shared_ptr<const ExecutionLease> runPrepared(CommandMode mode,
                                                  LegacyRunner* legacy,
                                                  Metal4Runner* metal4,
                                                  const std::shared_ptr<const PreparedFrame>& prepared,
                                                  Error* error) {
    if (mode == CommandMode::Legacy) return legacy->run(prepared, error);
    if (@available(macOS 26.0, *)) return metal4->run(prepared, error);
    require(false, "Metal4 run unavailable");
    return {};
}

struct DirectExtentReference {
    id<MTLFXTemporalScalerBase> scaler = nil;
    id residency = nil;
    id<MTLTexture> color = nil;
    id<MTLTexture> depth = nil;
    id<MTLTexture> motion = nil;
    id<MTLTexture> output = nil;
    id<MTLTexture> exposure = nil;

    ~DirectExtentReference() {
        [scaler release];
        [residency release];
        [exposure release];
        [output release];
        [motion release];
        [depth release];
        [color release];
    }
};

void createDirectExtentReference(DirectExtentReference& reference, id<MTLDevice> device,
                                id compiler, CommandMode mode, NSUInteger capacity,
                                bool lowResolutionMotion) API_AVAILABLE(macos(27.0)) {
    const MTLTextureUsage usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    reference.color = makeTexture(device, MTLPixelFormatRGBA8Unorm, capacity, capacity,
                                  MTLStorageModeShared, usage);
    reference.depth = makeTexture(device, MTLPixelFormatR32Float, capacity, capacity,
                                  MTLStorageModeShared, usage);
    reference.motion = makeTexture(device, MTLPixelFormatRG16Float,
                                   lowResolutionMotion ? capacity : kOutput,
                                   lowResolutionMotion ? capacity : kOutput,
                                   MTLStorageModeShared, usage);
    reference.output = makeTexture(device, MTLPixelFormatRGBA8Unorm, kOutput, kOutput,
                                   MTLStorageModePrivate,
                                   usage | MTLTextureUsageRenderTarget);
    reference.exposure = makeTexture(device, MTLPixelFormatR16Float, 1, 1,
                                     MTLStorageModeShared, usage);
    const _Float16 exposure = 1.0f;
    [reference.exposure replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0
                            withBytes:&exposure bytesPerRow:sizeof(exposure)];

    MTLFXTemporalScalerDescriptor* descriptor = [MTLFXTemporalScalerDescriptor new];
    descriptor.inputWidth = capacity;
    descriptor.inputHeight = capacity;
    descriptor.outputWidth = kOutput;
    descriptor.outputHeight = kOutput;
    descriptor.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
    descriptor.depthTextureFormat = MTLPixelFormatR32Float;
    descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
    descriptor.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
    descriptor.autoExposureEnabled = NO;
    descriptor.requiresSynchronousInitialization = YES;
    descriptor.inputContentPropertiesEnabled = YES;
    descriptor.inputContentMinScale =
        [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device];
    descriptor.inputContentMaxScale =
        [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device];
    if (@available(macOS 27.0, *)) {
        descriptor.outputResolutionMotionVectorsEnabled = !lowResolutionMotion;
        descriptor.jitteredMotionVectorsEnabled = YES;
    }
    if (mode == CommandMode::Metal4) {
        if (@available(macOS 26.0, *))
            reference.scaler = [descriptor newTemporalScalerWithDevice:device
                compiler:reinterpret_cast<id<MTL4Compiler>>(compiler)];
    } else {
        reference.scaler = [descriptor newTemporalScalerWithDevice:device];
    }
    [descriptor release];
    require(reference.scaler != nil, "direct retained-capacity MetalFX factory");

    require((reference.color.usage & reference.scaler.colorTextureUsage) ==
                reference.scaler.colorTextureUsage &&
            (reference.depth.usage & reference.scaler.depthTextureUsage) ==
                reference.scaler.depthTextureUsage &&
            (reference.motion.usage & reference.scaler.motionTextureUsage) ==
                reference.scaler.motionTextureUsage &&
            (reference.output.usage & reference.scaler.outputTextureUsage) ==
                reference.scaler.outputTextureUsage,
            "direct retained-capacity textures satisfy MetalFX usage");
    if (mode == CommandMode::Metal4) {
        if (@available(macOS 15.0, *)) {
            MTLResidencySetDescriptor* residencyDescriptor = [MTLResidencySetDescriptor new];
            residencyDescriptor.initialCapacity = 5;
            NSError* error = nil;
            reference.residency = [device newResidencySetWithDescriptor:residencyDescriptor
                                                                 error:&error];
            [residencyDescriptor release];
            require(reference.residency != nil && error == nil,
                    "direct retained-capacity Metal4 residency set");
            id<MTLResidencySet> set = reference.residency;
            for (id<MTLAllocation> allocation in @[reference.color, reference.depth,
                    reference.motion, reference.output, reference.exposure])
                [set addAllocation:allocation];
            [set commit];
        }
    }
}

template <typename T>
std::vector<T> cpuEdgeExtend(const std::vector<T>& active, NSUInteger activeWidth,
                             NSUInteger activeHeight, NSUInteger capacity,
                             NSUInteger channels) {
    require(active.size() == activeWidth * activeHeight * channels,
            "CPU edge-reference active input size");
    std::vector<T> padded(capacity * capacity * channels);
    for (NSUInteger y = 0; y < capacity; ++y) {
        const NSUInteger sourceY = std::min(y, activeHeight - 1);
        for (NSUInteger x = 0; x < capacity; ++x) {
            const NSUInteger sourceX = std::min(x, activeWidth - 1);
            const std::size_t source =
                (sourceY * activeWidth + sourceX) * channels;
            const std::size_t destination = (y * capacity + x) * channels;
            std::copy_n(active.begin() + static_cast<std::ptrdiff_t>(source), channels,
                        padded.begin() + static_cast<std::ptrdiff_t>(destination));
        }
    }
    return padded;
}

void fillDirectExtentReferenceInputs(DirectExtentReference& reference,
                                     const Resources& resources,
                                     NSUInteger activeWidth, NSUInteger activeHeight,
                                     NSUInteger capacity, bool lowResolutionMotion)
    API_AVAILABLE(macos(27.0)) {
    std::vector<unsigned char> activeColor(activeWidth * activeHeight * 4);
    [resources.color getBytes:activeColor.data() bytesPerRow:activeWidth * 4
                   fromRegion:MTLRegionMake2D(0, 0, activeWidth, activeHeight) mipmapLevel:0];
    const auto paddedColor = cpuEdgeExtend(activeColor, activeWidth, activeHeight,
                                           capacity, 4);
    [reference.color replaceRegion:MTLRegionMake2D(0, 0, capacity, capacity) mipmapLevel:0
                         withBytes:paddedColor.data() bytesPerRow:capacity * 4];

    std::vector<float> activeDepth(activeWidth * activeHeight);
    [resources.depth getBytes:activeDepth.data() bytesPerRow:activeWidth * sizeof(float)
                   fromRegion:MTLRegionMake2D(0, 0, activeWidth, activeHeight) mipmapLevel:0];
    const auto paddedDepth = cpuEdgeExtend(activeDepth, activeWidth, activeHeight,
                                           capacity, 1);
    [reference.depth replaceRegion:MTLRegionMake2D(0, 0, capacity, capacity) mipmapLevel:0
                         withBytes:paddedDepth.data() bytesPerRow:capacity * sizeof(float)];

    if (lowResolutionMotion) {
        std::vector<_Float16> activeMotion(activeWidth * activeHeight * 2);
        [resources.motion getBytes:activeMotion.data()
                      bytesPerRow:activeWidth * sizeof(_Float16) * 2
                       fromRegion:MTLRegionMake2D(0, 0, activeWidth, activeHeight)
                      mipmapLevel:0];
        const auto paddedMotion = cpuEdgeExtend(activeMotion, activeWidth, activeHeight,
                                                capacity, 2);
        [reference.motion replaceRegion:MTLRegionMake2D(0, 0, capacity, capacity)
                             mipmapLevel:0 withBytes:paddedMotion.data()
                             bytesPerRow:capacity * sizeof(_Float16) * 2];
    } else {
        std::vector<_Float16> outputMotion(kOutput * kOutput * 2);
        [resources.motion getBytes:outputMotion.data()
                      bytesPerRow:kOutput * sizeof(_Float16) * 2
                       fromRegion:MTLRegionMake2D(kOutputX, kOutputY, kOutput, kOutput)
                      mipmapLevel:0];
        [reference.motion replaceRegion:MTLRegionMake2D(0, 0, kOutput, kOutput)
                             mipmapLevel:0 withBytes:outputMotion.data()
                             bytesPerRow:kOutput * sizeof(_Float16) * 2];
    }
}

void submitDirectExtentMetal4(Metal4Runner& runner, DirectExtentReference& reference,
                              NSUInteger activeWidth, NSUInteger activeHeight)
    API_AVAILABLE(macos(27.0)) {
    id<MTL4CommandQueue> queue = reinterpret_cast<id<MTL4CommandQueue>>(runner.queue);
    id<MTL4CommandAllocator> allocator = reinterpret_cast<id<MTL4CommandAllocator>>(runner.allocator);
    id<MTL4CommandBuffer> command = reinterpret_cast<id<MTL4CommandBuffer>>(runner.command);
    if (runner.used) [allocator reset];
    runner.used = true;
    id<MTLFence> fence = [runner.device newFence];
    require(fence != nil, "direct retained-capacity Metal4 fence");
    [command beginCommandBufferWithAllocator:allocator];
    if (reference.residency)
        [command useResidencySet:reinterpret_cast<id<MTLResidencySet>>(reference.residency)];
    id<MTL4ComputeCommandEncoder> producer = [command computeCommandEncoder];
    [producer updateFence:fence afterEncoderStages:MTLStageDispatch];
    [producer endEncoding];

    id<MTLFXTemporalScalerBase> scaler = reference.scaler;
    scaler.colorTexture = reference.color;
    scaler.depthTexture = reference.depth;
    scaler.motionTexture = reference.motion;
    scaler.outputTexture = reference.output;
    scaler.exposureTexture = reference.exposure;
    scaler.inputContentWidth = activeWidth;
    scaler.inputContentHeight = activeHeight;
    scaler.colorContentOffsetX = 0;
    scaler.colorContentOffsetY = 0;
    scaler.depthContentOffsetX = 0;
    scaler.depthContentOffsetY = 0;
    scaler.motionContentOffsetX = 0;
    scaler.motionContentOffsetY = 0;
    scaler.outputOffsetX = 0;
    scaler.outputOffsetY = 0;
    scaler.jitterOffsetX = 0.125f;
    scaler.jitterOffsetY = -0.25f;
    scaler.motionVectorScaleX = static_cast<float>(activeWidth);
    scaler.motionVectorScaleY = static_cast<float>(activeHeight);
    scaler.preExposure = 1.0f;
    scaler.depthReversed = YES;
    scaler.reset = YES;
    scaler.fence = fence;
    [reinterpret_cast<id<MTL4FXTemporalScaler>>(reference.scaler)
        encodeToCommandBuffer:command];

    id<MTL4ComputeCommandEncoder> consumer = [command computeCommandEncoder];
    [consumer waitForFence:fence beforeEncoderStages:MTLStageBlit];
    [consumer endEncoding];
    [command endCommandBuffer];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError* gpuError = nil;
    MTL4CommitOptions* options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        gpuError = [feedback.error retain];
        dispatch_semaphore_signal(done);
    }];
    id<MTL4CommandBuffer> batch[] = {command};
    [queue commit:batch count:1 options:options];
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
            "direct retained-capacity Metal4 feedback");
    if (gpuError) NSLog(@"direct retained-capacity Metal4 GPU error: %@", gpuError);
    require(gpuError == nil, "direct retained-capacity Metal4 completion");
    [gpuError release];
    [options release];
    dispatch_release(done);
    [fence release];
}

void submitDirectExtentLegacy(LegacyRunner& runner, DirectExtentReference& reference,
                              NSUInteger activeWidth, NSUInteger activeHeight)
    API_AVAILABLE(macos(27.0)) {
    id<MTLCommandBuffer> command = [runner.queue commandBuffer];
    id<MTLFence> fence = [runner.queue.device newFence];
    require(command && fence, "direct retained-capacity legacy command/fence");
    id<MTLBlitCommandEncoder> producer = [command blitCommandEncoder];
    [producer updateFence:fence];
    [producer endEncoding];

    id<MTLFXTemporalScalerBase> scaler = reference.scaler;
    scaler.colorTexture = reference.color;
    scaler.depthTexture = reference.depth;
    scaler.motionTexture = reference.motion;
    scaler.outputTexture = reference.output;
    scaler.exposureTexture = reference.exposure;
    scaler.inputContentWidth = activeWidth;
    scaler.inputContentHeight = activeHeight;
    if (@available(macOS 27.0, *)) {
        scaler.colorContentOffsetX = 0;
        scaler.colorContentOffsetY = 0;
        scaler.depthContentOffsetX = 0;
        scaler.depthContentOffsetY = 0;
        scaler.motionContentOffsetX = 0;
        scaler.motionContentOffsetY = 0;
        scaler.outputOffsetX = 0;
        scaler.outputOffsetY = 0;
    }
    scaler.jitterOffsetX = 0.125f;
    scaler.jitterOffsetY = -0.25f;
    scaler.motionVectorScaleX = static_cast<float>(activeWidth);
    scaler.motionVectorScaleY = static_cast<float>(activeHeight);
    scaler.preExposure = 1.0f;
    scaler.depthReversed = YES;
    scaler.reset = YES;
    scaler.fence = fence;
    [reinterpret_cast<id<MTLFXTemporalScaler>>(reference.scaler)
        encodeToCommandBuffer:command];
    id<MTLBlitCommandEncoder> consumer = [command blitCommandEncoder];
    [consumer waitForFence:fence];
    [consumer endEncoding];
    completeLegacy(command, "direct retained-capacity legacy completion");
    [fence release];
}

struct OutputDiff {
    std::size_t differingPixels = 0;
    unsigned maxByteDelta = 0;
    double meanByteDeltaLevels = 0.0;
};

OutputDiff compareOutputRect(const std::vector<unsigned char>& backing,
                             NSUInteger backingWidth, NSUInteger originX, NSUInteger originY,
                             const std::vector<unsigned char>& reference) {
    require(reference.size() == kOutput * kOutput * 4,
            "direct MetalFX comparison extent");
    OutputDiff diff{};
    std::uint64_t absoluteDelta = 0;
    for (NSUInteger y = 0; y < kOutput; ++y) {
        for (NSUInteger x = 0; x < kOutput; ++x) {
            const std::size_t source = ((originY + y) * backingWidth + originX + x) * 4;
            const std::size_t target = (y * kOutput + x) * 4;
            unsigned pixelDelta = 0;
            for (std::size_t channel = 0; channel < 4; ++channel) {
                const unsigned delta = static_cast<unsigned>(std::abs(
                    static_cast<int>(backing[source + channel]) -
                    static_cast<int>(reference[target + channel])));
                pixelDelta = std::max(pixelDelta, delta);
                diff.maxByteDelta = std::max(diff.maxByteDelta, delta);
                absoluteDelta += delta;
            }
            if (pixelDelta != 0) ++diff.differingPixels;
        }
    }
    diff.meanByteDeltaLevels = static_cast<double>(absoluteDelta) /
        static_cast<double>(kOutput * kOutput * 4);
    return diff;
}

void fillExtentInputs(Resources& resources, NSUInteger activeWidth, NSUInteger activeHeight,
                     bool lowResolutionMotion, unsigned poisonVariant = 0)
    API_AVAILABLE(macos(27.0));

void verifyDirectExtentParity(id<MTLDevice> device, id compiler,
                              id<MTLCommandQueue> transfer, CommandMode mode,
                              LegacyRunner* legacy, Metal4Runner* metal4,
                              Resources& resources, NSUInteger capacity,
                              NSUInteger activeWidth, NSUInteger activeHeight,
                              bool lowResolutionMotion,
                              const std::vector<unsigned char>& reusedBytes,
                              const std::vector<unsigned char>& freshBytes)
    API_AVAILABLE(macos(27.0)) {
    DirectExtentReference retainedReference;
    createDirectExtentReference(retainedReference, device, compiler, mode, capacity,
                                lowResolutionMotion);
    fillExtentInputs(resources, capacity, capacity, lowResolutionMotion, 0);
    fillDirectExtentReferenceInputs(retainedReference, resources, capacity, capacity,
                                    capacity, lowResolutionMotion);
    if (mode == CommandMode::Metal4) {
        if (@available(macOS 26.0, *))
            submitDirectExtentMetal4(*metal4, retainedReference, capacity, capacity);
    } else {
        submitDirectExtentLegacy(*legacy, retainedReference, capacity, capacity);
    }
    fillExtentInputs(resources, activeWidth, activeHeight, lowResolutionMotion, 0);
    fillDirectExtentReferenceInputs(retainedReference, resources, activeWidth, activeHeight,
                                    capacity, lowResolutionMotion);
    if (mode == CommandMode::Metal4) {
        if (@available(macOS 26.0, *))
            submitDirectExtentMetal4(*metal4, retainedReference, activeWidth, activeHeight);
    } else {
        submitDirectExtentLegacy(*legacy, retainedReference, activeWidth, activeHeight);
    }
    const auto retainedBytes = readRGBA8(device, transfer, retainedReference.output);

    DirectExtentReference exactReference;
    createDirectExtentReference(exactReference, device, compiler, mode, activeWidth,
                                lowResolutionMotion);
    fillDirectExtentReferenceInputs(exactReference, resources, activeWidth, activeHeight,
                                   activeWidth, lowResolutionMotion);
    if (mode == CommandMode::Metal4) {
        if (@available(macOS 26.0, *))
            submitDirectExtentMetal4(*metal4, exactReference, activeWidth, activeHeight);
    } else {
        submitDirectExtentLegacy(*legacy, exactReference, activeWidth, activeHeight);
    }
    const auto exactBytes = readRGBA8(device, transfer, exactReference.output);
    const OutputDiff nativeCapacityDiff = compareOutputRect(
        retainedBytes, kOutput, 0, 0, exactBytes);
    const OutputDiff backendRetainedDiff = compareOutputRect(
        reusedBytes, resources.output.width, kOutputX, kOutputY, retainedBytes);
    const OutputDiff backendExactDiff = compareOutputRect(
        freshBytes, resources.output.width, kOutputX, kOutputY, exactBytes);
    std::printf("NATIVE_CAPACITY_COMPARE mode=%s motion=%s capacity=%zux%zu active=%zux%zu differing_pixels=%zu/%zu max_byte_delta=%u mean_byte_delta_levels=%.6f mean_normalized_delta=%.9f\n",
                mode == CommandMode::Metal4 ? "metal4" : "legacy",
                lowResolutionMotion ? "low" : "display", capacity, capacity,
                activeWidth, activeHeight, nativeCapacityDiff.differingPixels,
                static_cast<std::size_t>(kOutput * kOutput),
                nativeCapacityDiff.maxByteDelta, nativeCapacityDiff.meanByteDeltaLevels,
                nativeCapacityDiff.meanByteDeltaLevels / 255.0);
    std::printf("DIRECT_NATIVE_PARITY mode=%s motion=%s retained_pixels=%zu max_byte_delta=%u mean_byte_delta_levels=%.6f fresh_pixels=%zu fresh_max_byte_delta=%u\n",
                mode == CommandMode::Metal4 ? "metal4" : "legacy",
                lowResolutionMotion ? "low" : "display", backendRetainedDiff.differingPixels,
                backendRetainedDiff.maxByteDelta, backendRetainedDiff.meanByteDeltaLevels,
                backendExactDiff.differingPixels, backendExactDiff.maxByteDelta);
    require(backendRetainedDiff.differingPixels == 0 && backendRetainedDiff.maxByteDelta == 0,
            "reused backend output matches direct retained-capacity MetalFX with CPU edge padding");
    require(backendExactDiff.differingPixels == 0 && backendExactDiff.maxByteDelta == 0,
            "fresh backend output matches direct exact-capacity MetalFX");
    std::printf("SAME_DESCRIPTOR_NATIVE_PARITY_PASS mode=%s motion=%s retained=bit-exact fresh=bit-exact\n",
                mode == CommandMode::Metal4 ? "metal4" : "legacy",
                lowResolutionMotion ? "low" : "display");
}

void verifyGpuEdgeStagingMatchesCpu(id<MTLDevice> device,
                                    id<MTLCommandQueue> transfer,
                                    id<MTLFXTemporalScalerBase> scaler,
                                    Resources& resources, NSUInteger activeWidth,
                                    NSUInteger activeHeight, NSUInteger capacity,
                                    bool lowResolutionMotion) API_AVAILABLE(macos(27.0)) {
    require(scaler.colorTexture.width == capacity && scaler.colorTexture.height == capacity &&
            scaler.depthTexture.width == capacity && scaler.depthTexture.height == capacity,
            "reused generation binds capacity-sized staged color and depth");
    std::vector<unsigned char> activeColor(activeWidth * activeHeight * 4);
    [resources.color getBytes:activeColor.data() bytesPerRow:activeWidth * 4
                   fromRegion:MTLRegionMake2D(0, 0, activeWidth, activeHeight) mipmapLevel:0];
    const auto expectedColor = cpuEdgeExtend(activeColor, activeWidth, activeHeight,
                                             capacity, 4);
    require(readRGBA8(device, transfer, scaler.colorTexture) == expectedColor,
            "Metal color stage equals independent CPU edge extension");

    std::vector<float> activeDepth(activeWidth * activeHeight);
    [resources.depth getBytes:activeDepth.data() bytesPerRow:activeWidth * sizeof(float)
                   fromRegion:MTLRegionMake2D(0, 0, activeWidth, activeHeight) mipmapLevel:0];
    const auto expectedDepth = cpuEdgeExtend(activeDepth, activeWidth, activeHeight,
                                             capacity, 1);
    const auto actualDepth = readTextureBytes(device, transfer, scaler.depthTexture,
                                              sizeof(float));
    require(actualDepth.size() == expectedDepth.size() * sizeof(float) &&
            std::memcmp(actualDepth.data(), expectedDepth.data(), actualDepth.size()) == 0,
            "Metal depth stage equals independent CPU edge extension");

    if (lowResolutionMotion) {
        require(scaler.motionTexture.width == capacity && scaler.motionTexture.height == capacity,
                "reused generation binds capacity-sized staged low-resolution motion");
        std::vector<_Float16> activeMotion(activeWidth * activeHeight * 2);
        [resources.motion getBytes:activeMotion.data()
                      bytesPerRow:activeWidth * sizeof(_Float16) * 2
                       fromRegion:MTLRegionMake2D(0, 0, activeWidth, activeHeight)
                      mipmapLevel:0];
        const auto expectedMotion = cpuEdgeExtend(activeMotion, activeWidth, activeHeight,
                                                  capacity, 2);
        const auto actualMotion = readTextureBytes(device, transfer, scaler.motionTexture,
                                                   sizeof(_Float16) * 2);
        require(actualMotion.size() == expectedMotion.size() * sizeof(_Float16) &&
                std::memcmp(actualMotion.data(), expectedMotion.data(), actualMotion.size()) == 0,
                "Metal low-resolution motion stage equals independent CPU edge extension");
    }
    std::printf("EDGE_STAGING_CPU_ORACLE_PASS color=exact depth=exact motion=%s\n",
                lowResolutionMotion ? "exact" : "not-staged");
}

struct CaseResult {
    std::array<std::uint64_t, kSequenceFrames> hashes{};
};

CaseResult runCase(id<MTLDevice> device, id compiler, id<MTLCommandQueue> transfer,
                   CommandMode mode, MTLStorageMode outputStorage, bool comprehensive) {
    const bool sharedOutput = outputStorage == MTLStorageModeShared;
    const std::size_t captureBase = captureCount();
    CreateInfo create = makeCreateInfo();
    CreateContext context{reinterpret_cast<void*>(device),
                          mode == CommandMode::Metal4 ? reinterpret_cast<void*>(compiler) : nullptr,
                          mode};
    Error error;
    auto feature = Feature::create(context, create, &error);
    require(feature != nullptr, error.message.empty() ? "backend feature create" : error.message.c_str());

    Resources resources = makeResources(device, 80, outputStorage);
    std::unique_ptr<LegacyRunner> legacy;
    std::unique_ptr<Metal4Runner> metal4;
    if (mode == CommandMode::Legacy) legacy = std::make_unique<LegacyRunner>(device);
    else if (@available(macOS 26.0, *)) metal4 = std::make_unique<Metal4Runner>(device);

    CaseResult result{};
    std::shared_ptr<const PreparedFrame> replayPrepared;
    id firstScaler = nil;
    for (unsigned frameIndex = 0; frameIndex < kSequenceFrames; ++frameIndex) {
        fillInputs(resources, frameIndex);
        writeRGBA8(device, transfer, resources.output, sentinelBytes());
        // A new backend generation must initialize its own history even when
        // the caller did not request a scene-cut reset.
        FrameInfo frame = makeFrame(resources, frameIndex, false);
        TextureSet set = makeTextureSet(resources);
        auto prepared = feature->prepare(frame, set, &error);
        require(prepared != nullptr, error.message.empty() ? "frame preparation" : error.message.c_str());
        if (frameIndex == 0) {
            require(captureCount() == captureBase + 1, "first frame created exactly one scaler generation");
            FactoryCapture capture = captureAt(captureBase);
            verifyDescriptorCapture(capture, mode);
            firstScaler = capture.scaler;
            installScalerObservers(firstScaler);
        } else {
            require(captureCount() == captureBase + 1, "same backing capacity preserves MetalFX history generation");
        }

        auto lease = runPrepared(mode, legacy.get(), metal4.get(), prepared, &error);
        require(lease != nullptr, "completed execution lease retained by caller");
        verifyScalerFrame(firstScaler, frame);
        bool observedReset = false;
        bool observedDepth = false;
        require(observedBool(firstScaler, &gObservedResetKey, observedReset) &&
                observedReset == lease->effectiveReset(),
                "effective reset value reached MetalFX setter");
        require(lease->scaler() == reinterpret_cast<void*>(firstScaler),
                "execution lease reports the exact scaler generation");
        if (frameIndex == 0) {
            require(lease->effectiveReset() && !lease->generationInitialized(),
                    "fresh generation upgrades caller reset=false to one-time effective reset");
        } else {
            require(!lease->effectiveReset() && lease->generationInitialized(),
                    "subsequent caller reset=false preserves initialized temporal history");
        }
        require(observedBool(firstScaler, &gObservedDepthKey, observedDepth) && observedDepth,
                "depth-reversed value reached MetalFX setter");
        id<MTLFXTemporalScalerBase> scaler =
            reinterpret_cast<id<MTLFXTemporalScalerBase>>(firstScaler);
        const float converted = readR16(device, transfer, scaler.exposureTexture);
        require(closeFloat(converted, exposureValue(frameIndex), 0.001f),
                "exposure numerical R-channel conversion preserves value");

        const auto bytes = readRGBA8(device, transfer, resources.output);
        verifyOutputSentinel(bytes, resources.output.width, resources.output.height);
        result.hashes[frameIndex] = hashBytes(bytes);
        if (frameIndex == 1) replayPrepared = prepared;
    }

    if (comprehensive) {
        // Fresh-generation caller reset=false must be bit-identical to the
        // documented first-frame caller reset=true behavior for the same input.
        Resources explicitResources = makeResources(device, resources.capacity, outputStorage);
        fillInputs(explicitResources, 0);
        writeRGBA8(device, transfer, explicitResources.output, sentinelBytes());
        auto explicitFeature = Feature::create(context, create, &error);
        require(explicitFeature != nullptr, "explicit first-frame reset reference feature");
        FrameInfo explicitFrame = makeFrame(explicitResources, 0, true);
        auto explicitPrepared = explicitFeature->prepare(
            explicitFrame, makeTextureSet(explicitResources), &error);
        require(explicitPrepared != nullptr, "explicit first-frame reset reference preparation");
        auto explicitLease = runPrepared(mode, legacy.get(), metal4.get(), explicitPrepared, &error);
        require(explicitLease != nullptr && explicitLease->effectiveReset() &&
                !explicitLease->generationInitialized(),
                "explicit first-frame reference reports fresh generation reset");
        const auto explicitBytes = readRGBA8(device, transfer, explicitResources.output);
        require(hashBytes(explicitBytes) == result.hashes[0],
                "fresh caller-reset=false output matches explicit first-frame reset=true reference");

        // Reset the same scaler and replay the same deterministic fixture. A
        // reset discards temporal history, but the public API does not promise
        // bit identity with a scaler's first-ever invocation, so verify the
        // exact reset setter plus all output invariants rather than overfit to
        // a concrete model's internal first-frame state.
        for (unsigned frameIndex = 0; frameIndex < kSequenceFrames; ++frameIndex) {
            fillInputs(resources, frameIndex);
            writeRGBA8(device, transfer, resources.output, sentinelBytes());
            FrameInfo frame = makeFrame(resources, frameIndex, frameIndex == 0);
            auto prepared = feature->prepare(frame, makeTextureSet(resources), &error);
            require(prepared != nullptr, "deterministic replay preparation");
            require(captureCount() == captureBase + 2, "reset does not recreate scaler generation");
            auto lease = runPrepared(mode, legacy.get(), metal4.get(), prepared, &error);
            require(lease != nullptr, "deterministic replay lease");
            const auto bytes = readRGBA8(device, transfer, resources.output);
            verifyOutputSentinel(bytes, resources.output.width, resources.output.height);
            bool resetValue = false;
            require(observedBool(firstScaler, &gObservedResetKey, resetValue) &&
                    resetValue == (frameIndex == 0),
                    "deterministic replay uses explicit reset only on first frame");
        }

        // Changing only caller backing capacity must preserve the active-size
        // scaler generation and its temporal history.
        Resources resized = makeResources(device, 96, outputStorage);
        fillInputs(resized, 0);
        writeRGBA8(device, transfer, resized.output, sentinelBytes());
        FrameInfo resizedFrame = makeFrame(resized, 0, false);
        auto resizedPrepared = feature->prepare(resizedFrame, makeTextureSet(resized), &error);
        require(resizedPrepared != nullptr, error.message.empty() ? "resize preparation" : error.message.c_str());
        require(captureCount() == captureBase + 2,
                "backing-capacity-only resize preserves scaler generation");
        auto resizedLease = runPrepared(mode, legacy.get(), metal4.get(), resizedPrepared, &error);
        require(resizedLease != nullptr && resizedLease->scaler() == reinterpret_cast<void*>(firstScaler),
                "resize execution reuses active-size scaler");
        require(!resizedLease->effectiveReset() && resizedLease->generationInitialized(),
                "backing-capacity-only resize preserves temporal history");
        verifyScalerFrame(firstScaler, resizedFrame);
        verifyOutputSentinel(readRGBA8(device, transfer, resized.output),
                             resized.output.width, resized.output.height);

        // Preparing another frame against the resized backing and replaying an
        // earlier PreparedFrame both retain the same active-size generation.
        fillInputs(resized, 1);
        FrameInfo resizedFrame1 = makeFrame(resized, 1, false);
        auto resizedPrepared1 = feature->prepare(resizedFrame1, makeTextureSet(resized), &error);
        require(resizedPrepared1 != nullptr && captureCount() == captureBase + 2,
                "same resized backing preserves active-size generation");
        auto resizedLease1 = runPrepared(mode, legacy.get(), metal4.get(), resizedPrepared1, &error);
        require(resizedLease1 != nullptr, "second resized execution");
        require(!resizedLease1->effectiveReset() && resizedLease1->generationInitialized(),
                "second resized reset=false execution preserves new generation history");

        require(replayPrepared != nullptr, "old generation replay frame retained");
        auto oldReplayLease = runPrepared(mode, legacy.get(), metal4.get(), replayPrepared, &error);
        require(oldReplayLease != nullptr && captureCount() == captureBase + 2,
                "old recorded frame replays without factory mutation");
        id<MTLFXTemporalScalerBase> oldScaler =
            reinterpret_cast<id<MTLFXTemporalScalerBase>>(firstScaler);
        require(closeFloat(oldScaler.jitterOffsetX, -0.25f),
                "old prepared frame still targets old history generation");


        // Preparation failure happens before recording and leaves output bytes
        // untouched. This also covers the exact unsupported Exposure.Scale case.
        writeRGBA8(device, transfer, resources.output, sentinelBytes());
        FrameInfo invalidRect = makeFrame(resources, 0, false);
        invalidRect.outputRect.x = 20;
        auto invalidPrepared = feature->prepare(invalidRect, makeTextureSet(resources), &error);
        require(invalidPrepared == nullptr && error.code == ErrorCode::InvalidFrame,
                "out-of-bounds output rect fails preparation synchronously");
        auto staleBytes = readRGBA8(device, transfer, resources.output);
        require(staleBytes == sentinelBytes(), "failed preparation leaves output completely stale/untouched");

        // Color and depth may have different backing capacities when both active
        // rectangles fit. The normalized dispatch must still update only the active output.
        id<MTLTexture> narrowDepth = makeTexture(
            device, MTLPixelFormatR32Float, resources.capacity - 8, resources.capacity,
            MTLStorageModeShared, MTLTextureUsageShaderRead);
        FrameInfo narrowDepthFrame = makeFrame(resources, 0, false);
        TextureSet narrowDepthTextures = makeTextureSet(resources);
        narrowDepthTextures.depth = reinterpret_cast<void*>(narrowDepth);
        auto narrowDepthPrepared = feature->prepare(narrowDepthFrame, narrowDepthTextures, &error);
        require(narrowDepthPrepared != nullptr,
                error.message.empty() ? "independent depth backing preparation" : error.message.c_str());
        auto narrowDepthLease = runPrepared(
            mode, legacy.get(), metal4.get(), narrowDepthPrepared, &error);
        require(narrowDepthLease != nullptr,
                error.message.empty() ? "independent depth backing execution" : error.message.c_str());
        verifyOutputSentinel(readRGBA8(device, transfer, resources.output),
                             resources.output.width, resources.output.height);
        [narrowDepth release];
    }

    std::printf("CASE_PASS mode=%s storage=%s hashes=%016llx,%016llx,%016llx captures=%zu\n",
                mode == CommandMode::Metal4 ? "metal4" : "legacy",
                sharedOutput ? "shared" : "private",
                static_cast<unsigned long long>(result.hashes[0]),
                static_cast<unsigned long long>(result.hashes[1]),
                static_cast<unsigned long long>(result.hashes[2]),
                captureCount() - captureBase);
    return result;
}

void testFsrOperationsMetal4(id<MTLDevice> device, id<MTL4Compiler> compiler,
                            id<MTLCommandQueue> transfer) API_AVAILABLE(macos(26.0)) {
    Error error;
    auto feature = Feature::create(
        {reinterpret_cast<void*>(device), reinterpret_cast<void*>(compiler), CommandMode::Metal4},
        makeCreateInfo(), &error);
    require(feature != nullptr, "FSR operations feature");
    Resources resources = makeResources(device, 80, MTLStorageModeShared);
    fillInputs(resources, 1);
    writeRGBA8(device, transfer, resources.output, sentinelBytes());

    id<MTLTexture> reactive = makeTexture(device, MTLPixelFormatR8Unorm, 80, 80,
                                          MTLStorageModeShared, MTLTextureUsageShaderRead);
    id<MTLTexture> composition = makeTexture(device, MTLPixelFormatR8Unorm, 80, 80,
                                             MTLStorageModeShared, MTLTextureUsageShaderRead);
    std::vector<unsigned char> reactiveBytes(80 * 80, 32);
    std::vector<unsigned char> compositionBytes(80 * 80, 0);
    for (NSUInteger y = kColorY; y < kColorY + kContent; ++y)
        for (NSUInteger x = kColorX + kContent / 2; x < kColorX + kContent; ++x)
            compositionBytes[y * 80 + x] = 224;
    [reactive replaceRegion:MTLRegionMake2D(0, 0, 80, 80) mipmapLevel:0
                  withBytes:reactiveBytes.data() bytesPerRow:80];
    [composition replaceRegion:MTLRegionMake2D(0, 0, 80, 80) mipmapLevel:0
                     withBytes:compositionBytes.data() bytesPerRow:80];

    FrameInfo frame = makeFrame(resources, 1, true);
    frame.reactiveMask = {reinterpret_cast<void*>(reactive), true};
    TextureSet textures = makeTextureSet(resources);
    textures.reactive = reinterpret_cast<void*>(reactive);
    textures.composition = reinterpret_cast<void*>(composition);
    FrameOperations operations{};
    operations.colorTransfer = ColorTransfer::SRGB;
    operations.combineCompositionMask = true;
    operations.sharpening = true;
    operations.sharpness = 0.75f;
    const std::size_t captureBase = captureCount();
    auto prepared = feature->prepare(frame, textures, &error, operations);
    require(prepared != nullptr, error.message.empty() ? "FSR operations prepare" : error.message.c_str());
    Metal4Runner runner(device);
    auto lease = runner.run(prepared, &error);
    require(lease != nullptr, error.message.empty() ? "FSR operations encode" : error.message.c_str());
    require(captureCount() == captureBase + 1, "FSR operations create one scaler generation");
    id<MTLFXTemporalScalerBase> scaler =
        reinterpret_cast<id<MTLFXTemporalScalerBase>>(captureAt(captureBase).scaler);
    require(scaler.colorTexture != resources.color,
            "transfer conversion supplies MetalFX a linear scratch color");
    require(scaler.outputTexture != resources.output,
            "transfer/RCAS uses a linear private MetalFX output");
    if (@available(macOS 27.0, *)) {
        require(scaler.reactiveMaskTexture != nil &&
                    scaler.reactiveMaskTexture != reactive &&
                    scaler.reactiveMaskTexture != composition &&
                    scaler.reactiveMaskTexture.pixelFormat == MTLPixelFormatR8Unorm,
                "reactive and composition masks are combined into R8Unorm scratch");
    }
    const std::vector<unsigned char> sharpened = readRGBA8(device, transfer, resources.output);
    require(sharpened != sentinelBytes(),
            "transfer/RCAS pass replaces caller output sentinel");

    writeRGBA8(device, transfer, resources.output, sentinelBytes());
    operations.sharpening = false;
    operations.sharpness = 0.5f;
    prepared = feature->prepare(frame, textures, &error, operations);
    require(prepared != nullptr, error.message.empty() ? "RCAS-disabled nonzero prepare" : error.message.c_str());
    lease = runner.run(prepared, &error);
    require(lease != nullptr, error.message.empty() ? "RCAS-disabled nonzero encode" : error.message.c_str());
    const std::vector<unsigned char> unsharpened = readRGBA8(device, transfer, resources.output);
    require(unsharpened != sentinelBytes(), "RCAS-disabled path replaces caller output sentinel");
    require(unsharpened != sharpened, "RCAS enabled and disabled outputs differ observably");

    writeRGBA8(device, transfer, resources.output, sentinelBytes());
    operations.sharpness = 0.0f;
    prepared = feature->prepare(frame, textures, &error, operations);
    require(prepared != nullptr, error.message.empty() ? "RCAS-disabled zero prepare" : error.message.c_str());
    lease = runner.run(prepared, &error);
    require(lease != nullptr, error.message.empty() ? "RCAS-disabled zero encode" : error.message.c_str());
    require(readRGBA8(device, transfer, resources.output) == unsharpened,
            "disabled sharpening ignores the stored in-range sharpness value");

    writeRGBA8(device, transfer, resources.output, sentinelBytes());
    operations.colorTransfer = ColorTransfer::PQ;
    prepared = feature->prepare(frame, textures, &error, operations);
    require(prepared != nullptr, error.message.empty() ? "PQ prepare" : error.message.c_str());
    lease = runner.run(prepared, &error);
    require(lease != nullptr, error.message.empty() ? "PQ encode" : error.message.c_str());
    const std::vector<unsigned char> pq = readRGBA8(device, transfer, resources.output);
    require(pq != sentinelBytes(), "PQ path replaces caller output sentinel");
    require(pq != unsharpened, "PQ and sRGB transfer outputs differ observably");

    [composition release];
    [reactive release];
    std::puts("FSR_OPERATIONS_PASS transfer=srgb+pq mask=max rcas=off+on exposure=preserved");
}


std::pair<NSUInteger, NSUInteger> findExtentPair(id<MTLDevice> device) API_AVAILABLE(macos(27.0)) {
    const float minScale = [MTLFXTemporalScalerDescriptor
        supportedInputContentMinScaleForDevice:device];
    const float maxScale = [MTLFXTemporalScalerDescriptor
        supportedInputContentMaxScaleForDevice:device];
    for (NSUInteger larger = kOutput - 1; larger > 16; --larger) {
        const float largerScale = static_cast<float>(kOutput) / static_cast<float>(larger);
        if (largerScale < minScale || largerScale > maxScale) continue;
        for (NSUInteger smaller = 17; smaller < larger; ++smaller) {
            const float smallerScale = static_cast<float>(kOutput) / static_cast<float>(smaller);
            if (smallerScale >= minScale && smallerScale <= maxScale)
                return {larger, smaller};
        }
    }
    require(false, "device supports two legal distinct input extents");
    return {};
}

FrameInfo makeExtentFrame(Resources& resources, NSUInteger width, NSUInteger height,
                          bool lowResolutionMotion) {
    FrameInfo frame{};
    frame.color = reinterpret_cast<void*>(resources.color);
    frame.depth = reinterpret_cast<void*>(resources.depth);
    frame.motionVectors = reinterpret_cast<void*>(resources.motion);
    frame.output = reinterpret_cast<void*>(resources.output);
    frame.exposureTexture = {reinterpret_cast<void*>(resources.exposure), true};
    frame.inputContent = {static_cast<std::uint32_t>(width), static_cast<std::uint32_t>(height)};
    frame.colorRect = {0, 0, static_cast<std::uint32_t>(width), static_cast<std::uint32_t>(height)};
    frame.depthRect = frame.colorRect;
    frame.reactiveRect = frame.colorRect;
    frame.motionRect = lowResolutionMotion
        ? frame.colorRect
        : yaagl::pso::metalfx::Rect{static_cast<std::uint32_t>(kOutputX),
                                    static_cast<std::uint32_t>(kOutputY),
                                    static_cast<std::uint32_t>(kOutput),
                                    static_cast<std::uint32_t>(kOutput)};
    frame.outputRect = {static_cast<std::uint32_t>(kOutputX), static_cast<std::uint32_t>(kOutputY),
                        static_cast<std::uint32_t>(kOutput), static_cast<std::uint32_t>(kOutput)};
    frame.jitterOffsetX = {0.125f, true};
    frame.jitterOffsetY = {-0.25f, true};
    frame.motionVectorScaleX = {static_cast<float>(width), true};
    frame.motionVectorScaleY = {static_cast<float>(height), true};
    frame.preExposure = {1.0f, true};
    frame.resetHistory = {false, true};
    frame.exposureMode = ExposureMode::Texture;
    return frame;
}

void fillExtentInputs(Resources& resources, NSUInteger activeWidth, NSUInteger activeHeight,
                     bool lowResolutionMotion, unsigned poisonVariant) {
    const bool alternatePoison = (poisonVariant & 1u) != 0;
    const unsigned char poisonRed = alternatePoison ? 0 : 255;
    const unsigned char poisonGreen = alternatePoison ? 255 : 0;
    const unsigned char poisonBlue = alternatePoison ? 0 : 255;
    const float poisonDepth = alternatePoison ? 0.03f : 0.97f;
    const float poisonMotion = alternatePoison ? -16.0f : 16.0f;
    const NSUInteger backing = resources.capacity;
    std::vector<unsigned char> color(backing * backing * 4);
    std::vector<float> depth(backing * backing, poisonDepth);
    for (NSUInteger y = 0; y < backing; ++y) {
        for (NSUInteger x = 0; x < backing; ++x) {
            const std::size_t offset = (y * backing + x) * 4;
            if (x < activeWidth && y < activeHeight) {
                color[offset + 0] = static_cast<unsigned char>(32 + (x * 13 + y * 3) % 192);
                color[offset + 1] = static_cast<unsigned char>(24 + (x * 5 + y * 11) % 208);
                color[offset + 2] = static_cast<unsigned char>(40 + (x * 7 + y * 17) % 184);
                color[offset + 3] = 255;
                const float denominator = static_cast<float>(std::max<NSUInteger>(
                    1, activeWidth + activeHeight - 2));
                depth[y * backing + x] = 0.15f + 0.7f * static_cast<float>(x + y) / denominator;
            } else {
                color[offset + 0] = poisonRed;
                color[offset + 1] = poisonGreen;
                color[offset + 2] = poisonBlue;
                color[offset + 3] = 255;
            }
        }
    }
    [resources.color replaceRegion:MTLRegionMake2D(0, 0, backing, backing) mipmapLevel:0
                         withBytes:color.data() bytesPerRow:backing * 4];
    [resources.depth replaceRegion:MTLRegionMake2D(0, 0, backing, backing) mipmapLevel:0
                         withBytes:depth.data() bytesPerRow:backing * sizeof(float)];

    const NSUInteger motionWidth = resources.motion.width;
    const NSUInteger motionHeight = resources.motion.height;
    std::vector<_Float16> motion(motionWidth * motionHeight * 2);
    const NSUInteger motionX = lowResolutionMotion ? 0 : kOutputX;
    const NSUInteger motionY = lowResolutionMotion ? 0 : kOutputY;
    const NSUInteger activeMotionWidth = lowResolutionMotion ? activeWidth : kOutput;
    const NSUInteger activeMotionHeight = lowResolutionMotion ? activeHeight : kOutput;
    for (NSUInteger y = 0; y < motionHeight; ++y) {
        for (NSUInteger x = 0; x < motionWidth; ++x) {
            const bool active = x >= motionX && x < motionX + activeMotionWidth &&
                                y >= motionY && y < motionY + activeMotionHeight;
            const float vx = active ? 0.002f * (static_cast<float>(x % 9) - 4.0f)
                                    : poisonMotion;
            const float vy = active ? 0.002f * (static_cast<float>(y % 11) - 5.0f)
                                    : -poisonMotion;
            const std::size_t offset = (y * motionWidth + x) * 2;
            motion[offset + 0] = _Float16(vx);
            motion[offset + 1] = _Float16(vy);
        }
    }
    [resources.motion replaceRegion:MTLRegionMake2D(0, 0, motionWidth, motionHeight)
                         mipmapLevel:0 withBytes:motion.data()
                         bytesPerRow:motionWidth * sizeof(_Float16) * 2];
    const float exposure = 1.0f;
    [resources.exposure replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0
                           withBytes:&exposure bytesPerRow:sizeof(exposure)];
}

std::shared_ptr<const ExecutionLease> encodeExtentFrame(
    id<MTLDevice> device, id<MTLCommandQueue> transfer, Feature& feature,
    Resources& resources, const FrameInfo& frame, const FrameOperations& operations,
    CommandMode mode, LegacyRunner* legacy, Metal4Runner* metal4,
    bool verifyFullOutput = true, TemporalOutputInfo* outputInfo = nullptr,
    id<MTLFXTemporalScalerBase>* observeScaler = nullptr) {
    writeRGBA8(device, transfer, resources.output, sentinelBytes());
    Error error;
    auto prepared = feature.prepare(frame, makeTextureSet(resources), &error, operations);
    require(prepared != nullptr,
            error.message.empty() ? "dynamic-extent preparation" : error.message.c_str());
    if (outputInfo) *outputInfo = prepared->temporalOutputInfo();
    if (observeScaler) {
        const std::size_t captures = captureCount();
        require(captures != 0, "first dynamic-extent scaler capture");
        *observeScaler = reinterpret_cast<id<MTLFXTemporalScalerBase>>(
            captureAt(captures - 1).scaler);
        installScalerObservers(*observeScaler);
    }
    auto lease = runPrepared(mode, legacy, metal4, prepared, &error);
    require(lease != nullptr,
            error.message.empty() ? "dynamic-extent encode" : error.message.c_str());
    if (verifyFullOutput)
        verifyOutputSentinel(readRGBA8(device, transfer, resources.output),
                             resources.output.width, resources.output.height);
    return lease;
}

void testInputExtentReuse(id<MTLDevice> device, id compiler,
                          id<MTLCommandQueue> transfer, CommandMode mode,
                          bool lowResolutionMotion,
                          bool transferColor = false) API_AVAILABLE(macos(27.0)) {
    const auto [larger, smaller] = findExtentPair(device);
    CreateInfo create = makeCreateInfo();
    create.input = {static_cast<std::uint32_t>(larger), static_cast<std::uint32_t>(larger)};
    FrameOperations operations{};
    if (transferColor) operations.colorTransfer = ColorTransfer::SRGB;
    if (!lowResolutionMotion)
        create.featureFlags.value &= ~static_cast<std::uint32_t>(FeatureFlagMVLowRes);
    CreateContext context{reinterpret_cast<void*>(device),
                          mode == CommandMode::Metal4 ? reinterpret_cast<void*>(compiler) : nullptr,
                          mode};
    Error error;
    auto feature = Feature::create(context, create, &error);
    require(feature != nullptr, error.message.empty() ? "extent-reuse feature" : error.message.c_str());
    Resources resources = makeResources(device, larger, MTLStorageModeShared);
    if (!lowResolutionMotion) {
        [resources.motion release];
        resources.motion = makeTexture(device, MTLPixelFormatRG16Float,
                                       kOutputBacking, kOutputBacking,
                                       MTLStorageModeShared, MTLTextureUsageShaderRead);
    }
    std::unique_ptr<LegacyRunner> legacy;
    std::unique_ptr<Metal4Runner> metal4;
    if (mode == CommandMode::Legacy) legacy = std::make_unique<LegacyRunner>(device);
    else if (@available(macOS 26.0, *)) metal4 = std::make_unique<Metal4Runner>(device);

    const std::size_t captureBase = captureCount();
    fillExtentInputs(resources, larger, larger, lowResolutionMotion);
    const FrameInfo largeFrame = makeExtentFrame(resources, larger, larger, lowResolutionMotion);
    id<MTLFXTemporalScalerBase> scaler = nil;
    auto largeLease = encodeExtentFrame(device, transfer, *feature, resources, largeFrame,
                                        operations, mode, legacy.get(), metal4.get(), true,
                                        nullptr, &scaler);
    require(largeLease->effectiveReset() && !largeLease->generationInitialized(),
            "initial capacity frame resets its fresh generation");
    require(captureCount() == captureBase + 1, "initial extent creates one scaler");
    FactoryCapture largeCapture = captureAt(captureBase);
    require(largeCapture.inputWidth == larger && largeCapture.inputHeight == larger &&
            largeCapture.outputWidth == kOutput && largeCapture.outputHeight == kOutput,
            "first descriptor uses the observed active extent, not feature maximum");
    require(scaler == reinterpret_cast<id<MTLFXTemporalScalerBase>>(largeCapture.scaler),
            "pre-encode reset observer follows the captured scaler");
    bool resetValue = false;
    require(observedBool(scaler, &gObservedResetKey, resetValue) && resetValue,
            "initial fresh generation reset reaches MetalFX");
    largeLease.reset();

    fillExtentInputs(resources, smaller, smaller, lowResolutionMotion);
    const FrameInfo smallFrame = makeExtentFrame(resources, smaller, smaller, lowResolutionMotion);
    auto smallLease = encodeExtentFrame(device, transfer, *feature, resources, smallFrame,
                                        operations, mode, legacy.get(), metal4.get());
    require(captureCount() == captureBase + 1 &&
            smallLease->scaler() == reinterpret_cast<void*>(scaler),
            "smaller active extent reuses descriptor-capacity scaler");
    require(smallLease->effectiveReset() && smallLease->generationInitialized(),
            "changing active extent resets reused temporal history");
    require(observedBool(scaler, &gObservedResetKey, resetValue) && resetValue,
            "input-size reset reaches MetalFX");
    if (@available(macOS 27.0, *)) {
        require(largeCapture.outputMotion == !lowResolutionMotion,
                "descriptor preserves low/display-resolution motion mode");
    }
    require(scaler.motionTexture.width == (lowResolutionMotion ? larger : kOutput) &&
            scaler.motionTexture.height == (lowResolutionMotion ? larger : kOutput),
            "bound motion texture matches its descriptor capacity");
    const std::vector<unsigned char> reusedSmallBytes =
        readRGBA8(device, transfer, resources.output);
    if (!transferColor)
        verifyGpuEdgeStagingMatchesCpu(device, transfer, scaler, resources,
                                       smaller, smaller, larger, lowResolutionMotion);
    smallLease.reset();

    fillExtentInputs(resources, smaller, smaller, lowResolutionMotion, 1);
    FrameInfo alternatePoisonFrame =
        makeExtentFrame(resources, smaller, smaller, lowResolutionMotion);
    alternatePoisonFrame.resetHistory = {true, true};
    auto alternatePoisonLease = encodeExtentFrame(
        device, transfer, *feature, resources, alternatePoisonFrame,
        operations, mode, legacy.get(), metal4.get());
    require(alternatePoisonLease->effectiveReset() &&
            alternatePoisonLease->scaler() == reinterpret_cast<void*>(scaler),
            "poison-swap frame resets the same retained-capacity scaler");
    const std::vector<unsigned char> alternatePoisonBytes =
        readRGBA8(device, transfer, resources.output);
    std::size_t poisonDifferentPixels = 0;
    unsigned poisonMaxDelta = 0;
    std::uint64_t poisonAbsoluteDelta = 0;
    for (NSUInteger y = kOutputY; y < kOutputY + kOutput; ++y) {
        for (NSUInteger x = kOutputX; x < kOutputX + kOutput; ++x) {
            const std::size_t offset = (y * resources.output.width + x) * 4;
            unsigned pixelDelta = 0;
            for (std::size_t channel = 0; channel < 4; ++channel) {
                const unsigned delta = static_cast<unsigned>(std::abs(
                    static_cast<int>(alternatePoisonBytes[offset + channel]) -
                    static_cast<int>(reusedSmallBytes[offset + channel])));
                pixelDelta = std::max(pixelDelta, delta);
                poisonMaxDelta = std::max(poisonMaxDelta, delta);
                poisonAbsoluteDelta += delta;
            }
            if (pixelDelta != 0) ++poisonDifferentPixels;
        }
    }
    const double meanPoisonDelta = static_cast<double>(poisonAbsoluteDelta) /
        static_cast<double>(kOutput * kOutput * 4);
    std::printf("EXTENT_POISON_COMPARE mode=%s motion=%s color_transfer=%s differing_pixels=%zu/%zu max_byte_delta=%u mean_byte_delta_levels=%.6f mean_normalized_delta=%.9f\n",
                mode == CommandMode::Metal4 ? "metal4" : "legacy",
                lowResolutionMotion ? "low" : "display",
                transferColor ? "sRGB" : "none", poisonDifferentPixels,
                static_cast<std::size_t>(kOutput * kOutput), poisonMaxDelta,
                meanPoisonDelta, meanPoisonDelta / 255.0);
    require(alternatePoisonBytes == reusedSmallBytes,
            "changing only poisoned inactive padding leaves reset output bit-identical");
    std::puts("EXTENT_POISON_INVARIANCE_PASS active_content=identical reset=1 output=bit-exact");
    alternatePoisonLease.reset();

    CreateInfo freshCreate = create;
    freshCreate.input = {static_cast<std::uint32_t>(smaller),
                         static_cast<std::uint32_t>(smaller)};
    auto freshFeature = Feature::create(context, freshCreate, &error);
    require(freshFeature != nullptr,
            error.message.empty() ? "fresh exact-small feature" : error.message.c_str());
    Resources freshResources = makeResources(device, larger, MTLStorageModeShared);
    if (!lowResolutionMotion) {
        [freshResources.motion release];
        freshResources.motion = makeTexture(device, MTLPixelFormatRG16Float,
                                            kOutputBacking, kOutputBacking,
                                            MTLStorageModeShared, MTLTextureUsageShaderRead);
    }
    fillExtentInputs(freshResources, smaller, smaller, lowResolutionMotion);
    const std::size_t freshCaptureIndex = captureCount();
    auto freshSmallLease = encodeExtentFrame(
        device, transfer, *freshFeature, freshResources,
        makeExtentFrame(freshResources, smaller, smaller, lowResolutionMotion),
        operations, mode, legacy.get(), metal4.get());
    require(freshSmallLease->effectiveReset() && !freshSmallLease->generationInitialized(),
            "fresh exact-small reference begins with reset history");
    require(captureCount() == freshCaptureIndex + 1 &&
            captureAt(freshCaptureIndex).inputWidth == smaller &&
            captureAt(freshCaptureIndex).inputHeight == smaller,
            "fresh reference descriptor uses exact smaller capacity");
    id<MTLFXTemporalScalerBase> freshScaler =
        reinterpret_cast<id<MTLFXTemporalScalerBase>>(captureAt(freshCaptureIndex).scaler);
    installScalerObservers(freshScaler);
    require(observedBool(freshScaler, &gObservedResetKey, resetValue) && resetValue,
            "fresh exact-small reset reaches MetalFX");
    const std::vector<unsigned char> freshSmallBytes =
        readRGBA8(device, transfer, freshResources.output);
    std::size_t differingPixels = 0;
    unsigned maximumDifference = 0;
    std::uint64_t absoluteDifference = 0;
    for (NSUInteger y = kOutputY; y < kOutputY + kOutput; ++y) {
        for (NSUInteger x = kOutputX; x < kOutputX + kOutput; ++x) {
            const std::size_t offset = (y * resources.output.width + x) * 4;
            unsigned pixelDifference = 0;
            for (std::size_t channel = 0; channel < 4; ++channel) {
                const unsigned difference = static_cast<unsigned>(std::abs(
                    static_cast<int>(reusedSmallBytes[offset + channel]) -
                    static_cast<int>(freshSmallBytes[offset + channel])));
                pixelDifference = std::max(pixelDifference, difference);
                maximumDifference = std::max(maximumDifference, difference);
                absoluteDifference += difference;
            }
            if (pixelDifference != 0) ++differingPixels;
        }
    }
    const double meanChannelDifference = static_cast<double>(absoluteDifference) /
        static_cast<double>(kOutput * kOutput * 4);
    std::printf("EXTENT_FRESH_CAPACITY_MEASUREMENT mode=%s motion=%s color_transfer=%s differing_pixels=%zu/%zu max_byte_delta=%u mean_byte_delta_levels=%.6f mean_normalized_delta=%.9f hashes=%016llx/%016llx color_direct=%d motion=%zux%zu acceptance=measurement_only\n",
                mode == CommandMode::Metal4 ? "metal4" : "legacy",
                lowResolutionMotion ? "low" : "display",
                transferColor ? "sRGB" : "none", differingPixels,
                static_cast<std::size_t>(kOutput * kOutput), maximumDifference,
                meanChannelDifference, meanChannelDifference / 255.0,
                static_cast<unsigned long long>(hashBytes(reusedSmallBytes)),
                static_cast<unsigned long long>(hashBytes(freshSmallBytes)),
                scaler.colorTexture == resources.color,
                scaler.motionTexture.width, scaler.motionTexture.height);
    freshSmallLease.reset();

    fillExtentInputs(resources, smaller, smaller, lowResolutionMotion);
    auto stableSmallLease = encodeExtentFrame(
        device, transfer, *feature, resources,
        makeExtentFrame(resources, smaller, smaller, lowResolutionMotion),
        operations, mode, legacy.get(), metal4.get());
    require(!stableSmallLease->effectiveReset() && stableSmallLease->generationInitialized(),
            "stable active extent preserves temporal history");
    require(captureCount() == freshCaptureIndex + 1,
            "stable smaller extent does not create another scaler");
    stableSmallLease.reset();

    fillExtentInputs(resources, larger, larger, lowResolutionMotion);
    auto returnedLargeLease = encodeExtentFrame(
        device, transfer, *feature, resources,
        makeExtentFrame(resources, larger, larger, lowResolutionMotion),
        operations, mode, legacy.get(), metal4.get());
    require(returnedLargeLease->effectiveReset() && returnedLargeLease->generationInitialized(),
            "returning to a prior extent resets reused temporal history");
    require(captureCount() == freshCaptureIndex + 1 &&
            returnedLargeLease->scaler() == reinterpret_cast<void*>(scaler),
            "large-small-large sequence retains one scaler generation");
    require(observedBool(scaler, &gObservedResetKey, resetValue) && resetValue,
            "return-to-large history reset reaches MetalFX");
    returnedLargeLease.reset();

    if (!transferColor) {
        fillExtentInputs(resources, smaller, smaller, lowResolutionMotion);
        verifyDirectExtentParity(device, compiler, transfer, mode, legacy.get(), metal4.get(),
                                 resources, larger, smaller, smaller, lowResolutionMotion,
                                 reusedSmallBytes, freshSmallBytes);
    }

    std::printf("INPUT_EXTENT_REUSE_PASS mode=%s motion=%s color_transfer=%s extents=%zux%zu->%zux%zu backend_captures=2 padding=poisoned\n",
                mode == CommandMode::Metal4 ? "metal4" : "legacy",
                lowResolutionMotion ? "low" : "display",
                transferColor ? "sRGB" : "none", larger, larger, smaller, smaller);
}

void testInputCapacityGrowthAndScaleFallback(id<MTLDevice> device, id compiler,
                                             id<MTLCommandQueue> transfer,
                                             CommandMode mode) API_AVAILABLE(macos(27.0)) {
    const float minScale = [MTLFXTemporalScalerDescriptor
        supportedInputContentMinScaleForDevice:device];
    const float maxScale = [MTLFXTemporalScalerDescriptor
        supportedInputContentMaxScaleForDevice:device];
    NSUInteger large = static_cast<NSUInteger>(std::floor(
        static_cast<double>(kOutput) / static_cast<double>(minScale)));
    while (large > 16) {
        const float scale = static_cast<float>(kOutput) / static_cast<float>(large);
        if (scale >= minScale && scale <= maxScale) break;
        --large;
    }
    require(large > 16, "device supports a large legal input capacity");
    NSUInteger smaller = 0;
    for (NSUInteger candidate = large - 1; candidate > 16; --candidate) {
        const float scale = static_cast<float>(kOutput) / static_cast<float>(candidate);
        if (scale >= minScale && scale <= maxScale) {
            smaller = candidate;
            break;
        }
    }
    require(smaller > 16, "device supports mixed-axis legal input extents");
    NSUInteger cappedInput = 0;
    NSUInteger cappedOutput = 0;
    for (NSUInteger candidate = 16; candidate < large; ++candidate) {
        const double callerScale = static_cast<double>(kOutput) / candidate;
        if (callerScale <= maxScale) continue;
        const NSUInteger temporal = static_cast<NSUInteger>(std::floor(
            static_cast<double>(candidate) * static_cast<double>(maxScale)));
        const float actualScale = static_cast<float>(temporal) / static_cast<float>(candidate);
        const float highWaterScale = static_cast<float>(temporal) / static_cast<float>(large);
        if (temporal != 0 && actualScale >= minScale && actualScale <= maxScale &&
            highWaterScale < minScale) {
            cappedInput = candidate;
            cappedOutput = temporal;
            break;
        }
    }
    require(cappedInput != 0, "device scale range permits exact-cap high-water fallback");

    CreateInfo create = makeCreateInfo();
    create.input = {static_cast<std::uint32_t>(large), static_cast<std::uint32_t>(large)};
    Error error;
    CreateContext context{reinterpret_cast<void*>(device),
                          mode == CommandMode::Metal4 ? reinterpret_cast<void*>(compiler) : nullptr,
                          mode};
    auto feature = Feature::create(context, create, &error);
    require(feature != nullptr,
            error.message.empty() ? "capacity-growth feature" : error.message.c_str());
    Resources resources = makeResources(device, large, MTLStorageModeShared);
    std::unique_ptr<LegacyRunner> legacy;
    std::unique_ptr<Metal4Runner> metal4;
    if (mode == CommandMode::Legacy) legacy = std::make_unique<LegacyRunner>(device);
    else if (@available(macOS 26.0, *)) metal4 = std::make_unique<Metal4Runner>(device);

    FrameOperations operations{};
    operations.capOutputToTemporalMaxScale = true;
    const std::size_t captureBase = captureCount();
    fillExtentInputs(resources, large, smaller, true);
    auto firstLease = encodeExtentFrame(
        device, transfer, *feature, resources,
        makeExtentFrame(resources, large, smaller, true), operations,
        mode, legacy.get(), metal4.get());
    require(captureCount() == captureBase + 1 &&
            captureAt(captureBase).inputWidth == large &&
            captureAt(captureBase).inputHeight == smaller,
            "first generation uses observed mixed input capacity, not create maximum");
    id<MTLFXTemporalScalerBase> firstScaler =
        reinterpret_cast<id<MTLFXTemporalScalerBase>>(captureAt(captureBase).scaler);
    installScalerObservers(firstScaler);
    firstLease.reset();

    fillExtentInputs(resources, smaller, large, true);
    auto grownLease = encodeExtentFrame(
        device, transfer, *feature, resources,
        makeExtentFrame(resources, smaller, large, true), operations,
        mode, legacy.get(), metal4.get());
    require(captureCount() == captureBase + 2 &&
            captureAt(captureBase + 1).inputWidth == large &&
            captureAt(captureBase + 1).inputHeight == large,
            "componentwise capacity growth creates one square high-water generation");
    require(grownLease->effectiveReset() && !grownLease->generationInitialized(),
            "capacity growth starts clean temporal history");
    id<MTLFXTemporalScalerBase> grownScaler =
        reinterpret_cast<id<MTLFXTemporalScalerBase>>(captureAt(captureBase + 1).scaler);
    installScalerObservers(grownScaler);
    grownLease.reset();

    fillExtentInputs(resources, cappedInput, cappedInput, true);
    TemporalOutputInfo outputInfo;
    auto fallbackLease = encodeExtentFrame(
        device, transfer, *feature, resources,
        makeExtentFrame(resources, cappedInput, cappedInput, true), operations,
        mode, legacy.get(), metal4.get(), false, &outputInfo);
    require(captureCount() == captureBase + 3,
            "output-cap change recreates scaler with a scale-compatible input capacity");
    const FactoryCapture fallbackCapture = captureAt(captureBase + 2);
    require(fallbackCapture.inputWidth == cappedInput &&
            fallbackCapture.inputHeight == cappedInput &&
            fallbackCapture.outputWidth == cappedOutput &&
            fallbackCapture.outputHeight == cappedOutput,
            "scale-incompatible mixed high-water falls back to exact active extent");
    require(fallbackLease->effectiveReset() && !fallbackLease->generationInitialized(),
            "exact-cap fallback starts clean temporal history");
    require(outputInfo.width == cappedOutput && outputInfo.height == cappedOutput &&
            outputInfo.placementX == (kOutput - cappedOutput) / 2 &&
            outputInfo.placementY == (kOutput - cappedOutput) / 2,
            "exact-cap fallback retains centered temporal output placement");
    id<MTLFXTemporalScalerBase> fallbackScaler =
        reinterpret_cast<id<MTLFXTemporalScalerBase>>(fallbackCapture.scaler);
    installScalerObservers(fallbackScaler);
    bool resetValue = false;
    require(observedBool(fallbackScaler, &gObservedResetKey, resetValue) && resetValue,
            "exact-cap fallback reset reaches MetalFX");
    const auto outputBytes = readRGBA8(device, transfer, resources.output);
    std::size_t changedInside = 0;
    for (NSUInteger y = 0; y < resources.output.height; ++y) {
        for (NSUInteger x = 0; x < resources.output.width; ++x) {
            const bool inside = x >= kOutputX && x < kOutputX + kOutput &&
                                y >= kOutputY && y < kOutputY + kOutput;
            const std::size_t offset = (y * resources.output.width + x) * 4;
            const bool sentinel = outputBytes[offset] == kSentinel[0] &&
                outputBytes[offset + 1] == kSentinel[1] &&
                outputBytes[offset + 2] == kSentinel[2] &&
                outputBytes[offset + 3] == kSentinel[3];
            if (!inside) require(sentinel, "scale-fallback leaves output outside subrect sentinel");
            if (inside && !sentinel) ++changedInside;
        }
    }
    require(changedInside > 0, "scale-fallback updates requested output subrect");
    fallbackLease.reset();
    std::printf("INPUT_CAPACITY_GROWTH_FALLBACK_PASS mode=%s mixed=%zux%zu->%zux%zu capped=%zux%zu output=%zux%zu\n",
                mode == CommandMode::Metal4 ? "metal4" : "legacy",
                large, smaller, smaller, large, cappedInput, cappedInput, cappedOutput, cappedOutput);
}

void testDisplayResolutionMotionMetal4(id<MTLDevice> device, id<MTL4Compiler> compiler,
                                       id<MTLCommandQueue> transfer) API_AVAILABLE(macos(26.0)) {
    CreateInfo create = makeCreateInfo();
    create.featureFlags.value &= ~static_cast<std::uint32_t>(FeatureFlagMVLowRes);
    Error error;
    auto feature = Feature::create(
        {reinterpret_cast<void*>(device), reinterpret_cast<void*>(compiler), CommandMode::Metal4},
        create, &error);
    require(feature != nullptr,
            error.message.empty() ? "display-resolution motion feature" : error.message.c_str());

    Resources resources = makeResources(device, 80, MTLStorageModeShared);
    fillInputs(resources, 2);
    [resources.motion release];
    resources.motion = makeTexture(device, MTLPixelFormatRG16Float,
                                   kOutputBacking, kOutputBacking,
                                   MTLStorageModeShared, MTLTextureUsageShaderRead);
    std::vector<_Float16> motion(kOutputBacking * kOutputBacking * 2, _Float16(0));
    [resources.motion replaceRegion:MTLRegionMake2D(0, 0, kOutputBacking, kOutputBacking)
                         mipmapLevel:0 withBytes:motion.data()
                         bytesPerRow:kOutputBacking * sizeof(_Float16) * 2];
    writeRGBA8(device, transfer, resources.output, sentinelBytes());

    FrameInfo frame = makeFrame(resources, 2, true);
    frame.motionRect = frame.outputRect;
    TextureSet textures = makeTextureSet(resources);
    const std::size_t captureBase = captureCount();
    auto prepared = feature->prepare(frame, textures, &error);
    require(prepared != nullptr,
            error.message.empty() ? "display-resolution motion prepare" : error.message.c_str());
    Metal4Runner runner(device);
    auto lease = runner.run(prepared, &error);
    require(lease != nullptr,
            error.message.empty() ? "display-resolution motion encode" : error.message.c_str());

    FactoryCapture capture = captureAt(captureBase);
    require(capture.inputWidth == kContent && capture.inputHeight == kContent &&
            capture.outputWidth == kOutput && capture.outputHeight == kOutput,
            "display-resolution motion descriptor uses active dimensions");
    if (@available(macOS 27.0, *))
        require(capture.outputMotion, "display-resolution motion mode reaches MetalFX");
    id<MTLFXTemporalScalerBase> scaler =
        reinterpret_cast<id<MTLFXTemporalScalerBase>>(capture.scaler);
    require(scaler.motionTexture != resources.motion &&
            scaler.motionTexture.width == kOutput && scaler.motionTexture.height == kOutput,
            "display-resolution motion active rect is normalized into exact scratch");
    verifyOutputSentinel(readRGBA8(device, transfer, resources.output),
                         resources.output.width, resources.output.height);
    std::puts("DISPLAY_RESOLUTION_MOTION_PASS input=64x64 motion=128x128 output=128x128 backing=140x140");
}

void testFeatureReleaseBeforeSubmitMetal4(id<MTLDevice> device, id<MTL4Compiler> compiler,
                                          id<MTLCommandQueue> transfer) API_AVAILABLE(macos(26.0)) {
    CreateInfo create = makeCreateInfo();
    Error error;
    auto feature = Feature::create({reinterpret_cast<void*>(device), reinterpret_cast<void*>(compiler),
                                    CommandMode::Metal4}, create, &error);
    require(feature != nullptr, "release-before-submit feature");
    Resources resources = makeResources(device, 80, MTLStorageModeShared);
    fillInputs(resources, 0);
    writeRGBA8(device, transfer, resources.output, sentinelBytes());
    auto prepared = feature->prepare(makeFrame(resources, 0, true), makeTextureSet(resources), &error);
    require(prepared != nullptr, "release-before-submit prepared frame");

    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
    id<MTL4CommandAllocator> allocator = [device newCommandAllocator];
    id<MTL4CommandBuffer> command = [device newCommandBuffer];
    id<MTLFence> fence = [device newFence];
    require(queue && allocator && command && fence, "release-before-submit Metal4 objects");
    [command beginCommandBufferWithAllocator:allocator];
    id<MTL4ComputeCommandEncoder> producer = [command computeCommandEncoder];
    [producer updateFence:fence afterEncoderStages:MTLStageDispatch];
    [producer endEncoding];
    std::shared_ptr<const ExecutionLease> lease;
    require(prepared->encode(reinterpret_cast<void*>(command), reinterpret_cast<void*>(fence),
                             lease, &error), "release-before-submit encode");
    require(lease != nullptr, "release-before-submit lease");
    [command endCommandBuffer];

    feature.reset(); // PreparedFrame owns the scaler generation independently.

    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError* gpuError = nil;
    MTL4CommitOptions* options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        gpuError = [feedback.error retain];
        dispatch_semaphore_signal(done);
    }];
    id<MTL4CommandBuffer> batch[] = {command};
    [queue commit:batch count:1 options:options];
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
            "release-before-submit completion timeout");
    require(gpuError == nil, "Feature release before submit keeps GPU resources alive");
    const auto bytes = readRGBA8(device, transfer, resources.output);
    verifyOutputSentinel(bytes, resources.output.width, resources.output.height);

    [gpuError release];
    [options release];
    dispatch_release(done);
    [fence release];
    [command release];
    [allocator release];
    [queue release];
}

void testMetal4InflightReplay(id<MTLDevice> device, id<MTL4Compiler> compiler,
                              id<MTLCommandQueue> transfer) API_AVAILABLE(macos(26.0)) {
    CreateInfo create = makeCreateInfo();
    Error error;
    auto feature = Feature::create({reinterpret_cast<void*>(device), reinterpret_cast<void*>(compiler),
                                    CommandMode::Metal4}, create, &error);
    require(feature != nullptr, "inflight replay feature");
    Resources resources = makeResources(device, 80, MTLStorageModeShared);
    fillInputs(resources, 1);
    writeRGBA8(device, transfer, resources.output, sentinelBytes());
    auto prepared = feature->prepare(makeFrame(resources, 1, false), makeTextureSet(resources), &error);
    require(prepared != nullptr, "inflight replay prepared frame");

    id<MTL4CommandQueue> queue = [device newMTL4CommandQueue];
    require(queue != nil, "inflight replay queue");
    std::array<id<MTL4CommandAllocator>, 2> allocators = {
        [device newCommandAllocator], [device newCommandAllocator]};
    std::array<id<MTL4CommandBuffer>, 2> commands = {
        [device newCommandBuffer], [device newCommandBuffer]};
    std::array<id<MTLFence>, 2> fences = {[device newFence], [device newFence]};
    std::array<std::shared_ptr<const ExecutionLease>, 2> leases{};
    for (unsigned i = 0; i < 2; ++i) {
        require(allocators[i] && commands[i] && fences[i], "inflight replay slot");
        [commands[i] beginCommandBufferWithAllocator:allocators[i]];
        id<MTL4ComputeCommandEncoder> producer = [commands[i] computeCommandEncoder];
        [producer updateFence:fences[i] afterEncoderStages:MTLStageDispatch];
        [producer endEncoding];
        require(prepared->encode(reinterpret_cast<void*>(commands[i]),
                                 reinterpret_cast<void*>(fences[i]), leases[i], &error),
                "inflight replay encode");
        require(leases[i] != nullptr, "inflight replay lease");
        [commands[i] endCommandBuffer];
    }
    require(leases[0].get() != leases[1].get(), "each in-flight replay receives a unique ExecutionLease");

    std::array<dispatch_semaphore_t, 2> done = {
        dispatch_semaphore_create(0), dispatch_semaphore_create(0)};
    std::array<NSError*, 2> errors = {nil, nil};
    std::array<MTL4CommitOptions*, 2> options = {[MTL4CommitOptions new], [MTL4CommitOptions new]};
    for (unsigned i = 0; i < 2; ++i) {
        NSError** errorSlot = &errors[i];
        dispatch_semaphore_t doneSlot = done[i];
        [options[i] addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            *errorSlot = [feedback.error retain];
            dispatch_semaphore_signal(doneSlot);
        }];
        id<MTL4CommandBuffer> batch[] = {commands[i]};
        [queue commit:batch count:1 options:options[i]];
    }
    for (unsigned i = 0; i < 2; ++i) {
        require(dispatch_semaphore_wait(done[i], dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
                "inflight replay completion timeout");
        if (errors[i]) NSLog(@"inflight replay error: %@", errors[i]);
        require(errors[i] == nil, "inflight replay GPU completion");
    }
    const auto bytes = readRGBA8(device, transfer, resources.output);
    verifyOutputSentinel(bytes, resources.output.width, resources.output.height);

    for (unsigned i = 0; i < 2; ++i) {
        [errors[i] release];
        [options[i] release];
        dispatch_release(done[i]);
        [fences[i] release];
        [commands[i] release];
        [allocators[i] release];
    }
    [queue release];
}

void testExactScaleCapGpu(id<MTLDevice> device, id<MTLCommandQueue> transfer) {
    constexpr NSUInteger inputWidth = 1280, inputHeight = 720;
    constexpr NSUInteger outputWidth = 3840, outputHeight = 2160;
    const MTLTextureUsage readUsage = MTLTextureUsageShaderRead;
    id<MTLTexture> color = makeTexture(device, MTLPixelFormatRGBA8Unorm,
                                       inputWidth, inputHeight, MTLStorageModeShared, readUsage);
    id<MTLTexture> depth = makeTexture(device, MTLPixelFormatR32Float,
                                       inputWidth, inputHeight, MTLStorageModeShared, readUsage);
    id<MTLTexture> motion = makeTexture(device, MTLPixelFormatRG16Float,
                                        inputWidth, inputHeight, MTLStorageModeShared, readUsage);
    id<MTLTexture> output = makeTexture(
        device, MTLPixelFormatRGBA8Unorm, outputWidth, outputHeight, MTLStorageModeShared,
        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget);

    std::vector<unsigned char> colorBytes(inputWidth * inputHeight * 4, 0);
    for (std::size_t i = 0; i < colorBytes.size(); i += 4) {
        colorBytes[i] = 72;
        colorBytes[i + 1] = 144;
        colorBytes[i + 2] = 216;
        colorBytes[i + 3] = 255;
    }
    std::vector<float> depthBytes(inputWidth * inputHeight, 0.5f);
    std::vector<_Float16> motionBytes(inputWidth * inputHeight * 2, _Float16(0));
    [color replaceRegion:MTLRegionMake2D(0, 0, inputWidth, inputHeight) mipmapLevel:0
               withBytes:colorBytes.data() bytesPerRow:inputWidth * 4];
    [depth replaceRegion:MTLRegionMake2D(0, 0, inputWidth, inputHeight) mipmapLevel:0
               withBytes:depthBytes.data() bytesPerRow:inputWidth * sizeof(float)];
    [motion replaceRegion:MTLRegionMake2D(0, 0, inputWidth, inputHeight) mipmapLevel:0
                withBytes:motionBytes.data() bytesPerRow:inputWidth * sizeof(_Float16) * 2];

    TextureSet textures{reinterpret_cast<void*>(color), reinterpret_cast<void*>(depth),
                        reinterpret_cast<void*>(motion), reinterpret_cast<void*>(output),
                        nullptr, nullptr, nullptr};
    FrameOperations operations{};
    operations.capOutputToTemporalMaxScale = true;
    CreateContext context{reinterpret_cast<void*>(device), nullptr, CommandMode::Legacy};
    LegacyRunner legacy(device);
    Metal4Runner* noMetal4 = nullptr;
    Error error;

    const auto makeFrameFor = [&](std::uint32_t renderWidth, std::uint32_t renderHeight,
                                  std::uint32_t callerWidth, std::uint32_t callerHeight,
                                  bool reset) {
        FrameInfo frame{};
        frame.color = reinterpret_cast<void*>(color);
        frame.depth = reinterpret_cast<void*>(depth);
        frame.motionVectors = reinterpret_cast<void*>(motion);
        frame.output = reinterpret_cast<void*>(output);
        frame.inputContent = {renderWidth, renderHeight};
            frame.colorRect = {0, 0, renderWidth, renderHeight};
        frame.depthRect = frame.colorRect;
        frame.motionRect = frame.colorRect;
        frame.reactiveRect = frame.colorRect;
        frame.outputRect = {0, 0, callerWidth, callerHeight};
        frame.jitterOffsetX = {0.0f, true};
        frame.jitterOffsetY = {0.0f, true};
        frame.motionVectorScaleX = {static_cast<float>(renderWidth), true};
        frame.motionVectorScaleY = {static_cast<float>(renderHeight), true};
        frame.preExposure = {1.0f, true};
                frame.resetHistory = {reset, true};
        frame.exposureMode = ExposureMode::None;
        return frame;
    };
    const auto makeFeatureFor = [&](std::uint32_t callerWidth, std::uint32_t callerHeight) {
        CreateInfo create{};
        create.input = {static_cast<std::uint32_t>(inputWidth),
                        static_cast<std::uint32_t>(inputHeight)};
        create.output = {callerWidth, callerHeight};
        create.featureFlags = {static_cast<std::uint32_t>(FeatureFlagMVLowRes), true};
        create.outputSubrects = {false, true};
        auto feature = Feature::create(context, create, &error);
        require(feature != nullptr, error.message.empty() ? "exact-cap feature create" : error.message.c_str());
        return feature;
    };
    const auto checkLayout = [&](std::uint32_t renderWidth, std::uint32_t renderHeight,
                                 std::uint32_t callerWidth, std::uint32_t callerHeight,
                                 TemporalOutputInfo expected) {
        auto feature = makeFeatureFor(callerWidth, callerHeight);
        auto prepared = feature->prepare(
            makeFrameFor(renderWidth, renderHeight, callerWidth, callerHeight, true),
            textures, &error, operations);
        require(prepared != nullptr, error.message.empty() ? "exact-cap layout prepare" : error.message.c_str());
        const TemporalOutputInfo actual = prepared->temporalOutputInfo();
        require(actual.width == expected.width && actual.height == expected.height &&
                actual.placementX == expected.placementX && actual.placementY == expected.placementY &&
                actual.capped == expected.capped, "resolution-independent temporal layout");
        require(actual.placementX + actual.width <= callerWidth &&
                actual.placementY + actual.height <= callerHeight,
                "centered temporal placement stays within caller output");
        const std::uint32_t right = callerWidth - actual.placementX - actual.width;
        const std::uint32_t bottom = callerHeight - actual.placementY - actual.height;
        require((right == actual.placementX || right == actual.placementX + 1) &&
                (bottom == actual.placementY || bottom == actual.placementY + 1),
                "odd centered remainder lands on right and bottom edges");
    };

    auto feature = makeFeatureFor(outputWidth, outputHeight);
    const std::size_t captureBase = captureCount();
    std::vector<unsigned char> sentinel(outputWidth * outputHeight * 4, 0x7b);
    writeRGBA8(device, transfer, output, sentinel);
    auto capped = feature->prepare(makeFrameFor(1248, 696, outputWidth, outputHeight, true),
                                   textures, &error, operations);
    require(capped != nullptr, error.message.empty() ? "4K exact-cap prepare" : error.message.c_str());
    const TemporalOutputInfo cappedInfo = capped->temporalOutputInfo();
    require(cappedInfo.width == 3744 && cappedInfo.height == 2088 &&
            cappedInfo.placementX == 48 && cappedInfo.placementY == 36 && cappedInfo.capped,
            "4K exact-cap dimensions and placement");
    auto cappedLease = runPrepared(CommandMode::Legacy, &legacy, noMetal4, capped, &error);
    require(cappedLease != nullptr, error.message.empty() ? "4K exact-cap encode" : error.message.c_str());
    auto cappedBytes = readRGBA8(device, transfer, output);
    std::size_t nonBlackContent = 0;
    for (NSUInteger y = 0; y < outputHeight; ++y) {
        for (NSUInteger x = 0; x < outputWidth; ++x) {
            const std::size_t offset = (y * outputWidth + x) * 4;
            const bool inside = x >= 48 && x < 48 + 3744 && y >= 36 && y < 36 + 2088;
            if (!inside) {
                require(cappedBytes[offset] == 0 && cappedBytes[offset + 1] == 0 &&
                        cappedBytes[offset + 2] == 0 && cappedBytes[offset + 3] == 255,
                        "4K exact-cap borders are opaque black");
            } else if (cappedBytes[offset] || cappedBytes[offset + 1] || cappedBytes[offset + 2]) {
                ++nonBlackContent;
            }
        }
    }
    require(nonBlackContent > 0, "4K exact-cap interior contains temporal output");

    operations.colorTransfer = ColorTransfer::SRGB;
    operations.sharpening = true;
    operations.sharpness = 0.5f;
    auto finished = feature->prepare(
        makeFrameFor(1248, 696, outputWidth, outputHeight, false), textures, &error, operations);
    require(finished != nullptr, "capped transfer/RCAS prepare");
    auto finishedLease = runPrepared(CommandMode::Legacy, &legacy, noMetal4, finished, &error);
    require(finishedLease != nullptr, "capped transfer/RCAS encode");
    auto finishedBytes = readRGBA8(device, transfer, output);
    for (NSUInteger y = 0; y < outputHeight; ++y) {
        for (NSUInteger x = 0; x < outputWidth; ++x) {
            if (x >= 48 && x < 48 + 3744 && y >= 36 && y < 36 + 2088) continue;
            const std::size_t offset = (y * outputWidth + x) * 4;
            require(finishedBytes[offset] == 0 && finishedBytes[offset + 1] == 0 &&
                    finishedBytes[offset + 2] == 0 && finishedBytes[offset + 3] == 255,
                    "transfer/RCAS does not process or sample across opaque black border");
        }
    }
    operations.colorTransfer = ColorTransfer::Linear;
    operations.sharpening = false;
    operations.sharpness = 0.0f;

    writeRGBA8(device, transfer, output, sentinel);
    auto full = feature->prepare(makeFrameFor(1280, 720, outputWidth, outputHeight, false),
                                 textures, &error, operations);
    require(full != nullptr, error.message.empty() ? "4K full transition prepare" : error.message.c_str());
    const TemporalOutputInfo fullInfo = full->temporalOutputInfo();
    require(fullInfo.width == outputWidth && fullInfo.height == outputHeight &&
            fullInfo.placementX == 0 && fullInfo.placementY == 0 && !fullInfo.capped,
            "transition back to full caller output");
    auto fullLease = runPrepared(CommandMode::Legacy, &legacy, noMetal4, full, &error);
    require(fullLease != nullptr && fullLease->effectiveReset(),
            "changed temporal extent creates a fresh reset generation");
    auto fullBytes = readRGBA8(device, transfer, output);
    for (const auto [x, y] : std::array<std::pair<NSUInteger, NSUInteger>, 5>{
             std::pair{NSUInteger(0), NSUInteger(0)}, {outputWidth - 1, 0},
             {0, outputHeight - 1}, {outputWidth - 1, outputHeight - 1},
             {outputWidth / 2, outputHeight / 2}}) {
        const std::size_t offset = (y * outputWidth + x) * 4;
        require(fullBytes[offset] != 0 || fullBytes[offset + 1] != 0 || fullBytes[offset + 2] != 0,
                "full-output transition removes black border");
    }
    require(captureCount() == captureBase + 2, "cap-to-full transition recreates scaler once");
    FactoryCapture cappedCapture = captureAt(captureBase);
    FactoryCapture fullCapture = captureAt(captureBase + 1);
    require(cappedCapture.outputWidth == 3744 && cappedCapture.outputHeight == 2088 &&
            fullCapture.outputWidth == outputWidth && fullCapture.outputHeight == outputHeight,
            "factory received actual capped then full temporal dimensions");

    checkLayout(640, 360, 1920, 1080, {1920, 1080, 0, 0, false});
    checkLayout(800, 450, 2560, 1440, {2400, 1350, 80, 45, true});
    checkLayout(801, 451, 2560, 1440, {2403, 1353, 78, 43, true});

    std::puts("EXACT_SCALE_CAP_PASS temporal=3744x2088 placement=48,36 caller=3840x2160 "
              "monitors=1080p,1440p,4K odd=1 transition=full");
    [output release];
    [motion release];
    [depth release];
    [color release];
}

void releaseCaptures() {
    std::lock_guard<std::mutex> lock(gCaptureMutex);
    for (FactoryCapture& capture : gCaptures) {
        [capture.scaler release];
        capture.scaler = nil;
    }
    gCaptures.clear();
    gObservedInputCount = 0;
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        // Narrow reruns cover input-extent staging without repeating unrelated cases.
        if (argc == 2 && std::strcmp(argv[1], "--edge-reuse-only") == 0) {
            if (@available(macOS 27.0, *)) {
                id<MTLDevice> device = MTLCreateSystemDefaultDevice();
                require(device != nil && [MTLFXTemporalScalerDescriptor supportsDevice:device],
                        "MetalFX temporal device for scoped edge-reuse cases");
                installFactoryCapture();
                id<MTLCommandQueue> transfer = [device newCommandQueue];
                require(transfer != nil, "scoped edge-reuse transfer queue");
                testInputExtentReuse(device, nil, transfer, CommandMode::Legacy, true);
                if (@available(macOS 26.0, *)) {
                    require([MTLFXTemporalScalerDescriptor supportsMetal4FX:device],
                            "Metal4FX supported for scoped edge-reuse cases");
                    NSError* compilerError = nil;
                    MTL4CompilerDescriptor* descriptor = [MTL4CompilerDescriptor new];
                    id<MTL4Compiler> compiler =
                        [device newCompilerWithDescriptor:descriptor error:&compilerError];
                    [descriptor release];
                    if (compilerError) NSLog(@"Metal4 compiler error: %@", compilerError);
                    require(compiler != nil, "scoped edge-reuse Metal4 compiler");
                    testInputExtentReuse(device, compiler, transfer, CommandMode::Metal4, true);
                    testInputExtentReuse(device, compiler, transfer, CommandMode::Metal4, false);
                    testInputExtentReuse(device, compiler, transfer, CommandMode::Metal4,
                                         true, true);
                    [compiler release];
                } else {
                    require(false, "Metal4FX scoped edge-reuse requires macOS 26 or newer");
                }
                releaseCaptures();
                [transfer release];
                [device release];
                std::puts("METALFX_EDGE_REUSE_ONLY_PASS");
                return 0;
            }
            require(false, "scoped edge-reuse cases require macOS 27 or newer");
            return 1;
        }
        require(argc == 1, "unknown MetalFX backend test argument");
        if (@available(macOS 27.0, *)) {
        } else {
            require(false, "SDK27 runtime required for full offset contract test");
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        require(device != nil && [MTLFXTemporalScalerDescriptor supportsDevice:device],
                "MetalFX temporal device");
        installFactoryCapture();

        id<MTLCommandQueue> transfer = [device newCommandQueue];
        require(transfer != nil, "transfer queue");

        unsigned afterLegacyObserved = gObservationBegins;
        if ([device supportsFamily:static_cast<MTLGPUFamily>(1010)]) {
            Error legacyError;
            auto legacyFeature = Feature::create(
                {reinterpret_cast<void*>(device), nullptr, CommandMode::Legacy},
                makeCreateInfo(), &legacyError);
            require(legacyFeature != nullptr, "Apple10 legacy failure feature");
            Resources legacyResources = makeResources(device, 80, MTLStorageModeShared);
            auto legacyPrepared = legacyFeature->prepare(
                makeFrame(legacyResources, 0, true), makeTextureSet(legacyResources),
                &legacyError);
            require(legacyPrepared && legacyError.code == ErrorCode::None,
                    "Apple10 legacy factory uses the system-default scaler");
            std::puts("LEGACY_SYSTEM_DEFAULT");
            // Apple10 normally skips Legacy encoding coverage; exercise its extent-reuse path.
            if (@available(macOS 27.0, *))
                testInputExtentReuse(device, nil, transfer, CommandMode::Legacy, true);
        } else {
            installEncodeObserver(&gTestEncodeObserver);
            gRejectNextObservation = true;
            const CaseResult legacyShared =
                runCase(device, nil, transfer, CommandMode::Legacy, MTLStorageModeShared, true);
            require(gObservationBegins > 1 && gObservationRejected == 1 &&
                    gObservationBegins == gObservationEnds + gObservationRejected && !gObservationActive,
                    "legacy observer accepted/declined begin/end pairing");
            installEncodeObserver(nullptr);
            afterLegacyObserved = gObservationBegins;
            const CaseResult legacyPrivate =
                runCase(device, nil, transfer, CommandMode::Legacy, MTLStorageModePrivate, false);
            require(gObservationBegins == afterLegacyObserved, "disabled legacy observer is not invoked");
            require(legacyShared.hashes == legacyPrivate.hashes,
                    "legacy observed Shared and unobserved Private outputs are pixel-identical");
            if (@available(macOS 27.0, *)) {
                testInputExtentReuse(device, nil, transfer, CommandMode::Legacy, true);
                testInputExtentReuse(device, nil, transfer, CommandMode::Legacy, false);
                testInputCapacityGrowthAndScaleFallback(device, nil, transfer, CommandMode::Legacy);
            }
        }

        if (@available(macOS 26.0, *)) {
            if ([MTLFXTemporalScalerDescriptor supportsMetal4FX:device]) {
                NSError* compilerError = nil;
                MTL4CompilerDescriptor* descriptor = [MTL4CompilerDescriptor new];
                id<MTL4Compiler> compiler =
                    [device newCompilerWithDescriptor:descriptor error:&compilerError];
                [descriptor release];
                if (compilerError) NSLog(@"Metal4 compiler error: %@", compilerError);
                require(compiler != nil, "Metal4 compiler");

                installEncodeObserver(&gTestEncodeObserver);
                const CaseResult metal4Shared =
                    runCase(device, compiler, transfer, CommandMode::Metal4, MTLStorageModeShared, true);
                require(gObservationBegins > afterLegacyObserved &&
                        gObservationBegins == gObservationEnds + gObservationRejected && !gObservationActive,
                        "Metal4 observer typed identity and begin/end pairing");
                installEncodeObserver(nullptr);
                const unsigned afterMetal4Observed = gObservationBegins;
                const CaseResult metal4Private =
                    runCase(device, compiler, transfer, CommandMode::Metal4, MTLStorageModePrivate, false);
                require(gObservationBegins == afterMetal4Observed, "disabled Metal4 observer is not invoked");
                require(metal4Shared.hashes == metal4Private.hashes,
                        "Metal4 observed Shared and unobserved Private outputs are pixel-identical");
                testFsrOperationsMetal4(device, compiler, transfer);
                testDisplayResolutionMotionMetal4(device, compiler, transfer);
                if (@available(macOS 27.0, *)) {
                    testInputExtentReuse(device, compiler, transfer, CommandMode::Metal4, true);
                    testInputExtentReuse(device, compiler, transfer, CommandMode::Metal4, false);
                    testInputExtentReuse(device, compiler, transfer, CommandMode::Metal4, true, true);
                    testInputCapacityGrowthAndScaleFallback(device, compiler, transfer,
                                                            CommandMode::Metal4);
                }
                releaseCaptures();
                testExactScaleCapGpu(device, transfer);
                testFeatureReleaseBeforeSubmitMetal4(device, compiler, transfer);
                testMetal4InflightReplay(device, compiler, transfer);
                [compiler release];
            } else {
                std::puts("METAL4_SKIP supportsMetal4FX=0");
            }
        }

        std::printf("METALFX_BACKEND_NATIVE_PASS captures=%zu full_offsets=1 exposure_numeric=1 "
                    "history=1 resize_generation=1 input_extent_reuse=1 capacity_growth=1 "
                    "scale_fallback=1 replay_leases=1 stale_failure=1 encode_observer=1\n",
                    captureCount());
        releaseCaptures();
        [transfer release];
        [device release];
        return 0;
    }
}
