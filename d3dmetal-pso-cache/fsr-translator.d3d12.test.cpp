#include "d3d12-test-helpers.hpp"

#include "third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api.h"
#include "third-party/fidelityfx/Kits/FidelityFX/api/include/dx12/ffx_api_dx12.h"
#include "third-party/fidelityfx/Kits/FidelityFX/upscalers/include/ffx_upscale.h"

namespace {
constexpr UINT kFsrRenderWidth = 1248;
constexpr UINT kFsrRenderHeight = 696;
constexpr UINT kFsrOutputWidth = 3840;
constexpr UINT kFsrOutputHeight = 2160;
constexpr UINT kTemporalOutputWidth = kFsrRenderWidth * 3;
constexpr UINT kTemporalOutputHeight = kFsrRenderHeight * 3;
constexpr UINT kTemporalOffsetX = (kFsrOutputWidth - kTemporalOutputWidth) / 2;
constexpr UINT kTemporalOffsetY = (kFsrOutputHeight - kTemporalOutputHeight) / 2;
constexpr std::uint64_t kProvider = 0x4d46580000000001ull;

using Create = ffxReturnCode_t (*)(ffxContext*, ffxCreateContextDescHeader*, const ffxAllocationCallbacks*);
using Destroy = ffxReturnCode_t (*)(ffxContext*, const ffxAllocationCallbacks*);
using Dispatch = ffxReturnCode_t (*)(ffxContext*, const ffxDispatchDescHeader*);
using Query = ffxReturnCode_t (*)(ffxContext*, ffxQueryDescHeader*);

struct FsrApi { Create create; Destroy destroy; Dispatch dispatch; Query query; };

void expectFfx(ffxReturnCode_t actual, ffxReturnCode_t expected, const char* label) {
    if (actual != expected) {
        std::fprintf(stderr, "FSR_TRANSLATOR_FAIL %s got=%u expected=%u\n", label, actual, expected);
        std::exit(1);
    }
}

struct AllocatorState { std::uint32_t allocations = 0, frees = 0; };
void* allocate(void* user, std::uint64_t bytes) {
    ++static_cast<AllocatorState*>(user)->allocations;
    return std::malloc(static_cast<std::size_t>(bytes));
}
void deallocate(void* user, void* memory) {
    ++static_cast<AllocatorState*>(user)->frees;
    std::free(memory);
}

struct OutputMeasurements {
    double interiorMean = 0.0;
    float borderMaximum = 0.0f;
};

OutputMeasurements measureOutput(const ReadbackTexture& readback) {
    const std::uint8_t* mapped = nullptr;
    D3D12_RANGE range{0, static_cast<SIZE_T>(readback.size)};
    check(readback.buffer->Map(0, &range, reinterpret_cast<void**>(const_cast<std::uint8_t**>(&mapped))),
          "Map FSR readback");
    double interiorSum = 0.0;
    std::size_t interiorCount = 0;
    float borderMaximum = 0.0f;
    for (UINT y = 0; y < kFsrOutputHeight; ++y) {
        const auto* row = reinterpret_cast<const std::uint16_t*>(mapped + readback.footprint.Offset +
            static_cast<SIZE_T>(y) * readback.footprint.Footprint.RowPitch);
        for (UINT x = 0; x < kFsrOutputWidth; ++x) {
            const float value = unhalf(row[x * 4]);
            if (!std::isfinite(value)) fail("non-finite FSR output");
            const bool interior = x >= kTemporalOffsetX && x < kTemporalOffsetX + kTemporalOutputWidth &&
                                  y >= kTemporalOffsetY && y < kTemporalOffsetY + kTemporalOutputHeight;
            if (interior) {
                interiorSum += value;
                ++interiorCount;
            } else {
                for (UINT channel = 0; channel < 3; ++channel) {
                    const float magnitude = std::fabs(unhalf(row[x * 4 + channel]));
                    if (!std::isfinite(magnitude)) fail("non-finite FSR output margin");
                    if (magnitude > borderMaximum) borderMaximum = magnitude;
                }
            }
        }
    }
    readback.buffer->Unmap(0, nullptr);
    return {interiorSum / interiorCount, borderMaximum};
}
} // namespace

int main() {
    HMODULE module = LoadLibraryW(L"amd_fidelityfx_upscaler_dx12.dll");
    if (!module) fail("LoadLibrary amd_fidelityfx_upscaler_dx12", GetLastError());
    FsrApi api{load<Create>(module, "ffxCreateContext"), load<Destroy>(module, "ffxDestroyContext"),
               load<Dispatch>(module, "ffxDispatch"), load<Query>(module, "ffxQuery")};

    std::uint64_t count = 0;
    ffxQueryDescGetVersions versions{{FFX_API_QUERY_DESC_TYPE_GET_VERSIONS, nullptr},
        FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE, nullptr, &count, nullptr, nullptr};
    expectFfx(api.query(nullptr, &versions.header), FFX_API_RETURN_OK, "provider count");
    if (count != 1) fail("provider count mismatch");
    std::uint64_t id = 0; const char* name = nullptr; count = 1;
    versions.versionIds = &id; versions.versionNames = &name;
    expectFfx(api.query(nullptr, &versions.header), FFX_API_RETURN_OK, "provider data");
    if (id != kProvider || !name || std::strcmp(name, "MetalFX (FSR 4 API)")) fail("provider identity");
    ffxApiHeader unknown{0x100ffu, nullptr};
    expectFfx(api.query(nullptr, &unknown), FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE, "unknown query");
    versions.outputCount = nullptr; versions.versionIds = nullptr; versions.versionNames = nullptr;
    expectFfx(api.query(nullptr, &versions.header), FFX_API_RETURN_OK, "provider probe without outputs");
    ffxQueryDescUpscaleGetUpscaleRatioFromQualityMode ratioQuery{
        {FFX_API_QUERY_DESC_TYPE_UPSCALE_GETUPSCALERATIOFROMQUALITYMODE, nullptr},
        FFX_UPSCALE_QUALITY_MODE_QUALITY, nullptr};
    expectFfx(api.query(nullptr, &ratioQuery.header), FFX_API_RETURN_OK, "ratio probe without output");
    ffxQueryDescUpscaleGetRenderResolutionFromQualityMode resolutionQuery{
        {FFX_API_QUERY_DESC_TYPE_UPSCALE_GETRENDERRESOLUTIONFROMQUALITYMODE, nullptr},
        kFsrOutputWidth, kFsrOutputHeight, FFX_UPSCALE_QUALITY_MODE_QUALITY, nullptr, nullptr};
    expectFfx(api.query(nullptr, &resolutionQuery.header), FFX_API_RETURN_OK, "resolution probe without outputs");
    std::uint32_t queriedWidth = 0, queriedHeight = 0;
    resolutionQuery.pOutRenderWidth = &queriedWidth;
    resolutionQuery.pOutRenderHeight = &queriedHeight;
    expectFfx(api.query(nullptr, &resolutionQuery.header), FFX_API_RETURN_OK, "quality resolution");
    if (queriedWidth != 2560 || queriedHeight != 1440) fail("quality resolution mismatch");
    resolutionQuery.displayWidth = 3839;
    resolutionQuery.displayHeight = 2159;
    resolutionQuery.qualityMode = FFX_UPSCALE_QUALITY_MODE_ULTRA_PERFORMANCE;
    expectFfx(api.query(nullptr, &resolutionQuery.header), FFX_API_RETURN_OK, "Ultra resolution");
    if (queriedWidth != 1279 || queriedHeight != 719) fail("Ultra quality ratio was remapped");
    ffxQueryDescUpscaleGetJitterPhaseCount phaseQuery{
        {FFX_API_QUERY_DESC_TYPE_UPSCALE_GETJITTERPHASECOUNT, nullptr},
        kFsrRenderWidth, kFsrOutputWidth, nullptr};
    expectFfx(api.query(nullptr, &phaseQuery.header), FFX_API_RETURN_OK, "phase probe without output");
    ffxQueryDescUpscaleGetJitterOffset jitterQuery{
        {FFX_API_QUERY_DESC_TYPE_UPSCALE_GETJITTEROFFSET, nullptr}, 0, 18, nullptr, nullptr};
    expectFfx(api.query(nullptr, &jitterQuery.header), FFX_API_RETURN_OK, "jitter probe without outputs");

    Gpu gpu;
    ffxCreateBackendDX12Desc backend{{FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12, nullptr}, gpu.device.Get()};
    ffxCreateContextDescUpscaleVersion version{{FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE_VERSION, &backend.header},
                                               FFX_UPSCALER_VERSION};
    ffxOverrideVersion overrideVersion{{FFX_API_DESC_TYPE_OVERRIDE_VERSION, &version.header}, kProvider};
    ffxCreateContextDescUpscale create{{FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE, &overrideVersion.header},
        FFX_UPSCALE_ENABLE_HIGH_DYNAMIC_RANGE, {kFsrRenderWidth, kFsrRenderHeight},
        {kFsrOutputWidth, kFsrOutputHeight}, nullptr};
    AllocatorState allocations;
    ffxAllocationCallbacks callbacks{&allocations, &allocate, &deallocate};
    ffxContext context = nullptr;
    expectFfx(api.create(&context, &create.header, &callbacks), FFX_API_RETURN_OK, "create");
    if (!context || allocations.allocations != 1) fail("custom allocator create");

    std::vector<std::uint16_t> colorPixels(static_cast<std::size_t>(kFsrRenderWidth) * kFsrRenderHeight * 4);
    for (std::size_t i = 0; i < colorPixels.size(); i += 4) {
        colorPixels[i] = half(0.25f); colorPixels[i + 1] = half(0.5f);
        colorPixels[i + 2] = half(0.75f); colorPixels[i + 3] = half(1.0f);
    }
    std::vector<float> depthPixels(static_cast<std::size_t>(kFsrRenderWidth) * kFsrRenderHeight, 0.5f);
    std::vector<std::uint16_t> motionPixels(static_cast<std::size_t>(kFsrRenderWidth) * kFsrRenderHeight * 2, half(0.0f));
    std::vector<std::uint16_t> sentinel(static_cast<std::size_t>(kFsrOutputWidth) * kFsrOutputHeight * 4, half(7.0f));
    auto color = makeTexture(gpu, kFsrRenderWidth, kFsrRenderHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                             D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    auto depth = makeTexture(gpu, kFsrRenderWidth, kFsrRenderHeight, DXGI_FORMAT_R32_FLOAT,
                             D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    auto motion = makeTexture(gpu, kFsrRenderWidth, kFsrRenderHeight, DXGI_FORMAT_R16G16_FLOAT,
                              D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    auto output = makeTexture(gpu, kFsrOutputWidth, kFsrOutputHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                              D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_DEST);
    uploadTexture(gpu, color.Get(), colorPixels.data(), kFsrRenderWidth * 8);
    uploadTexture(gpu, depth.Get(), depthPixels.data(), kFsrRenderWidth * 4);
    uploadTexture(gpu, motion.Get(), motionPixels.data(), kFsrRenderWidth * 4);
    uploadTexture(gpu, output.Get(), sentinel.data(), kFsrOutputWidth * 8);

    gpu.begin();
    transition(gpu.list.Get(), color.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    transition(gpu.list.Get(), depth.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    transition(gpu.list.Get(), motion.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    transition(gpu.list.Get(), output.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    ffxDispatchDescUpscale dispatch{};
    dispatch.header.type = FFX_API_DISPATCH_DESC_TYPE_UPSCALE;
    dispatch.commandList = gpu.list.Get();
    dispatch.color = ffxApiGetResourceDX12(color.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
    dispatch.depth = ffxApiGetResourceDX12(depth.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
    dispatch.motionVectors = ffxApiGetResourceDX12(motion.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
    dispatch.output = ffxApiGetResourceDX12(output.Get(), FFX_API_RESOURCE_STATE_UNORDERED_ACCESS);
    dispatch.renderSize = {kFsrRenderWidth, kFsrRenderHeight};
    dispatch.upscaleSize = {kFsrOutputWidth, kFsrOutputHeight};
    dispatch.motionVectorScale = {static_cast<float>(kFsrRenderWidth), static_cast<float>(kFsrRenderHeight)};
    dispatch.enableSharpening = false; dispatch.sharpness = 0.0f;
    dispatch.frameTimeDelta = 16.6667f; dispatch.preExposure = 1.0f; dispatch.reset = true;
    dispatch.cameraNear = 0.1f; dispatch.cameraFar = 1000.0f;
    dispatch.cameraFovAngleVertical = 1.0472f; dispatch.viewSpaceToMetersFactor = 0.0f;
    expectFfx(api.dispatch(&context, &dispatch.header), FFX_API_RETURN_OK, "dispatch");
    ffxContext stale = context;
    expectFfx(api.destroy(&context, &callbacks), FFX_API_RETURN_OK, "destroy before submission");
    if (context || allocations.frees != 1) fail("destroy allocator/lifetime");
    expectFfx(api.destroy(&stale, &callbacks), FFX_API_RETURN_ERROR_PARAMETER, "stale handle");

    auto readback = makeReadback(gpu, output.Get());
    transition(gpu.list.Get(), output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    copyToReadback(gpu.list.Get(), output.Get(), readback);
    gpu.submit();
    const OutputMeasurements measurements = measureOutput(readback);
    if (measurements.interiorMean > 2.0 || measurements.interiorMean < 0.05)
        fail("FSR temporal output retained sentinel or ignored input");
    if (measurements.borderMaximum > 0.001f)
        fail("FSR caller output margins were not black");
    std::printf("FSR_TRANSLATOR_D3D12_PASS interiorMean=%.6f borderMaximum=%.6f "
                "temporal=%ux%u placement=%u,%u caller=%ux%u allocations=%u frees=%u\n",
                measurements.interiorMean, measurements.borderMaximum,
                kTemporalOutputWidth, kTemporalOutputHeight, kTemporalOffsetX, kTemporalOffsetY,
                kFsrOutputWidth, kFsrOutputHeight, allocations.allocations, allocations.frees);
    FreeLibrary(module);
    return 0;
}
