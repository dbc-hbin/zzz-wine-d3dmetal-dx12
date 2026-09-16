// Reuse the uploaded fixture's proven D3D12/NGX ABI and resource helpers.
// Compile this translation unit INSTEAD OF ngx-smoke.cpp, and link the same
// ngx-smoke-msvc.obj. The include is intentional, not another linked TU.
#define main yaagl_original_exposure_smoke_main
#include "ngx-smoke.cpp"
#undef main
#include <string>

namespace {
constexpr UINT kW=128, kH=64, kOW=256, kOH=128, kFrames=24;
void transition(Gpu& gpu, ID3D12Resource* resource,
                D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource=resource;
    barrier.Transition.Subresource=D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore=before;
    barrier.Transition.StateAfter=after;
    gpu.commands->ResourceBarrier(1,&barrier);
}
void updateTexture(Gpu& gpu, ID3D12Resource* resource, const void* pixels,
                   std::size_t rowBytes, bool first) {
    if (!first) {
        gpu.begin();
        transition(gpu,resource,D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST);
        gpu.submit();
    }
    uploadTexture(gpu,resource,pixels,rowBytes);
}
std::vector<std::uint8_t> readRGBA8(Gpu& gpu,ID3D12Resource* output) {
    const auto desc=output->GetDesc();
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT rows=0; UINT64 rowBytes=0,total=0;
    gpu.device->GetCopyableFootprints(&desc,0,1,0,&footprint,&rows,&rowBytes,&total);
    if (desc.Format!=DXGI_FORMAT_R8G8B8A8_UNORM || rowBytes!=kOW*4 || rows!=kOH) fail("Unexpected readback layout");
    auto staging=makeBuffer(gpu,total,D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
    gpu.begin();
    transition(gpu,output,D3D12_RESOURCE_STATE_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION source{},destination{};
    source.pResource=output; source.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    destination.pResource=staging.Get(); destination.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    destination.PlacedFootprint=footprint;
    gpu.commands->CopyTextureRegion(&destination,0,0,0,&source,nullptr);
    transition(gpu,output,D3D12_RESOURCE_STATE_COPY_SOURCE,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    gpu.submit();
    void* mapped=nullptr;
    D3D12_RANGE range{0,static_cast<SIZE_T>(total)};
    check(staging->Map(0,&range,&mapped),"Map RGBA8 readback");
    std::vector<std::uint8_t> result(static_cast<std::size_t>(kOW)*kOH*4);
    for (UINT y=0;y<kOH;++y) {
        std::memcpy(result.data()+static_cast<std::size_t>(y)*kOW*4,
            static_cast<const char*>(mapped)+footprint.Offset+static_cast<std::size_t>(y)*footprint.Footprint.RowPitch,kOW*4);
    }
    D3D12_RANGE written{0,0}; staging->Unmap(0,&written);
    return result;
}
bool glyphAt(int x,int y) {
    // A white 'H' drawn on and moving with a gray plaque.
    return x>=14 && x<34 && y>=6 && y<19 &&
        (x<17 || x>=31 || (y>=11 && y<14));
}
void makeFrame(UINT frame,const std::string& mode,std::vector<std::uint8_t>& color,
               std::vector<float>& depth,std::vector<std::uint16_t>& motion) {
    const int px=12+2*static_cast<int>(frame), py=6+static_cast<int>(frame);
    const bool pixels=mode=="pixels";
    for (UINT y=0;y<kH;++y) for (UINT x=0;x<kW;++x) {
        const auto i=static_cast<std::size_t>(y)*kW+x;
        const int lx=static_cast<int>(x)-px,ly=static_cast<int>(y)-py;
        const bool plaque=lx>=0 && lx<56 && ly>=0 && ly<28;
        const bool glyph=plaque && glyphAt(lx,ly);
        std::uint8_t v=static_cast<std::uint8_t>(((x/8+y/8)&1)?40:65);
        if (plaque) v=static_cast<std::uint8_t>(((lx/4+ly/4)&1)?120:150);
        if (glyph) v=240;
        color[4*i]=v; color[4*i+1]=v; color[4*i+2]=v; color[4*i+3]=255;
        float z=plaque?.75f:.25f;
        float vx=plaque?-2.0f:0.0f,vy=plaque?-1.0f:0.0f;
        if (mode=="missing-label-motion" && glyph) { vx=0;vy=0;z=.25f; }
        if (mode=="normal-depth") z=1-z;
        depth[i]=z;
        motion[2*i]=half(pixels?vx:vx/static_cast<float>(kW));
        motion[2*i+1]=half(pixels?vy:vy/static_cast<float>(kH));
    }
}
void writeBytes(FILE* f,const void* p,std::size_t n) {
    if (std::fwrite(p,1,n,f)!=n) fail("Write output");
}
} // namespace

int main(int argc,char** argv) {
    if (argc!=3) {
        std::fprintf(stderr,"usage: ngx-reprojection.exe normalized|pixels|normal-depth|bad-y|missing-label-motion|reset output-prefix\n");
        return 2;
    }
    const std::string mode=argv[1],prefix=argv[2];
    if (mode!="normalized" && mode!="pixels" && mode!="normal-depth" && mode!="bad-y" && mode!="missing-label-motion" && mode!="reset") return 2;
    HMODULE module=LoadLibraryW(L"nvngx.dll");
    if (!module) fail("LoadLibrary(nvngx.dll)",GetLastError());
    const auto init=load<Init>(module,"NVSDK_NGX_D3D12_Init");
    const auto shutdown=load<Shutdown>(module,"NVSDK_NGX_D3D12_Shutdown");
    const auto getParameters=load<GetParameters>(module,"NVSDK_NGX_D3D12_GetParameters");
    const auto createFeature=load<CreateFeature>(module,"NVSDK_NGX_D3D12_CreateFeature");
    const auto evaluateFeature=load<EvaluateFeature>(module,"NVSDK_NGX_D3D12_EvaluateFeature");
    const auto releaseFeature=load<ReleaseFeature>(module,"NVSDK_NGX_D3D12_ReleaseFeature");
    Gpu gpu;
    wchar_t dataPath[MAX_PATH];
    if (!GetTempPathW(MAX_PATH,dataPath)) fail("GetTempPath",GetLastError());
    checkNgx(init(0x594141474c4e4758ull,dataPath,gpu.device.Get(),nullptr,NVSDK_NGX_Version_API),"NGX init");
    NVSDK_NGX_Parameter* params=nullptr;
    checkNgx(getParameters(&params),"GetParameters");
    if (!params) fail("Null NGX parameters");
    const int flags=mode=="normal-depth"?66:74;
    setCreateParameters(params,kW,kH,flags);
    ngx_smoke_set_uint(params,NVSDK_NGX_Parameter_OutWidth,kOW);
    ngx_smoke_set_uint(params,NVSDK_NGX_Parameter_OutHeight,kOH);
    auto color=makeTexture(gpu,kW,kH,DXGI_FORMAT_R8G8B8A8_UNORM,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
    // R32_FLOAT is intentional in this first semantic test: it separates the
    // depth convention from packed depth/stencil view translation. A pass
    // does NOT validate Depth32Float_Stencil8 / plane selection.
    auto depth=makeTexture(gpu,kW,kH,DXGI_FORMAT_R32_FLOAT,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
    auto motion=makeTexture(gpu,kW,kH,DXGI_FORMAT_R16G16_FLOAT,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
    auto output=makeTexture(gpu,kOW,kOH,DXGI_FORMAT_R8G8B8A8_UNORM,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    NVSDK_NGX_Handle* handle=nullptr;
    gpu.begin();
    checkNgx(createFeature(gpu.commands.Get(),NVSDK_NGX_Feature_SuperSampling,params,&handle),"CreateFeature");
    gpu.submit();
    if (!handle) fail("Null NGX feature");
    FILE* outputs=std::fopen((prefix+".rgba").c_str(),"wb");
    FILE* inputs=std::fopen((prefix+".input.rgba").c_str(),"wb");
    if (!outputs || !inputs) fail("Open output files");
    std::vector<std::uint8_t> colors(static_cast<std::size_t>(kW)*kH*4);
    std::vector<float> depths(static_cast<std::size_t>(kW)*kH);
    std::vector<std::uint16_t> motions(static_cast<std::size_t>(kW)*kH*2);
    for (UINT frame=0;frame<kFrames;++frame) {
        makeFrame(frame,mode,colors,depths,motions);
        updateTexture(gpu,color.Get(),colors.data(),kW*4,frame==0);
        updateTexture(gpu,depth.Get(),depths.data(),kW*4,frame==0);
        updateTexture(gpu,motion.Get(),motions.data(),kW*4,frame==0);
        ngx_smoke_reset(params);
        // Keep flags visible for the audit. They are creation-time state, not
        // instructions to change an existing feature during evaluation.
        ngx_smoke_set_int(params,NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags,flags);
        setEvaluationParameters(params,color.Get(),output.Get(),depth.Get(),motion.Get(),nullptr,
            kW,kH,1.0f,1.0f,true,0.0f,0.0f,(frame==0 || mode=="reset")?1:0);
        ngx_smoke_set_float(params,NVSDK_NGX_Parameter_MV_Scale_X,mode=="pixels"?1.0f:static_cast<float>(kW));
        ngx_smoke_set_float(params,NVSDK_NGX_Parameter_MV_Scale_Y,mode=="pixels"?1.0f:(mode=="bad-y"?-static_cast<float>(kH):static_cast<float>(kH)));
        ngx_smoke_set_uint(params,NVSDK_NGX_Parameter_Width,kW);
        ngx_smoke_set_uint(params,NVSDK_NGX_Parameter_Height,kH);
        ngx_smoke_set_uint(params,NVSDK_NGX_Parameter_OutWidth,kOW);
        ngx_smoke_set_uint(params,NVSDK_NGX_Parameter_OutHeight,kOH);
        gpu.begin();
        checkNgx(evaluateFeature(gpu.commands.Get(),handle,params,nullptr),"EvaluateFeature");
        gpu.submit();
        auto bytes=readRGBA8(gpu,output.Get());
        writeBytes(outputs,bytes.data(),bytes.size());
        writeBytes(inputs,colors.data(),colors.size());
    }
    if (std::fclose(outputs) || std::fclose(inputs)) fail("Close output files");
    FILE* metadata=std::fopen((prefix+".json").c_str(),"wb");
    if (!metadata) fail("Open metadata");
    std::fprintf(metadata,"{\"mode\":\"%s\",\"width\":%u,\"height\":%u,\"input_width\":%u,\"input_height\":%u,\"frames\":%u,\"flags\":%d,\"dx\":2,\"dy\":1,\"jitter\":false}\n",
        mode.c_str(),kOW,kOH,kW,kH,kFrames,flags);
    if (std::fclose(metadata)) fail("Close metadata");
    checkNgx(releaseFeature(handle),"ReleaseFeature");
    checkNgx(shutdown(),"Shutdown");
    FreeLibrary(module);
    std::printf("WROTE %u frames to %s.rgba; GPU assertions are in compare-reprojection.py\n",kFrames,prefix.c_str());
    return 0;
}
