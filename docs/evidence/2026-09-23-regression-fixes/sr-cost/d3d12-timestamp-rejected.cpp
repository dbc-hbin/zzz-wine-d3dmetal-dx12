#define WIN32_LEAN_AND_MEAN
#include "d3d12-test-helpers.hpp"
#include "third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api.h"
#include "third-party/fidelityfx/Kits/FidelityFX/api/include/dx12/ffx_api_dx12.h"
#include "third-party/fidelityfx/Kits/FidelityFX/upscalers/include/ffx_upscale.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

using Clock = std::chrono::steady_clock;
using Create = ffxReturnCode_t (*)(ffxContext*, ffxCreateContextDescHeader*, const ffxAllocationCallbacks*);
using Destroy = ffxReturnCode_t (*)(ffxContext*, const ffxAllocationCallbacks*);
using Dispatch = ffxReturnCode_t (*)(ffxContext*, const ffxDispatchDescHeader*);
using Query = ffxReturnCode_t (*)(ffxContext*, ffxQueryDescHeader*);
struct FsrApi { Create create; Destroy destroy; Dispatch dispatch; Query query; };

static double ms(Clock::time_point a, Clock::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}
static double quantile(std::vector<double> values, double q) {
    std::sort(values.begin(), values.end());
    return values[static_cast<std::size_t>(std::ceil(q * values.size())) - 1];
}
static void require(bool condition, const char* label, std::uint32_t code = 0) {
    if (!condition) fail(label, static_cast<long>(code));
}

int main(int argc, char** argv) {
    constexpr UINT rw = 1128, rh = 624, ow = 1920, oh = 1080;
    constexpr int warmup = 8, measured = 24;
    const std::string requested = argc > 1 ? argv[1] : "mfx";
    const std::string dllName = argc > 2 ? argv[2] : "amd_fidelityfx_upscaler_dx12.dll";
    const bool sharpen = argc > 3 ? std::string(argv[3]) == "on" : true;
    require(argc <= 3 || std::string(argv[3]) == "on" || std::string(argv[3]) == "off", "sharpen must be on/off");
    const std::string createMode = argc > 4 ? argv[4] : "sdr";
    const bool hdr = createMode == "hdr";
    const bool autoExposure = createMode == "auto";
    require(argc <= 4 || createMode == "hdr" || createMode == "sdr" || createMode == "auto",
            "create mode must be sdr/hdr/auto");
    std::wstring dllPath(dllName.begin(), dllName.end());
    HMODULE module = LoadLibraryW(dllPath.c_str());
    require(module != nullptr, "LoadLibrary FSR upscaler", GetLastError());
    wchar_t loadedPath[32768]{};
    GetModuleFileNameW(module, loadedPath, static_cast<DWORD>(std::size(loadedPath)));
    FsrApi api{load<Create>(module, "ffxCreateContext"), load<Destroy>(module, "ffxDestroyContext"),
               load<Dispatch>(module, "ffxDispatch"), load<Query>(module, "ffxQuery")};

    std::uint64_t count = 0;
    ffxQueryDescGetVersions versions{{FFX_API_QUERY_DESC_TYPE_GET_VERSIONS, nullptr},
        FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE, nullptr, &count, nullptr, nullptr};
    require(api.query(nullptr, &versions.header) == FFX_API_RETURN_OK, "query provider count");
    require(count > 0 && count <= 16, "provider count bound");
    std::vector<std::uint64_t> ids(static_cast<std::size_t>(count));
    std::vector<const char*> names(static_cast<std::size_t>(count));
    versions.versionIds = ids.data(); versions.versionNames = names.data();
    require(api.query(nullptr, &versions.header) == FFX_API_RETURN_OK, "query provider identities");
    std::uint64_t provider = 0;
    const char* providerName = nullptr;
    const std::string wanted = requested == "mfx" ? "MetalFX (FSR 4 API)" : requested;
    for (std::uint64_t i = 0; i < count; ++i) {
        std::printf("available_provider id=0x%016llx name=%s\n",
                    static_cast<unsigned long long>(ids[static_cast<std::size_t>(i)]),
                    names[static_cast<std::size_t>(i)] ? names[static_cast<std::size_t>(i)] : "<null>");
        if (names[static_cast<std::size_t>(i)] && wanted == names[static_cast<std::size_t>(i)]) {
            provider = ids[static_cast<std::size_t>(i)];
            providerName = names[static_cast<std::size_t>(i)];
        }
    }
    require(provider != 0 && providerName, "requested provider not enumerated");

    Gpu gpu;
    ffxCreateBackendDX12Desc backend{{FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12, nullptr}, gpu.device.Get()};
    ffxCreateContextDescUpscaleVersion version{{FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE_VERSION, &backend.header},
                                                FFX_UPSCALER_VERSION};
    ffxOverrideVersion overrideVersion{{FFX_API_DESC_TYPE_OVERRIDE_VERSION, &version.header}, provider};
    const std::uint32_t createFlags = static_cast<std::uint32_t>(
        (hdr ? FFX_UPSCALE_ENABLE_HIGH_DYNAMIC_RANGE : 0) |
        (autoExposure ? FFX_UPSCALE_ENABLE_AUTO_EXPOSURE : 0));
    ffxCreateContextDescUpscale create{{FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE, &overrideVersion.header},
        createFlags, {rw, rh}, {ow, oh}, nullptr};
    ffxContext context = nullptr;
    const ffxReturnCode_t createResult = api.create(&context, &create.header, nullptr);
    require(createResult == FFX_API_RETURN_OK && context, "create selected FSR provider", createResult);

    std::vector<std::uint16_t> colorPixels(static_cast<std::size_t>(rw) * rh * 4);
    for (UINT y = 0; y < rh; ++y) for (UINT x = 0; x < rw; ++x) {
        const std::size_t i = (static_cast<std::size_t>(y) * rw + x) * 4;
        colorPixels[i] = half(0.2f + 0.5f * static_cast<float>(x % 17) / 16.0f);
        colorPixels[i + 1] = half(0.4f); colorPixels[i + 2] = half(0.7f); colorPixels[i + 3] = half(1.0f);
    }
    std::vector<float> depthPixels(static_cast<std::size_t>(rw) * rh, 0.5f);
    std::vector<std::uint16_t> motionPixels(static_cast<std::size_t>(rw) * rh * 2, half(0.0f));
    std::vector<std::uint8_t> reactivePixels(static_cast<std::size_t>(rw) * rh);
    for (UINT y = 0; y < rh; ++y) for (UINT x = 0; x < rw; ++x)
        reactivePixels[static_cast<std::size_t>(y) * rw + x] = ((x / 8 + y / 8) & 1) ? 255 : 0;
    std::vector<std::uint16_t> sentinel(static_cast<std::size_t>(ow) * oh * 4, half(7.0f));
    auto color = makeTexture(gpu, rw, rh, DXGI_FORMAT_R16G16B16A16_FLOAT, D3D12_RESOURCE_FLAG_NONE,
                             D3D12_RESOURCE_STATE_COPY_DEST);
    auto depth = makeTexture(gpu, rw, rh, DXGI_FORMAT_R32_FLOAT, D3D12_RESOURCE_FLAG_NONE,
                             D3D12_RESOURCE_STATE_COPY_DEST);
    auto motion = makeTexture(gpu, rw, rh, DXGI_FORMAT_R16G16_FLOAT, D3D12_RESOURCE_FLAG_NONE,
                              D3D12_RESOURCE_STATE_COPY_DEST);
    auto reactive = makeTexture(gpu, rw, rh, DXGI_FORMAT_R8_UNORM, D3D12_RESOURCE_FLAG_NONE,
                                D3D12_RESOURCE_STATE_COPY_DEST);
    auto output = makeTexture(gpu, ow, oh, DXGI_FORMAT_R16G16B16A16_FLOAT,
                              D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_DEST);
    uploadTexture(gpu, color.Get(), colorPixels.data(), rw * 8);
    uploadTexture(gpu, depth.Get(), depthPixels.data(), rw * 4);
    uploadTexture(gpu, motion.Get(), motionPixels.data(), rw * 4);
    uploadTexture(gpu, reactive.Get(), reactivePixels.data(), rw);
    uploadTexture(gpu, output.Get(), sentinel.data(), ow * 8);
    gpu.begin();
    transition(gpu.list.Get(), color.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    transition(gpu.list.Get(), depth.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    transition(gpu.list.Get(), motion.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    transition(gpu.list.Get(), reactive.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    transition(gpu.list.Get(), output.Get(), D3D12_RESOURCE_STATE_COPY_DEST, D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    gpu.submit();

    D3D12_QUERY_HEAP_DESC qdesc{};
    qdesc.Type = D3D12_QUERY_HEAP_TYPE_TIMESTAMP;
    qdesc.Count = 2;
    ComPtr<ID3D12QueryHeap> queries;
    check(gpu.device->CreateQueryHeap(&qdesc, IID_PPV_ARGS(&queries)), "CreateQueryHeap(timestamp)");
    UINT64 frequency = 0;
    check(gpu.queue->GetTimestampFrequency(&frequency), "GetTimestampFrequency");
    require(frequency > 0, "zero timestamp frequency");
    auto timestamps = makeBuffer(gpu, sizeof(UINT64) * 2, D3D12_HEAP_TYPE_READBACK,
                                 D3D12_RESOURCE_STATE_COPY_DEST);
    std::vector<double> gpuQueryTimes;
    gpuQueryTimes.reserve(measured);
    std::printf("timestamp_frequency=%llu\n", static_cast<unsigned long long>(frequency));
    std::vector<double> apiTimes, closeTimes, executeFenceTimes, fenceArmTimes, eventWaitTimes, submitTimes, completionTimes;
    apiTimes.reserve(measured); closeTimes.reserve(measured); executeFenceTimes.reserve(measured); fenceArmTimes.reserve(measured); eventWaitTimes.reserve(measured);
    submitTimes.reserve(measured); completionTimes.reserve(measured);
    for (int frame = 0; frame < warmup + measured; ++frame) {
        gpu.begin();
        ffxDispatchDescUpscale dispatch{};
        dispatch.header.type = FFX_API_DISPATCH_DESC_TYPE_UPSCALE;
        dispatch.commandList = gpu.list.Get();
        dispatch.color = ffxApiGetResourceDX12(color.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
        dispatch.depth = ffxApiGetResourceDX12(depth.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
        dispatch.motionVectors = ffxApiGetResourceDX12(motion.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
        dispatch.reactive = ffxApiGetResourceDX12(reactive.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
        dispatch.output = ffxApiGetResourceDX12(output.Get(), FFX_API_RESOURCE_STATE_UNORDERED_ACCESS);
        dispatch.renderSize = {rw, rh}; dispatch.upscaleSize = {ow, oh};
        dispatch.motionVectorScale = {static_cast<float>(rw), static_cast<float>(rh)};
        dispatch.jitterOffset = {0.1875f, 0.129629612f};
        dispatch.enableSharpening = sharpen; dispatch.sharpness = 0.5f;
        dispatch.frameTimeDelta = 16.6667f; dispatch.preExposure = 1.0f; dispatch.reset = frame == 0;
        dispatch.cameraNear = 0.1f; dispatch.cameraFar = 1000.0f; dispatch.cameraFovAngleVertical = 1.0472f;
        gpu.list->EndQuery(queries.Get(), D3D12_QUERY_TYPE_TIMESTAMP, 0);
        const auto start = Clock::now();
        const ffxReturnCode_t result = api.dispatch(&context, &dispatch.header);
        const auto dispatched = Clock::now();
        require(result == FFX_API_RETURN_OK, "FSR dispatch failed", result);
        gpu.list->EndQuery(queries.Get(), D3D12_QUERY_TYPE_TIMESTAMP, 1);
        gpu.list->ResolveQueryData(queries.Get(), D3D12_QUERY_TYPE_TIMESTAMP, 0, 2,
                                   timestamps.Get(), 0);
        gpu.close();
        const auto closed = Clock::now();
        gpu.executeClosed();
        const auto completed = Clock::now();
        UINT64* ticks = nullptr;
        D3D12_RANGE tickRange{0, sizeof(UINT64) * 2};
        check(timestamps->Map(0, &tickRange, reinterpret_cast<void**>(&ticks)), "Map timestamps");
        const UINT64 t0 = ticks[0], t1 = ticks[1];
        D3D12_RANGE emptyRange{0, 0};
        timestamps->Unmap(0, &emptyRange);
        std::printf("QUERY frame=%d start=%llu end=%llu ticks=%llu gpu_ms=%.4f\n", frame,
                    static_cast<unsigned long long>(t0), static_cast<unsigned long long>(t1),
                    static_cast<unsigned long long>(t1-t0),
                    static_cast<double>(t1-t0)*1000.0/static_cast<double>(frequency));
        if (frame >= warmup) {
            require(t1 > t0, "invalid timestamp ordering");
            gpuQueryTimes.push_back(static_cast<double>(t1-t0)*1000.0/static_cast<double>(frequency));
            apiTimes.push_back(ms(start, dispatched));
            closeTimes.push_back(ms(dispatched, closed));
            executeFenceTimes.push_back(ms(closed, completed));
            fenceArmTimes.push_back(gpu.fenceArmMs); eventWaitTimes.push_back(gpu.fenceWaitMs);
            submitTimes.push_back(ms(dispatched, completed));
            completionTimes.push_back(ms(start, completed));
        }
    }
    const ffxReturnCode_t destroyResult = api.destroy(&context, nullptr);
    require(destroyResult == FFX_API_RETURN_OK, "destroy FSR context", destroyResult);

    auto readback = makeReadback(gpu, output.Get());
    gpu.begin();
    transition(gpu.list.Get(), output.Get(), D3D12_RESOURCE_STATE_UNORDERED_ACCESS, D3D12_RESOURCE_STATE_COPY_SOURCE);
    copyToReadback(gpu.list.Get(), output.Get(), readback);
    gpu.submit();
    const std::uint8_t* mapped = nullptr;
    D3D12_RANGE range{0, static_cast<SIZE_T>(readback.size)};
    check(readback.buffer->Map(0, &range, reinterpret_cast<void**>(const_cast<std::uint8_t**>(&mapped))),
          "Map output readback");
    double outputMean = 0.0;
    std::size_t pixels = 0;
    for (UINT y = 0; y < oh; ++y) {
        const auto* row = reinterpret_cast<const std::uint16_t*>(mapped + readback.footprint.Offset +
            static_cast<SIZE_T>(y) * readback.footprint.Footprint.RowPitch);
        for (UINT x = 0; x < ow; ++x) {
            const float r = unhalf(row[x * 4]);
            require(std::isfinite(r) && r >= 0.0f && r < 7.0f, "invalid/unwritten output pixel");
            outputMean += r; ++pixels;
        }
    }
    readback.buffer->Unmap(0, nullptr);
    outputMean /= static_cast<double>(pixels);
    require(outputMean > 0.05 && outputMean < 2.0, "nonsensical output mean");

    std::printf("BENCH mode=%s provider_id=0x%016llx provider=%s module=%ls dims=%ux%u->%ux%u mask=R8 create_flags=%u dispatch_flags=0 sharpen=%s sharpness=0.5 warm=%d samples=%d api_ms_p50/p90=%.3f/%.3f close_ms_p50/p90=%.3f/%.3f execute_and_fence_wall_ms_p50/p90=%.3f/%.3f fence_arm_cpu_ms_p50/p90=%.3f/%.3f host_event_wait_ms_p50/p90=%.3f/%.3f submit_to_fence_wall_ms_p50/p90=%.3f/%.3f dispatch_to_fence_wall_ms_p50/p90=%.3f/%.3f output_mean=%.6f result=PASS\n",
        requested.c_str(), static_cast<unsigned long long>(provider), providerName, loadedPath, rw, rh, ow, oh,
        createFlags, sharpen ? "on" : "off",
        warmup, measured, quantile(apiTimes, 0.50), quantile(apiTimes, 0.90),
        quantile(closeTimes, 0.50), quantile(closeTimes, 0.90),
        quantile(executeFenceTimes, 0.50), quantile(executeFenceTimes, 0.90),
        quantile(fenceArmTimes, 0.50), quantile(fenceArmTimes, 0.90),
        quantile(eventWaitTimes, 0.50), quantile(eventWaitTimes, 0.90),
        quantile(submitTimes, 0.50), quantile(submitTimes, 0.90),
        quantile(completionTimes, 0.50), quantile(completionTimes, 0.90), outputMean);
    std::printf("QUERY_SUMMARY gpu_ms_p50/p90=%.4f/%.4f\n",
                quantile(gpuQueryTimes, 0.50), quantile(gpuQueryTimes, 0.90));
    FreeLibrary(module);
    return 0;
}
