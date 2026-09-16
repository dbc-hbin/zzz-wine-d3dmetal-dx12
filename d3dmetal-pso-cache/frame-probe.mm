#import "frame-probe.hpp"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <functional>
#include <mutex>
#include <set>
#include <string>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

// Diagnostic code, off by default. No texture getBytes/readback, extra GPU
// command buffers, global waits, or unverified D3DMetal offsets here.
namespace yaagl::pso::frameprobe {
namespace {
std::atomic<bool> gEnabled{false}, gSeenMPL{false}, gLogFailed{false}, gLogCapped{false};
bool gResetHistory = false;
GetFloat gFloat = nullptr;
GetUint gUint = nullptr;
GetInt gInt = nullptr;
GetResource gResource = nullptr;
thread_local const Evaluation* gEvaluation = nullptr;
thread_local ReplayScope* gReplay = nullptr;
thread_local unsigned gInsideMetalFX = 0;
RecordLedger gLedger;
std::atomic<std::uint64_t> gEvalID{1}, gRecordID{1}, gEncodeID{1}, gObjectID{1}, gPassID{1}, gSeq{1};
std::atomic<unsigned> gPendingWrites{0};
std::atomic<std::uint64_t> gDropped{0};
std::mutex gObjectLock, gHookLock;
std::set<std::pair<std::uintptr_t, std::uintptr_t>> gHooks;
char gIdentityKey, gEpochKey, gEncoderKey, gDrawKey, gCreationKey;
int gLog = -1, gDirectory = -1;
NSString* gRoot = nil;
NSString* gLogPath = nil;
dispatch_queue_t gWriter = nullptr;
dispatch_queue_t gControl = nullptr;
std::uint64_t gBytesWritten = 0; // writer queue only
constexpr std::uint64_t kLogLimit = 64ULL * 1024 * 1024;
// 0 idle, 1 starting, 2 capturing, 3 stopping. Do not stop someone else's capture.
std::atomic<int> gCaptureState{0};
std::atomic<std::uint64_t> gCaptureID{0};
std::atomic<unsigned> gPresented{0}, gFrameTarget{8};
std::atomic<std::uint64_t> gLastPoll{0};
std::mutex gDeviceLock;
id gDevice = nil; // retained, established from the actual MetalFX CB/device

std::uint64_t ns() noexcept {
    timespec t{}; clock_gettime(CLOCK_MONOTONIC, &t);
    return static_cast<std::uint64_t>(t.tv_sec) * 1000000000ULL + static_cast<std::uint64_t>(t.tv_nsec);
}
template<class T> T loadAt(const void* p, std::size_t offset) noexcept {
    T result{};
    if (p) std::memcpy(&result, static_cast<const char*>(p) + offset, sizeof(T));
    return result;
}
// Cast only after install() validates the method ABI. memcpy avoids compiler
// diagnostics about IMP's deliberately unprototyped runtime typedef.
template<class F> F asIMP(IMP imp) noexcept {
    static_assert(sizeof(F)==sizeof(IMP));F result;std::memcpy(&result,&imp,sizeof(result));return result;
}
SEL sel(const char* name) { return sel_registerName(name); }
bool has(id object, const char* name) { return object && [object respondsToSelector:sel(name)]; }
id objectAt(id object, const char* name) {
    return has(object, name) ? reinterpret_cast<id(*)(id,SEL)>(objc_msgSend)(object,sel(name)) : nil;
}
std::uint64_t sizeAt(id object, const char* name) {
    return has(object,name) ? reinterpret_cast<NSUInteger(*)(id,SEL)>(objc_msgSend)(object,sel(name)) : 0;
}
float floatAt(id object, const char* name) {
    return has(object,name) ? reinterpret_cast<float(*)(id,SEL)>(objc_msgSend)(object,sel(name)) : NAN;
}
int boolAt(id object, const char* name) {
    return has(object,name) ? (reinterpret_cast<BOOL(*)(id,SEL)>(objc_msgSend)(object,sel(name)) ? 1 : 0) : -1;
}
id optionalSize(id object, const char* name) {
    return has(object,name) ? static_cast<id>(@(sizeAt(object,name))) : static_cast<id>([NSNull null]);
}
id number(float f) { return std::isfinite(f) ? static_cast<id>(@(f)) : static_cast<id>([NSNull null]); }
NSString* pointer(const void* p) { return [NSString stringWithFormat:@"%p",p]; }
NSString* className(id object) {
    return object ? [NSString stringWithUTF8String:class_getName(object_getClass(object))] : @"nil";
}
std::uint64_t oid(id object) {
    if (!object) return 0;
    std::lock_guard<std::mutex> lock(gObjectLock);
    NSNumber* n = static_cast<NSNumber*>(objc_getAssociatedObject(object,&gIdentityKey));
    if (n) return [n unsignedLongLongValue];
    const auto value = gObjectID.fetch_add(1);
    objc_setAssociatedObject(object,&gIdentityKey,@(value),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return value;
}
std::uint64_t epoch(id cb) {
    std::lock_guard<std::mutex> lock(gObjectLock);
    return [static_cast<NSNumber*>(objc_getAssociatedObject(cb,&gEpochKey)) unsignedLongLongValue];
}
void newEpoch(id cb) {
    std::lock_guard<std::mutex> lock(gObjectLock);
    const auto n = [static_cast<NSNumber*>(objc_getAssociatedObject(cb,&gEpochKey)) unsignedLongLongValue] + 1;
    objc_setAssociatedObject(cb,&gEpochKey,@(n),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
NSDictionary* texture(id t) {
    if (!t) return @{@"oid":@0,@"pointer":@"nil"};
    id label = objectAt(t,"label");
    return @{@"oid":@(oid(t)),@"pointer":pointer(t),@"class":className(t),
        @"width":@(sizeAt(t,"width")),@"height":@(sizeAt(t,"height")),
        @"format":@(sizeAt(t,"pixelFormat")),@"usage":@(sizeAt(t,"usage")),
        @"storage":@(sizeAt(t,"storageMode")),@"type":@(sizeAt(t,"textureType")),
        @"samples":@(sizeAt(t,"sampleCount")),@"label":label ?: @""};
}
NSDictionary* descriptor(const Descriptor& d) {
    return @{@"color":pointer(reinterpret_cast<void*>(d.color)),@"depth":pointer(reinterpret_cast<void*>(d.depth)),
        @"motion":pointer(reinterpret_cast<void*>(d.motion)),@"output":pointer(reinterpret_cast<void*>(d.output)),
        @"exposure":pointer(reinterpret_cast<void*>(d.exposure)),@"reactive":pointer(reinterpret_cast<void*>(d.reactive)),
        @"width":@(d.width),@"height":@(d.height),@"reset":@(d.reset),
        @"jitter_x":number(d.jitterX),@"jitter_y":number(d.jitterY),
        @"mv_x":number(d.motionScaleX),@"mv_y":number(d.motionScaleY),@"pre_exposure":number(d.preExposure),
        @"origins":@[@(d.colorX),@(d.colorY),@(d.depthX),@(d.depthY),@(d.motionX),@(d.motionY),
                     @(d.reactiveX),@(d.reactiveY),@(d.outputX),@(d.outputY)]};
}
void emit(NSString* event, NSDictionary* fields) noexcept {
    if (!gEnabled.load(std::memory_order_relaxed) || gLogFailed.load() || gLogCapped.load() || gLog < 0) return;
    const int saved = errno;
    @try { @autoreleasepool {
        NSMutableDictionary* row = [NSMutableDictionary dictionaryWithDictionary:fields ?: @{}];
        [row setObject:@"zzz-frame-probe" forKey:@"source"];
        [row setObject:event forKey:@"event"];
        [row setObject:@(gSeq.fetch_add(1)) forKey:@"seq"];
        [row setObject:@(ns()) forKey:@"cpu_ns"];
        [row setObject:@(getpid()) forKey:@"pid"];
        [row setObject:@(gCaptureID.load()) forKey:@"capture_id"];
        [row setObject:@(gDropped.load()) forKey:@"dropped_total"];
        NSError* error = nil;
        NSData* data = [NSJSONSerialization dataWithJSONObject:row options:0 error:&error];
        if (!data || [data length] > 128 * 1024) { ++gDropped; errno=saved; return; }
        if (gPendingWrites.fetch_add(1) >= 256) { --gPendingWrites; ++gDropped; errno=saved; return; }
        // dispatch_async copies the block, retaining captured ObjC objects in MRC.
        dispatch_async(gWriter, ^{
            const auto length = static_cast<std::size_t>([data length]);
            if (gBytesWritten + length + 1 > kLogLimit) {
                if (!gLogCapped.exchange(true)) {
                    char marker[256];
                    const int n=std::snprintf(marker,sizeof(marker),
                        "{\"source\":\"zzz-frame-probe\",\"event\":\"log_limit\",\"pid\":%d,\"seq\":%llu}\n",
                        getpid(),static_cast<unsigned long long>(gSeq.fetch_add(1)));
                    if(n>0 && static_cast<std::size_t>(n)<sizeof(marker)) (void)write(gLog,marker,static_cast<std::size_t>(n));
                }
                ++gDropped; --gPendingWrites; return;
            }
            const char* p = static_cast<const char*>([data bytes]);
            std::size_t left = length;
            while (left) {
                const ssize_t n = write(gLog,p,left);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) { gLogFailed.store(true); break; }
                p += n; left -= static_cast<std::size_t>(n);
            }
            if (!left && write(gLog,"\n",1) != 1) gLogFailed.store(true);
            gBytesWritten += length + 1; --gPendingWrites;
        });
    }} @catch (id) { ++gDropped; }
    errno = saved;
}
void exceptionEvent(const char* where) noexcept {
    emit(@"probe_exception",@{@"where":[NSString stringWithUTF8String:where]});
}

// Only inspect/swap methods after validating their Objective-C ABI. Concrete
// class replacement avoids modifying an inherited superclass implementation.
using MakeIMP = std::function<IMP(IMP,SEL)>;
bool install(Class cls, const char* name, char returnType, const char* arguments, const MakeIMP& make) {
    if (!cls) return false;
    const SEL s = sel(name);
    const auto key = std::make_pair(reinterpret_cast<std::uintptr_t>(cls),reinterpret_cast<std::uintptr_t>(s));
    std::lock_guard<std::mutex> lock(gHookLock);
    if (gHooks.count(key)) return true;
    Method m = class_getInstanceMethod(cls,s);
    if (!m || method_getNumberOfArguments(m) != 2 + std::strlen(arguments)) return false;
    char* r = method_copyReturnType(m);
    bool valid = r && r[0] == returnType; std::free(r);
    for (unsigned i=0; valid && arguments[i]; ++i) {
        char* a = method_copyArgumentType(m,i+2);
        const char c = a ? a[0] : 0;
        valid = c == arguments[i] || (arguments[i]=='Q' && c=='q');
        if (arguments[i]=='{') valid = a && a[0]=='{' && std::strstr(a,"=dddddd}");
        std::free(a);
    }
    if (!valid) {
        emit(@"hook_signature_rejected",@{@"class":[NSString stringWithUTF8String:class_getName(cls)],
            @"selector":[NSString stringWithUTF8String:name]}); return false;
    }
    IMP replacement = make(method_getImplementation(m),s);
    if (!replacement) return false;
    if (!class_addMethod(cls,s,replacement,method_getTypeEncoding(m)))
        class_replaceMethod(cls,s,replacement,method_getTypeEncoding(m));
    gHooks.insert(key);
    emit(@"hook_installed",@{@"class":[NSString stringWithUTF8String:class_getName(cls)],
        @"selector":[NSString stringWithUTF8String:name]});
    return true;
}

void rememberDevice(id device) {
    if (!device) return;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    if (!gDevice) gDevice = [device retain];
}
id retainedDevice() {
    std::lock_guard<std::mutex> lock(gDeviceLock);
    return [gDevice retain];
}
void stopCapture(std::uint64_t generation, NSString* reason) noexcept {
    if (generation != gCaptureID.load()) return;
    int expected = 2;
    if (!gCaptureState.compare_exchange_strong(expected,3)) return;
    @try {
        [[MTLCaptureManager sharedCaptureManager] stopCapture];
        emit(@"capture_stopped",@{@"reason":reason,@"presented_callbacks":@(gPresented.load()),
            @"first_frame_may_be_partial":@YES,@"last_frame_may_be_partial":@YES});
    } @catch (id) { exceptionEvent("stopCapture"); }
    gCaptureState.store(0);
}
void requestStop(std::uint64_t generation, NSString* reason) {
    dispatch_async(gControl, ^{ @autoreleasepool { stopCapture(generation,reason); } });
}
void pollCapture() noexcept {
    if (!enabled() || !gSeenMPL.load() || gDirectory<0) return;
    const int saved = errno;
    @try { @autoreleasepool {
        const auto now = ns();
        auto previous = gLastPoll.load();
        if (now - previous < 50000000ULL || !gLastPoll.compare_exchange_strong(previous,now)) return;
        char stopName[80]; std::snprintf(stopName,sizeof(stopName),"stop-%d",getpid());
        struct stat st{};
        if (fstatat(gDirectory,stopName,&st,AT_SYMLINK_NOFOLLOW)==0 && S_ISREG(st.st_mode) && st.st_uid==geteuid()) {
            unlinkat(gDirectory,stopName,0); requestStop(gCaptureID.load(),@"manual_stop");
        }
        if (gCaptureState.load()!=0) return;
        id device = retainedDevice();
        if (!device) return;
        char armName[80]; std::snprintf(armName,sizeof(armName),"capture-%d.arm",getpid());
        const int fd = openat(gDirectory,armName,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);
        if (fd<0) { [device release]; return; }
        char bytes[4096]; ssize_t length = -1;
        if (fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_uid==geteuid() && !(st.st_mode&0077) && st.st_size<4096)
            length = read(fd,bytes,sizeof(bytes));
        close(fd); unlinkat(gDirectory,armName,0);
        if (length<0) { emit(@"capture_request_rejected",@{}); [device release]; return; }
        unsigned frames=8, timeout=15;
        if (length) {
            NSData* data = [NSData dataWithBytes:bytes length:static_cast<NSUInteger>(length)];
            id request=[NSJSONSerialization JSONObjectWithData:data options:0 error:nullptr];
            if (![request isKindOfClass:[NSDictionary class]]) { [device release]; emit(@"capture_request_rejected",@{}); return; }
            id f=[request objectForKey:@"presentations"], t=[request objectForKey:@"timeout_seconds"];
            if (f && ![f isKindOfClass:[NSNumber class]]) { [device release]; return; }
            if (t && ![t isKindOfClass:[NSNumber class]]) { [device release]; return; }
            if (f) frames=static_cast<unsigned>([f unsignedIntValue]);
            if (t) timeout=static_cast<unsigned>([t unsignedIntValue]);
        }
        if (frames<2 || frames>32 || timeout<2 || timeout>60) {
            emit(@"capture_request_rejected",@{}); [device release]; return;
        }
        int idle=0;
        if (!gCaptureState.compare_exchange_strong(idle,1)) { [device release]; return; }
        MTLCaptureManager* manager=[MTLCaptureManager sharedCaptureManager];
        if ([manager isCapturing] || ![manager supportsDestination:MTLCaptureDestinationGPUTraceDocument]) {
            emit(@"capture_unavailable",@{@"other_capture_active":@([manager isCapturing]),
                @"hint":@"Set MTL_CAPTURE_ENABLED=1 before Wine starts; require full Xcode GPU tools"});
            gCaptureState.store(0); [device release]; return;
        }
        const auto generation=gCaptureID.fetch_add(1)+1;
        NSString* name=[NSString stringWithFormat:@"capture-%d-%llu-%llu.gputrace",getpid(),static_cast<unsigned long long>(generation),static_cast<unsigned long long>(ns())];
        NSString* path=[gRoot stringByAppendingPathComponent:name];
        MTLCaptureDescriptor* d=[[MTLCaptureDescriptor alloc] init];
        [d setCaptureObject:device]; [d setDestination:MTLCaptureDestinationGPUTraceDocument];
        [d setOutputURL:[NSURL fileURLWithPath:path]];
        NSError* error=nil;
        const BOOL started=[manager startCaptureWithDescriptor:d error:&error];
        [d release]; [device release];
        if (!started) {
            emit(@"capture_start_failed",@{@"error":[error localizedDescription] ?: @"unknown"});
            gCaptureState.store(0); return;
        }
        gFrameTarget.store(frames); gPresented.store(0); gCaptureState.store(2);
        emit(@"capture_started",@{@"path":path,@"target_presentations":@(frames),
            @"timeout_seconds":@(timeout),@"scope":@"device",@"first_frame_may_be_partial":@YES});
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,static_cast<int64_t>(timeout)*NSEC_PER_SEC),gControl,^{
            @autoreleasepool { stopCapture(generation,@"timeout_not_a_frame_boundary"); }
        });
    }} @catch (id) { exceptionEvent("pollCapture"); }
    errno=saved;
}

void writeReady() {
    NSDictionary* data=@{@"pid":@(getpid()),@"log":gLogPath,@"probe_schema":@1,
        @"path":gRoot,@"scope":@"MPL temporal diagnostics; eval IDs are not Present IDs"};
    NSData* bytes=[NSJSONSerialization dataWithJSONObject:data options:NSJSONWritingPrettyPrinted error:nullptr];
    char name[80],tmp[100]; std::snprintf(name,sizeof(name),"ready-%d.json",getpid());
    std::snprintf(tmp,sizeof(tmp),".ready-%d-%llu.tmp",getpid(),static_cast<unsigned long long>(ns()));
    const int fd=openat(gDirectory,tmp,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC|O_NOFOLLOW,0600);
    if (fd>=0) {
        const auto length=[bytes length];
        const bool ok=write(fd,[bytes bytes],length)==static_cast<ssize_t>(length);
        close(fd);
        if (ok) renameat(gDirectory,tmp,gDirectory,name); else unlinkat(gDirectory,tmp,0);
    }
}

void installCommandBufferHooks(id cb);
void installEncoderHooks(id encoder);
void installLayerHook();
void installFactoryHooks();

NSDictionary* evaluationJSON(const Evaluation& e) {
    NSMutableArray* resources=[NSMutableArray array];
    for (const auto p:e.resources) [resources addObject:pointer(reinterpret_cast<void*>(p))];
    return @{@"eval_id":@(e.id),@"feature":pointer(reinterpret_cast<void*>(e.feature)),
        @"command_list":pointer(reinterpret_cast<void*>(e.commandList)),@"params":pointer(reinterpret_cast<void*>(e.parameters)),
        @"valid":@(e.valid),@"flags":@(e.flags),@"active_width":@(e.width),@"active_height":@(e.height),
        @"nominal_width":@(e.nominalWidth),@"nominal_height":@(e.nominalHeight),
        @"out_width":@(e.outWidth),@"out_height":@(e.outHeight),@"reset":@(e.reset),
        @"jitter_x":number(e.jitterX),@"jitter_y":number(e.jitterY),@"mv_x":number(e.motionX),@"mv_y":number(e.motionY),
        @"pre_exposure":number(e.preExposure),@"ngx_resources":resources};
}
void readEvaluation(Evaluation& e,const void* params) {
    if (!params) return;
    auto u=[&](const char* k,std::uint32_t& x){return gUint && gUint(params,k,&x)==1;};
    auto f=[&](const char* k,float& x){return gFloat && gFloat(params,k,&x)==1 && std::isfinite(x);};
    std::int32_t flags=0;
    if (gInt && gInt(params,"DLSS.Feature.Create.Flags",&flags)==1) {e.flags=static_cast<std::uint32_t>(flags);e.valid|=Flags;}
    if (u("DLSS.Render.Subrect.Dimensions.Width",e.width) && u("DLSS.Render.Subrect.Dimensions.Height",e.height)) e.valid|=ActiveExtent;
    if (u("Width",e.nominalWidth) && u("Height",e.nominalHeight)) e.valid|=NominalExtent;
    if (u("OutWidth",e.outWidth) && u("OutHeight",e.outHeight)) e.valid|=OutputExtent;
    if (f("Jitter.Offset.X",e.jitterX) && f("Jitter.Offset.Y",e.jitterY)) e.valid|=Jitter;
    if (f("MV.Scale.X",e.motionX) && f("MV.Scale.Y",e.motionY)) e.valid|=Motion;
    if (f("DLSS.Pre.Exposure",e.preExposure)) e.valid|=PreExposure;
    if (u("Reset",e.reset)) e.valid|=Reset;
    const char* keys[]={"Color","Depth","MotionVectors","Output","ExposureTexture","DLSS.Input.Bias.Current.Color.Mask"};
    for (unsigned i=0;i<e.resources.size();++i) {
        void* p=nullptr;
        if (gResource && gResource(params,keys[i],&p)==1) e.resources[i]=reinterpret_cast<Identity>(p);
    }
}

NSDictionary* creation(id d) {
    return @{@"input_width":optionalSize(d,"inputWidth"),@"input_height":optionalSize(d,"inputHeight"),
        @"output_width":optionalSize(d,"outputWidth"),@"output_height":optionalSize(d,"outputHeight"),
        @"min_scale":number(floatAt(d,"inputContentMinScale")),@"max_scale":number(floatAt(d,"inputContentMaxScale")),
        @"auto_exposure":@(boolAt(d,"isAutoExposureEnabled")),@"jittered_motion":@(boolAt(d,"isJitteredMotionVectorsEnabled")),
        @"output_resolution_motion":@(boolAt(d,"isOutputResolutionMotionVectorsEnabled")),
        @"input_content_properties":@(boolAt(d,"isInputContentPropertiesEnabled")),
        @"reactive_mask":@(boolAt(d,"isReactiveMaskTextureEnabled")),
        @"synchronous_initialization":@(boolAt(d,"requiresSynchronousInitialization"))};
}
void created(id scaler,NSDictionary* values,const char* factory) noexcept {
    @try { @autoreleasepool {
        if (!scaler) {emit(@"factory_returned_nil",@{});return;}
        objc_setAssociatedObject(scaler,&gCreationKey,values,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        emit(@"scaler_created",@{@"scaler_oid":@(oid(scaler)),@"scaler":pointer(scaler),@"class":className(scaler),
            @"factory":[NSString stringWithUTF8String:factory],@"creation":values ?: @{}});
    }} @catch (id) { exceptionEvent("created"); }
}
void installFactoryHooks() {
    Class cls=objc_getClass("MTLFXTemporalScalerDescriptor");
    install(cls,"newTemporalScalerWithDevice:",'@',"@",[](IMP old,SEL s){
        using F=id(*)(id,SEL,id); F previous=asIMP<F>(old);
        return imp_implementationWithBlock(^id(id self,id device){
            NSDictionary* values=nil;
            @try {values=[creation(self) retain];} @catch(id) {exceptionEvent("factory_read");}
            id result=previous(self,s,device); // preserve +1 'new' ownership
            created(result,values,"newTemporalScalerWithDevice:"); [values release]; return result;
        });
    });
    install(cls,"newTemporalScalerWithDevice:compiler:",'@',"@@",[](IMP old,SEL s){
        using F=id(*)(id,SEL,id,id); F previous=asIMP<F>(old);
        return imp_implementationWithBlock(^id(id self,id device,id compiler){
            NSDictionary* values=nil;
            @try {values=[creation(self) retain];} @catch(id) {exceptionEvent("factory_read");}
            id result=previous(self,s,device,compiler);
            created(result,values,"newTemporalScalerWithDevice:compiler:"); [values release]; return result;
        });
    });
}

void installEncodeHook(id scaler) {
    const bool ok=install(object_getClass(scaler),"encodeToCommandBuffer:",'v',"@",[](IMP old,SEL s){
        using F=void(*)(id,SEL,id); F previous=asIMP<F>(old);
        return imp_implementationWithBlock(^void(id self,id cb){
            ReplayScope* scope=gReplay;
            if (!scope || scope->scaler!=reinterpret_cast<void*>(self) || scope->inEncode) {
                previous(self,s,cb); return;
            }
            scope->inEncode=true;
            const auto eid=scope->beforeEncode(self,cb);
            bool normal=false; ++gInsideMetalFX;
            @try { previous(self,s,cb); normal=true; }
            @finally {
                --gInsideMetalFX;
                scope->afterEncode(self,cb,eid,normal);
                scope->inEncode=false;
            }
        });
    });
    if (!ok) emit(@"encode_hook_unavailable",@{@"class":className(scaler)});
}

NSDictionary* encoderContext(id encoder) {
    return static_cast<NSDictionary*>(objc_getAssociatedObject(encoder,&gEncoderKey)) ?: @{};
}
void encoderEvent(id encoder,NSString* kind,NSDictionary* values) noexcept {
    if (gCaptureState.load()!=2) return;
    @try { @autoreleasepool {
        NSMutableDictionary* fields=[NSMutableDictionary dictionaryWithDictionary:encoderContext(encoder)];
        [fields addEntriesFromDictionary:values ?: @{}];
        [fields setObject:@(oid(encoder)) forKey:@"encoder_oid"];
        emit(kind,fields);
    }} @catch (id) { exceptionEvent("encoderEvent"); }
}
void drawMarker(id encoder,SEL selector) noexcept {
    if (gCaptureState.load()!=2) return;
    @try { @autoreleasepool {
        unsigned long long ordinal=0;
        {
            std::lock_guard<std::mutex> lock(gObjectLock);
            ordinal=[static_cast<NSNumber*>(objc_getAssociatedObject(encoder,&gDrawKey)) unsignedLongLongValue]+1;
            objc_setAssociatedObject(encoder,&gDrawKey,@(ordinal),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSDictionary* context=encoderContext(encoder);
        NSString* name=[NSString stringWithFormat:@"YAAGL.draw pass=%@ api_call=%llu %@",
            [context objectForKey:@"pass_id"] ?: @0,ordinal,[NSString stringWithUTF8String:sel_getName(selector)]];
        if (has(encoder,"insertDebugSignpost:"))
            reinterpret_cast<void(*)(id,SEL,id)>(objc_msgSend)(encoder,sel("insertDebugSignpost:"),name);
        encoderEvent(encoder,@"draw_api",@{@"ordinal":@(ordinal),@"selector":[NSString stringWithUTF8String:sel_getName(selector)]});
    }} @catch (id) { exceptionEvent("drawMarker"); }
}
void installEncoderHooks(id encoder) {
    const Class c=object_getClass(encoder);
    install(c,"setRenderPipelineState:",'v',"@",[](IMP old,SEL s){
        auto previous=asIMP<void(*)(id,SEL,id)>(old);
        return imp_implementationWithBlock(^void(id self,id pso){
            previous(self,s,pso);
            @try { @autoreleasepool {encoderEvent(self,@"pipeline",@{@"pso_oid":@(oid(pso)),@"pso":pointer(pso),@"label":objectAt(pso,"label") ?: @""});}}
            @catch(id){exceptionEvent("pipeline");}
        });
    });
    install(c,"setViewport:",'v',"{",[](IMP old,SEL s){
        auto previous=asIMP<void(*)(id,SEL,MTLViewport)>(old);
        return imp_implementationWithBlock(^void(id self,MTLViewport v){
            previous(self,s,v);
            encoderEvent(self,@"viewport",@{@"x":@(v.originX),@"y":@(v.originY),@"width":@(v.width),@"height":@(v.height),
                @"znear":@(v.znear),@"zfar":@(v.zfar)});
        });
    });
    for (const char* name:{"setVertexBuffer:offset:atIndex:","setFragmentBuffer:offset:atIndex:"}) {
        install(c,name,'v',"@QQ",[](IMP old,SEL s){
            auto previous=asIMP<void(*)(id,SEL,id,NSUInteger,NSUInteger)>(old);
            return imp_implementationWithBlock(^void(id self,id buffer,NSUInteger offset,NSUInteger index){
                previous(self,s,buffer,offset,index);
                @try { @autoreleasepool {encoderEvent(self,@"buffer_binding",@{@"selector":[NSString stringWithUTF8String:sel_getName(s)],
                    @"buffer_oid":@(oid(buffer)),@"buffer":pointer(buffer),@"offset":@(offset),@"index":@(index),
                    @"length":@(sizeAt(buffer,"length")),@"cpu_contents_read":@NO});}}
                @catch(id){exceptionEvent("buffer_binding");}
            });
        });
    }
    // Metal 4 does not use legacy setVertexBuffer for every resource. Record
    // the actual argument table; its GPU-versioned contents are in .gputrace.
    install(c,"setArgumentTable:atStages:",'v',"@Q",[](IMP old,SEL s){
        auto previous=asIMP<void(*)(id,SEL,id,NSUInteger)>(old);
        return imp_implementationWithBlock(^void(id self,id table,NSUInteger stages){
            previous(self,s,table,stages);
            @try { @autoreleasepool {encoderEvent(self,@"argument_table",@{@"table_oid":@(oid(table)),@"table":pointer(table),@"stages":@(stages)});}}
            @catch(id){exceptionEvent("argument_table");}
        });
    });
    install(c,"drawPrimitives:vertexStart:vertexCount:",'v',"QQQ",[](IMP old,SEL s){
        auto p=asIMP<void(*)(id,SEL,NSUInteger,NSUInteger,NSUInteger)>(old);
        return imp_implementationWithBlock(^void(id self,NSUInteger a,NSUInteger b,NSUInteger d){drawMarker(self,s);p(self,s,a,b,d);});
    });
    install(c,"drawPrimitives:vertexStart:vertexCount:instanceCount:",'v',"QQQQ",[](IMP old,SEL s){
        auto p=asIMP<void(*)(id,SEL,NSUInteger,NSUInteger,NSUInteger,NSUInteger)>(old);
        return imp_implementationWithBlock(^void(id self,NSUInteger a,NSUInteger b,NSUInteger d,NSUInteger e){drawMarker(self,s);p(self,s,a,b,d,e);});
    });
    install(c,"drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:",'v',"QQQQQ",[](IMP old,SEL s){
        auto p=asIMP<void(*)(id,SEL,NSUInteger,NSUInteger,NSUInteger,NSUInteger,NSUInteger)>(old);
        return imp_implementationWithBlock(^void(id self,NSUInteger a,NSUInteger b,NSUInteger d,NSUInteger e,NSUInteger f){drawMarker(self,s);p(self,s,a,b,d,e,f);});
    });
    // Legacy indexed forms. Unwrapped indirect/mesh/other draws remain fully
    // visible in Xcode's native device capture; marker ordinal != draw index.
    install(c,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:",'v',"QQQ@Q",[](IMP old,SEL s){
        auto p=asIMP<void(*)(id,SEL,NSUInteger,NSUInteger,NSUInteger,id,NSUInteger)>(old);
        return imp_implementationWithBlock(^void(id self,NSUInteger a,NSUInteger b,NSUInteger d,id buffer,NSUInteger offset){
            drawMarker(self,s);p(self,s,a,b,d,buffer,offset);
        });
    });
    install(c,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:",'v',"QQQ@QQ",[](IMP old,SEL s){
        auto p=asIMP<void(*)(id,SEL,NSUInteger,NSUInteger,NSUInteger,id,NSUInteger,NSUInteger)>(old);
        return imp_implementationWithBlock(^void(id self,NSUInteger a,NSUInteger b,NSUInteger d,id buffer,NSUInteger offset,NSUInteger instances){
            drawMarker(self,s);p(self,s,a,b,d,buffer,offset,instances);
        });
    });
    install(c,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:",'v',"QQQ@QQQQ",[](IMP old,SEL s){
        auto p=asIMP<void(*)(id,SEL,NSUInteger,NSUInteger,NSUInteger,id,NSUInteger,NSUInteger,NSInteger,NSUInteger)>(old);
        return imp_implementationWithBlock(^void(id self,NSUInteger a,NSUInteger b,NSUInteger d,id buffer,NSUInteger offset,NSUInteger instances,NSInteger baseVertex,NSUInteger baseInstance){
            drawMarker(self,s);p(self,s,a,b,d,buffer,offset,instances,baseVertex,baseInstance);
        });
    });
}

void renderPass(id cb,id d,id encoder) noexcept {
    if (!encoder || gCaptureState.load()!=2) return;
    @try { @autoreleasepool {
        NSMutableArray* targets=[NSMutableArray array];
        id attachments=objectAt(d,"colorAttachments");
        if (has(attachments,"objectAtIndexedSubscript:")) for (NSUInteger i=0;i<8;++i) {
            id a=reinterpret_cast<id(*)(id,SEL,NSUInteger)>(objc_msgSend)(attachments,sel("objectAtIndexedSubscript:"),i);
            id t=objectAt(a,"texture");
            if (t) [targets addObject:@{@"index":@(i),@"texture":texture(t),@"level":@(sizeAt(a,"level")),@"slice":@(sizeAt(a,"slice"))}];
        }
        const auto pass=gPassID.fetch_add(1);
        NSDictionary* ctx=@{@"pass_id":@(pass),@"cb_oid":@(oid(cb)),@"cb_epoch":@(epoch(cb)),
            @"inside_metalfx":@(gInsideMetalFX!=0)};
        objc_setAssociatedObject(encoder,&gEncoderKey,ctx,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(encoder,&gDrawKey,@0,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        encoderEvent(encoder,@"render_pass",@{@"targets":targets,@"depth":texture(objectAt(objectAt(d,"depthAttachment"),"texture"))});
        if (has(encoder,"insertDebugSignpost:")) {
            NSString* marker=[NSString stringWithFormat:@"YAAGL.PASS p=%llu cb=%llu epoch=%llu MFX=%u",static_cast<unsigned long long>(pass),
                static_cast<unsigned long long>(oid(cb)),static_cast<unsigned long long>(epoch(cb)),gInsideMetalFX];
            reinterpret_cast<void(*)(id,SEL,id)>(objc_msgSend)(encoder,sel("insertDebugSignpost:"),marker);
        }
        installEncoderHooks(encoder);
    }} @catch(id){exceptionEvent("renderPass");}
}
void installCommandBufferHooks(id cb) {
    const Class c=object_getClass(cb);
    // Epoch zero means the initial MTL4 begin was not observed. Never invent a
    // generation for a reusable command buffer already being recorded.
    install(c,"beginCommandBufferWithAllocator:",'v',"@",[](IMP old,SEL s){
        auto p=asIMP<void(*)(id,SEL,id)>(old);
        return imp_implementationWithBlock(^void(id self,id allocator){
            p(self,s,allocator);
            @try { @autoreleasepool {newEpoch(self);emit(@"cb_begin",@{@"cb_oid":@(oid(self)),@"cb_epoch":@(epoch(self)),@"allocator_oid":@(oid(allocator))});}}
            @catch(id){exceptionEvent("cb_begin");}
        });
    });
    install(c,"renderCommandEncoderWithDescriptor:",'@',"@",[](IMP old,SEL s){
        auto p=asIMP<id(*)(id,SEL,id)>(old);
        return imp_implementationWithBlock(^id(id self,id d){id encoder=p(self,s,d);renderPass(self,d,encoder);return encoder;});
    });
    install(c,"renderCommandEncoderWithDescriptor:options:",'@',"@Q",[](IMP old,SEL s){
        auto p=asIMP<id(*)(id,SEL,id,NSUInteger)>(old);
        return imp_implementationWithBlock(^id(id self,id d,NSUInteger options){id encoder=p(self,s,d,options);renderPass(self,d,encoder);return encoder;});
    });
}

void drawableAcquired(id layer,id drawable) noexcept {
    if (!drawable || !gSeenMPL.load()) return;
    @try { @autoreleasepool {
        const auto acquisition=gObjectID.fetch_add(1);
        id t=objectAt(drawable,"texture");
        const auto layerID=oid(layer), drawableID=oid(drawable);
        emit(@"drawable_acquired",@{@"acquisition_id":@(acquisition),@"layer_oid":@(layerID),
            @"drawable_oid":@(drawableID),@"drawable_id":@(sizeAt(drawable,"drawableID")),@"texture":texture(t),
            @"no_eval_association_assumed":@YES});
        const auto generation=gCaptureID.load();
        const bool duringCapture=gCaptureState.load()==2;
        if (!duringCapture || !has(drawable,"addPresentedHandler:")) return;
        // Match device only to decide capture duration, not to claim which
        // Evaluate produced this drawable. The GPU dependency trace proves that.
        id device=retainedDevice();
        const bool sameDevice=objectAt(t,"device")==device; [device release];
        if (!sameDevice) return;
        const auto textureID=oid(t);
        using Handler=void(^)(id);
        Handler handler=^void(id presented){
            @autoreleasepool {
                double time=0;
                if (has(presented,"presentedTime")) time=reinterpret_cast<double(*)(id,SEL)>(objc_msgSend)(presented,sel("presentedTime"));
                emit(@"drawable_presented",@{@"acquisition_id":@(acquisition),@"layer_oid":@(layerID),@"drawable_oid":@(drawableID),
                    @"texture_oid":@(textureID),@"presented_time":@(time),@"acquired_capture_id":@(generation)});
                if (generation==gCaptureID.load() && gCaptureState.load()==2 && ++gPresented>=gFrameTarget.load())
                    requestStop(generation,@"presented_callback_target");
            }
        };
        reinterpret_cast<void(*)(id,SEL,Handler)>(objc_msgSend)(drawable,sel("addPresentedHandler:"),handler);
    }} @catch(id){exceptionEvent("drawableAcquired");}
}
void installLayerHook() {
    install(objc_getClass("CAMetalLayer"),"nextDrawable",'@',"",[](IMP old,SEL s){
        auto p=asIMP<id(*)(id,SEL)>(old);
        return imp_implementationWithBlock(^id(id self){
            pollCapture();
            id drawable=p(self,s); drawableAcquired(self,drawable); return drawable;
        });
    });
}
} // namespace

bool enabled() noexcept {return gEnabled.load(std::memory_order_relaxed);}
void initialize(GetFloat f,GetUint u,GetInt i,GetResource r) noexcept {
    const char* on=getenv("YAAGL_METALFX_FRAME_PROBE");
    if (!on || std::strcmp(on,"1")!=0) return;
    const int saved=errno;
    try { @try { @autoreleasepool {
        const char* dir=getenv("YAAGL_METALFX_PROBE_DIR");
        if (!dir || dir[0]!='/') {std::fprintf(stderr,"[frame-probe] absolute YAAGL_METALFX_PROBE_DIR required\n");return;}
        (void)mkdir(dir,0700);
        gDirectory=open(dir,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        struct stat st{};
        if (gDirectory<0 || fstat(gDirectory,&st)!=0 || st.st_uid!=geteuid() || (st.st_mode&0077)) {
            if (gDirectory>=0) close(gDirectory);gDirectory=-1;
            std::fprintf(stderr,"[frame-probe] probe directory must be owned by you, mode 0700, not a symlink\n");return;
        }
        gRoot=[[NSString stringWithUTF8String:dir] copy];
        NSString* name=[NSString stringWithFormat:@"probe-%d-%llu.jsonl",getpid(),static_cast<unsigned long long>(ns())];
        gLog=openat(gDirectory,[name UTF8String],O_WRONLY|O_CREAT|O_EXCL|O_APPEND|O_CLOEXEC|O_NOFOLLOW,0600);
        if (gLog<0) return;
        gLogPath=[[gRoot stringByAppendingPathComponent:name] copy];
        gWriter=dispatch_queue_create("yaagl.frame-probe.writer",DISPATCH_QUEUE_SERIAL);
        gControl=dispatch_queue_create("yaagl.frame-probe.control",DISPATCH_QUEUE_SERIAL);
        gFloat=f;gUint=u;gInt=i;gResource=r;
        const char* reset=getenv("YAAGL_METALFX_PROBE_RESET_HISTORY");
        gResetHistory=reset && std::strcmp(reset,"1")==0;
        gEnabled.store(true);
        emit(@"initialized",@{@"schema":@1,@"history_reset_test":@(gResetHistory),@"log_limit_bytes":@(kLogLimit),
            @"gpu_snapshots":@"native .gputrace only; JSON contains metadata, not texels",
            @"frame_identity":@"eval/record/encode/acquisition are distinct; do not equate"});
        installFactoryHooks();installLayerHook();
    }} @catch(id){exceptionEvent("initialize");}
    } catch (...) {std::fprintf(stderr,"[frame-probe] initialization failed; no correction applied\n");}
    errno=saved;
}

EvaluationScope::EvaluationScope(const void* feature,const void* commandList,const void* params) noexcept {
    if (!enabled()) return;
    const int saved=errno;
    try { @try { @autoreleasepool {
        value_.id=gEvalID.fetch_add(1);value_.feature=reinterpret_cast<Identity>(feature);
        value_.commandList=reinterpret_cast<Identity>(commandList);value_.parameters=reinterpret_cast<Identity>(params);
        readEvaluation(value_,params);
        previous_=gEvaluation;gEvaluation=&value_;active_=true;
        if (!gSeenMPL.exchange(true)) {writeReady();emit(@"probe_ready",@{});}
        installFactoryHooks();installLayerHook();pollCapture();
        emit(@"evaluate",evaluationJSON(value_));
    }} @catch(id){exceptionEvent("evaluation");}
    } catch (...){exceptionEvent("evaluation_cpp");}
    errno=saved;
}
EvaluationScope::~EvaluationScope(){if(active_)gEvaluation=previous_;}
void recordComplete(const void* command) noexcept {
    if (!enabled() || !command) return;
    const int saved=errno;
    try { @try { @autoreleasepool {
        Record r;r.id=gRecordID.fetch_add(1);
        if(gEvaluation)r.evaluation=*gEvaluation;
        r.scaler=loadAt<Identity>(command,8);r.descriptor=loadAt<Descriptor>(command,0x20);
        r.forcedReset=loadAt<std::uint8_t>(command,0x98)!=0;
        const auto stored=gLedger.store(reinterpret_cast<Identity>(command),r);
        emit(@"record",@{@"record_id":@(r.id),@"eval_id":@(r.evaluation.id),@"command":pointer(command),
            @"scaler":pointer(reinterpret_cast<void*>(r.scaler)),@"forced_reset":@(r.forcedReset),
            @"replaced_unconsumed":@(stored.replaced),@"evicted_unconsumed":@(stored.evicted),@"descriptor":descriptor(r.descriptor)});
    }} @catch(id){exceptionEvent("recordComplete");}
    } catch(...){exceptionEvent("recordComplete_cpp");}
    errno=saved;
}
ReplayScope::ReplayScope(const void* command) noexcept {
    if(!enabled() || !command)return;
    const int saved=errno;
    try { @try { @autoreleasepool {
        command_=command;scaler=loadAt<void*>(command,8);descriptor_=loadAt<Descriptor>(command,0x20);
        forcedReset_=loadAt<std::uint8_t>(command,0x98)!=0;
        match_=gLedger.take(reinterpret_cast<Identity>(command),reinterpret_cast<Identity>(scaler),descriptor_,forcedReset_);
        previous_=gReplay;gReplay=this;active_=true;
        emit(@"replay",@{@"command":pointer(command),@"scaler":pointer(scaler),@"match":[NSString stringWithUTF8String:matchName(match_.match)],
            @"record_id":@(match_.record ? match_.record->id : 0),@"eval_id":@(match_.record ? match_.record->evaluation.id : 0),
            @"descriptor":descriptor(descriptor_)});
        if(scaler)installEncodeHook(static_cast<id>(scaler));
    }} @catch(id){exceptionEvent("replay");}
    } catch(...){exceptionEvent("replay_cpp");}
    errno=saved;
}
ReplayScope::~ReplayScope(){
    if(!active_)return;
    if(!encodes_)emit(@"NO_NATIVE_ENCODE",@{@"command":pointer(command_)});
    gReplay=previous_;
}
std::uint64_t ReplayScope::beforeEncode(void* pointerValue,void* cbValue) noexcept {
    ++encodes_;const auto eid=gEncodeID.fetch_add(1);const int saved=errno;
    try { @try { @autoreleasepool {
        id object=static_cast<id>(pointerValue),cb=static_cast<id>(cbValue);
        id device=objectAt(cb,"device");
        if(!device)device=objectAt(objectAt(object,"colorTexture"),"device");
        rememberDevice(device);installCommandBufferHooks(cb);pollCapture();
        const int originalReset=boolAt(object,"reset");
        bool resetApplied=false;
        if(gResetHistory && has(object,"setReset:")) {
            reinterpret_cast<void(*)(id,SEL,BOOL)>(objc_msgSend)(object,sel("setReset:"),YES);resetApplied=true;
        }
        NSDictionary* createdInfo=static_cast<NSDictionary*>(objc_getAssociatedObject(object,&gCreationKey));
        NSDictionary* actual=@{@"color":texture(objectAt(object,"colorTexture")),@"depth":texture(objectAt(object,"depthTexture")),
            @"motion":texture(objectAt(object,"motionTexture")),@"output":texture(objectAt(object,"outputTexture")),
            @"exposure":texture(objectAt(object,"exposureTexture")),@"reactive":texture(objectAt(object,"reactiveMaskTexture")),
            @"jitter_x":number(floatAt(object,"jitterOffsetX")),@"jitter_y":number(floatAt(object,"jitterOffsetY")),
            @"mv_x":number(floatAt(object,"motionVectorScaleX")),@"mv_y":number(floatAt(object,"motionVectorScaleY")),
            @"pre_exposure":number(floatAt(object,"preExposure")),@"depth_reversed":@(boolAt(object,"isDepthReversed")),
            @"reset":@(boolAt(object,"reset")),@"width":optionalSize(object,"inputContentWidth"),@"height":optionalSize(object,"inputContentHeight"),
            @"capacity_width":optionalSize(object,"inputWidth"),@"capacity_height":optionalSize(object,"inputHeight")};
        emit(@"encode_before",@{@"encode_id":@(eid),@"record_id":@(match_.record ? match_.record->id : 0),
            @"eval_id":@(match_.record ? match_.record->evaluation.id : 0),@"match":[NSString stringWithUTF8String:matchName(match_.match)],
            @"command":pointer(command_),@"scaler_oid":@(oid(object)),@"scaler_class":className(object),
            @"cb_oid":@(oid(cb)),@"cb_epoch":@(epoch(cb)),@"cb":pointer(cb),@"cb_class":className(cb),
            @"recorded":descriptor(descriptor_),@"forced_reset":@(forcedReset_),@"actual":actual,
            @"creation_known":@(createdInfo!=nil),@"creation":createdInfo ?: @{},
            @"history_reset_test":@(gResetHistory),@"history_reset_applied":@(resetApplied),@"original_reset":@(originalReset)});
        if(has(cb,"pushDebugGroup:") && has(cb,"popDebugGroup")) {
            NSString* label=[NSString stringWithFormat:@"YAAGL.MFX e=%llu r=%llu eval=%llu cb=%llu epoch=%llu [A=input B=output]",
                static_cast<unsigned long long>(eid),static_cast<unsigned long long>(match_.record ? match_.record->id : 0),
                static_cast<unsigned long long>(match_.record ? match_.record->evaluation.id : 0),static_cast<unsigned long long>(oid(cb)),static_cast<unsigned long long>(epoch(cb))];
            reinterpret_cast<void(*)(id,SEL,id)>(objc_msgSend)(cb,sel("pushDebugGroup:"),label);pushed_=true;
        }
    }} @catch(id){exceptionEvent("beforeEncode");}
    } catch(...){exceptionEvent("beforeEncode_cpp");}
    errno=saved;return eid;
}
void ReplayScope::afterEncode(void*,void* cbValue,std::uint64_t eid,bool normal) noexcept {
    const int saved=errno;
    @try { @autoreleasepool {
        id cb=static_cast<id>(cbValue);
        if(pushed_) {reinterpret_cast<void(*)(id,SEL)>(objc_msgSend)(cb,sel("popDebugGroup"));pushed_=false;}
        emit(@"encode_after",@{@"encode_id":@(eid),@"returned_normally":@(normal),@"cpu_encode_only_not_gpu_completion":@YES});
    }} @catch(id){exceptionEvent("afterEncode");}
    errno=saved;
}
#ifdef YAAGL_FRAME_PROBE_TESTS
void flushForTests() noexcept {if(gWriter)dispatch_sync(gWriter,^{});}
#endif
} // namespace yaagl::pso::frameprobe
