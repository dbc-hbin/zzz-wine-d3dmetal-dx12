// macOS CPU-only runtime test. No Wine, private D3DMetal or GPU required.
#import <Foundation/Foundation.h>
#import "frame-probe.hpp"
#include <array>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
using namespace yaagl::pso::frameprobe;
@interface ProbeMockTexture : NSObject
- (NSUInteger)width;- (NSUInteger)height;- (NSUInteger)pixelFormat;
@end
@implementation ProbeMockTexture
- (NSUInteger)width{return 4096;}- (NSUInteger)height{return 2160;}- (NSUInteger)pixelFormat{return 115;}
@end
@interface ProbeMockCB : NSObject
@property(nonatomic) NSUInteger pushes;
@property(nonatomic) NSUInteger pops;
- (void)pushDebugGroup:(NSString*)s;- (void)popDebugGroup;
- (void)beginCommandBufferWithAllocator:(id)a;
@end
@implementation ProbeMockCB
- (void)pushDebugGroup:(NSString*)s{(void)s;self.pushes+=1;}
- (void)popDebugGroup{self.pops+=1;}
- (void)beginCommandBufferWithAllocator:(id)a{(void)a;}
@end
@interface ProbeMockScaler : NSObject
@property(nonatomic,retain) id colorTexture;
@property(nonatomic,retain) id depthTexture;
@property(nonatomic,retain) id motionTexture;
@property(nonatomic,retain) id outputTexture;
@property(nonatomic) float jitterOffsetX;
@property(nonatomic) float jitterOffsetY;
@property(nonatomic) float motionVectorScaleX;
@property(nonatomic) float motionVectorScaleY;
@property(nonatomic) float preExposure;
@property(nonatomic) NSUInteger inputContentWidth;
@property(nonatomic) NSUInteger inputContentHeight;
@property(nonatomic,getter=isDepthReversed) BOOL depthReversed;
@property(nonatomic) BOOL reset;
@property(nonatomic) NSUInteger calls;
@property(nonatomic) BOOL seenReset;
- (NSUInteger)inputWidth;- (NSUInteger)inputHeight;
- (void)encodeToCommandBuffer:(id)cb;
@end
@implementation ProbeMockScaler
- (NSUInteger)inputWidth{return 4096;}- (NSUInteger)inputHeight{return 2160;}
- (void)encodeToCommandBuffer:(id)cb{(void)cb;self.calls+=1;self.seenReset=self.reset;self.reset=NO;}
- (void)dealloc{[_colorTexture release];[_depthTexture release];[_motionTexture release];[_outputTexture release];[super dealloc];}
@end
@interface ProbeMockSubclass : ProbeMockScaler @end
@implementation ProbeMockSubclass @end
struct Params {float jitter;};
static std::uint32_t __attribute__((ms_abi)) getFloat(const void* p,const char* key,float* out){
    if(!std::strcmp(key,"Jitter.Offset.X")){*out=static_cast<const Params*>(p)->jitter;return 1;}
    if(!std::strcmp(key,"Jitter.Offset.Y")){*out=0;return 1;}
    if(!std::strcmp(key,"MV.Scale.X")){*out=2256;return 1;}
    if(!std::strcmp(key,"MV.Scale.Y")){*out=1272;return 1;}
    if(!std::strcmp(key,"DLSS.Pre.Exposure")){*out=1;return 1;}return 0xbad00000;
}
static std::uint32_t __attribute__((ms_abi)) getUint(const void*,const char* key,std::uint32_t* out){
    if(!std::strcmp(key,"DLSS.Render.Subrect.Dimensions.Width")){*out=2256;return 1;}
    if(!std::strcmp(key,"DLSS.Render.Subrect.Dimensions.Height")){*out=1272;return 1;}
    if(!std::strcmp(key,"Reset")){*out=0;return 1;}return 0xbad00000;
}
static std::uint32_t __attribute__((ms_abi)) getInt(const void*,const char* key,std::int32_t* out){
    if(!std::strcmp(key,"DLSS.Feature.Create.Flags")){*out=74;return 1;}return 0xbad00000;
}
static std::uint32_t __attribute__((ms_abi)) getResource(const void*,const char*,void**){return 0xbad00000;}
struct Command {std::array<std::uint8_t,0xa0> bytes{};};
static Descriptor desc(ProbeMockScaler* scaler,float jitter){
    Descriptor d{};d.color=reinterpret_cast<std::uintptr_t>(scaler.colorTexture);
    d.depth=reinterpret_cast<std::uintptr_t>(scaler.depthTexture);d.motion=reinterpret_cast<std::uintptr_t>(scaler.motionTexture);
    d.output=reinterpret_cast<std::uintptr_t>(scaler.outputTexture);d.width=2256;d.height=1272;d.jitterX=jitter;
    d.motionScaleX=2256;d.motionScaleY=1272;d.preExposure=1;return d;
}
static void record(Command& c,ProbeMockScaler* scaler,Params& p){
    auto d=desc(scaler,p.jitter);void* object=scaler;
    std::memcpy(c.bytes.data()+8,&object,sizeof(object));std::memcpy(c.bytes.data()+0x20,&d,sizeof(d));
    EvaluationScope eval(scaler,reinterpret_cast<void*>(0x1234),&p);recordComplete(c.bytes.data());
}
static void replay(Command& c,ProbeMockScaler* scaler,ProbeMockCB* cb,bool broken=false){
    Descriptor d{};std::memcpy(&d,c.bytes.data()+0x20,sizeof(d));
    ReplayScope scope(c.bytes.data());
    // Simulate D3DMetal's native setters AFTER replay entry, BEFORE encode.
    scaler.inputContentWidth=d.width;scaler.inputContentHeight=d.height;
    scaler.jitterOffsetX=broken?4.0f:d.jitterX;scaler.jitterOffsetY=d.jitterY;
    scaler.motionVectorScaleX=d.motionScaleX;scaler.motionVectorScaleY=d.motionScaleY;
    scaler.preExposure=d.preExposure;scaler.depthReversed=YES;scaler.reset=NO;
    [scaler encodeToCommandBuffer:cb];
}
int main(int argc,char**argv){
    if(argc!=2){std::fprintf(stderr,"usage: native-mock MODE0700_DIRECTORY\n");return 2;}
    @autoreleasepool{
        setenv("YAAGL_METALFX_FRAME_PROBE","1",1);setenv("YAAGL_METALFX_PROBE_DIR",argv[1],1);
        initialize(getFloat,getUint,getInt,getResource);assert(enabled());
        ProbeMockTexture* t=[[ProbeMockTexture alloc]init];ProbeMockScaler* s=[[ProbeMockScaler alloc]init];
        s.colorTexture=t;s.depthTexture=t;s.motionTexture=t;s.outputTexture=t;
        ProbeMockCB* cb=[[ProbeMockCB alloc]init];Params p{.1f};Command a,b,c;
        record(a,s,p);p.jitter=.2f;record(b,s,p);p.jitter=.9f;
        replay(b,s,cb);replay(a,s,cb); // must still correlate to Evaluate 2 then 1
        [cb beginCommandBufferWithAllocator:nil]; // epoch is now observed
        replay(a,s,cb); // deliberate repeated replay -> untracked, not Eval 1
        p.jitter=.3f;record(c,s,p);c.bytes[0x50]^=1;replay(c,s,cb); // width bytes changed after recording
        p.jitter=.4f;record(c,s,p);replay(c,s,cb,true); // real encode sees 4.0, not the entry's .4
        const char* reset=getenv("YAAGL_METALFX_PROBE_RESET_HISTORY");
        assert(s.seenReset==(reset && !std::strcmp(reset,"1") ? YES:NO));
        auto pushes=cb.pushes;[s encodeToCommandBuffer:cb];assert(cb.pushes==pushes); // pass-through outside scope
        ProbeMockSubclass* sub=[[ProbeMockSubclass alloc]init];sub.colorTexture=t;sub.depthTexture=t;sub.motionTexture=t;sub.outputTexture=t;
        record(c,sub,p);replay(c,sub,cb);assert(sub.calls==1); // inherited IMP chains exactly once
        assert(cb.pushes==cb.pops && cb.pushes==6);assert(s.calls==6);
        flushForTests();std::puts("PASS: native setters, delayed/reordered record association, repeated replay, changed bytes, scope isolation, inherited IMP, balanced groups, optional reset");
        [sub release];[s release];[t release];[cb release];
    }return 0;
}
