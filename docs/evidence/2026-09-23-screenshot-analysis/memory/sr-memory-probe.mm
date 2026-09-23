#import "metalfx-backend.hpp"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#include <mach/mach.h>
#include <cstdio>
#include <cstdlib>
#include <memory>
using namespace yaagl::pso::metalfx;

static void check(bool value, const char* text) {
    if (!value) { std::fprintf(stderr, "FAIL %s\n", text); std::exit(1); }
}
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
    id<MTLTexture> color, depth, motion, output;
    Inputs(id<MTLDevice> d, NSUInteger w, NSUInteger h, NSUInteger ow, NSUInteger oh)
        : color(texture(d,w,h,MTLPixelFormatRGBA16Float,MTLStorageModePrivate)),
          depth(texture(d,w,h,MTLPixelFormatR32Float,MTLStorageModePrivate)),
          motion(texture(d,w,h,MTLPixelFormatRG16Float,MTLStorageModePrivate)),
          output(texture(d,ow,oh,MTLPixelFormatRGBA16Float,MTLStorageModePrivate)) {}
    ~Inputs() { [color release]; [depth release]; [motion release]; [output release]; }
    TextureSet set() const { return {(void*)color,(void*)depth,(void*)motion,(void*)output,nullptr,nullptr,nullptr}; }
    FrameInfo frame(unsigned w, unsigned h, unsigned ow, unsigned oh, bool reset) const {
        FrameInfo f{};
        f.color=(void*)color; f.depth=(void*)depth; f.motionVectors=(void*)motion; f.output=(void*)output;
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
    bool used=false;
    explicit Runner(id<MTLDevice> d): device(d),queue([d newMTL4CommandQueue]),
        allocator([d newCommandAllocator]),command([d newCommandBuffer]) {
        check(queue && allocator && command,"Metal4 runner");
    }
    ~Runner() { [command release]; [allocator release]; [queue release]; }
    void run(const std::shared_ptr<const PreparedFrame>& prepared) {
        if (used) [allocator reset];
        used=true;
        id<MTLFence> fence=[device newFence]; check(fence != nil,"fence");
        [command beginCommandBufferWithAllocator:allocator];
        id<MTL4ComputeCommandEncoder> producer=[command computeCommandEncoder];
        [producer updateFence:fence afterEncoderStages:MTLStageDispatch]; [producer endEncoding];
        std::shared_ptr<const ExecutionLease> lease;
        Error error;
        bool encoded=prepared->encode((void*)command,(void*)fence,lease,&error);
        check(encoded && lease != nullptr,error.message.empty()?"MetalFX encode":error.message.c_str());
        id<MTL4ComputeCommandEncoder> consumer=[command computeCommandEncoder];
        [consumer waitForFence:fence beforeEncoderStages:MTLStageBlit]; [consumer endEncoding];
        [command endCommandBuffer];
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        __block NSError* gpuError=nil;
        MTL4CommitOptions* options=[MTL4CommitOptions new];
        [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            gpuError=[feedback.error retain]; dispatch_semaphore_signal(done);
        }];
        id<MTL4CommandBuffer> batch[]={command}; [queue commit:batch count:1 options:options];
        check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))==0,"GPU timeout");
        if (gpuError) NSLog(@"GPU error: %@",gpuError);
        check(gpuError == nil,"GPU completion");
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
        operations.sharpening=true;
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
            frames(device,runner,f,inputs,1128,624,1920,1080,64,"steady 64 drained");
            frames(device,runner,f,inputs,1056,594,1920,1080,8,"input resize drained");
            frames(device,runner,f,inputs,1128,624,1920,1080,8,"return resize drained");
            frames(device,runner,f,inputs,1128,624,1920,1080,64,"steady 64 again");
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
