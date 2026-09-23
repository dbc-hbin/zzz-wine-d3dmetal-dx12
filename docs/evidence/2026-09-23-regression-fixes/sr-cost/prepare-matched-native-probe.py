#!/usr/bin/env python3
"""Create an FFX-aligned standalone probe with observed D3DMetal resources."""
from __future__ import annotations

import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
out.parent.mkdir(parents=True, exist_ok=True)


def replace_once(before: str, after: str, label: str) -> None:
    global source
    count = source.count(before)
    if count != 1:
        raise SystemExit(f'{label}: expected one source anchor, found {count}')
    source = source.replace(before, after, 1)


replace_once(
    'id<MTL4CounterHeap> gSRProbeHeap = nil;\n',
    '''id<MTL4CounterHeap> gSRProbeHeap = nil;
namespace yaagl::pso::d3dmetal {
id<MTL4CounterHeap> timingProbeHeapForBuffer(void*) noexcept { return ::gSRProbeHeap; }
NSUInteger timingProbeBaseForBuffer(void*) noexcept { return 0; }
}
''',
    'standalone timing counter bridge',
)
replace_once(
    'f.jitterOffsetX={0.f,true}; f.jitterOffsetY={0.f,true};',
    'f.jitterOffsetX={0.1875f,true}; f.jitterOffsetY={0.129629612f,true};',
    'FFX jitter alignment',
)
replace_once(
    'operations.sharpening=false;',
    'operations.sharpening=false; operations.capOutputToTemporalMaxScale=true;',
    'FFX temporal output-cap alignment',
)
replace_once(
    '''static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger w, NSUInteger h,
                               MTLPixelFormat format, MTLStorageMode storage) {''',
    '''static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger w, NSUInteger h,
                               MTLPixelFormat format, MTLStorageMode storage,
                               MTLTextureUsage usage) {''',
    'matching caller resource descriptor',
)
replace_once(
    '    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;',
    '    desc.usage = usage;\n    desc.allowGPUOptimizedContents = YES;\n    desc.hazardTrackingMode = MTLHazardTrackingModeUntracked;',
    'matching caller usage and tracking mode',
)
for before, after, label in (
    ('color(texture(d,w,h,MTLPixelFormatRGBA16Float,MTLStorageModeShared))',
     'color(texture(d,w,h,MTLPixelFormatRGBA16Float,MTLStorageModeShared, MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView))',
     'matching color caller texture'),
    ('depth(texture(d,w,h,MTLPixelFormatR32Float,MTLStorageModeShared))',
     'depth(texture(d,w,h,MTLPixelFormatR32Float,MTLStorageModeShared, MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView))',
     'matching depth caller texture'),
    ('motion(texture(d,w,h,MTLPixelFormatRG16Float,MTLStorageModeShared))',
     'motion(texture(d,w,h,MTLPixelFormatRG16Float,MTLStorageModeShared, MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView))',
     'matching motion caller texture'),
    ('reactive(texture(d,w,h,MTLPixelFormatR8Unorm,MTLStorageModeShared))',
     'reactive(texture(d,w,h,MTLPixelFormatR8Unorm,MTLStorageModeShared, MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView))',
     'matching reactive caller texture'),
    ('output(texture(d,ow,oh,MTLPixelFormatRGBA16Float,MTLStorageModePrivate))',
     'output(texture(d,ow,oh,MTLPixelFormatRGBA16Float,MTLStorageModeShared, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView))',
     'matching output caller texture'),
):
    replace_once(before, after, label)

replace_once(
    '''    id<MTL4CommandBuffer> command;
    bool used=false; unsigned frameNumber=0;
    explicit Runner(id<MTLDevice> d): device(d),queue([d newMTL4CommandQueue]),
        allocator([d newCommandAllocator]),command([d newCommandBuffer]) {
        check(queue && allocator && command,"Metal4 runner");''',
    '''    id<MTL4CommandBuffer> command;
    id<MTLFence> fence=nil;
    bool used=false; unsigned frameNumber=0;
    explicit Runner(id<MTLDevice> d): device(d),queue([d newMTL4CommandQueue]),
        allocator([d newCommandAllocator]),command([d newCommandBuffer]) {
        check(queue && allocator && command,"Metal4 runner");
        fence=[d newFence]; check(fence != nil,"persistent fence");''',
    'persistent per-runner fence',
)
replace_once(
    '~Runner() { [gSRProbeHeap release]; gSRProbeHeap=nil; [command release]; [allocator release]; [queue release]; }',
    '~Runner() { [gSRProbeHeap release]; gSRProbeHeap=nil; [fence release]; [command release]; [allocator release]; [queue release]; }',
    'persistent fence ownership',
)
replace_once(
    '''    void run(const std::shared_ptr<const PreparedFrame>& prepared) {
        if (used) [allocator reset];
        used=true;
        id<MTLFence> fence=[device newFence]; check(fence != nil,"fence");''',
    '''    void run(const std::shared_ptr<const PreparedFrame>& prepared, bool resetHistory) {
        if (used) [allocator reset];
        used=true;''',
    'reuse fence without changing producer/consumer order',
)
replace_once(
    '''std::printf("GPU_PROBE frame=%u pre_ms=%.4f scaler_ms=%.4f finish_ms=%.4f total_ms=%.4f commit_wall_ms=%.4f feedback_gpu_start=%.9f feedback_gpu_end=%.9f\\n",frameNumber++,''',
    '''std::printf("GPU_PROBE frame=%u reset=%u fence=%p pre_ms=%.4f scaler_ms=%.4f finish_ms=%.4f total_ms=%.4f commit_wall_ms=%.4f feedback_gpu_start=%.9f feedback_gpu_end=%.9f\\n",frameNumber++, resetHistory ? 1u : 0u, (void*)fence,''',
    'log caller reset and reused fence identity',
)
replace_once(
    '[gpuError release]; [options release]; dispatch_release(done); [fence release];',
    '[gpuError release]; [options release]; dispatch_release(done);',
    'release persistent fence with runner',
)
replace_once(
    '''                   Inputs& inputs, unsigned w, unsigned h, unsigned ow, unsigned oh,
                   unsigned n, const char* label) {''',
    '''                   Inputs& inputs, unsigned w, unsigned h, unsigned ow, unsigned oh,
                   unsigned n, bool resetFirst, const char* label) {''',
    'carry reset schedule across frame batches',
)
replace_once(
    '''auto prepared=f->prepare(inputs.frame(w,h,ow,oh,i==0),inputs.set(),&error,operations);''',
    '''const bool resetHistory=resetFirst && i==0;
        auto prepared=f->prepare(inputs.frame(w,h,ow,oh,resetHistory),inputs.set(),&error,operations);''',
    'reset only first overall frame',
)
replace_once('runner.run(prepared);','runner.run(prepared,resetHistory);','log corrected reset schedule')
replace_once(
    'frames(device,runner,f,inputs,1128,624,1920,1080,8,"warm 8 drained");',
    'frames(device,runner,f,inputs,1128,624,1920,1080,8,true,"warm 8 drained");',
    'warmup reset true once',
)
replace_once(
    'frames(device,runner,f,inputs,1128,624,1920,1080,24,"steady 24 drained");',
    'frames(device,runner,f,inputs,1128,624,1920,1080,24,false,"steady 24 drained");',
    'steady frames preserve temporal history',
)

replace_once(
    'scaler_ms=',
    'metalfx_fence_span_ms=',
    'label MetalFX encode span as fence-inclusive-capable, not kernel-only',
)

out.write_text(source)
print(f'Wrote FFX-aligned standalone probe to {out}')
