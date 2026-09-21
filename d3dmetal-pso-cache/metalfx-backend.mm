#import "metalfx-backend.hpp"
#include "fsr-kernels.inc"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <new>
#include <utility>

namespace yaagl::pso::metalfx {
namespace {

std::atomic<const EncodeObserver*> gEncodeObserver{nullptr};

class EncodeObservationScope final {
public:
    EncodeObservationScope() noexcept
        : observer_(gEncodeObserver.load(std::memory_order_acquire)) {}
    bool enabled() const noexcept { return observer_ != nullptr; }
    void begin(const EncodeObservation& observation) noexcept {
        if (!observer_) return;
        const int saved = errno;
        @try { token_ = observer_->begin(observation); }
        @catch (id) { token_ = nullptr; } // Diagnostics must not fail rendering.
        errno = saved;
    }
    void completed() noexcept { completed_ = true; }
    ~EncodeObservationScope() {
        if (!token_ || !observer_) return;
        const int saved = errno;
        @try { observer_->end(token_, completed_); }
        @catch (id) {} // The observer owns failure reporting and GPU lifetimes.
        errno = saved;
    }
    EncodeObservationScope(const EncodeObservationScope&) = delete;
    EncodeObservationScope& operator=(const EncodeObservationScope&) = delete;
private:
    const EncodeObserver* observer_ = nullptr;
    void* token_ = nullptr;
    bool completed_ = false;
};

template <typename T>
T retainObject(T object) noexcept {
    return object ? static_cast<T>([(id)object retain]) : nil;
}

template <typename T>
void releaseObject(T& object) noexcept {
    if (!object) return;
    [(id)object release];
    object = nil;
}

void clearError(Error* error) noexcept {
    if (!error) return;
    error->code = ErrorCode::None;
    try {
        error->message.clear();
    } catch (...) {
    }
}

void setError(Error* error, ErrorCode code, const char* message) noexcept {
    if (!error) return;
    error->code = code;
    try {
        error->message = message ? message : "";
    } catch (...) {
        try {
            error->message.clear();
        } catch (...) {
        }
    }
}

bool finite(float value) noexcept {
    return std::isfinite(value);
}

id<MTLTexture> asTexture(void* value) noexcept {
    return reinterpret_cast<id<MTLTexture>>(value);
}

id<MTLDevice> asDevice(void* value) noexcept {
    return reinterpret_cast<id<MTLDevice>>(value);
}

id asCompiler(void* value) noexcept {
    return reinterpret_cast<id>(value);
}

id<MTLFence> asFence(void* value) noexcept {
    return reinterpret_cast<id<MTLFence>>(value);
}

bool sameDevice(id<MTLDevice> expected, id<MTLTexture> texture) noexcept {
    return texture && texture.device == expected;
}

bool basicTextureShape(id<MTLTexture> texture) noexcept {
    if (!texture || texture.textureType != MTLTextureType2D || texture.depth != 1 ||
        texture.arrayLength != 1 || texture.sampleCount != 1 ||
        texture.mipmapLevelCount == 0 || texture.framebufferOnly) {
        return false;
    }
    return true;
}

bool rectFits(const Rect& rect, id<MTLTexture> texture) noexcept {
    if (!texture || rect.width == 0 || rect.height == 0) return false;
    const std::uint64_t right = static_cast<std::uint64_t>(rect.x) + rect.width;
    const std::uint64_t bottom = static_cast<std::uint64_t>(rect.y) + rect.height;
    return right <= texture.width && bottom <= texture.height;
}

bool hasUsage(id<MTLTexture> texture, MTLTextureUsage usage) noexcept {
    return texture && (texture.usage & usage) == usage;
}

bool allOffsetsZero(const FrameInfo& frame) noexcept {
    return frame.colorRect.x == 0 && frame.colorRect.y == 0 &&
           frame.depthRect.x == 0 && frame.depthRect.y == 0 &&
           frame.motionRect.x == 0 && frame.motionRect.y == 0 &&
           frame.reactiveRect.x == 0 && frame.reactiveRect.y == 0 &&
           frame.outputRect.x == 0 && frame.outputRect.y == 0;
}

bool exposureShaderReadable(MTLPixelFormat format) noexcept {
    switch (format) {
    case MTLPixelFormatR8Unorm:
    case MTLPixelFormatR8Snorm:
    case MTLPixelFormatR16Unorm:
    case MTLPixelFormatR16Snorm:
    case MTLPixelFormatR16Float:
    case MTLPixelFormatR32Float:
    case MTLPixelFormatRG8Unorm:
    case MTLPixelFormatRG8Snorm:
    case MTLPixelFormatRG16Unorm:
    case MTLPixelFormatRG16Snorm:
    case MTLPixelFormatRG16Float:
    case MTLPixelFormatRG32Float:
    case MTLPixelFormatRGBA8Unorm:
    case MTLPixelFormatRGBA8Snorm:
    case MTLPixelFormatRGBA16Unorm:
    case MTLPixelFormatRGBA16Snorm:
    case MTLPixelFormatRGBA16Float:
    case MTLPixelFormatRGBA32Float:
        return true;
    default:
        return false;
    }
}

bool requiresExposureConversion(id<MTLTexture> texture) noexcept {
    return texture && (texture.pixelFormat != MTLPixelFormatR16Float ||
                       texture.width != 1 || texture.height != 1);
}

constexpr std::uint32_t kKnownFlags = FeatureFlagIsHDR | FeatureFlagMVLowRes |
                                      FeatureFlagMVJittered | FeatureFlagDepthInverted |
                                      FeatureFlagAutoExposure;

const char* kExposureKernel = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void yaagl_metalfx_exposure_r_to_r16(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]]) {
    const float exposure = source.read(uint2(0, 0)).r;
    destination.write(half4(half(exposure), half(0.0), half(0.0), half(1.0)), uint2(0, 0));
}
)METAL";

id<MTLComputePipelineState> makePipeline(id<MTLDevice> device, const char* sourceText,
                                                 NSString* functionName) noexcept {
    @try {
        NSError* error = nil;
        NSString* source = [NSString stringWithUTF8String:sourceText];
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) return nil;
        id<MTLFunction> function = [library newFunctionWithName:functionName];
        [library release];
        if (!function) return nil;
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:function error:&error];
        [function release];
        return pipeline;
    } @catch (id) {
        return nil;
    }
}

id<MTLComputePipelineState> makeExposurePipeline(id<MTLDevice> device) noexcept {
    @try {
        NSError* error = nil;
        NSString* source = [NSString stringWithUTF8String:kExposureKernel];
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) return nil;
        id<MTLFunction> function = [library newFunctionWithName:@"yaagl_metalfx_exposure_r_to_r16"];
        [library release];
        if (!function) return nil;
        id<MTLComputePipelineState> pipeline =
            [device newComputePipelineStateWithFunction:function error:&error];
        [function release];
        return pipeline;
    } @catch (id) {
        return nil;
    }
}

id<MTLTexture> makePrivateOutput(id<MTLDevice> device, id<MTLTexture> caller,
                                MTLTextureUsage requiredUsage) noexcept {
    @try {
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:caller.pixelFormat
                                                               width:caller.width
                                                              height:caller.height
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
        descriptor.usage = caller.usage | requiredUsage;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture && caller.label)
            texture.label = [caller.label stringByAppendingString:@".YAAGL.MetalFX.PrivateOutput"];
        return texture;
    } @catch (id) {
        return nil;
    }
}

bool isSrgbFormat(MTLPixelFormat format) noexcept {
    return format == MTLPixelFormatRGBA8Unorm_sRGB ||
           format == MTLPixelFormatBGRA8Unorm_sRGB;
}

MTLPixelFormat linearFormat(MTLPixelFormat format) noexcept {
    switch (format) {
    case MTLPixelFormatRGBA8Unorm_sRGB: return MTLPixelFormatRGBA8Unorm;
    case MTLPixelFormatBGRA8Unorm_sRGB: return MTLPixelFormatBGRA8Unorm;
    default: return format;
    }
}

id<MTLTexture> makeScratchTexture(id<MTLDevice> device, id<MTLTexture> source,
                                   MTLPixelFormat format, MTLTextureUsage usage,
                                   NSString* suffix, NSUInteger width = 0,
                                   NSUInteger height = 0) noexcept {
    @try {
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                               width:width ? width : source.width
                                                              height:height ? height : source.height
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
        descriptor.usage = usage;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture && source.label) texture.label = [source.label stringByAppendingString:suffix];
        return texture;
    } @catch (id) {
        return nil;
    }
}

id<MTLTexture> makeMaskTexture(id<MTLDevice> device, id<MTLTexture> source) noexcept {
    return makeScratchTexture(device, source, MTLPixelFormatR8Unorm,
                              MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
                              @".YAAGL.FSR.CombinedMask");
}

id<MTLTexture> makeExposureR16(id<MTLDevice> device) noexcept {
    @try {
        MTLTextureDescriptor* descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR16Float
                                                               width:1
                                                              height:1
                                                           mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
        descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture) texture.label = @"YAAGL MetalFX exposure R16F";
        return texture;
    } @catch (id) {
        return nil;
    }
}

id makeResidencySet(id<MTLDevice> device, const TextureSet& textures,
                    id<MTLTexture> outputTexture, id<MTLTexture> convertedExposure,
                    id<MTLTexture> linearColor, id<MTLTexture> combinedMask,
                    id<MTLBuffer> linearizeParams, id<MTLBuffer> maskParams,
                    id<MTLBuffer> finishParams) noexcept {
    if (@available(macOS 15.0, *)) {
        @try {
            MTLResidencySetDescriptor* descriptor = [MTLResidencySetDescriptor new];
            descriptor.initialCapacity = 14;
            descriptor.label = @"YAAGL MetalFX execution";
            NSError* error = nil;
            id<MTLResidencySet> residency =
                [device newResidencySetWithDescriptor:descriptor error:&error];
            [descriptor release];
            if (!residency) return nil;

            id<MTLAllocation> candidates[] = {
                asTexture(textures.color), asTexture(textures.depth), asTexture(textures.motion),
                asTexture(textures.output), asTexture(textures.exposure), asTexture(textures.reactive),
                asTexture(textures.composition), outputTexture, convertedExposure, linearColor,
                combinedMask, linearizeParams, maskParams, finishParams,
            };
            for (std::size_t i = 0; i != std::size(candidates); ++i) {
                id<MTLAllocation> candidate = candidates[i];
                if (!candidate) continue;
                bool duplicate = false;
                for (std::size_t j = 0; j != i; ++j)
                    if (candidates[j] == candidate) duplicate = true;
                if (!duplicate) [residency addAllocation:candidate];
            }
            [residency commit];
            return residency;
        } @catch (id) {
            return nil;
        }
    }
    return nil;
}

} // namespace

struct ScalerGeneration {
    id scaler = nil;
    NSUInteger inputCapacityWidth = 0;
    NSUInteger inputCapacityHeight = 0;
    MTLPixelFormat colorFormat = MTLPixelFormatInvalid;
    MTLPixelFormat depthFormat = MTLPixelFormatInvalid;
    MTLPixelFormat motionFormat = MTLPixelFormatInvalid;
    MTLPixelFormat outputFormat = MTLPixelFormatInvalid;
    MTLPixelFormat reactiveFormat = MTLPixelFormatInvalid;
    bool reactiveEnabled = false;
    NSUInteger outputWidth = 0;
    NSUInteger outputHeight = 0;
    MTLTextureUsage colorUsage = MTLTextureUsageUnknown;
    MTLTextureUsage depthUsage = MTLTextureUsageUnknown;
    MTLTextureUsage motionUsage = MTLTextureUsageUnknown;
    MTLTextureUsage outputUsage = MTLTextureUsageUnknown;
    MTLTextureUsage reactiveUsage = MTLTextureUsageUnknown;
    bool generationFresh = true;
    std::mutex encodeMutex;

    ~ScalerGeneration() {
        releaseObject(scaler);
    }
};

struct Feature::Impl {
    CreateInfo create{};
    CommandMode commandMode = CommandMode::Metal4;
    id<MTLDevice> device = nil;
    id compiler = nil;
    id<MTLComputePipelineState> exposurePipeline = nil;
    id<MTLComputePipelineState> linearizePipeline = nil;
    id<MTLComputePipelineState> combineMaskPipeline = nil;
    id<MTLComputePipelineState> finishPipeline = nil;
    float minScale = 1.0f;
    float maxScale = 1.0f;
    std::shared_ptr<ScalerGeneration> currentGeneration;
    std::mutex mutex;

    ~Impl() {
        currentGeneration.reset();
        releaseObject(finishPipeline);
        releaseObject(combineMaskPipeline);
        releaseObject(linearizePipeline);
        releaseObject(exposurePipeline);
        releaseObject(compiler);
        releaseObject(device);
    }
};

struct ExecutionLease::Impl {
    id<MTLTexture> privateOutput = nil;
    id<MTLTexture> convertedExposure = nil;
    id<MTLTexture> linearColor = nil;
    id<MTLTexture> combinedMask = nil;
    id<MTLBuffer> linearizeParams = nil;
    id<MTLBuffer> maskParams = nil;
    id<MTLBuffer> finishParams = nil;
    id residency = nil;
    id argumentTable = nil;
    id fsrArgumentTable = nil;
    id<MTLFence> fence = nil;
    bool effectiveReset = false;
    bool generationInitialized = false;
    void* scaler = nullptr;

    ~Impl() {
        releaseObject(fence);
        releaseObject(fsrArgumentTable);
        releaseObject(argumentTable);
        releaseObject(residency);
        releaseObject(finishParams);
        releaseObject(maskParams);
        releaseObject(linearizeParams);
        releaseObject(combinedMask);
        releaseObject(linearColor);
        releaseObject(convertedExposure);
        releaseObject(privateOutput);
    }
};

struct PreparedFrame::Impl {
    std::shared_ptr<Feature::Impl> feature;
    std::shared_ptr<ScalerGeneration> generation;
    FrameInfo frame{};
    TextureSet textures{};
    FrameOperations operations{};
    id<MTLTexture> color = nil;
    id<MTLTexture> depth = nil;
    id<MTLTexture> motion = nil;
    id<MTLTexture> output = nil;
    id<MTLTexture> exposure = nil;
    id<MTLTexture> reactive = nil;
    id<MTLTexture> composition = nil;
    NSUInteger temporalOutputWidth = 0;
    NSUInteger temporalOutputHeight = 0;
    NSUInteger placementX = 0;
    NSUInteger placementY = 0;
    bool cappedOutput = false;
    bool needsOutputShadow = false;
    bool needsExposureConversion = false;
    mutable std::mutex firstLeaseMutex;
    mutable std::shared_ptr<ExecutionLease::Impl> firstLease;

    ~Impl() {
        releaseObject(composition);
        releaseObject(reactive);
        releaseObject(exposure);
        releaseObject(output);
        releaseObject(motion);
        releaseObject(depth);
        releaseObject(color);
    }
};

namespace {

bool validateCreate(const CreateContext& context, const CreateInfo& create,
                    Error* error) noexcept {
    id<MTLDevice> device = asDevice(context.device);
    if (!device || create.input.width == 0 || create.input.height == 0 ||
        create.output.width == 0 || create.output.height == 0) {
        setError(error, ErrorCode::InvalidContext, "invalid Metal device or temporal feature dimensions");
        return false;
    }
    if ((create.flags() & ~kKnownFlags) != 0) {
        setError(error, ErrorCode::UnsupportedFeature, "temporal feature contains unknown creation flags");
        return false;
    }
    @try {
        if (context.mode == CommandMode::Metal4) {
            if (@available(macOS 26.0, *)) {
                id<MTL4Compiler> compiler =
                    reinterpret_cast<id<MTL4Compiler>>(asCompiler(context.compiler));
                if (!compiler || compiler.device != device ||
                    ![MTLFXTemporalScalerDescriptor supportsMetal4FX:device]) {
                    setError(error, ErrorCode::InvalidContext,
                             "Metal4 compiler/device does not support Metal4FX temporal scaling");
                    return false;
                }
            } else {
                setError(error, ErrorCode::UnsupportedFeature, "Metal4 MetalFX translation requires macOS 26 or newer");
                return false;
            }
        } else if (![MTLFXTemporalScalerDescriptor supportsDevice:device]) {
            setError(error, ErrorCode::UnsupportedFeature, "Metal device does not support MetalFX temporal scaling");
            return false;
        }

        if (!create.lowResolutionMotionVectors() || create.jitteredMotionVectors()) {
            if (@available(macOS 27.0, *)) {
            } else {
                setError(error, ErrorCode::UnsupportedFeature,
                         "output-resolution or jittered motion vectors require the macOS 27 MetalFX API");
                return false;
            }
        }
    } @catch (id) {
        setError(error, ErrorCode::InvalidContext, "MetalFX capability query raised an exception");
        return false;
    }
    return true;
}

bool validateFrameScalars(const FrameInfo& frame, Error* error) noexcept {
    if (!finite(frame.jitterOffsetX.value) || !finite(frame.jitterOffsetY.value) ||
        !finite(frame.motionVectorScaleX.value) || !finite(frame.motionVectorScaleY.value) ||
        !finite(frame.preExposure.value) || frame.motionVectorScaleX.value == 0.0f ||
        frame.motionVectorScaleY.value == 0.0f || frame.preExposure.value <= 0.0f) {
        setError(error, ErrorCode::InvalidFrame, "MetalFX frame contains an invalid scalar");
        return false;
    }
    return true;
}

struct TemporalOutputLayout {
    NSUInteger width = 0;
    NSUInteger height = 0;
    NSUInteger placementX = 0;
    NSUInteger placementY = 0;
    bool capped = false;
};

TemporalOutputLayout temporalOutputLayout(const Feature::Impl& feature,
                                          const FrameInfo& frame,
                                          const FrameOperations& operations) noexcept {
    TemporalOutputLayout layout{frame.outputRect.width, frame.outputRect.height, 0, 0, false};
    if (!operations.capOutputToTemporalMaxScale) return layout;

    const double callerScaleX = static_cast<double>(frame.outputRect.width) /
                                static_cast<double>(frame.inputContent.width);
    const double callerScaleY = static_cast<double>(frame.outputRect.height) /
                                static_cast<double>(frame.inputContent.height);
    if (callerScaleX <= feature.maxScale && callerScaleY <= feature.maxScale) return layout;

    const double uniformScale = std::min({static_cast<double>(feature.maxScale),
                                          callerScaleX, callerScaleY});
    layout.width = static_cast<NSUInteger>(std::floor(
        static_cast<double>(frame.inputContent.width) * uniformScale));
    layout.height = static_cast<NSUInteger>(std::floor(
        static_cast<double>(frame.inputContent.height) * uniformScale));
    layout.capped = true;
    if (layout.capped) {
        layout.placementX = (frame.outputRect.width - layout.width) / 2;
        layout.placementY = (frame.outputRect.height - layout.height) / 2;
    }
    return layout;
}

bool validateFrameTextures(const Feature::Impl& feature, const FrameInfo& frame,
                           const TextureSet& set, const FrameOperations& operations,
                           Error* error) noexcept {
    id<MTLTexture> color = asTexture(set.color);
    id<MTLTexture> depth = asTexture(set.depth);
    id<MTLTexture> motion = asTexture(set.motion);
    id<MTLTexture> output = asTexture(set.output);
    id<MTLTexture> exposure = asTexture(set.exposure);
    id<MTLTexture> reactive = asTexture(set.reactive);
    id<MTLTexture> composition = asTexture(set.composition);

    if (operations.colorTransfer != ColorTransfer::Linear &&
        operations.colorTransfer != ColorTransfer::SRGB &&
        operations.colorTransfer != ColorTransfer::PQ) {
        setError(error, ErrorCode::InvalidFrame, "FSR frame requested an unknown color transfer");
        return false;
    }
    if (!finite(operations.sharpness) || operations.sharpness < 0.0f ||
        operations.sharpness > 1.0f) {
        setError(error, ErrorCode::InvalidFrame, "FSR RCAS sharpness must be in [0,1]");
        return false;
    }
    if (!operations.sharpening && operations.sharpness != 0.0f) {
        setError(error, ErrorCode::InvalidFrame,
                 "FSR sharpness must be zero when sharpening is disabled");
        return false;
    }
    if (!operations.combineCompositionMask && composition) {
        setError(error, ErrorCode::InvalidFrame,
                 "composition texture requires composition-mask translation");
        return false;
    }

    if (feature.create.autoExposure()) {
        if (frame.exposureMode != ExposureMode::Automatic) {
            setError(error, ErrorCode::InvalidFrame,
                     "MetalFX auto-exposure feature received a non-automatic frame exposure mode");
            return false;
        }
    } else if (frame.exposureMode == ExposureMode::Automatic) {
        setError(error, ErrorCode::InvalidFrame,
                 "MetalFX frame requested automatic exposure without create-time auto-exposure");
        return false;
    }

    if (!frame.color || !frame.depth || !frame.motionVectors || !frame.output ||
        !color || !depth || !motion || !output) {
        setError(error, ErrorCode::InvalidFrame, "MetalFX frame is missing a required texture");
        return false;
    }
    for (id<MTLTexture> texture : {color, depth, motion, output}) {
        if (!basicTextureShape(texture) || !sameDevice(feature.device, texture)) {
            setError(error, ErrorCode::IncompatibleTexture,
                     "required MetalFX texture is not a compatible 2D texture on the feature device");
            return false;
        }
    }
    if (depth.width != color.width || depth.height != color.height) {
        setError(error, ErrorCode::IncompatibleTexture,
                 "MetalFX depth backing dimensions must exactly match the color backing dimensions");
        return false;
    }
    if (!rectFits(frame.colorRect, color) || !rectFits(frame.depthRect, depth) ||
        !rectFits(frame.motionRect, motion) || !rectFits(frame.outputRect, output)) {
        setError(error, ErrorCode::InvalidFrame, "MetalFX subrect exceeds a supplied Metal texture view");
        return false;
    }
    if (frame.inputContent.width == 0 || frame.inputContent.height == 0 ||
        frame.outputRect.width != feature.create.output.width ||
        frame.outputRect.height != feature.create.output.height) {
        setError(error, ErrorCode::InvalidFrame, "MetalFX dynamic content/output dimensions are inconsistent with the feature");
        return false;
    }
    if (frame.colorRect.width != frame.inputContent.width ||
        frame.colorRect.height != frame.inputContent.height ||
        frame.depthRect.width != frame.inputContent.width ||
        frame.depthRect.height != frame.inputContent.height) {
        setError(error, ErrorCode::InvalidFrame,
                 "MetalFX color/depth subrect dimensions must match the dynamic input content");
        return false;
    }
    const Extent expectedMotion = feature.create.lowResolutionMotionVectors()
        ? frame.inputContent : feature.create.output;
    if (frame.motionRect.width != expectedMotion.width ||
        frame.motionRect.height != expectedMotion.height) {
        setError(error, ErrorCode::InvalidFrame,
                 "MetalFX motion-vector subrect dimensions do not match its creation mode");
        return false;
    }
    if (frame.reactiveMask.value &&
        (frame.reactiveRect.width != frame.inputContent.width ||
         frame.reactiveRect.height != frame.inputContent.height)) {
        setError(error, ErrorCode::InvalidFrame,
                 "MetalFX reactive-mask subrect dimensions must match the dynamic input content");
        return false;
    }
    if (!feature.create.outputSubrects.value &&
        (frame.outputRect.x != 0 || frame.outputRect.y != 0)) {
        setError(error, ErrorCode::InvalidFrame,
                 "MetalFX output subrect offset requires create-time output-subrect opt-in");
        return false;
    }
    const TemporalOutputLayout temporal = temporalOutputLayout(feature, frame, operations);
    const float scaleX = static_cast<float>(temporal.width) /
                          static_cast<float>(frame.inputContent.width);
    const float scaleY = static_cast<float>(temporal.height) /
                          static_cast<float>(frame.inputContent.height);
    if (temporal.width == 0 || temporal.height == 0 || !finite(scaleX) || !finite(scaleY) ||
        scaleX < feature.minScale || scaleX > feature.maxScale ||
        scaleY < feature.minScale || scaleY > feature.maxScale) {
        setError(error, ErrorCode::UnsupportedFeature,
                 "dynamic input scale lies outside the MetalFX device range");
        return false;
    }
    if (!allOffsetsZero(frame)) {
        if (@available(macOS 27.0, *)) {
        } else {
            setError(error, ErrorCode::UnsupportedFeature,
                     "MetalFX content/output offsets require the macOS 27 MetalFX API");
            return false;
        }
    }

    if (frame.exposureMode == ExposureMode::Texture) {
        if (!frame.exposureTexture.value || !exposure || !basicTextureShape(exposure) ||
            !sameDevice(feature.device, exposure) || exposure.width == 0 || exposure.height == 0) {
            setError(error, ErrorCode::IncompatibleTexture, "manual MetalFX exposure texture is invalid");
            return false;
        }
        if (!hasUsage(exposure, MTLTextureUsageShaderRead)) {
            setError(error, ErrorCode::IncompatibleTexture, "manual MetalFX exposure texture is not shader-readable");
            return false;
        }
        if (requiresExposureConversion(exposure) && !exposureShaderReadable(exposure.pixelFormat)) {
            setError(error, ErrorCode::IncompatibleTexture,
                     "manual MetalFX exposure format cannot be numerically converted to R16Float");
            return false;
        }
    } else if (exposure) {
        // Auto exposure intentionally ignores the supplied exposure texture,
        // matching the public MetalFX contract. Do not reject its D3D presence.
        exposure = nil;
    }

    if (reactive) {
        if (!frame.reactiveMask.value || !basicTextureShape(reactive) ||
            !sameDevice(feature.device, reactive) || !rectFits(frame.reactiveRect, reactive)) {
            setError(error, ErrorCode::IncompatibleTexture, "MetalFX bias-current-color mask texture is invalid");
            return false;
        }
        if (@available(macOS 27.0, *)) {
        } else {
            setError(error, ErrorCode::UnsupportedFeature, "reactive-mask translation requires the macOS 27 MetalFX usage contract");
            return false;
        }
    } else if (frame.reactiveMask.value && !operations.combineCompositionMask) {
        setError(error, ErrorCode::InvalidFrame, "MetalFX reactive mask resource was not resolved to a Metal texture");
        return false;
    }

    if (operations.combineCompositionMask) {
        if (!reactive && !composition) {
            setError(error, ErrorCode::InvalidFrame,
                     "composition-mask translation requires at least one source mask");
            return false;
        }
        for (id<MTLTexture> mask : {reactive, composition}) {
            if (!mask) continue;
            if (!basicTextureShape(mask) || !sameDevice(feature.device, mask) ||
                !rectFits(frame.reactiveRect, mask) ||
                !hasUsage(mask, MTLTextureUsageShaderRead)) {
                setError(error, ErrorCode::IncompatibleTexture,
                         "FSR reactive/composition mask is not a shader-readable render-size texture");
                return false;
            }
        }
        if (@available(macOS 27.0, *)) {
        } else {
            setError(error, ErrorCode::UnsupportedFeature,
                     "composition-mask translation requires macOS 27 MetalFX");
            return false;
        }
    }
    if (operations.colorTransfer != ColorTransfer::Linear &&
        (!hasUsage(color, MTLTextureUsageShaderRead) ||
         !hasUsage(output, MTLTextureUsageShaderWrite))) {
        setError(error, ErrorCode::IncompatibleTexture,
                 "FSR transfer conversion requires shader-readable color and shader-writable output");
        return false;
    }
    const TemporalOutputLayout outputLayout = temporalOutputLayout(feature, frame, operations);
    if ((operations.sharpening || outputLayout.capped) &&
        !hasUsage(output, MTLTextureUsageShaderWrite)) {
        setError(error, ErrorCode::IncompatibleTexture,
                 "FSR output finishing requires a shader-writable output texture");
        return false;
    }

    const MTLStorageMode storage = output.storageMode;
    if (storage != MTLStorageModePrivate && storage != MTLStorageModeShared) {
        setError(error, ErrorCode::IncompatibleTexture,
                 "MetalFX output must use Private or Shared Metal storage");
        return false;
    }
    return true;
}

bool ensureExposurePipeline(Feature::Impl& feature, Error* error) noexcept {
    if (feature.exposurePipeline) return true;
    feature.exposurePipeline = makeExposurePipeline(feature.device);
    if (!feature.exposurePipeline) {
        setError(error, ErrorCode::ResourceCreationFailed,
                 "failed to synchronously create numerical MetalFX exposure conversion pipeline");
        return false;
    }
    return true;
}

bool ensureFsrPipelines(Feature::Impl& feature, Error* error) noexcept {
    if (!feature.linearizePipeline)
        feature.linearizePipeline = makePipeline(feature.device, kFsrKernelsSource,
                                                 @"yaagl_fsr_linearize");
    if (!feature.combineMaskPipeline)
        feature.combineMaskPipeline = makePipeline(feature.device, kFsrKernelsSource,
                                                   @"yaagl_fsr_combine_masks");
    if (!feature.finishPipeline)
        feature.finishPipeline = makePipeline(feature.device, kFsrKernelsSource,
                                              @"yaagl_fsr_finish");
    if (!feature.linearizePipeline || !feature.combineMaskPipeline || !feature.finishPipeline) {
        setError(error, ErrorCode::ResourceCreationFailed,
                 "failed to create FSR translation compute pipelines");
        return false;
    }
    return true;
}

bool generationMatches(const ScalerGeneration& generation,
                       id<MTLTexture> color, id<MTLTexture> depth,
                       id<MTLTexture> motion, id<MTLTexture> output,
                       id<MTLTexture> reactive, const FrameOperations& operations,
                       const TemporalOutputLayout& temporal) noexcept {
    if (generation.inputCapacityWidth != color.width ||
        generation.inputCapacityHeight != color.height ||
        generation.colorFormat != (operations.colorTransfer == ColorTransfer::Linear
                                      ? color.pixelFormat : linearFormat(color.pixelFormat)) ||
        generation.depthFormat != depth.pixelFormat ||
        generation.motionFormat != motion.pixelFormat ||
        generation.outputWidth != temporal.width || generation.outputHeight != temporal.height ||
        generation.outputFormat != ((operations.colorTransfer != ColorTransfer::Linear || operations.sharpening)
                                       ? linearFormat(output.pixelFormat) : output.pixelFormat)) {
        return false;
    }
    const bool combined = operations.combineCompositionMask;
    if (!reactive && !combined) return !generation.reactiveEnabled;
    return generation.reactiveEnabled &&
           generation.reactiveFormat == (combined ? MTLPixelFormatR8Unorm : reactive.pixelFormat);
}

std::shared_ptr<ScalerGeneration> ensureScaler(Feature::Impl& feature,
                                               const FrameInfo& frame,
                                               const TextureSet& set,
                                               const FrameOperations& operations,
                                               Error* error) noexcept {
    id<MTLTexture> color = asTexture(set.color);
    id<MTLTexture> depth = asTexture(set.depth);
    id<MTLTexture> motion = asTexture(set.motion);
    id<MTLTexture> output = asTexture(set.output);
    id<MTLTexture> reactive = asTexture(set.reactive);
    const TemporalOutputLayout temporal = temporalOutputLayout(feature, frame, operations);

    if (feature.currentGeneration &&
        generationMatches(*feature.currentGeneration, color, depth, motion, output, reactive,
                          operations, temporal))
        return feature.currentGeneration;

    @try {
        std::shared_ptr<ScalerGeneration> generation;
        try {
            generation = std::make_shared<ScalerGeneration>();
        } catch (...) {
            setError(error, ErrorCode::ResourceCreationFailed,
                     "failed to allocate MetalFX scaler generation state");
            return {};
        }
        MTLFXTemporalScalerDescriptor* descriptor = [MTLFXTemporalScalerDescriptor new];
        descriptor.colorTextureFormat = operations.colorTransfer == ColorTransfer::Linear
                                            ? color.pixelFormat : linearFormat(color.pixelFormat);
        descriptor.depthTextureFormat = depth.pixelFormat;
        descriptor.motionTextureFormat = motion.pixelFormat;
        descriptor.outputTextureFormat =
            (operations.colorTransfer != ColorTransfer::Linear || operations.sharpening)
                ? linearFormat(output.pixelFormat) : output.pixelFormat;
        // The new translator follows the public SDK contract: descriptor input
        // dimensions describe the resolved input color view's backing capacity.
        // Per-Evaluate inputContent* remains the meaningful dynamic render size.
        descriptor.inputWidth = color.width;
        descriptor.inputHeight = color.height;
        descriptor.outputWidth = temporal.width;
        descriptor.outputHeight = temporal.height;
        descriptor.autoExposureEnabled = feature.create.autoExposure();
        descriptor.requiresSynchronousInitialization = YES;
        descriptor.inputContentPropertiesEnabled = YES;
        descriptor.inputContentMinScale = feature.minScale;
        descriptor.inputContentMaxScale = feature.maxScale;
        if (@available(macOS 27.0, *)) {
            descriptor.outputResolutionMotionVectorsEnabled =
                !feature.create.lowResolutionMotionVectors();
            descriptor.jitteredMotionVectorsEnabled = feature.create.jitteredMotionVectors();
        }
        if (reactive || operations.combineCompositionMask) {
            if (@available(macOS 27.0, *)) {
                descriptor.reactiveMaskTextureEnabled = YES;
                descriptor.reactiveMaskTextureFormat = operations.combineCompositionMask
                                                           ? MTLPixelFormatR8Unorm
                                                           : reactive.pixelFormat;
            }
        }

        id scaler = nil;
        @try {
            IndependentFactoryScope factoryScope;
            if (feature.commandMode == CommandMode::Metal4) {
                if (@available(macOS 26.0, *)) {
                    id<MTL4Compiler> compiler = reinterpret_cast<id<MTL4Compiler>>(feature.compiler);
                    scaler = [descriptor newTemporalScalerWithDevice:feature.device compiler:compiler];
                }
            } else {
                scaler = [descriptor newTemporalScalerWithDevice:feature.device];
            }
        } @finally {
            [descriptor release];
        }
        if (!scaler) {
            setError(error, ErrorCode::ScalerCreationFailed,
                     "MetalFX temporal scaler factory returned nil");
            return {};
        }
        generation->scaler = scaler; // new factory returns +1
        generation->inputCapacityWidth = color.width;
        generation->inputCapacityHeight = color.height;
        generation->colorFormat = operations.colorTransfer == ColorTransfer::Linear
                                      ? color.pixelFormat : linearFormat(color.pixelFormat);
        generation->depthFormat = depth.pixelFormat;
        generation->motionFormat = motion.pixelFormat;
        generation->outputFormat =
            (operations.colorTransfer != ColorTransfer::Linear || operations.sharpening)
                ? linearFormat(output.pixelFormat) : output.pixelFormat;
        generation->outputWidth = temporal.width;
        generation->outputHeight = temporal.height;
        generation->reactiveEnabled = reactive != nil || operations.combineCompositionMask;
        generation->reactiveFormat = operations.combineCompositionMask
                                         ? MTLPixelFormatR8Unorm
                                         : (reactive ? reactive.pixelFormat : MTLPixelFormatInvalid);
        generation->colorUsage = [scaler colorTextureUsage];
        generation->depthUsage = [scaler depthTextureUsage];
        generation->motionUsage = [scaler motionTextureUsage];
        generation->outputUsage = [scaler outputTextureUsage];
        if (reactive || operations.combineCompositionMask) {
            if (@available(macOS 27.0, *))
                generation->reactiveUsage = [scaler reactiveMaskTextureUsage];
        }

        if ((operations.colorTransfer == ColorTransfer::Linear &&
             !hasUsage(color, generation->colorUsage)) || !hasUsage(depth, generation->depthUsage) ||
            !hasUsage(motion, generation->motionUsage)) {
            setError(error, ErrorCode::IncompatibleTexture,
                     "MetalFX input texture usage does not satisfy MetalFX requirements");
            return {};
        }
        if (reactive && !operations.combineCompositionMask &&
            !hasUsage(reactive, generation->reactiveUsage)) {
            setError(error, ErrorCode::IncompatibleTexture,
                     "MetalFX reactive texture usage does not satisfy MetalFX requirements");
            return {};
        }
        feature.currentGeneration = generation;
        return generation;
    } @catch (id) {
        setError(error, ErrorCode::ScalerCreationFailed,
                 "MetalFX temporal scaler creation raised an exception");
        return {};
    }
}

std::shared_ptr<ExecutionLease::Impl> makeLease(const PreparedFrame::Impl& frame,
                                                Error* error) noexcept {
    try {
        auto lease = std::make_shared<ExecutionLease::Impl>();
        Feature::Impl& feature = *frame.feature;
        ScalerGeneration& generation = *frame.generation;

        const bool transfer = frame.operations.colorTransfer != ColorTransfer::Linear;
        const bool finish = transfer || frame.operations.sharpening || frame.cappedOutput;
        id<MTLTexture> scalerOutput = frame.output;
        if (frame.needsOutputShadow) {
            if (finish) {
                scalerOutput = makeScratchTexture(
                    feature.device, frame.output, generation.outputFormat,
                    generation.outputUsage | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
                    @".YAAGL.FSR.LinearOutput",
                    frame.cappedOutput ? frame.temporalOutputWidth : 0,
                    frame.cappedOutput ? frame.temporalOutputHeight : 0);
            } else {
                scalerOutput = makePrivateOutput(feature.device, frame.output, generation.outputUsage);
            }
            if (!scalerOutput) {
                setError(error, ErrorCode::ResourceCreationFailed,
                         "failed to allocate Private MetalFX output texture");
                return {};
            }
            lease->privateOutput = scalerOutput;
        }
        if (transfer) {
            lease->linearColor = makeScratchTexture(
                feature.device, frame.color, generation.colorFormat,
                generation.colorUsage | MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite,
                @".YAAGL.FSR.LinearColor");
            if (!lease->linearColor) {
                setError(error, ErrorCode::ResourceCreationFailed,
                         "failed to allocate FSR linear input texture");
                return {};
            }
        }
        if (frame.operations.combineCompositionMask) {
            lease->combinedMask = makeMaskTexture(feature.device,
                                                  frame.reactive ? frame.reactive : frame.composition);
            if (!lease->combinedMask ||
                !hasUsage(lease->combinedMask, generation.reactiveUsage)) {
                setError(error, ErrorCode::ResourceCreationFailed,
                         "failed to allocate MetalFX combined reactive mask");
                return {};
            }
        }

        if (frame.needsExposureConversion) {
            lease->convertedExposure = makeExposureR16(feature.device);
            if (!lease->convertedExposure) {
                setError(error, ErrorCode::ResourceCreationFailed,
                         "failed to allocate R16Float exposure conversion texture");
                return {};
            }
        }

        struct alignas(8) Params {
            std::uint32_t sourceOrigin[2];
            std::uint32_t destinationOrigin[2];
            std::uint32_t extent[2];
            std::uint32_t dispatchOrigin[2];
            std::uint32_t dispatchExtent[2];
            std::uint32_t transfer;
            std::uint32_t flags;
            float sharpness;
            float exposure;
        };
        const std::uint32_t flags = (frame.reactive ? 1u : 0u) |
                                    (frame.composition ? 2u : 0u) |
                                    (frame.operations.sharpening ? 4u : 0u) |
                                    (frame.frame.exposureMode == ExposureMode::Texture ? 8u : 0u) |
                                    (frame.cappedOutput ? 16u : 0u);
        const auto makeParams = [&](const Rect& source, const Rect& destination,
                                    const Rect& dispatch, ColorTransfer transfer) {
            Params params{{source.x, source.y}, {destination.x, destination.y},
                          {source.width, source.height}, {dispatch.x, dispatch.y},
                          {dispatch.width, dispatch.height}, static_cast<std::uint32_t>(transfer),
                          flags, frame.operations.sharpness, frame.frame.preExposure.value};
            return [feature.device newBufferWithBytes:&params length:sizeof(params)
                                               options:MTLResourceStorageModeShared];
        };
        if (transfer) {
            const ColorTransfer inputTransfer =
                frame.operations.colorTransfer == ColorTransfer::SRGB &&
                        isSrgbFormat(frame.color.pixelFormat)
                    ? ColorTransfer::Linear : frame.operations.colorTransfer;
            lease->linearizeParams = makeParams(frame.frame.colorRect, frame.frame.colorRect,
                                                frame.frame.colorRect, inputTransfer);
        }
        if (frame.operations.combineCompositionMask)
            lease->maskParams = makeParams(frame.frame.reactiveRect,
                                           frame.frame.reactiveRect,
                                           frame.frame.reactiveRect,
                                           ColorTransfer::Linear);
        if (finish) {
            const ColorTransfer outputTransfer =
                frame.operations.colorTransfer == ColorTransfer::SRGB &&
                        isSrgbFormat(frame.output.pixelFormat)
                    ? ColorTransfer::Linear : frame.operations.colorTransfer;
            const Rect source{frame.cappedOutput ? 0u : frame.frame.outputRect.x,
                              frame.cappedOutput ? 0u : frame.frame.outputRect.y,
                              static_cast<std::uint32_t>(frame.temporalOutputWidth),
                              static_cast<std::uint32_t>(frame.temporalOutputHeight)};
            const Rect destination{static_cast<std::uint32_t>(frame.frame.outputRect.x + frame.placementX),
                                   static_cast<std::uint32_t>(frame.frame.outputRect.y + frame.placementY),
                                   source.width, source.height};
            lease->finishParams = makeParams(source, destination, frame.frame.outputRect,
                                             outputTransfer);
        }
        if ((transfer && !lease->linearizeParams) ||
            (frame.operations.combineCompositionMask && !lease->maskParams) ||
            (finish && !lease->finishParams)) {
            setError(error, ErrorCode::ResourceCreationFailed,
                     "failed to allocate FSR operation constants");
            return {};
        }

        lease->residency = makeResidencySet(feature.device, frame.textures,
                                            scalerOutput, lease->convertedExposure,
                                            lease->linearColor, lease->combinedMask,
                                            lease->linearizeParams, lease->maskParams,
                                            lease->finishParams);
        if (feature.commandMode == CommandMode::Metal4 && !lease->residency) {
            setError(error, ErrorCode::ResourceCreationFailed,
                     "failed to create Metal4 residency set for MetalFX execution");
            return {};
        }

        if ((lease->linearizeParams || lease->maskParams || lease->finishParams) &&
            feature.commandMode == CommandMode::Metal4) {
            if (@available(macOS 26.0, *)) {
                @try {
                    MTL4ArgumentTableDescriptor* descriptor = [MTL4ArgumentTableDescriptor new];
                    descriptor.maxBufferBindCount = 1;
                    descriptor.maxTextureBindCount = 3;
                    descriptor.initializeBindings = YES;
                    descriptor.label = @"YAAGL FSR translation";
                    NSError* tableError = nil;
                    lease->fsrArgumentTable =
                        [feature.device newArgumentTableWithDescriptor:descriptor error:&tableError];
                    [descriptor release];
                    if (!lease->fsrArgumentTable) {
                        setError(error, ErrorCode::ResourceCreationFailed,
                                 "failed to create Metal4 FSR argument table");
                        return {};
                    }
                } @catch (id) {
                    setError(error, ErrorCode::ResourceCreationFailed,
                             "Metal4 FSR argument-table setup raised an exception");
                    return {};
                }
            }
        }

        if (frame.needsExposureConversion && feature.commandMode == CommandMode::Metal4) {
            if (@available(macOS 26.0, *)) {
                @try {
                    MTL4ArgumentTableDescriptor* descriptor = [MTL4ArgumentTableDescriptor new];
                    descriptor.maxTextureBindCount = 2;
                    descriptor.initializeBindings = YES;
                    descriptor.label = @"YAAGL MetalFX exposure conversion";
                    NSError* tableError = nil;
                    lease->argumentTable =
                        [feature.device newArgumentTableWithDescriptor:descriptor error:&tableError];
                    [descriptor release];
                    if (!lease->argumentTable) {
                        setError(error, ErrorCode::ResourceCreationFailed,
                                 "failed to create Metal4 exposure argument table");
                        return {};
                    }
                    id<MTL4ArgumentTable> table =
                        reinterpret_cast<id<MTL4ArgumentTable>>(lease->argumentTable);
                    [table setTexture:frame.exposure.gpuResourceID atIndex:0];
                    [table setTexture:lease->convertedExposure.gpuResourceID atIndex:1];
                } @catch (id) {
                    setError(error, ErrorCode::ResourceCreationFailed,
                             "Metal4 exposure argument-table setup raised an exception");
                    return {};
                }
            }
        }
        return lease;
    } catch (...) {
        setError(error, ErrorCode::ResourceCreationFailed,
                 "failed to allocate MetalFX execution ownership state");
        return {};
    }
}

bool encodeExposureMetal4(const PreparedFrame::Impl& frame,
                          ExecutionLease::Impl& lease,
                          id<MTL4CommandBuffer> command,
                          id<MTLFence> fence) API_AVAILABLE(macos(26.0)) {
    id<MTL4ComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return false;
    @try {
        [encoder waitForFence:fence beforeEncoderStages:MTLStageDispatch];
        [encoder setComputePipelineState:frame.feature->exposurePipeline];
        [encoder setArgumentTable:lease.argumentTable];
        [encoder dispatchThreads:MTLSizeMake(1, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
        [encoder endEncoding];
        return true;
    } @catch (id) {
        @try { [encoder endEncoding]; } @catch (id) {}
        return false;
    }
}

bool encodeExposureLegacy(const PreparedFrame::Impl& frame,
                          ExecutionLease::Impl& lease,
                          id<MTLCommandBuffer> command,
                          id<MTLFence> fence) {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return false;
    @try {
        [encoder waitForFence:fence];
        [encoder setComputePipelineState:frame.feature->exposurePipeline];
        [encoder setTexture:frame.exposure atIndex:0];
        [encoder setTexture:lease.convertedExposure atIndex:1];
        [encoder dispatchThreads:MTLSizeMake(1, 1, 1)
             threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [encoder updateFence:fence];
        [encoder endEncoding];
        return true;
    } @catch (id) {
        @try { [encoder endEncoding]; } @catch (id) {}
        return false;
    }
}

bool encodeFsrPassMetal4(ExecutionLease::Impl& lease,
                         id<MTL4CommandBuffer> command, id<MTLFence> fence,
                         id<MTLComputePipelineState> pipeline, id<MTLBuffer> params,
                         id<MTLTexture> first, id<MTLTexture> second,
                         id<MTLTexture> third, const Rect& rect) API_AVAILABLE(macos(26.0)) {
    id<MTL4ComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return false;
    @try {
        id<MTL4ArgumentTable> table =
            reinterpret_cast<id<MTL4ArgumentTable>>(lease.fsrArgumentTable);
        [table setAddress:params.gpuAddress atIndex:0];
        [table setTexture:first.gpuResourceID atIndex:0];
        [table setTexture:second.gpuResourceID atIndex:1];
        if (third) [table setTexture:third.gpuResourceID atIndex:2];
        [encoder waitForFence:fence beforeEncoderStages:MTLStageDispatch];
        [encoder setComputePipelineState:pipeline];
        [encoder setArgumentTable:table];
        [encoder dispatchThreads:MTLSizeMake(rect.width, rect.height, 1)
             threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder updateFence:fence afterEncoderStages:MTLStageDispatch];
        [encoder endEncoding];
        return true;
    } @catch (id) {
        @try { [encoder endEncoding]; } @catch (id) {}
        return false;
    }
}

bool encodeFsrPassLegacy(
                         id<MTLCommandBuffer> command, id<MTLFence> fence,
                         id<MTLComputePipelineState> pipeline, id<MTLBuffer> params,
                         id<MTLTexture> first, id<MTLTexture> second,
                         id<MTLTexture> third, const Rect& rect) {
    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return false;
    @try {
        [encoder waitForFence:fence];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:params offset:0 atIndex:0];
        [encoder setTexture:first atIndex:0];
        [encoder setTexture:second atIndex:1];
        if (third) [encoder setTexture:third atIndex:2];
        [encoder dispatchThreads:MTLSizeMake(rect.width, rect.height, 1)
             threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [encoder updateFence:fence];
        [encoder endEncoding];
        return true;
    } @catch (id) {
        @try { [encoder endEncoding]; } @catch (id) {}
        return false;
    }
}

bool encodeFsrPreMetal4(const PreparedFrame::Impl& frame, ExecutionLease::Impl& lease,
                        id<MTL4CommandBuffer> command, id<MTLFence> fence)
                        API_AVAILABLE(macos(26.0)) {
    if (lease.linearColor && !encodeFsrPassMetal4(
            lease, command, fence, frame.feature->linearizePipeline,
            lease.linearizeParams, frame.color, lease.linearColor, nil, frame.frame.colorRect))
        return false;
    if (lease.combinedMask) {
        id<MTLTexture> fallback = frame.reactive ? frame.reactive : frame.composition;
        if (!encodeFsrPassMetal4(lease, command, fence,
                                frame.feature->combineMaskPipeline, lease.maskParams,
                                frame.reactive ? frame.reactive : fallback,
                                frame.composition ? frame.composition : fallback,
                                lease.combinedMask, frame.frame.reactiveRect))
            return false;
    }
    return true;
}

bool encodeFsrPreLegacy(const PreparedFrame::Impl& frame, ExecutionLease::Impl& lease,
                        id<MTLCommandBuffer> command, id<MTLFence> fence) {
    if (lease.linearColor && !encodeFsrPassLegacy(
             command, fence, frame.feature->linearizePipeline,
            lease.linearizeParams, frame.color, lease.linearColor, nil, frame.frame.colorRect))
        return false;
    if (lease.combinedMask) {
        id<MTLTexture> fallback = frame.reactive ? frame.reactive : frame.composition;
        if (!encodeFsrPassLegacy( command, fence,
                                frame.feature->combineMaskPipeline, lease.maskParams,
                                frame.reactive ? frame.reactive : fallback,
                                frame.composition ? frame.composition : fallback,
                                lease.combinedMask, frame.frame.reactiveRect))
            return false;
    }
    return true;
}

bool encodeFsrFinishMetal4(const PreparedFrame::Impl& frame, ExecutionLease::Impl& lease,
                           id<MTL4CommandBuffer> command, id<MTLFence> fence)
                           API_AVAILABLE(macos(26.0)) {
    if (!lease.finishParams) return true;
    return encodeFsrPassMetal4(lease, command, fence, frame.feature->finishPipeline,
                               lease.finishParams, lease.privateOutput, frame.output,
                               lease.convertedExposure ? lease.convertedExposure :
                                   (frame.exposure ? frame.exposure : lease.privateOutput),
                               frame.frame.outputRect);
}

bool encodeFsrFinishLegacy(const PreparedFrame::Impl& frame, ExecutionLease::Impl& lease,
                           id<MTLCommandBuffer> command, id<MTLFence> fence) {
    if (!lease.finishParams) return true;
    return encodeFsrPassLegacy( command, fence, frame.feature->finishPipeline,
                               lease.finishParams, lease.privateOutput, frame.output,
                               lease.convertedExposure ? lease.convertedExposure :
                                   (frame.exposure ? frame.exposure : lease.privateOutput),
                               frame.frame.outputRect);
}

bool copyOutputMetal4(const PreparedFrame::Impl& frame,
                      ExecutionLease::Impl& lease,
                      id<MTL4CommandBuffer> command,
                      id<MTLFence> fence) API_AVAILABLE(macos(26.0)) {
    if (!lease.privateOutput || lease.finishParams) return true;
    id<MTL4ComputeCommandEncoder> encoder = [command computeCommandEncoder];
    if (!encoder) return false;
    const Rect& rect = frame.frame.outputRect;
    @try {
        [encoder waitForFence:fence beforeEncoderStages:MTLStageBlit];
        [encoder copyFromTexture:lease.privateOutput
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(rect.x, rect.y, 0)
                      sourceSize:MTLSizeMake(rect.width, rect.height, 1)
                       toTexture:frame.output
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(rect.x, rect.y, 0)];
        [encoder updateFence:fence afterEncoderStages:MTLStageBlit];
        [encoder endEncoding];
        return true;
    } @catch (id) {
        @try { [encoder endEncoding]; } @catch (id) {}
        return false;
    }
}

bool copyOutputLegacy(const PreparedFrame::Impl& frame,
                      ExecutionLease::Impl& lease,
                      id<MTLCommandBuffer> command,
                      id<MTLFence> fence) {
    if (!lease.privateOutput || lease.finishParams) return true;
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    if (!encoder) return false;
    const Rect& rect = frame.frame.outputRect;
    @try {
        [encoder waitForFence:fence];
        [encoder copyFromTexture:lease.privateOutput
                     sourceSlice:0
                     sourceLevel:0
                    sourceOrigin:MTLOriginMake(rect.x, rect.y, 0)
                      sourceSize:MTLSizeMake(rect.width, rect.height, 1)
                       toTexture:frame.output
                destinationSlice:0
                destinationLevel:0
               destinationOrigin:MTLOriginMake(rect.x, rect.y, 0)];
        [encoder updateFence:fence];
        [encoder endEncoding];
        return true;
    } @catch (id) {
        @try { [encoder endEncoding]; } @catch (id) {}
        return false;
    }
}

void configureScalerForFrame(Feature::Impl& feature, ScalerGeneration& generation,
                             const PreparedFrame::Impl& frame,
                             ExecutionLease::Impl& lease, id<MTLFence> fence,
                             bool effectiveReset) {
    id scaler = generation.scaler;
    [scaler setColorTexture:lease.linearColor ? lease.linearColor : frame.color];
    [scaler setDepthTexture:frame.depth];
    [scaler setMotionTexture:frame.motion];
    [scaler setOutputTexture:lease.privateOutput ? lease.privateOutput : frame.output];
    [scaler setExposureTexture:frame.frame.exposureMode == ExposureMode::Texture
                                   ? (lease.convertedExposure ? lease.convertedExposure : frame.exposure)
                                   : nil];
    if (@available(macOS 27.0, *))
        [scaler setReactiveMaskTexture:lease.combinedMask ? lease.combinedMask : frame.reactive];
    [scaler setInputContentWidth:frame.frame.inputContent.width];
    [scaler setInputContentHeight:frame.frame.inputContent.height];
    if (@available(macOS 27.0, *)) {
        [scaler setColorContentOffsetX:frame.frame.colorRect.x];
        [scaler setColorContentOffsetY:frame.frame.colorRect.y];
        [scaler setDepthContentOffsetX:frame.frame.depthRect.x];
        [scaler setDepthContentOffsetY:frame.frame.depthRect.y];
        [scaler setMotionContentOffsetX:frame.frame.motionRect.x];
        [scaler setMotionContentOffsetY:frame.frame.motionRect.y];
        [scaler setReactiveMaskContentOffsetX:frame.frame.reactiveRect.x];
        [scaler setReactiveMaskContentOffsetY:frame.frame.reactiveRect.y];
        [scaler setOutputOffsetX:frame.cappedOutput ? 0 : frame.frame.outputRect.x];
        [scaler setOutputOffsetY:frame.cappedOutput ? 0 : frame.frame.outputRect.y];
    }
    [scaler setPreExposure:frame.frame.preExposure.value];
    [scaler setJitterOffsetX:frame.frame.jitterOffsetX.value];
    [scaler setJitterOffsetY:frame.frame.jitterOffsetY.value];
    [scaler setMotionVectorScaleX:frame.frame.motionVectorScaleX.value];
    [scaler setMotionVectorScaleY:frame.frame.motionVectorScaleY.value];
    [scaler setReset:effectiveReset ? YES : NO];
    [scaler setDepthReversed:feature.create.depthInverted() ? YES : NO];
    [scaler setFence:fence];
}

} // namespace

Feature::Feature(std::shared_ptr<Impl> impl) noexcept : impl_(std::move(impl)) {}

Feature::~Feature() = default;

std::shared_ptr<Feature> Feature::create(const CreateContext& context,
                                         const CreateInfo& info,
                                         Error* error) noexcept {
    clearError(error);
    if (!validateCreate(context, info, error)) return {};
    try {
        auto impl = std::make_shared<Impl>();
        impl->create = info;
        impl->commandMode = context.mode;
        impl->device = retainObject(asDevice(context.device));
        impl->compiler = retainObject(asCompiler(context.compiler));
        @try {
            impl->minScale = [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:impl->device];
            impl->maxScale = [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:impl->device];
        } @catch (id) {
            setError(error, ErrorCode::InvalidContext, "MetalFX dynamic-scale query raised an exception");
            return {};
        }
        if (!finite(impl->minScale) || !finite(impl->maxScale) || impl->minScale <= 0.0f ||
            impl->maxScale < impl->minScale) {
            setError(error, ErrorCode::InvalidContext, "MetalFX returned an invalid dynamic-scale range");
            return {};
        }
        return std::shared_ptr<Feature>(new Feature(std::move(impl)));
    } catch (...) {
        setError(error, ErrorCode::ResourceCreationFailed, "failed to allocate MetalFX feature state");
        return {};
    }
}

CommandMode Feature::mode() const noexcept {
    return impl_ ? impl_->commandMode : CommandMode::Legacy;
}

std::shared_ptr<const PreparedFrame> Feature::prepare(
    const FrameInfo& info, const TextureSet& textures, Error* error,
    const FrameOperations& operations) noexcept {
    clearError(error);
    if (!impl_ || !validateFrameScalars(info, error) ||
        !validateFrameTextures(*impl_, info, textures, operations, error)) {
        return {};
    }

    try {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        const TemporalOutputLayout temporal = temporalOutputLayout(*impl_, info, operations);
        const bool needsFsrPipelines = operations.colorTransfer != ColorTransfer::Linear ||
                                       operations.combineCompositionMask || operations.sharpening ||
                                       temporal.capped;
        if (needsFsrPipelines && !ensureFsrPipelines(*impl_, error)) return {};
        std::shared_ptr<ScalerGeneration> generation =
            ensureScaler(*impl_, info, textures, operations, error);
        if (!generation) return {};

        id<MTLTexture> color = asTexture(textures.color);
        id<MTLTexture> depth = asTexture(textures.depth);
        id<MTLTexture> motion = asTexture(textures.motion);
        id<MTLTexture> output = asTexture(textures.output);
        id<MTLTexture> exposure = info.exposureMode == ExposureMode::Texture
                                      ? asTexture(textures.exposure)
                                      : nil;
        id<MTLTexture> reactive = asTexture(textures.reactive);
        id<MTLTexture> composition = asTexture(textures.composition);

        // Usage can differ between resource/view instances even when formats do
        // not. Revalidate every Evaluate against the created scaler.
        if ((operations.colorTransfer == ColorTransfer::Linear &&
             !hasUsage(color, generation->colorUsage)) || !hasUsage(depth, generation->depthUsage) ||
            !hasUsage(motion, generation->motionUsage) ||
            (reactive && !operations.combineCompositionMask &&
             !hasUsage(reactive, generation->reactiveUsage))) {
            setError(error, ErrorCode::IncompatibleTexture,
                     "MetalFX frame texture usage does not satisfy this MetalFX scaler");
            return {};
        }

        const bool exposureConversion = exposure && requiresExposureConversion(exposure);
        if (exposureConversion && !ensureExposurePipeline(*impl_, error)) return {};

        auto frame = std::make_shared<PreparedFrame::Impl>();
        frame->feature = impl_;
        frame->generation = generation;
        frame->frame = info;
        frame->textures = textures;
        frame->operations = operations;
        if (info.exposureMode != ExposureMode::Texture) frame->textures.exposure = nullptr;
        frame->color = retainObject(color);
        frame->depth = retainObject(depth);
        frame->motion = retainObject(motion);
        frame->output = retainObject(output);
        frame->exposure = retainObject(exposure);
        frame->reactive = retainObject(reactive);
        frame->composition = retainObject(composition);
        frame->temporalOutputWidth = temporal.width;
        frame->temporalOutputHeight = temporal.height;
        frame->placementX = temporal.placementX;
        frame->placementY = temporal.placementY;
        frame->cappedOutput = temporal.capped;
        frame->needsOutputShadow = temporal.capped ||
                                   operations.colorTransfer != ColorTransfer::Linear ||
                                   operations.sharpening ||
                                   output.storageMode != MTLStorageModePrivate ||
                                   !hasUsage(output, generation->outputUsage);
        frame->needsExposureConversion = exposureConversion;

        // Pre-create one complete execution resource set. This makes the first
        // Evaluate fail synchronously on output/exposure/residency allocation
        // instead of recording a command that can only leave stale output.
        frame->firstLease = makeLease(*frame, error);
        if (!frame->firstLease) return {};

        return std::shared_ptr<const PreparedFrame>(
            new PreparedFrame(std::move(frame)));
    } catch (...) {
        setError(error, ErrorCode::ResourceCreationFailed,
                 "failed to prepare immutable MetalFX frame state");
        return {};
    }
}

PreparedFrame::PreparedFrame(std::shared_ptr<Impl> impl) noexcept : impl_(std::move(impl)) {}

PreparedFrame::~PreparedFrame() = default;

void installEncodeObserver(const EncodeObserver* observer) noexcept {
    gEncodeObserver.store(observer && observer->begin && observer->end ? observer : nullptr,
                          std::memory_order_release);
}

CommandMode PreparedFrame::mode() const noexcept {
    return impl_ && impl_->feature ? impl_->feature->commandMode : CommandMode::Legacy;
}

TemporalOutputInfo PreparedFrame::temporalOutputInfo() const noexcept {
    if (!impl_) return {};
    return {static_cast<std::uint32_t>(impl_->temporalOutputWidth),
            static_cast<std::uint32_t>(impl_->temporalOutputHeight),
            static_cast<std::uint32_t>(impl_->placementX),
            static_cast<std::uint32_t>(impl_->placementY), impl_->cappedOutput};
}

bool PreparedFrame::encode(void* commandBuffer, void* fencePointer,
                           std::shared_ptr<const ExecutionLease>& leaseResult,
                           Error* error, const EncodeIdentity* identity) const noexcept {
    clearError(error);
    leaseResult.reset();
    if (!impl_ || !impl_->feature || !commandBuffer || !fencePointer) {
        setError(error, ErrorCode::InvalidContext, "MetalFX encode is missing command buffer or fence");
        return false;
    }

    try {
        std::shared_ptr<ExecutionLease::Impl> lease;
        {
            std::lock_guard<std::mutex> lock(impl_->firstLeaseMutex);
            lease = std::move(impl_->firstLease);
        }
        if (!lease) {
            lease = makeLease(*impl_, error);
            if (!lease) return false;
        }
        lease->fence = retainObject(asFence(fencePointer));

        // Publish ownership before recording any command. Keep this non-null
        // on every later failure so GPU-captured scratch cannot be released.
        auto publicLease = std::shared_ptr<ExecutionLease>(new ExecutionLease(lease));
        leaseResult = publicLease;

        Feature::Impl& feature = *impl_->feature;
        ScalerGeneration& generation = *impl_->generation;
        std::lock_guard<std::mutex> lock(generation.encodeMutex);
        const bool generationInitialized = !generation.generationFresh;
        const bool effectiveReset = impl_->frame.resetHistory.value || generation.generationFresh;
        lease->effectiveReset = effectiveReset;
        lease->generationInitialized = generationInitialized;
        lease->scaler = reinterpret_cast<void*>(generation.scaler);
        EncodeObservationScope observation;
        const auto beginObservation = [&]() noexcept {
            if (!observation.enabled()) return;
            EncodeObservation value{};
            value.mode = feature.commandMode;
            value.prepared = this;
            value.create = &feature.create;
            value.frame = &impl_->frame;
            value.callerTextures = impl_->textures;
            value.scaler = reinterpret_cast<void*>(generation.scaler);
            value.commandBuffer = commandBuffer;
            value.fence = fencePointer;
            if (identity) {
                value.featureID = identity->featureID;
                value.evaluationID = identity->evaluationID;
                value.recordedCommand = identity->recordedCommand;
            }
            value.effectiveReset = effectiveReset;
            value.generationInitialized = generationInitialized;
            observation.begin(value);
        };
        @try {
            if (feature.commandMode == CommandMode::Metal4) {
                if (@available(macOS 26.0, *)) {
                    id<MTL4CommandBuffer> command =
                        reinterpret_cast<id<MTL4CommandBuffer>>(commandBuffer);
                    id<MTLResidencySet> residency =
                        reinterpret_cast<id<MTLResidencySet>>(lease->residency);
                    if (command.device != feature.device) {
                        setError(error, ErrorCode::InvalidContext,
                                 "Metal4 command buffer belongs to a different device");
                        return false;
                    }
                    if (residency) [command useResidencySet:residency];
                    if (impl_->needsExposureConversion &&
                        !encodeExposureMetal4(*impl_, *lease, command, lease->fence)) {
                        setError(error, ErrorCode::EncodeFailed,
                                 "failed to encode numerical exposure conversion on Metal4");
                        return false;
                    }
                    if (!encodeFsrPreMetal4(*impl_, *lease, command, lease->fence)) {
                        setError(error, ErrorCode::EncodeFailed,
                                 "failed to encode FSR preprocessing on Metal4");
                        return false;
                    }
                    configureScalerForFrame(feature, generation, *impl_, *lease, lease->fence,
                                            effectiveReset);
                    beginObservation();
                    [generation.scaler encodeToCommandBuffer:command];
                    if (!encodeFsrFinishMetal4(*impl_, *lease, command, lease->fence)) {
                        setError(error, ErrorCode::EncodeFailed,
                                 "failed to encode FSR transfer/RCAS output on Metal4");
                        return false;
                    }
                    if (!copyOutputMetal4(*impl_, *lease, command, lease->fence)) {
                        setError(error, ErrorCode::EncodeFailed,
                                 "failed to encode required MetalFX output subrect copy on Metal4");
                        return false;
                    }
                } else {
                    setError(error, ErrorCode::UnsupportedFeature,
                             "Metal4 MetalFX encode is unavailable on this OS");
                    return false;
                }
            } else {
                id<MTLCommandBuffer> command = reinterpret_cast<id<MTLCommandBuffer>>(commandBuffer);
                if (command.device != feature.device) {
                    setError(error, ErrorCode::InvalidContext,
                             "legacy command buffer belongs to a different device");
                    return false;
                }
                if (@available(macOS 15.0, *)) {
                    id<MTLResidencySet> residency =
                        reinterpret_cast<id<MTLResidencySet>>(lease->residency);
                    if (residency) [command useResidencySet:residency];
                }
                if (impl_->needsExposureConversion &&
                    !encodeExposureLegacy(*impl_, *lease, command, lease->fence)) {
                    setError(error, ErrorCode::EncodeFailed,
                             "failed to encode numerical exposure conversion on legacy Metal");
                    return false;
                }
                if (!encodeFsrPreLegacy(*impl_, *lease, command, lease->fence)) {
                    setError(error, ErrorCode::EncodeFailed,
                             "failed to encode FSR preprocessing on legacy Metal");
                    return false;
                }
                configureScalerForFrame(feature, generation, *impl_, *lease, lease->fence,
                                        effectiveReset);
                beginObservation();
                [generation.scaler encodeToCommandBuffer:command];
                if (!encodeFsrFinishLegacy(*impl_, *lease, command, lease->fence)) {
                    setError(error, ErrorCode::EncodeFailed,
                             "failed to encode FSR transfer/RCAS output on legacy Metal");
                    return false;
                }
                if (!copyOutputLegacy(*impl_, *lease, command, lease->fence)) {
                    setError(error, ErrorCode::EncodeFailed,
                             "failed to encode required MetalFX output subrect copy on legacy Metal");
                    return false;
                }
            }
        } @catch (id) {
            setError(error, ErrorCode::EncodeFailed,
                     "MetalFX temporal frame encoding raised an exception");
            return false;
        }

        generation.generationFresh = false;
        observation.completed();
        return true;
    } catch (...) {
        setError(error, ErrorCode::EncodeFailed, "failed to retain MetalFX execution state");
        return false;
    }
}

ExecutionLease::ExecutionLease(std::shared_ptr<Impl> impl) noexcept : impl_(std::move(impl)) {}

ExecutionLease::~ExecutionLease() = default;

bool ExecutionLease::effectiveReset() const noexcept {
    return impl_ && impl_->effectiveReset;
}

bool ExecutionLease::generationInitialized() const noexcept {
    return impl_ && impl_->generationInitialized;
}

void* ExecutionLease::scaler() const noexcept {
    return impl_ ? impl_->scaler : nullptr;
}

} // namespace yaagl::pso::metalfx
