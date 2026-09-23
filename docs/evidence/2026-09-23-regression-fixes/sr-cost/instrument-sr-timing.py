#!/usr/bin/env python3
"""Apply test-only Metal4 timing and attribution probes to temporary copies."""
from __future__ import annotations

import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(sys.argv[2]).resolve()
source = root / 'd3dmetal-pso-cache'
out.mkdir(parents=True, exist_ok=True)


def replace_once(text: str, before: str, after: str, label: str) -> str:
    count = text.count(before)
    if count != 1:
        raise SystemExit(f'{label}: expected one source anchor, found {count}')
    return text.replace(before, after, 1)


transport = (source / 'd3dmetal-transport.mm').read_text()
transport = replace_once(
    transport,
    '#include <dlfcn.h>\n',
    '#include <dlfcn.h>\n#include <chrono>\n#include <cmath>\n#include <cstdlib>\n',
    'transport includes',
)
transport = replace_once(
    transport,
    'namespace {\n\nconstexpr std::size_t kMaxResources = 8;',
    '''namespace {

struct TimingProbeRecord {
    NSUInteger base = static_cast<NSUInteger>(-1);
    double replayHostWallMs = 0.0;
};
constexpr NSUInteger kTimingProbeEntries = 4096;
constexpr NSUInteger kTimingProbeStride = 4;
std::mutex gTimingProbeLock;
id<MTL4CounterHeap> gTimingProbeHeap = nil;
std::uint64_t gTimingProbeFrequency = 0;
NSUInteger gTimingProbeNext = 0;
std::unordered_map<void*, std::vector<TimingProbeRecord>> gTimingProbeRecords;

NSUInteger reserveTimingProbe(id<MTL4CommandBuffer> commandBuffer) noexcept {
    if (!std::getenv("METALFX_SR_TIMING_PROBE") || !commandBuffer) return static_cast<NSUInteger>(-1);
    if (@available(macOS 26.0, *)) {
        try {
            std::lock_guard<std::mutex> lock(gTimingProbeLock);
            if (!gTimingProbeHeap) {
                MTL4CounterHeapDescriptor* descriptor = [MTL4CounterHeapDescriptor new];
                descriptor.type = MTL4CounterHeapTypeTimestamp;
                descriptor.count = kTimingProbeEntries;
                NSError* error = nil;
                gTimingProbeHeap = [commandBuffer.device newCounterHeapWithDescriptor:descriptor error:&error];
                [descriptor release];
                if (!gTimingProbeHeap) return static_cast<NSUInteger>(-1);
                gTimingProbeFrequency = [commandBuffer.device queryTimestampFrequency];
                if (gTimingProbeFrequency == 0) return static_cast<NSUInteger>(-1);
            }
            if (gTimingProbeNext > kTimingProbeEntries - kTimingProbeStride)
                return static_cast<NSUInteger>(-1);
            const NSUInteger base = gTimingProbeNext;
            gTimingProbeNext += kTimingProbeStride;
            gTimingProbeRecords[reinterpret_cast<void*>(commandBuffer)].push_back({base, 0.0});
            return base;
        } catch (...) {
            return static_cast<NSUInteger>(-1);
        }
    }
    return static_cast<NSUInteger>(-1);
}

void finishTimingProbe(void* commandBuffer, NSUInteger base, double replayHostWallMs) noexcept {
    if (base == static_cast<NSUInteger>(-1)) return;
    try {
        std::lock_guard<std::mutex> lock(gTimingProbeLock);
        const auto it = gTimingProbeRecords.find(commandBuffer);
        if (it == gTimingProbeRecords.end()) return;
        for (auto row = it->second.rbegin(); row != it->second.rend(); ++row) {
            if (row->base == base) { row->replayHostWallMs = replayHostWallMs; return; }
        }
    } catch (...) {
    }
}

constexpr std::size_t kMaxResources = 8;''',
    'transport probe registry',
)
transport = replace_once(
    transport,
    '@end\n\nnamespace yaagl::pso::d3dmetal {\n\nbool initialize',
    '''@end

namespace yaagl::pso::d3dmetal {

id<MTL4CounterHeap> timingProbeHeapForBuffer(void* commandBuffer) noexcept {
    if (!std::getenv("METALFX_SR_TIMING_PROBE")) return nil;
    try {
        std::lock_guard<std::mutex> lock(gTimingProbeLock);
        const auto it = gTimingProbeRecords.find(commandBuffer);
        return it == gTimingProbeRecords.end() || it->second.empty() ? nil : gTimingProbeHeap;
    } catch (...) {
        return nil;
    }
}

NSUInteger timingProbeBaseForBuffer(void* commandBuffer) noexcept {
    if (!std::getenv("METALFX_SR_TIMING_PROBE")) return static_cast<NSUInteger>(-1);
    try {
        std::lock_guard<std::mutex> lock(gTimingProbeLock);
        const auto it = gTimingProbeRecords.find(commandBuffer);
        return it == gTimingProbeRecords.end() || it->second.empty()
            ? static_cast<NSUInteger>(-1) : it->second.back().base;
    } catch (...) {
        return static_cast<NSUInteger>(-1);
    }
}

bool initialize''',
    'transport probe accessors',
)
transport = replace_once(
    transport,
    '''    bool encoded = false;
    void* replacement = nullptr;
    @try {
        // The native compute stream is live when opcode 0x3e is replayed.''',
    '''    bool encoded = false;
    void* replacement = nullptr;
    const auto replayStart = std::chrono::steady_clock::now();
    id<MTL4CommandBuffer> timingCommand = reinterpret_cast<id<MTL4CommandBuffer>>(commandBuffer);
    const NSUInteger timingBase = reserveTimingProbe(timingCommand);
    @try {
        // The native compute stream is live when opcode 0x3e is replayed.''',
    'replay timing start',
)
transport = replace_once(
    transport,
    '''        sendVoid(encoder, endSelector);
        storeAt<void*>(mplReplayer, kReplayerComputeEncoder, nullptr);

        encoded = state->encode(const_cast<void*>(command), commandBuffer, fence);

        // Re-enter the ordinary MPL compute stream exactly as ComputeEncoder::''',
    '''        sendVoid(encoder, endSelector);
        storeAt<void*>(mplReplayer, kReplayerComputeEncoder, nullptr);
        if (timingBase != static_cast<NSUInteger>(-1)) {
            @try { [timingCommand writeTimestampIntoHeap:timingProbeHeapForBuffer(commandBuffer) atIndex:timingBase]; }
            @catch (id) {}
        }

        encoded = state->encode(const_cast<void*>(command), commandBuffer, fence);
        if (timingBase != static_cast<NSUInteger>(-1)) {
            @try { [timingCommand writeTimestampIntoHeap:timingProbeHeapForBuffer(commandBuffer) atIndex:timingBase + 3]; }
            @catch (id) {}
        }

        // Re-enter the ordinary MPL compute stream exactly as ComputeEncoder::''',
    'replay SR boundaries',
)
transport = replace_once(
    transport,
    '''        sendSetObject(replacement, tableSelector, argumentTable);
        waitFence(replacement, waitSelector, fence, kComputeStage);
        return encoded;''',
    '''        sendSetObject(replacement, tableSelector, argumentTable);
        waitFence(replacement, waitSelector, fence, kComputeStage);
        finishTimingProbe(commandBuffer, timingBase,
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - replayStart).count());
        return encoded;''',
    'replay CPU timing end',
)
transport = replace_once(
    transport,
    '''    using Commit = void (*)(id, SEL, const void* const*, NSUInteger, id);
    reinterpret_cast<Commit>(objc_msgSend)(''',
    '''    std::shared_ptr<std::vector<TimingProbeRecord>> timingSamples;
    id<MTL4CounterHeap> timingHeap = nil;
    std::uint64_t timingFrequency = 0;
    if (std::getenv("METALFX_SR_TIMING_PROBE") && options && buffers) {
        try {
            timingSamples = std::make_shared<std::vector<TimingProbeRecord>>();
            {
                std::lock_guard<std::mutex> lock(gTimingProbeLock);
                timingHeap = gTimingProbeHeap;
                timingFrequency = gTimingProbeFrequency;
                for (std::size_t i = 0; i < count; ++i) {
                    const auto it = gTimingProbeRecords.find(const_cast<void*>(buffers[i]));
                    if (it == gTimingProbeRecords.end()) continue;
                    timingSamples->insert(timingSamples->end(), it->second.begin(), it->second.end());
                    gTimingProbeRecords.erase(it);
                }
            }
            if (timingSamples->empty()) timingSamples.reset();
            if (timingSamples && timingHeap && timingFrequency > 0) {
                if (@available(macOS 26.0, *)) {
                const auto commitStart = std::chrono::steady_clock::now();
                [reinterpret_cast<MTL4CommitOptions*>(options)
                    addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
                        @autoreleasepool {
                            @try {
                            const double commitFeedbackHostMs =
                                std::chrono::duration<double, std::milli>(
                                    std::chrono::steady_clock::now() - commitStart).count();
                            const double feedbackGpuStart = feedback.GPUStartTime;
                            const double feedbackGpuEnd = feedback.GPUEndTime;
                            const bool feedbackValid = std::isfinite(feedbackGpuStart) &&
                                std::isfinite(feedbackGpuEnd) && feedbackGpuEnd > feedbackGpuStart;
                            const double feedbackGpuMs = feedbackValid
                                ? (feedbackGpuEnd - feedbackGpuStart) * 1000.0 : -1.0;
                            for (const TimingProbeRecord& row : *timingSamples) {
                                NSData* resolved = [timingHeap resolveCounterRange:NSMakeRange(row.base, 4)];
                                if (!resolved || resolved.length < sizeof(MTL4TimestampHeapEntry) * 4) {
                                    std::fprintf(stderr, "YAAGL_TIMING base=%lu result=COUNTER_RESOLVE_FAILED\\n",
                                                 static_cast<unsigned long>(row.base));
                                    continue;
                                }
                                const auto* entry = static_cast<const MTL4TimestampHeapEntry*>(resolved.bytes);
                                const bool counterValid = entry[0].timestamp > 0 &&
                                    entry[0].timestamp < entry[1].timestamp &&
                                    entry[1].timestamp < entry[2].timestamp &&
                                    entry[2].timestamp < entry[3].timestamp;
                                double beforeMfxMs = -1.0, mfxMs = -1.0, afterMfxMs = -1.0, srGpuMs = -1.0;
                                if (counterValid) {
                                    const double scale = 1000.0 / static_cast<double>(timingFrequency);
                                    beforeMfxMs = double(entry[1].timestamp - entry[0].timestamp) * scale;
                                    mfxMs = double(entry[2].timestamp - entry[1].timestamp) * scale;
                                    afterMfxMs = double(entry[3].timestamp - entry[2].timestamp) * scale;
                                    srGpuMs = double(entry[3].timestamp - entry[0].timestamp) * scale;
                                }
                                std::fprintf(stderr,
                                    "YAAGL_TIMING index=%lu replay_host_wall_ms=%.4f commit_to_feedback_host_ms=%.4f "
                                    "backend_pre_gpu_ms=%.4f metalfx_fence_span_ms=%.4f backend_post_gpu_ms=%.4f "
                                    "sr_gpu_ms=%.4f feedback_gpu_ms=%.4f counter_valid=%d feedback_valid=%d result=%s\\n",
                                    static_cast<unsigned long>(row.base / 4), row.replayHostWallMs,
                                    commitFeedbackHostMs, beforeMfxMs, mfxMs, afterMfxMs, srGpuMs,
                                    feedbackGpuMs, counterValid ? 1 : 0, feedbackValid ? 1 : 0,
                                    counterValid ? "PASS" : "INVALID");
                            }
                            } @catch (id) {
                                std::fprintf(stderr, "YAAGL_TIMING result=COUNTER_RESOLVE_EXCEPTION\\n");
                            }
                        }
                    }];
                }
            }
        } catch (...) {
            std::fprintf(stderr, "YAAGL_TIMING result=HANDLER_SETUP_FAILED\\n");
        }
    }
    using Commit = void (*)(id, SEL, const void* const*, NSUInteger, id);
    reinterpret_cast<Commit>(objc_msgSend)(''',
    'DoExecute feedback timing',
)
# One-shot native experiment in the FFX process on the borrowed MPL context.
transport = replace_once(transport,
    '    out.compiler = compiler;\n    out.qiOwner = owner;\n    return true;',
    '''    out.compiler = compiler;
    out.qiOwner = owner;
    if (const char* path = std::getenv("METALFX_SR_INPROCESS_OUTPUT")) {
        static std::atomic<bool> started{false};
        if (!started.exchange(true)) yaagl_sr_inprocess_probe(device, compiler, path);
    }
    return true;''', 'in-process borrowed context')
transport = replace_once(transport,
    'namespace yaagl::pso::d3dmetal {\n\nid<MTL4CounterHeap> timingProbeHeapForBuffer',
    '''namespace yaagl::pso::d3dmetal {

NSUInteger reserveTimingProbeForInProcess(void* commandBuffer) noexcept {
    return reserveTimingProbe(reinterpret_cast<id<MTL4CommandBuffer>>(commandBuffer));
}
void releaseTimingProbeForInProcess(void* commandBuffer, NSUInteger base) noexcept {
    try {
        std::lock_guard<std::mutex> lock(gTimingProbeLock);
        const auto it = gTimingProbeRecords.find(commandBuffer);
        if (it == gTimingProbeRecords.end()) return;
        auto& rows = it->second;
        rows.erase(std::remove_if(rows.begin(), rows.end(),
            [base](const TimingProbeRecord& row) { return row.base == base; }), rows.end());
        if (rows.empty()) gTimingProbeRecords.erase(it);
    } catch (...) {}
}

id<MTL4CounterHeap> timingProbeHeapForBuffer''', 'in-process counter access')
transport = '#include <algorithm>\nextern "C" void yaagl_sr_inprocess_probe(void*, void*, const char*) noexcept;\n' + transport
(out / 'd3dmetal-transport.timing.mm').write_text(transport)

backend = (source / 'metalfx-backend.mm').read_text()
backend = replace_once(
    backend,
    '#import <MetalFX/MetalFX.h>\n',
    '''#import <MetalFX/MetalFX.h>

#include <cstdio>
#include <cstdlib>
#import <objc/runtime.h>

namespace {
bool srConfigEnabled() noexcept {
    const char* value = std::getenv("METALFX_SR_CONFIG_PROBE");
    return value && value[0] == '1';
}
bool srDefaultCompilerRequested() noexcept {
    const char* value = std::getenv("METALFX_SR_DEFAULT_COMPILER");
    return value && value[0] == '1';
}
const char* srObjectClass(id object) noexcept {
    return object ? object_getClassName(object) : "<nil>";
}
const char* srPixelFormatName(MTLPixelFormat format) noexcept {
    switch (format) {
        case MTLPixelFormatRGBA16Float: return "RGBA16Float";
        case MTLPixelFormatR32Float: return "R32Float";
        case MTLPixelFormatRG16Float: return "RG16Float";
        case MTLPixelFormatR8Unorm: return "R8Unorm";
        default: return "other";
    }
}
const char* srStorageModeName(MTLStorageMode mode) noexcept {
    switch (mode) {
        case MTLStorageModeShared: return "Shared";
        case MTLStorageModePrivate: return "Private";
        case MTLStorageModeManaged: return "Managed";
        case MTLStorageModeMemoryless: return "Memoryless";
        default: return "other";
    }
}
void srLogTexture(const char* name, id<MTLTexture> texture) noexcept {
    if (!srConfigEnabled()) return;
    if (!texture) {
        std::fprintf(stderr, "YAAGL_SR_CONFIG texture name=%s value=<nil>\\n", name);
        return;
    }
    id<MTLBuffer> buffer = texture.buffer;
    id<MTLTexture> parent = texture.parentTexture;
    id<MTLHeap> heap = texture.heap;
    IOSurfaceRef surface = texture.iosurface;
    std::fprintf(stderr,
        "YAAGL_SR_CONFIG texture name=%s size=%lux%lu format=%s:%u storage=%s:%u usage=0x%lx device_id=%llu buffer=%p buffer_class=%s buffer_length=%llu buffer_offset=%lu buffer_bpr=%lu parent=%p parent_class=%s heap=%p heap_class=%s optimized=%d hazard=%u iosurface=%p iosurface_plane=%lu\\n",
        name, static_cast<unsigned long>(texture.width),
        static_cast<unsigned long>(texture.height), srPixelFormatName(texture.pixelFormat),
        static_cast<unsigned>(texture.pixelFormat), srStorageModeName(texture.storageMode),
        static_cast<unsigned>(texture.storageMode), static_cast<unsigned long>(texture.usage),
        static_cast<unsigned long long>(texture.device.registryID), buffer,
        srObjectClass((id)buffer), static_cast<unsigned long long>(buffer ? buffer.length : 0),
        static_cast<unsigned long>(texture.bufferOffset), static_cast<unsigned long>(texture.bufferBytesPerRow),
        parent, srObjectClass((id)parent), heap, srObjectClass((id)heap),
        texture.allowGPUOptimizedContents, static_cast<unsigned>(texture.hazardTrackingMode),
        surface, static_cast<unsigned long>(texture.iosurfacePlane));
}
void srLogCompiler(const char* role, id<MTLDevice> device, id<MTL4Compiler> compiler) noexcept {
    if (!srConfigEnabled()) return;
    NSString* label = compiler ? compiler.label : nil;
    id serializer = compiler ? (id)compiler.pipelineDataSetSerializer : nil;
    NSString* name = device ? device.name : nil;
    std::fprintf(stderr,
        "YAAGL_SR_CONFIG compiler role=%s object=%p class=%s device_id=%llu device_name=%s label=%s serializer_class=%s\\n",
        role, (void*)compiler, srObjectClass((id)compiler),
        static_cast<unsigned long long>(device ? device.registryID : 0),
        name ? name.UTF8String : "<nil>", label ? label.UTF8String : "<nil>",
        srObjectClass(serializer));
}
}

namespace yaagl::pso::d3dmetal {
id<MTL4CounterHeap> timingProbeHeapForBuffer(void*) noexcept;
NSUInteger timingProbeBaseForBuffer(void*) noexcept;
}
''',
    'backend probe declarations',
)
backend = replace_once(
    backend,
    '    float maxScale = 1.0f;\n    std::shared_ptr<ScalerGeneration> currentGeneration;',
    '    float maxScale = 1.0f;\n    bool srConfigPrinted = false;\n    std::shared_ptr<ScalerGeneration> currentGeneration;',
    'test-only config snapshot state',
)
backend = replace_once(
    backend,
    '        impl->compiler = retainObject(asCompiler(context.compiler));\n',
    '''        impl->compiler = retainObject(asCompiler(context.compiler));
        if (::srConfigEnabled()) {
            ::srLogCompiler("borrowed-original", impl->device,
                            reinterpret_cast<id<MTL4Compiler>>(impl->compiler));
            std::fprintf(stderr,
                "YAAGL_SR_CONFIG create mode=%u flags=0x%x input=%lux%lu output=%lux%lu lowres_motion=%d auto_exposure=%d jittered_motion=%d depth_inverted=%d output_subrects=%d\\n",
                static_cast<unsigned>(context.mode), static_cast<unsigned>(info.featureFlags.value),
                static_cast<unsigned long>(info.input.width), static_cast<unsigned long>(info.input.height),
                static_cast<unsigned long>(info.output.width), static_cast<unsigned long>(info.output.height),
                info.lowResolutionMotionVectors(), info.autoExposure(), info.jitteredMotionVectors(),
                info.depthInverted(), info.outputSubrects.value);
        }
        if (::srDefaultCompilerRequested()) {
            if (context.mode != CommandMode::Metal4) {
                setError(error, ErrorCode::InvalidContext,
                         "test-only default compiler requires Metal4 mode");
                return {};
            }
            if (@available(macOS 26.0, *)) {
                MTL4CompilerDescriptor* descriptor = [MTL4CompilerDescriptor new];
                NSError* compilerError = nil;
                id<MTL4Compiler> replacement =
                    [impl->device newCompilerWithDescriptor:descriptor error:&compilerError];
                [descriptor release];
                if (!replacement || replacement.device != impl->device) {
                    [replacement release];
                    setError(error, ErrorCode::InvalidContext,
                             "test-only same-device default MTL4Compiler creation failed");
                    return {};
                }
                releaseObject(impl->compiler);
                impl->compiler = replacement;
            } else {
                setError(error, ErrorCode::UnsupportedFeature,
                         "test-only default compiler requires macOS 26");
                return {};
            }
        }
        ::srLogCompiler("selected", impl->device,
                        reinterpret_cast<id<MTL4Compiler>>(impl->compiler));
''',
    'same-device default compiler discriminator',
)
backend = replace_once(
    backend,
    '        return std::shared_ptr<Feature>(new Feature(std::move(impl)));',
    '''        if (::srConfigEnabled()) {
            std::fprintf(stderr,
                "YAAGL_SR_CONFIG feature device_class=%s device_id=%llu mode=%u flags=0x%x input=%lux%lu output=%lux%lu min_scale=%.8f max_scale=%.8f auto_exposure=%d lowres_motion=%d jittered_motion=%d depth_inverted=%d output_subrects=%d\\n",
                ::srObjectClass((id)impl->device),
                static_cast<unsigned long long>(impl->device.registryID),
                static_cast<unsigned>(impl->commandMode), static_cast<unsigned>(impl->create.featureFlags.value),
                static_cast<unsigned long>(impl->create.input.width), static_cast<unsigned long>(impl->create.input.height),
                static_cast<unsigned long>(impl->create.output.width), static_cast<unsigned long>(impl->create.output.height),
                impl->minScale, impl->maxScale, impl->create.autoExposure(),
                impl->create.lowResolutionMotionVectors(), impl->create.jitteredMotionVectors(),
                impl->create.depthInverted(), impl->create.outputSubrects.value);
        }
        return std::shared_ptr<Feature>(new Feature(std::move(impl)));''',
    'runtime feature configuration',
)
backend = replace_once(
    backend,
    '        feature.currentGeneration = generation;\n        return generation;',
    '''        if (::srConfigEnabled()) {
            std::fprintf(stderr,
                "YAAGL_SR_CONFIG scaler class=%s device_id=%llu mode=%u input_capacity=%lux%lu active_input=%lux%lu descriptor_output=%lux%lu requested_output_rect=%u,%u,%u,%u temporal_output=%lux%lu placement=%lu,%lu capped=%d max_scale=%.8f auto_exposure=%d lowres_motion=%d jittered_motion=%d reactive_enabled=%d reactive_format=%s:%u color_format=%s:%u depth_format=%s:%u motion_format=%s:%u output_format=%s:%u ops_transfer=%u sharpen=%d combine_mask=%d cap_to_max=%d jitter=%.8f,%.8f motion_scale=%.8f,%.8f pre_exposure=%.8f reset=%d required_usage=color:0x%lx,depth:0x%lx,motion:0x%lx,output:0x%lx,reactive:0x%lx\\n",
                ::srObjectClass(scaler), static_cast<unsigned long long>(feature.device.registryID),
                static_cast<unsigned>(feature.commandMode),
                static_cast<unsigned long>(inputCapacityWidth), static_cast<unsigned long>(inputCapacityHeight),
                static_cast<unsigned long>(frame.inputContent.width), static_cast<unsigned long>(frame.inputContent.height),
                static_cast<unsigned long>(temporal.width), static_cast<unsigned long>(temporal.height),
                frame.outputRect.x, frame.outputRect.y, frame.outputRect.width, frame.outputRect.height,
                static_cast<unsigned long>(temporal.width), static_cast<unsigned long>(temporal.height),
                static_cast<unsigned long>(temporal.placementX), static_cast<unsigned long>(temporal.placementY),
                temporal.capped, feature.maxScale, feature.create.autoExposure(),
                feature.create.lowResolutionMotionVectors(), feature.create.jitteredMotionVectors(),
                generation->reactiveEnabled, ::srPixelFormatName(generation->reactiveFormat),
                static_cast<unsigned>(generation->reactiveFormat), ::srPixelFormatName(generation->colorFormat),
                static_cast<unsigned>(generation->colorFormat), ::srPixelFormatName(generation->depthFormat),
                static_cast<unsigned>(generation->depthFormat), ::srPixelFormatName(generation->motionFormat),
                static_cast<unsigned>(generation->motionFormat), ::srPixelFormatName(generation->outputFormat),
                static_cast<unsigned>(generation->outputFormat), static_cast<unsigned>(operations.colorTransfer),
                operations.sharpening, operations.combineCompositionMask,
                operations.capOutputToTemporalMaxScale, frame.jitterOffsetX.value, frame.jitterOffsetY.value,
                frame.motionVectorScaleX.value, frame.motionVectorScaleY.value, frame.preExposure.value,
                frame.resetHistory.value, static_cast<unsigned long>(generation->colorUsage),
                static_cast<unsigned long>(generation->depthUsage), static_cast<unsigned long>(generation->motionUsage),
                static_cast<unsigned long>(generation->outputUsage), static_cast<unsigned long>(generation->reactiveUsage));
        }
        feature.currentGeneration = generation;
        return generation;''',
    'runtime scaler and descriptor configuration',
)
backend = replace_once(
    backend,
    '        frame->needsExposureConversion = exposureConversion;\n\n        // Pre-create one complete execution resource set.',
    '''        frame->needsExposureConversion = exposureConversion;
        const bool printSrConfig = ::srConfigEnabled() && !impl_->srConfigPrinted;
        if (printSrConfig) {
            impl_->srConfigPrinted = true;
            std::fprintf(stderr,
                "YAAGL_SR_CONFIG frame active_input=%lux%lu output_rect=%u,%u,%u,%u temporal_output=%lux%lu placement=%lu,%lu capped=%d exposure_mode=%u needs_staging=color:%d,depth:%d,motion:%d,reactive:%d,output_shadow:%d,exposure_conversion:%d\\n",
                static_cast<unsigned long>(info.inputContent.width), static_cast<unsigned long>(info.inputContent.height),
                info.outputRect.x, info.outputRect.y, info.outputRect.width, info.outputRect.height,
                static_cast<unsigned long>(temporal.width), static_cast<unsigned long>(temporal.height),
                static_cast<unsigned long>(temporal.placementX), static_cast<unsigned long>(temporal.placementY),
                temporal.capped, static_cast<unsigned>(info.exposureMode), frame->needsColorStaging,
                frame->needsDepthStaging, frame->needsMotionStaging, frame->needsReactiveStaging,
                frame->needsOutputShadow, frame->needsExposureConversion);
            ::srLogTexture("caller_color", color);
            ::srLogTexture("caller_depth", depth);
            ::srLogTexture("caller_motion", motion);
            ::srLogTexture("caller_reactive", reactive);
            ::srLogTexture("caller_output", output);
            ::srLogTexture("caller_exposure", exposure);
        }

        // Pre-create one complete execution resource set.''',
    'runtime frame resources and staging decision',
)
backend = replace_once(
    backend,
    '        frame->firstLease = makeLease(*frame, error);\n        if (!frame->firstLease) return {};',
    '''        frame->firstLease = makeLease(*frame, error);
        if (!frame->firstLease) return {};
        if (printSrConfig) {
            ::srLogTexture("metalfx_color", frame->firstLease->linearColor ? frame->firstLease->linearColor :
                           (frame->firstLease->stagedColor ? frame->firstLease->stagedColor : frame->color));
            ::srLogTexture("metalfx_depth", frame->firstLease->stagedDepth ? frame->firstLease->stagedDepth : frame->depth);
            ::srLogTexture("metalfx_motion", frame->firstLease->stagedMotion ? frame->firstLease->stagedMotion : frame->motion);
            ::srLogTexture("metalfx_reactive", frame->firstLease->combinedMask ? frame->firstLease->combinedMask :
                           (frame->firstLease->stagedReactive ? frame->firstLease->stagedReactive : frame->reactive));
            ::srLogTexture("metalfx_output", frame->firstLease->privateOutput ? frame->firstLease->privateOutput : frame->output);
            ::srLogTexture("metalfx_exposure", frame->firstLease->convertedExposure ? frame->firstLease->convertedExposure : frame->exposure);
        }''',
    'effective scaler textures after staging',
)
backend = replace_once(
    backend,
    '''                    beginObservation();
                    [generation.scaler encodeToCommandBuffer:command];
                    if (!encodeFsrFinishMetal4''',
    '''                    beginObservation();
                    const id<MTL4CounterHeap> timingHeap =
                        ::yaagl::pso::d3dmetal::timingProbeHeapForBuffer(commandBuffer);
                    const NSUInteger timingBase =
                        ::yaagl::pso::d3dmetal::timingProbeBaseForBuffer(commandBuffer);
                    if (timingHeap && timingBase != static_cast<NSUInteger>(-1)) {
                        @try { [command writeTimestampIntoHeap:timingHeap atIndex:timingBase + 1]; }
                        @catch (id) {}
                    }
                    [generation.scaler encodeToCommandBuffer:command];
                    if (timingHeap && timingBase != static_cast<NSUInteger>(-1)) {
                        @try { [command writeTimestampIntoHeap:timingHeap atIndex:timingBase + 2]; }
                        @catch (id) {}
                    }
                    if (!encodeFsrFinishMetal4''',
    'MetalFX exact GPU boundaries',
)
(out / 'metalfx-backend.timing.mm').write_text(backend)
print(f'Wrote test-only timing copies to {out}')
