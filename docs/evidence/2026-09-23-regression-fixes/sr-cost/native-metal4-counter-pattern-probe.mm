#import "metalfx-backend.hpp"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <mach/mach.h>
#include <cstdio>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>
#include <chrono>
#include <cstdlib>
#include <memory>
using namespace yaagl::pso::metalfx;
id<MTL4CounterHeap> gSRProbeHeap = nil;

static void check(bool value, const char* text) {
    if (!value) { std::fprintf(stderr, "FAIL %s\n", text); std::exit(1); }
}
static float halfToFloat(std::uint16_t value) { std::uint32_t sign=std::uint32_t(value&0x8000u)<<16, exp=(value>>10)&0x1fu, mant=value&0x3ffu, bits; if(exp==0){if(mant==0)bits=sign;else{exp=113;while((mant&0x400u)==0){mant<<=1;--exp;}bits=sign|(exp<<23)|((mant&0x3ffu)<<13);}}else if(exp==31)bits=sign|0x7f800000u|(mant<<13);else bits=sign|((exp+112)<<23)|(mant<<13);float out;std::memcpy(&out,&bits,sizeof(out));return out;}

static void sample(id<MTLDevice> device, const char* phase) {
    task_vm_info_data_t vm{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t rc = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count);
    mach_task_basic_info_data_t basic{};
    count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t rc2 = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basic, &count);
    std::printf("%-24s metal=%8.2f MiB footprint=%8.2f MiB rss=%8.2f MiB\n", phase,
        double(device.currentAllocatedSize)/1048576., rc == KERN_SUCCESS ? double(vm.phys_footprint)/1048576. : -1.,
        rc2 == KERN_SUCCESS ? double(basic.resident_size)/1048576. : -1.);
    std::fflush(stdout);
}
static id<MTLTexture> texture(id<MTLDevice> device, NSUInteger w, NSUInteger h,
                               MTLPixelFormat format, MTLStorageMode storage) {
    auto* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    desc.storageMode = storage;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> result = [device newTextureWithDescriptor:desc];
    check(result != nil, "texture allocation");
    return result;
}
struct Inputs {
    id<MTLTexture> color, depth, motion, reactive, output;
    Inputs(id<MTLDevice> d, NSUInteger w, NSUInteger h, NSUInteger ow, NSUInteger oh)
        : color(texture(d,w,h,MTLPixelFormatRGBA16Float,MTLStorageModeShared)),
          depth(texture(d,w,h,MTLPixelFormatR32Float,MTLStorageModeShared)),
          motion(texture(d,w,h,MTLPixelFormatRG16Float,MTLStorageModeShared)),
          reactive(texture(d,w,h,MTLPixelFormatR8Unorm,MTLStorageModeShared)),
          output(texture(d,ow,oh,MTLPixelFormatRGBA16Float,MTLStorageModePrivate)) {
        std::vector<std::uint16_t> cp((size_t)w*h*4);
        std::vector<float> dp((size_t)w*h,0.5f);
        std::vector<std::uint16_t> mp((size_t)w*h*2,0);
        std::vector<std::uint8_t> rp((size_t)w*h);
        auto toHalf=[](float value) { std::uint32_t bits; std::memcpy(&bits,&value,sizeof(bits));
            const std::uint32_t sign=(bits>>16)&0x8000u; int e=int((bits>>23)&0xffu)-112;
            std::uint32_t mantissa=bits&0x7fffffu; if(e<=0) { if(e < -10) return (std::uint16_t)sign; mantissa=(mantissa|0x800000u)>>(1-e); return (std::uint16_t)(sign|((mantissa+0x1000u)>>13)); }
            if(e>=31) return (std::uint16_t)(sign|0x7c00u); return (std::uint16_t)(sign|(std::uint32_t(e)<<10)|((mantissa+0x1000u)>>13)); };
        for(NSUInteger y=0;y<h;++y) for(NSUInteger x=0;x<w;++x) { size_t i=(size_t(y)*w+x)*4; cp[i]=toHalf(.2f+.5f*float(x%17)/16.f); cp[i+1]=toHalf(.4f); cp[i+2]=toHalf(.7f); cp[i+3]=toHalf(1.f); rp[size_t(y)*w+x]=((x/8+y/8)&1)?255:0; }
        const MTLRegion region=MTLRegionMake2D(0,0,w,h);
        [color replaceRegion:region mipmapLevel:0 withBytes:cp.data() bytesPerRow:w*8];
        [depth replaceRegion:region mipmapLevel:0 withBytes:dp.data() bytesPerRow:w*4];
        [motion replaceRegion:region mipmapLevel:0 withBytes:mp.data() bytesPerRow:w*4];
        [reactive replaceRegion:region mipmapLevel:0 withBytes:rp.data() bytesPerRow:w];
    }
    ~Inputs() { [color release]; [depth release]; [motion release]; [reactive release]; [output release]; }
    TextureSet set() const { return {(void*)color,(void*)depth,(void*)motion,(void*)output,nullptr,(void*)reactive,nullptr}; }
    FrameInfo frame(unsigned w, unsigned h, unsigned ow, unsigned oh, bool reset) const {
        FrameInfo f{};
        f.color=(void*)color; f.depth=(void*)depth; f.motionVectors=(void*)motion; f.output=(void*)output; f.reactiveMask={(void*)reactive,true};
        f.inputContent={w,h}; f.colorRect={0,0,w,h}; f.depthRect=f.colorRect;
        f.motionRect=f.colorRect; f.reactiveRect=f.colorRect; f.outputRect={0,0,ow,oh};
        f.jitterOffsetX={0.f,true}; f.jitterOffsetY={0.f,true};
        f.motionVectorScaleX={float(w),true}; f.motionVectorScaleY={float(h),true};
        f.preExposure={1.f,true}; f.resetHistory={reset,true}; f.exposureMode=ExposureMode::Automatic;
        return f;
    }
};
static std::shared_ptr<Feature> feature(id<MTLDevice> d, id<MTL4Compiler> compiler,
                                         unsigned w, unsigned h, unsigned ow, unsigned oh) {
    CreateInfo info{}; info.input={w,h}; info.output={ow,oh};
    info.featureFlags={std::uint32_t(FeatureFlagMVLowRes | FeatureFlagAutoExposure),true};
    info.outputSubrects={false,true};
    Error error;
    auto result=Feature::create({(void*)d,(void*)compiler,CommandMode::Metal4},info,&error);
    check(result != nullptr,error.message.empty()?"feature creation":error.message.c_str());
    return result;
}
struct Runner {
    id<MTLDevice> device;
    id<MTL4CommandQueue> queue;
    id<MTL4CommandAllocator> allocator;
    id<MTL4CommandBuffer> command;
    bool used=false; unsigned frameNumber=0;
    explicit Runner(id<MTLDevice> d): device(d),queue([d newMTL4CommandQueue]),
        allocator([d newCommandAllocator]),command([d newCommandBuffer]) {
        check(queue && allocator && command,"Metal4 runner");
        MTL4CounterHeapDescriptor* desc=[MTL4CounterHeapDescriptor new]; desc.type=MTL4CounterHeapTypeTimestamp; desc.count=4;
        NSError* err=nil; gSRProbeHeap=[d newCounterHeapWithDescriptor:desc error:&err]; [desc release];
        check(gSRProbeHeap != nil,"counter heap");
        std::printf("GPU_FREQ=%llu\n",(unsigned long long)[d queryTimestampFrequency]);
    }
    ~Runner() { [gSRProbeHeap release]; gSRProbeHeap=nil; [command release]; [allocator release]; [queue release]; }
    void run(const std::shared_ptr<const PreparedFrame>& prepared) {
        if (used) [allocator reset];
        used=true;
        id<MTLFence> fence=[device newFence]; check(fence != nil,"fence");
        [command beginCommandBufferWithAllocator:allocator];
        id<MTL4ComputeCommandEncoder> producer=[command computeCommandEncoder];
        [producer updateFence:fence afterEncoderStages:MTLStageDispatch]; [producer endEncoding];
        [command writeTimestampIntoHeap:gSRProbeHeap atIndex:0];
        std::shared_ptr<const ExecutionLease> lease;
        Error error;
        bool encoded=prepared->encode((void*)command,(void*)fence,lease,&error);
        check(encoded && lease != nullptr,error.message.empty()?"MetalFX encode":error.message.c_str());
        id<MTL4ComputeCommandEncoder> consumer=[command computeCommandEncoder];
        [consumer waitForFence:fence beforeEncoderStages:MTLStageBlit]; [consumer endEncoding];
        [command writeTimestampIntoHeap:gSRProbeHeap atIndex:3];
        [command endCommandBuffer];
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        __block NSError* gpuError=nil;
        __block CFTimeInterval feedbackStart=0.0, feedbackEnd=0.0;
        MTL4CommitOptions* options=[MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            feedbackStart=feedback.GPUStartTime; feedbackEnd=feedback.GPUEndTime;
            gpuError=[feedback.error retain]; dispatch_semaphore_signal(done);
        }];
        id<MTL4CommandBuffer> batch[]={command};
        const auto wallStart=std::chrono::steady_clock::now();
        [queue commit:batch count:1 options:options];
        check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0,"GPU timeout");
        const double wallMs=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-wallStart).count();
        if (gpuError) NSLog(@"GPU error: %@",gpuError);
        check(gpuError == nil,"GPU completion");
        NSData* resolved=[gSRProbeHeap resolveCounterRange:NSMakeRange(0,4)];
        check(resolved != nil && resolved.length == sizeof(MTL4TimestampHeapEntry)*4,"resolved timestamp size");
        const auto* entry=(const MTL4TimestampHeapEntry*)resolved.bytes;
        const uint64_t freq=[device queryTimestampFrequency];
        check(freq > 0 && entry[0].timestamp > 0 && entry[0].timestamp < entry[1].timestamp &&
              entry[1].timestamp < entry[2].timestamp && entry[2].timestamp < entry[3].timestamp, "valid monotonic GPU timestamps");
        std::printf("GPU_PROBE frame=%u pre_ms=%.4f scaler_ms=%.4f finish_ms=%.4f total_ms=%.4f commit_wall_ms=%.4f feedback_gpu_start=%.9f feedback_gpu_end=%.9f\n",frameNumber++,
           double(entry[1].timestamp-entry[0].timestamp)*1000./freq,
           double(entry[2].timestamp-entry[1].timestamp)*1000./freq,
           double(entry[3].timestamp-entry[2].timestamp)*1000./freq,
           double(entry[3].timestamp-entry[0].timestamp)*1000./freq, wallMs, feedbackStart, feedbackEnd);
        [gpuError release]; [options release]; dispatch_release(done); [fence release];
        lease.reset(); // Real transport keeps leases until the allocator retires.
        [allocator reset]; used=false;
    }
};
static void frames(id<MTLDevice> device, Runner& runner, std::shared_ptr<Feature>& f,
                   Inputs& inputs, unsigned w, unsigned h, unsigned ow, unsigned oh,
                   unsigned n, const char* label) {
    for (unsigned i=0;i<n;++i) @autoreleasepool {
        Error error;
        FrameOperations operations{};
        operations.sharpening=false;
        auto prepared=f->prepare(inputs.frame(w,h,ow,oh,i==0),inputs.set(),&error,operations);
        check(prepared != nullptr,error.message.empty()?"prepare":error.message.c_str());
        runner.run(prepared);
    }
    sample(device,label);
}
int main() {
    @autoreleasepool {
        id<MTLDevice> device=MTLCreateSystemDefaultDevice(); check(device != nil,"device");
        sample(device,"device baseline");
        MTL4CompilerDescriptor* desc=[MTL4CompilerDescriptor new]; NSError* err=nil;
        id<MTL4Compiler> compiler=[device newCompilerWithDescriptor:desc error:&err]; [desc release];
        check(compiler != nil,"compiler");
        sample(device,"compiler baseline");
        @autoreleasepool {
            Runner runner(device);
            Inputs inputs(device,1128,624,1920,1080);
            sample(device,"caller textures");
            auto f=feature(device,compiler,1128,624,1920,1080);
            frames(device,runner,f,inputs,1128,624,1920,1080,8,"warm 8 drained");
            frames(device,runner,f,inputs,1128,624,1920,1080,24,"steady 24 drained");
            id<MTLCommandQueue> q=[device newCommandQueue]; id<MTLCommandBuffer> cb=[q commandBuffer];
            constexpr NSUInteger rowBytes=1920*8, imageBytes=rowBytes*1080;
            id<MTLBuffer> readback=[device newBufferWithLength:imageBytes options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
            [blit copyFromTexture:inputs.output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1920,1080,1) toBuffer:readback destinationOffset:0 destinationBytesPerRow:rowBytes destinationBytesPerImage:imageBytes];
            [blit endEncoding]; [cb commit]; [cb waitUntilCompleted]; check(cb.status==MTLCommandBufferStatusCompleted,"readback completion");
            const std::uint16_t* pixels=(const std::uint16_t*)readback.contents; double mean=0.0; size_t count=0;
            for(size_t y=0;y<1080;++y) for(size_t x=0;x<1920;++x) { float v=halfToFloat(pixels[y*1920*4+x*4]); check(std::isfinite(v)&&v>=0.f&&v<7.f,"output finite/unwritten check"); mean+=v; ++count; }
            mean/=double(count); check(mean>.05&&mean<2.,"output range check"); std::printf("OUTPUT_VALIDATION mean=%.6f pixels=%zu result=PASS\n",mean,count);
            [readback release]; [q release];
            f.reset();
            sample(device,"feature reset/pool held");
        }
        sample(device,"backend+textures gone/drained");
        [compiler release];
        sample(device,"compiler released");
        [device release];
    }
    return 0;
}
