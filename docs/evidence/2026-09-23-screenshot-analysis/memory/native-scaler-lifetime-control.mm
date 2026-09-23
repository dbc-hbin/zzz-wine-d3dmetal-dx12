#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <cstdio>
#include <cstdlib>

static unsigned gDeallocated = 0;
static char gMarkerKey;

@interface ScalerDeallocationMarker : NSObject
@end
@implementation ScalerDeallocationMarker
- (void)dealloc {
    ++gDeallocated;
    std::fprintf(stderr, "SCALER_OBJ_DEALLOC count=%u\n", gDeallocated);
    [super dealloc];
}
@end

static void attachMarker(id object) {
    id marker = [ScalerDeallocationMarker new];
    objc_setAssociatedObject(object, &gMarkerKey, marker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [marker release];
}

static void require(bool ok, const char* message) {
    if (!ok) { std::fprintf(stderr, "FAIL %s\n", message); std::exit(1); }
}

static void sample(id<MTLDevice> device, const char* label) {
    task_vm_info_data_t vm{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    const kern_return_t status = task_info(mach_task_self(), TASK_VM_INFO,
        reinterpret_cast<task_info_t>(&vm), &count);
    std::fprintf(stderr, "MEM %-22s metal=%.2f MiB footprint=%.2f MiB scaler_dealloc=%u\n",
        label, static_cast<double>(device.currentAllocatedSize) / 1048576.0,
        status == KERN_SUCCESS ? static_cast<double>(vm.phys_footprint) / 1048576.0 : -1.0,
        gDeallocated);
}

static void createDestroy(id<MTLDevice> device, id<MTL4Compiler> compiler,
                          unsigned inputWidth, unsigned inputHeight, const char* label) {
    @autoreleasepool {
        MTLFXTemporalScalerDescriptor* descriptor = [MTLFXTemporalScalerDescriptor new];
        descriptor.colorTextureFormat = MTLPixelFormatRGBA16Float;
        descriptor.depthTextureFormat = MTLPixelFormatR32Float;
        descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
        descriptor.outputTextureFormat = MTLPixelFormatRGBA16Float;
        descriptor.inputWidth = inputWidth;
        descriptor.inputHeight = inputHeight;
        descriptor.outputWidth = 1920;
        descriptor.outputHeight = 1080;
        descriptor.autoExposureEnabled = YES;
        descriptor.requiresSynchronousInitialization = YES;
        descriptor.inputContentPropertiesEnabled = YES;
        descriptor.inputContentMinScale =
            [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device];
        descriptor.inputContentMaxScale =
            [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device];
        require([MTLFXTemporalScalerDescriptor supportsMetal4FX:device], "Metal4FX device support");
        id<MTL4FXTemporalScaler> scaler =
            [descriptor newTemporalScalerWithDevice:device compiler:compiler];
        require(scaler != nil, "newTemporalScalerWithDevice:compiler:");
        [descriptor release];
        attachMarker(scaler);
        char live[64];
        std::snprintf(live, sizeof(live), "%s live", label);
        sample(device, live);
        [scaler release];
    }
    @autoreleasepool { } // Drain framework autoreleases before judging retirement.
    char retired[64];
    std::snprintf(retired, sizeof(retired), "%s retired", label);
    sample(device, retired);
}

int main() {
    @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, "default Metal device");
    require([MTLFXTemporalScalerDescriptor supportsMetal4FX:device], "Metal4FX device support");
    MTL4CompilerDescriptor* compilerDescriptor = [MTL4CompilerDescriptor new];
    NSError* error = nil;
    id<MTL4Compiler> compiler = [device newCompilerWithDescriptor:compilerDescriptor error:&error];
    [compilerDescriptor release];
    if (error) NSLog(@"compiler error: %@", error);
    require(compiler != nil, "Metal4 compiler creation");
    id markerControl = [NSObject new];
    attachMarker(markerControl);
    [markerControl release];
    require(gDeallocated == 1, "associated sentinel observes Objective-C owner deallocation");
    sample(device, "sentinel control");
    createDestroy(device, compiler, 1128, 624, "native A");
    createDestroy(device, compiler, 1056, 594, "native B");
    createDestroy(device, compiler, 1128, 624, "native A2");
    [compiler release];
    sample(device, "compiler released");
    [device release];
    }
    std::fprintf(stderr, "AFTER_DEVICE_RELEASE_OUTER_POOL scaler_dealloc=%u\n", gDeallocated);
    return 0;
}
