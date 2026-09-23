#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>

#include "metalfx-backend.hpp"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <pthread.h>
#include <stdexcept>
#include <string>
#include <vector>

namespace yaagl::pso::d3dmetal {
NSUInteger reserveTimingProbeForInProcess(void* commandBuffer) noexcept;
void releaseTimingProbeForInProcess(void* commandBuffer, NSUInteger base) noexcept;
id<MTL4CounterHeap> timingProbeHeapForBuffer(void* commandBuffer) noexcept;
NSUInteger timingProbeBaseForBuffer(void* commandBuffer) noexcept;
}

namespace {
using namespace yaagl::pso::metalfx;

void require(bool value, const char* message) {
    if (!value) throw std::runtime_error(message);
}

void logThread(FILE* log, const char* prefix, unsigned frame, id<MTL4CommandQueue> queue,
               id<MTL4CommandAllocator> allocator, id<MTL4CommandBuffer> command,
               id<MTLFence> fence) {
    qos_class_t qos = QOS_CLASS_UNSPECIFIED;
    int relativePriority = 0;
    const int qosStatus = pthread_get_qos_class_np(pthread_self(), &qos, &relativePriority);
    std::uint64_t threadID = 0;
    const int threadIDStatus = pthread_threadid_np(nullptr, &threadID);
    std::fprintf(log,
        "%s frame=%u thread_id=%llu thread_id_status=%d qos_status=%d qos_class=%d relative_priority=%d "
        "queue=%p queue_class=%s allocator=%p command_buffer=%p fence=%p\n",
        prefix, frame, static_cast<unsigned long long>(threadID), threadIDStatus, qosStatus,
        static_cast<int>(qos), relativePriority, (void*)queue,
        queue ? object_getClassName((id)queue) : "<nil>", (void*)allocator, (void*)command, (void*)fence);
    std::fflush(log);
}

static std::uint16_t floatToHalf(float value) {
    std::uint32_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    const std::uint32_t sign = (bits >> 16) & 0x8000u;
    int exponent = int((bits >> 23) & 0xffu) - 112;
    std::uint32_t mantissa = bits & 0x7fffffu;
    if (exponent <= 0) {
        if (exponent < -10) return static_cast<std::uint16_t>(sign);
        mantissa = (mantissa | 0x800000u) >> (1 - exponent);
        return static_cast<std::uint16_t>(sign | ((mantissa + 0x1000u) >> 13));
    }
    if (exponent >= 31) return static_cast<std::uint16_t>(sign | 0x7c00u);
    return static_cast<std::uint16_t>(sign | (std::uint32_t(exponent) << 10) |
                                      ((mantissa + 0x1000u) >> 13));
}

static id<MTLTexture> makeTexture(id<MTLDevice> device, NSUInteger width, NSUInteger height,
                                  MTLPixelFormat format, MTLStorageMode storage,
                                  MTLTextureUsage usage) {
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    descriptor.storageMode = storage;
    descriptor.usage = usage;
    descriptor.allowGPUOptimizedContents = YES;
    descriptor.hazardTrackingMode = MTLHazardTrackingModeUntracked;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
    require(texture != nil, "caller texture allocation failed");
    return texture;
}

struct Inputs final {
    id<MTLTexture> color = nil;
    id<MTLTexture> depth = nil;
    id<MTLTexture> motion = nil;
    id<MTLTexture> reactive = nil;
    id<MTLTexture> output = nil;

    Inputs(id<MTLDevice> device, NSUInteger width, NSUInteger height,
           NSUInteger outputWidth, NSUInteger outputHeight) {
        const MTLTextureUsage inputUsage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        color = makeTexture(device, width, height, MTLPixelFormatRGBA16Float,
                            MTLStorageModeShared, inputUsage);
        depth = makeTexture(device, width, height, MTLPixelFormatR32Float,
                            MTLStorageModeShared, inputUsage);
        motion = makeTexture(device, width, height, MTLPixelFormatRG16Float,
                             MTLStorageModeShared, inputUsage);
        reactive = makeTexture(device, width, height, MTLPixelFormatR8Unorm,
                               MTLStorageModeShared, inputUsage);
        output = makeTexture(device, outputWidth, outputHeight, MTLPixelFormatRGBA16Float,
            MTLStorageModeShared, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
            MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView);

        std::vector<std::uint16_t> colorPixels(static_cast<std::size_t>(width) * height * 4);
        std::vector<float> depthPixels(static_cast<std::size_t>(width) * height, 0.5f);
        std::vector<std::uint16_t> motionPixels(static_cast<std::size_t>(width) * height * 2, 0);
        std::vector<std::uint8_t> reactivePixels(static_cast<std::size_t>(width) * height);
        for (NSUInteger y = 0; y < height; ++y) {
            for (NSUInteger x = 0; x < width; ++x) {
                const std::size_t pixel = static_cast<std::size_t>(y) * width + x;
                const std::size_t colorIndex = pixel * 4;
                colorPixels[colorIndex] = floatToHalf(0.2f + 0.5f * float(x % 17) / 16.0f);
                colorPixels[colorIndex + 1] = floatToHalf(0.4f);
                colorPixels[colorIndex + 2] = floatToHalf(0.7f);
                colorPixels[colorIndex + 3] = floatToHalf(1.0f);
                reactivePixels[pixel] = ((x / 8 + y / 8) & 1) ? 255 : 0;
            }
        }
        const MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        [color replaceRegion:region mipmapLevel:0 withBytes:colorPixels.data() bytesPerRow:width * 8];
        [depth replaceRegion:region mipmapLevel:0 withBytes:depthPixels.data() bytesPerRow:width * 4];
        [motion replaceRegion:region mipmapLevel:0 withBytes:motionPixels.data() bytesPerRow:width * 4];
        [reactive replaceRegion:region mipmapLevel:0 withBytes:reactivePixels.data() bytesPerRow:width];
    }

    ~Inputs() {
        [color release]; [depth release]; [motion release]; [reactive release]; [output release];
    }

    TextureSet textureSet() const {
        return {(void*)color, (void*)depth, (void*)motion, (void*)output,
                nullptr, (void*)reactive, nullptr};
    }

    FrameInfo frame(bool reset) const {
        constexpr unsigned width = 1128, height = 624, outputWidth = 1920, outputHeight = 1080;
        FrameInfo info{};
        info.color = (void*)color;
        info.depth = (void*)depth;
        info.motionVectors = (void*)motion;
        info.output = (void*)output;
        info.reactiveMask = {(void*)reactive, true};
        info.inputContent = {width, height};
        info.colorRect = {0, 0, width, height};
        info.depthRect = info.colorRect;
        info.motionRect = info.colorRect;
        info.reactiveRect = info.colorRect;
        info.outputRect = {0, 0, outputWidth, outputHeight};
        info.jitterOffsetX = {0.1875f, true};
        info.jitterOffsetY = {0.129629612f, true};
        info.motionVectorScaleX = {float(width), true};
        info.motionVectorScaleY = {float(height), true};
        info.preExposure = {1.0f, true};
        info.resetHistory = {reset, true};
        info.exposureMode = ExposureMode::Automatic;
        return info;
    }
};

std::shared_ptr<Feature> makeFeature(id<MTLDevice> device, id<MTL4Compiler> compiler) {
    CreateInfo create{};
    create.input = {1128, 624};
    create.output = {1920, 1080};
    create.featureFlags = {std::uint32_t(FeatureFlagMVLowRes | FeatureFlagAutoExposure), true};
    create.outputSubrects = {false, true};
    Error error;
    auto result = Feature::create({(void*)device, (void*)compiler, CommandMode::Metal4}, create, &error);
    require(result != nullptr, error.message.empty() ? "Feature::create failed" : error.message.c_str());
    return result;
}

struct Runner final {
    id<MTLDevice> device = nil;
    id<MTL4Compiler> compiler = nil;
    id<MTL4CommandQueue> queue = nil;
    id<MTL4CommandAllocator> allocator = nil;
    id<MTL4CommandBuffer> command = nil;
    id<MTLFence> fence = nil;
    bool used = false;
    FILE* log = nullptr;

    Runner(id<MTLDevice> sourceDevice, id<MTL4Compiler> sourceCompiler, FILE* output)
        : device([sourceDevice retain]), compiler([sourceCompiler retain]), log(output) {
        queue = [device newMTL4CommandQueue];
        allocator = [device newCommandAllocator];
        command = [device newCommandBuffer];
        fence = [device newFence];
        require(queue && allocator && command && fence, "MTL4 runner allocation failed");
    }

    ~Runner() {
        [fence release]; [command release]; [allocator release]; [queue release]; [compiler release]; [device release];
    }

    void run(const std::shared_ptr<const PreparedFrame>& prepared, bool reset, unsigned frame) {
        if (used) [allocator reset];
        used = true;
        [command beginCommandBufferWithAllocator:allocator];
        id<MTL4ComputeCommandEncoder> producer = [command computeCommandEncoder];
        require(producer != nil, "producer encoder allocation failed");
        [producer updateFence:fence afterEncoderStages:MTLStageDispatch];
        [producer endEncoding];

        const NSUInteger base = yaagl::pso::d3dmetal::reserveTimingProbeForInProcess((void*)command);
        id<MTL4CounterHeap> heap = yaagl::pso::d3dmetal::timingProbeHeapForBuffer((void*)command);
        require(heap != nil && base != static_cast<NSUInteger>(-1), "timing probe reservation failed");
        [command writeTimestampIntoHeap:heap atIndex:base];

        std::shared_ptr<const ExecutionLease> lease;
        Error error;
        const bool encoded = prepared->encode((void*)command, (void*)fence, lease, &error);
        require(encoded && lease != nullptr, error.message.empty() ? "MetalFX encode failed" : error.message.c_str());

        id<MTL4ComputeCommandEncoder> consumer = [command computeCommandEncoder];
        require(consumer != nil, "consumer encoder allocation failed");
        [consumer waitForFence:fence beforeEncoderStages:MTLStageBlit];
        [consumer endEncoding];
        [command writeTimestampIntoHeap:heap atIndex:base + 3];
        [command endCommandBuffer];

        logThread(log, "INPROCESS_NATIVE_COMMIT", frame, queue, allocator, command, fence);
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        __block NSError* gpuError = nil;
        __block CFTimeInterval gpuStart = 0.0, gpuEnd = 0.0;
        MTL4CommitOptions* options = [MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            gpuStart = feedback.GPUStartTime;
            gpuEnd = feedback.GPUEndTime;
            gpuError = [feedback.error retain];
            dispatch_semaphore_signal(done);
        }];
        id<MTL4CommandBuffer> batch[] = {command};
        const auto wallStart = std::chrono::steady_clock::now();
        [queue commit:batch count:1 options:options];
        const long waitStatus = dispatch_semaphore_wait(done,
            dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
        const double hostWaitMs = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - wallStart).count();
        require(waitStatus == 0, "direct commit feedback timeout");
        require(gpuError == nil, "direct commit GPU error");

        NSData* resolved = [heap resolveCounterRange:NSMakeRange(base, 4)];
        require(resolved != nil && resolved.length == sizeof(MTL4TimestampHeapEntry) * 4,
                "direct counter resolve failed");
        const auto* entries = static_cast<const MTL4TimestampHeapEntry*>(resolved.bytes);
        const std::uint64_t frequency = [device queryTimestampFrequency];
        require(frequency > 0 && entries[0].timestamp > 0 &&
                entries[0].timestamp < entries[1].timestamp &&
                entries[1].timestamp < entries[2].timestamp &&
                entries[2].timestamp < entries[3].timestamp,
                "direct timestamps are not monotonic");
        const double scale = 1000.0 / static_cast<double>(frequency);
        std::fprintf(log,
            "INPROCESS_NATIVE_FRAME frame=%u reset=%u device=%p compiler=%p queue=%p queue_class=%s "
            "allocator=%p command_buffer=%p fence=%p pre_gpu_ms=%.4f metalfx_fence_span_ms=%.4f "
            "post_gpu_ms=%.4f total_gpu_ms=%.4f host_wait_ms=%.4f feedback_gpu_start=%.9f "
            "feedback_gpu_end=%.9f counter_valid=1 result=PASS\n",
            frame, reset ? 1u : 0u, (void*)device, (void*)compiler,
            (void*)queue, object_getClassName((id)queue), (void*)allocator, (void*)command, (void*)fence,
            double(entries[1].timestamp - entries[0].timestamp) * scale,
            double(entries[2].timestamp - entries[1].timestamp) * scale,
            double(entries[3].timestamp - entries[2].timestamp) * scale,
            double(entries[3].timestamp - entries[0].timestamp) * scale,
            hostWaitMs, gpuStart, gpuEnd);
        std::fflush(log);

        [gpuError release]; [options release]; dispatch_release(done);
        lease.reset();
        yaagl::pso::d3dmetal::releaseTimingProbeForInProcess((void*)command, base);
    }
};

void validateOutput(id<MTLDevice> device, id<MTLTexture> output, FILE* log) {
    constexpr NSUInteger width = 1920, height = 1080;
    constexpr NSUInteger rowBytes = width * 8, imageBytes = rowBytes * height;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLBuffer> buffer = [device newBufferWithLength:imageBytes options:MTLResourceStorageModeShared];
    require(queue != nil && buffer != nil, "readback resources allocation failed");
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    require(command != nil && blit != nil, "readback command allocation failed");
    [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(width, height, 1) toBuffer:buffer destinationOffset:0
       destinationBytesPerRow:rowBytes destinationBytesPerImage:imageBytes];
    [blit endEncoding]; [command commit]; [command waitUntilCompleted];
    require(command.status == MTLCommandBufferStatusCompleted, "readback command failed");
    const auto* pixels = static_cast<const std::uint16_t*>(buffer.contents);
    double mean = 0.0;
    const std::size_t count = static_cast<std::size_t>(width) * height;
    for (std::size_t y = 0; y < height; ++y) {
        for (std::size_t x = 0; x < width; ++x) {
            const float value = [] (std::uint16_t half) {
                const std::uint32_t sign = std::uint32_t(half & 0x8000u) << 16;
                std::uint32_t exponent = (half >> 10) & 0x1fu;
                std::uint32_t mantissa = half & 0x3ffu;
                std::uint32_t bits = 0;
                if (exponent == 0) {
                    if (mantissa == 0) bits = sign;
                    else {
                        exponent = 113;
                        while ((mantissa & 0x400u) == 0) { mantissa <<= 1; --exponent; }
                        bits = sign | (exponent << 23) | ((mantissa & 0x3ffu) << 13);
                    }
                } else if (exponent == 31) bits = sign | 0x7f800000u | (mantissa << 13);
                else bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
                float result = 0.0f;
                std::memcpy(&result, &bits, sizeof(result));
                return result;
            }(pixels[y * width * 4 + x * 4]);
            require(std::isfinite(value) && value >= 0.0f && value < 7.0f,
                    "output contains an invalid or unwritten pixel");
            mean += value;
        }
    }
    mean /= static_cast<double>(count);
    require(mean > 0.05 && mean < 2.0, "output mean outside validation range");
    std::fprintf(log, "INPROCESS_NATIVE_VALIDATION output_mean=%.6f pixels=%zu result=PASS\n",
                 mean, count);
    std::fflush(log);
    [buffer release]; [queue release];
}

void runProbe(id<MTLDevice> device, id<MTL4Compiler> compiler, FILE* log) {
    constexpr NSUInteger width = 1128, height = 624, outputWidth = 1920, outputHeight = 1080;
    const auto feature = makeFeature(device, compiler);
    Inputs inputs(device, width, height, outputWidth, outputHeight);
    Runner runner(device, compiler, log);
    std::fprintf(log,
        "INPROCESS_NATIVE_CONTEXT source_device=%p source_compiler=%p feature_create_device=%p "
        "feature_create_compiler=%p device_id=%llu device_class=%s compiler_class=%s "
        "queue=%p queue_class=%s allocator=%p command_buffer=%p fence=%p dims=1128x624->1920x1080 "
        "reset=frame0_only flags=0x42 jitter=0.1875,0.129629612 cap_requested=1\n",
        (void*)device, (void*)compiler, (void*)device, (void*)compiler,
        static_cast<unsigned long long>(device.registryID), object_getClassName((id)device),
        object_getClassName((id)compiler), (void*)runner.queue, object_getClassName((id)runner.queue),
        (void*)runner.allocator, (void*)runner.command, (void*)runner.fence);
    std::fflush(log);

    for (unsigned frame = 0; frame < 32; ++frame) {
        @autoreleasepool {
            Error error;
            FrameOperations operations{};
            operations.sharpening = false;
            operations.capOutputToTemporalMaxScale = true;
            const bool reset = frame == 0;
            const auto prepared = feature->prepare(inputs.frame(reset), inputs.textureSet(), &error, operations);
            require(prepared != nullptr, error.message.empty() ? "Feature::prepare failed" : error.message.c_str());
            runner.run(prepared, reset, frame);
        }
    }
    validateOutput(device, inputs.output, log);
}
} // namespace

extern "C" void yaagl_sr_inprocess_probe(void* devicePointer, void* compilerPointer,
                                          const char* outputPath) noexcept {
    FILE* log = stderr;
    bool closeLog = false;
    if (outputPath && outputPath[0]) {
        if (FILE* file = std::fopen(outputPath, "w")) { log = file; closeLog = true; }
    }
    auto device = reinterpret_cast<id<MTLDevice>>(devicePointer);
    auto compiler = reinterpret_cast<id<MTL4Compiler>>(compilerPointer);
    if (!device || !compiler) {
        std::fprintf(log, "INPROCESS_NATIVE_PROBE_ERROR null_borrowed_device_or_compiler\n");
    } else {
        @autoreleasepool {
            @try {
                try {
                    runProbe(device, compiler, log);
                } catch (const std::exception& error) {
                    std::fprintf(log, "INPROCESS_NATIVE_PROBE_ERROR %s\n", error.what());
                } catch (...) {
                    std::fprintf(log, "INPROCESS_NATIVE_PROBE_ERROR unknown_cpp_exception\n");
                }
            } @catch (id error) {
                std::fprintf(log, "INPROCESS_NATIVE_PROBE_ERROR objc_exception=%s\n",
                    [[error description] UTF8String]);
            }
        }
    }
    std::fflush(log);
    if (closeLog) std::fclose(log);
}
