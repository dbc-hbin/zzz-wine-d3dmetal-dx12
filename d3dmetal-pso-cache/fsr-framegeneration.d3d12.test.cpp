#include "d3d12-test-helpers.hpp"

#include "third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api.h"
#include "third-party/fidelityfx/Kits/FidelityFX/api/include/dx12/ffx_api_dx12.h"
#include "third-party/fidelityfx/Kits/FidelityFX/framegeneration/include/dx12/ffx_api_framegeneration_dx12.h"
#include "third-party/fidelityfx/Kits/FidelityFX/framegeneration/include/ffx_framegeneration.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace {

constexpr UINT kWidth = 640;
constexpr UINT kHeight = 384;
constexpr UINT kMargin = 48;
constexpr std::uint64_t kOriginalProvider = 0xf600000000c01006ull;
constexpr float kSentinel = 7.0f;
constexpr double kPi = 3.14159265358979323846;
constexpr std::uint32_t kDispatchFlags =
    FFX_FRAMEGENERATION_FLAG_NO_SWAPCHAIN_CONTEXT_NOTIFY;

static_assert(FFX_FRAMEGENERATION_VERSION ==
                  FFX_FRAMEGENERATION_MAKE_VERSION(4, 0, 0),
              "This regression exercises the framegeneration 4.0.0 contract.");

struct FrameGenerationApi {
    PfnFfxCreateContext create;
    PfnFfxDestroyContext destroy;
    PfnFfxConfigure configure;
    PfnFfxQuery query;
    PfnFfxDispatch dispatch;
};

void requireFfx(ffxReturnCode_t actual, ffxReturnCode_t expected,
                const char* path, const char* operation) {
    if (actual != expected) {
        std::fprintf(stderr,
                     "FSR_FRAMEGENERATION_D3D12_FAIL path=%s operation=%s "
                     "got=%u expected=%u\n",
                     path, operation, static_cast<unsigned>(actual),
                     static_cast<unsigned>(expected));
        std::exit(1);
    }
}

void require(bool condition, const char* path, const char* reason) {
    if (!condition) {
        std::fprintf(stderr, "FSR_FRAMEGENERATION_D3D12_FAIL path=%s %s\n",
                     path, reason);
        std::exit(1);
    }
}

struct Motion {
    float x;
    float y;
};

Motion patternMotion(unsigned pattern) {
    return pattern == 0 ? Motion{16.0f, 8.0f} : Motion{-12.0f, 16.0f};
}

// A translating, textured plane. The two sequences have different texture
// phases and different motion directions. Values stay within SDR [0, 1].
// Evaluating at a half-integer time gives an independent spatial midpoint
// reference; it is not constructed by averaging the two endpoint images.
float patternValue(unsigned pattern, float time, UINT x, UINT y,
                   unsigned channel) {
    const Motion velocity = patternMotion(pattern);
    const double u = static_cast<double>(x) -
                     static_cast<double>(time) * velocity.x +
                     static_cast<double>(pattern) * 19.0;
    const double v = static_cast<double>(y) -
                     static_cast<double>(time) * velocity.y +
                     static_cast<double>(pattern) * 31.0;
    double value = 0.0;
    switch (channel) {
    case 0:
        value = 0.5 + 0.30 * std::sin(2.0 * kPi * u / 64.0) +
                      0.12 * std::cos(2.0 * kPi * v / 96.0);
        break;
    case 1:
        value = 0.5 + 0.28 * std::cos(2.0 * kPi * (u + v) / 96.0) +
                      0.12 * std::sin(2.0 * kPi * (u - v) / 64.0);
        break;
    default:
        value = 0.5 + 0.30 * std::sin(2.0 * kPi * v / 64.0) +
                      0.12 * std::cos(2.0 * kPi * u / 96.0);
        break;
    }
    return static_cast<float>(value);
}

std::vector<std::uint16_t> makePattern(unsigned pattern, float time) {
    std::vector<std::uint16_t> pixels(
        static_cast<std::size_t>(kWidth) * kHeight * 4);
    for (UINT y = 0; y < kHeight; ++y) {
        for (UINT x = 0; x < kWidth; ++x) {
            const std::size_t offset =
                (static_cast<std::size_t>(y) * kWidth + x) * 4;
            for (unsigned channel = 0; channel < 3; ++channel)
                pixels[offset + channel] =
                    half(patternValue(pattern, time, x, y, channel));
            pixels[offset + 3] = half(1.0f);
        }
    }
    return pixels;
}

struct Measurements {
    double previousError = 0.0;
    double currentError = 0.0;
    double midpointError = 0.0;
    double endpointSeparation = 0.0;
    std::size_t changedFromPrevious = 0;
    std::size_t changedFromCurrent = 0;
    std::size_t samples = 0;
};

Measurements inspectOutput(const ReadbackTexture& readback,
                           unsigned pattern, unsigned step,
                           const std::vector<std::uint16_t>& previous,
                           const std::vector<std::uint16_t>& current,
                           const char* path) {
    void* mapping = nullptr;
    D3D12_RANGE readRange{0, static_cast<SIZE_T>(readback.size)};
    check(readback.buffer->Map(0, &readRange, &mapping),
          "Map framegeneration output");
    const auto* bytes = static_cast<const std::uint8_t*>(mapping);
    Measurements result;

    for (UINT y = 0; y < kHeight; ++y) {
        const auto* row = reinterpret_cast<const std::uint16_t*>(
            bytes + readback.footprint.Offset +
            static_cast<SIZE_T>(y) * readback.footprint.Footprint.RowPitch);
        for (UINT x = 0; x < kWidth; ++x) {
            const std::size_t offset =
                (static_cast<std::size_t>(y) * kWidth + x) * 4;
            const bool interior =
                x >= kMargin && x < kWidth - kMargin &&
                y >= kMargin && y < kHeight - kMargin;

            for (unsigned channel = 0; channel < 4; ++channel) {
                const float value = unhalf(row[x * 4 + channel]);
                require(std::isfinite(value), path, "non-finite output");
                require(std::fabs(value - kSentinel) > 0.01f, path,
                        "output contains untouched sentinel");

                if (channel == 3)
                    continue;

                require(value > -0.25f && value < 1.25f, path,
                        "SDR output is outside the permitted reconstruction range");

                // Reset output is read back and checked for writes, but it is
                // not required to interpolate without a previous frame.
                if (!interior || step < 3)
                    continue;

                const double a = unhalf(previous[offset + channel]);
                const double b = unhalf(current[offset + channel]);
                const double midpoint = unhalf(half(patternValue(
                    pattern, static_cast<float>(step) - 0.5f,
                    x, y, channel)));
                const double errorA = std::fabs(static_cast<double>(value) - a);
                const double errorB = std::fabs(static_cast<double>(value) - b);
                result.previousError += errorA;
                result.currentError += errorB;
                result.midpointError +=
                    std::fabs(static_cast<double>(value) - midpoint);
                result.endpointSeparation += std::fabs(a - b);
                if (errorA > 0.02)
                    ++result.changedFromPrevious;
                if (errorB > 0.02)
                    ++result.changedFromCurrent;
                ++result.samples;
            }
        }
    }

    D3D12_RANGE writtenRange{0, 0};
    readback.buffer->Unmap(0, &writtenRange);

    if (step >= 3) {
        require(result.samples != 0, path, "empty measurement region");
        const double count = static_cast<double>(result.samples);
        result.previousError /= count;
        result.currentError /= count;
        result.midpointError /= count;
        result.endpointSeparation /= count;

        require(result.endpointSeparation > 0.08, path,
                "test endpoints do not contain sufficient motion");
        require(result.previousError > 0.015 &&
                    result.currentError > 0.015,
                path, "generated output is an endpoint copy");
        require(result.previousError > 0.12 * result.endpointSeparation &&
                    result.currentError > 0.12 * result.endpointSeparation,
                path, "generated output is too close to an endpoint");
        require(result.changedFromPrevious > result.samples / 5 &&
                    result.changedFromCurrent > result.samples / 5,
                path, "too few output samples differ from both endpoints");

        // Noise, a constant fill, stale history, or an arbitrary non-endpoint
        // image must not pass merely because it overwrote the sentinel.
        require(result.midpointError < 0.065, path,
                "generated image does not reconstruct the moving pattern");
        require(result.midpointError <
                    0.8 * std::min(result.previousError, result.currentError),
                path, "generated image is not closer to the spatial midpoint");

        std::printf(
            "FSR_FRAMEGENERATION_MEASURE path=%s pattern=%u step=%u "
            "previousMAE=%.6f currentMAE=%.6f midpointMAE=%.6f "
            "endpointSeparation=%.6f\n",
            path, pattern, step, result.previousError, result.currentError,
            result.midpointError, result.endpointSeparation);
    }

    return result;
}

void runProvider(Gpu& gpu, const FrameGenerationApi& api, bool native, bool hudless = false) {
    const char* const path = hudless ? "native-unsupported-hudless" : native ? "native-override" : "builtin";

    ffxCreateBackendDX12Desc backend{};
    backend.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12;
    backend.device = gpu.device.Get();

    ffxCreateContextDescFrameGenerationVersion version{};
    version.header.type =
        FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION_VERSION;
    version.header.pNext = &backend.header;
    version.version = FFX_FRAMEGENERATION_VERSION;

    ffxOverrideVersion original{};
    original.header.type = FFX_API_DESC_TYPE_OVERRIDE_VERSION;
    original.header.pNext = &version.header;
    original.versionId = kOriginalProvider;

    ffxCreateContextDescFrameGeneration create{};
    create.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION;
    create.header.pNext = native ? &original.header : &version.header;
    create.displaySize = {kWidth, kHeight};
    create.maxRenderSize = {kWidth, kHeight};
    create.backBufferFormat =
        ffxApiGetSurfaceFormatDX12(DXGI_FORMAT_R16G16B16A16_FLOAT);

    ffxContext context = nullptr;
    requireFfx(api.create(&context, &create.header, nullptr),
               FFX_API_RETURN_OK, path, "create");
    require(context != nullptr, path, "create returned a null context");

    ffxQueryGetProviderVersion provider{};
    provider.header.type = FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION;
    requireFfx(api.query(&context, &provider.header), FFX_API_RETURN_OK,
               path, "query selected provider");
    require(provider.versionId != 0 && provider.versionName != nullptr &&
                provider.versionName[0] != '\0',
            path, "invalid selected-provider identity");
    if (native) {
        require(provider.versionId == kOriginalProvider, path,
                "original-provider override did not select the native provider");
    } else {
        require(provider.versionId != kOriginalProvider, path,
                "default context silently selected the native provider");
        require(std::strstr(provider.versionName, "MetalFX") != nullptr, path,
                "default context did not select the MetalFX translator");
    }
    std::printf("FSR_FRAMEGENERATION_PROVIDER path=%s id=0x%016llx name=%s\n",
                path, static_cast<unsigned long long>(provider.versionId),
                provider.versionName);

    if (!native) {
        ffxApiHeader unknown{
            FFX_API_MAKE_EFFECT_SUB_ID(FFX_API_EFFECT_ID_FRAMEGENERATION, 0xff),
            nullptr};
        requireFfx(api.query(&context, &unknown),
                   FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE, path, "unknown query");
        require(api.configure(&context, &unknown) != FFX_API_RETURN_OK, path,
                "unknown configure was accepted");
        requireFfx(api.dispatch(&context, &unknown),
                   FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE, path,
                   "unknown dispatch");
    }

    using Texture = decltype(makeTexture(
        gpu, kWidth, kHeight, DXGI_FORMAT_R32_FLOAT,
        D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST));

    // Keep all caller resources alive through context destruction, including
    // endpoints used as history. Every output starts with a fresh sentinel.
    std::vector<Texture> resources;
    resources.reserve(24);
    const std::size_t pixelCount =
        static_cast<std::size_t>(kWidth) * kHeight;
    const std::vector<float> depthPixels(pixelCount, 0.5f);
    const std::vector<std::uint16_t> sentinel(pixelCount * 4, half(kSentinel));
    std::uint64_t frameID = 0;
    unsigned verifiedIntermediates = 0;

    for (unsigned pattern = 0; pattern < 2; ++pattern) {
        std::vector<std::uint16_t> previous;
        // The measured MetalFX reset sequence needs two further warm-up frames.
        // Verify writes throughout warm-up and actual interpolation thereafter.
        for (unsigned step = 0; step < 5; ++step, ++frameID) {
            const bool reset = step == 0;
            const auto current = makePattern(pattern, static_cast<float>(step));
            const Motion velocity = patternMotion(pattern);

            // FFX motion vectors map the current sample to the previous frame.
            // Pixel-valued vectors are converted to UV by the prepare scale.
            std::vector<std::uint16_t> motionPixels(pixelCount * 2);
            for (std::size_t i = 0; i < pixelCount; ++i) {
                motionPixels[i * 2] = half(reset ? 0.0f : -velocity.x);
                motionPixels[i * 2 + 1] = half(reset ? 0.0f : -velocity.y);
            }

            auto color = makeTexture(
                gpu, kWidth, kHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
            auto depth = makeTexture(
                gpu, kWidth, kHeight, DXGI_FORMAT_R32_FLOAT,
                D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
            auto motion = makeTexture(
                gpu, kWidth, kHeight, DXGI_FORMAT_R16G16_FLOAT,
                D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
            auto output = makeTexture(
                gpu, kWidth, kHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
                D3D12_RESOURCE_STATE_COPY_DEST);

            resources.push_back(color);
            resources.push_back(depth);
            resources.push_back(motion);
            resources.push_back(output);

            uploadTexture(gpu, color.Get(), current.data(), kWidth * 8);
            uploadTexture(gpu, depth.Get(), depthPixels.data(), kWidth * 4);
            uploadTexture(gpu, motion.Get(), motionPixels.data(), kWidth * 4);
            uploadTexture(gpu, output.Get(), sentinel.data(), kWidth * 8);

            ffxConfigureDescFrameGeneration configure{};
            configure.header.type =
                FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATION;
            configure.swapChain = nullptr;
            configure.frameGenerationEnabled = true;
            configure.allowAsyncWorkloads = false;
            configure.flags = kDispatchFlags;
            configure.generationRect = {0, 0, kWidth, kHeight};
            configure.frameID = frameID;
            if (hudless)
                configure.HUDLessColor = ffxApiGetResourceDX12(
                    color.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
            requireFfx(api.configure(&context, &configure.header),
                       FFX_API_RETURN_OK, path, "configure direct interpolation");

            auto readback = makeReadback(gpu, output.Get());
            gpu.begin();
            transition(gpu.list.Get(), output.Get(),
                       D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                       D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

            ffxDispatchDescFrameGenerationPrepareV2 prepare{};
            prepare.header.type =
                FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_V2;
            prepare.frameID = frameID;
            prepare.flags = kDispatchFlags;
            prepare.commandList = gpu.list.Get();
            prepare.renderSize = {kWidth, kHeight};
            prepare.motionVectorScale = {1.0f, 1.0f};
            prepare.frameTimeDelta = 16.6667f;
            prepare.reset = reset;
            prepare.cameraNear = 0.1f;
            prepare.cameraFar = 1000.0f;
            prepare.cameraFovAngleVertical = 1.04719755f;
            prepare.viewSpaceToMetersFactor = 1.0f;
            prepare.depth = ffxApiGetResourceDX12(
                depth.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
            prepare.motionVectors = ffxApiGetResourceDX12(
                motion.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
            prepare.cameraUp[1] = 1.0f;
            prepare.cameraRight[0] = 1.0f;
            prepare.cameraForward[2] = 1.0f;

            ffxDispatchDescFrameGeneration dispatch{};
            dispatch.header.type = FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION;
            dispatch.commandList = gpu.list.Get();
            dispatch.presentColor = ffxApiGetResourceDX12(
                color.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
            dispatch.outputs[0] = ffxApiGetResourceDX12(
                output.Get(), FFX_API_RESOURCE_STATE_UNORDERED_ACCESS);
            dispatch.numGeneratedFrames = 1;
            dispatch.reset = reset;
            dispatch.backbufferTransferFunction =
                FFX_API_BACKBUFFER_TRANSFER_FUNCTION_SRGB;
            dispatch.minMaxLuminance[0] = 0.0f;
            dispatch.minMaxLuminance[1] = 100.0f;
            dispatch.generationRect = {0, 0, kWidth, kHeight};
            dispatch.frameID = frameID;

            if (!native && !hudless && frameID == 0) {
                // These are real malformed PrepareV2/dispatch contracts, not
                // fabricated descriptor layouts or unsupported feature probes.
                auto badPrepare = prepare;
                badPrepare.commandList = nullptr;
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "PrepareV2 without command list");

                badPrepare = prepare;
                badPrepare.depth = {};
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "PrepareV2 without depth");

                badPrepare = prepare;
                badPrepare.motionVectors = {};
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "PrepareV2 without motion vectors");
            }

            requireFfx(api.dispatch(&context, &prepare.header),
                       FFX_API_RETURN_OK, path, "PrepareV2");
            requireFfx(api.query(&context, &provider.header), FFX_API_RETURN_OK, path,
                       "query actual prepared provider");
            require(provider.versionId == (native || hudless ? kOriginalProvider : 0x4d46584647000001ull),
                    path, "Prepare selected the wrong provider");

            if (!native && !hudless && frameID == 0) {
                auto badDispatch = dispatch;
                badDispatch.commandList = nullptr;
                requireFfx(api.dispatch(&context, &badDispatch.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "generation without command list");

                badDispatch = dispatch;
                badDispatch.presentColor = {};
                requireFfx(api.dispatch(&context, &badDispatch.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "generation without presentColor");

                badDispatch = dispatch;
                badDispatch.outputs[0] = {};
                requireFfx(api.dispatch(&context, &badDispatch.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "generation without output");
            }

            requireFfx(api.dispatch(&context, &dispatch.header),
                       FFX_API_RETURN_OK, path, "generate one intermediate");

            D3D12_RESOURCE_BARRIER uav{};
            uav.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV;
            uav.UAV.pResource = output.Get();
            gpu.list->ResourceBarrier(1, &uav);
            transition(gpu.list.Get(), output.Get(),
                       D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
                       D3D12_RESOURCE_STATE_COPY_SOURCE);
            copyToReadback(gpu.list.Get(), output.Get(), readback);

            // The supplied helper submits the command list and waits for its
            // exact fence value. No timing assumptions or sleep/poll loops.
            gpu.submit();
            check(gpu.device->GetDeviceRemovedReason(),
                  "framegeneration GPU completion");
            inspectOutput(readback, pattern, step, previous, current, path);
            if (step >= 3)
                ++verifiedIntermediates;
            previous = current;
        }
    }

    require(verifiedIntermediates == 4, path,
            "not all moving-pattern intermediates were verified");
    // All recorded work, including the final readback, has completed before
    // releasing either the provider context or its input/output resources.
    requireFfx(api.destroy(&context, nullptr), FFX_API_RETURN_OK, path, "destroy");
    require(context == nullptr, path, "destroy did not clear the context");
    std::printf("FSR_FRAMEGENERATION_PATH_PASS path=%s intermediates=%u\n",
                path, verifiedIntermediates);
}

} // namespace

namespace {

// Requires the pinned public framegeneration-swapchain DX12 header to have
// been included by the translation unit. No private adapter/vtable is used.

struct SwapchainSmokeCallbacks {
    const FrameGenerationApi* api = nullptr;
    ffxContext* context = nullptr;
    volatile LONG calls = 0;
    volatile LONG successes = 0;
    volatile LONG generated = 0;
    volatile LONG failures = 0;
};

ffxReturnCode_t swapchainSmokeGenerate(
    ffxDispatchDescFrameGeneration* params, void* user) {
    auto& state = *static_cast<SwapchainSmokeCallbacks*>(user);
    InterlockedIncrement(&state.calls);

    // Dispatch exactly the resources and command list supplied by the real
    // swapchain. In particular, do not substitute an application-owned output.
    const ffxReturnCode_t result =
        state.api->dispatch(state.context, &params->header);
    if (result == FFX_API_RETURN_OK) {
        InterlockedIncrement(&state.successes);
        InterlockedExchangeAdd(
            &state.generated, static_cast<LONG>(params->numGeneratedFrames));
    } else {
        InterlockedIncrement(&state.failures);
    }
    return result;
}

void swapchainSmokeFence(Gpu& gpu) {
    ComPtr<ID3D12Fence> fence;
    check(gpu.device->CreateFence(
              0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)),
          "swapchain CreateFence");

    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!event)
        fail("swapchain CreateEvent", GetLastError());

    check(gpu.queue->Signal(fence.Get(), 1), "swapchain Signal");
    check(fence->SetEventOnCompletion(1, event),
          "swapchain SetEventOnCompletion");
    const DWORD result = WaitForSingleObject(event, 30000);
    CloseHandle(event);
    require(result == WAIT_OBJECT_0, "swapchain", "GPU fence timeout");
    require(fence->GetCompletedValue() == 1, "swapchain",
            "GPU fence did not complete normally");
    check(gpu.device->GetDeviceRemovedReason(), "swapchain GPU completion");
}

void swapchainSmokeDrain(
    Gpu& gpu, const FrameGenerationApi& api, ffxContext& context) {
    // This operation is a DISPATCH in the pinned SDK, not a query. A fence on
    // the game queue alone does not drain the provider's presentation queues.
    swapchainSmokeFence(gpu);
    ffxDispatchDescFrameGenerationSwapChainWaitForPresentsDX12 wait{};
    wait.header.type =
        FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_WAIT_FOR_PRESENTS_DX12;
    requireFfx(api.dispatch(&context, &wait.header), FFX_API_RETURN_OK,
               "swapchain", "wait for presents");
    swapchainSmokeFence(gpu);
}

void swapchainSmokePump(HWND window) {
    MSG message{};
    while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
        require(message.message != WM_QUIT, "swapchain",
                "unexpected WM_QUIT");
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    require(IsWindow(window) != FALSE, "swapchain",
            "presentation window was destroyed");
}

void runSwapchain(Gpu& gpu, const FrameGenerationApi& api) {
    const char* const path = "swapchain";
    constexpr UINT disabledFrames = 70;
    constexpr UINT frameCount = disabledFrames + 8;
    constexpr DXGI_FORMAT format = DXGI_FORMAT_R16G16B16A16_FLOAT;

    // STATIC is a real, predefined Win32 window class; no callback or class
    // registration with a lifetime extending beyond this function is needed.
    RECT rectangle{0, 0, static_cast<LONG>(kWidth),
                   static_cast<LONG>(kHeight)};
    constexpr DWORD style = WS_OVERLAPPEDWINDOW;
    check(AdjustWindowRect(&rectangle, style, FALSE)
              ? S_OK : HRESULT_FROM_WIN32(GetLastError()),
          "swapchain AdjustWindowRect");
    HWND window = CreateWindowExW(
        0, L"STATIC", L"FidelityFX native swapchain smoke", style,
        CW_USEDEFAULT, CW_USEDEFAULT,
        rectangle.right - rectangle.left,
        rectangle.bottom - rectangle.top,
        nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    require(window != nullptr, path, "CreateWindowExW failed");
    ShowWindow(window, SW_SHOWNORMAL);
    UpdateWindow(window);
    swapchainSmokePump(window);

    // Resolve DXGI dynamically so this addition needs no new import library.
    HMODULE dxgi = LoadLibraryW(L"dxgi.dll");
    require(dxgi != nullptr, path, "LoadLibraryW(dxgi.dll) failed");
    using CreateFactory = HRESULT(WINAPI*)(REFIID, void**);
    const auto createFactory =
        load<CreateFactory>(dxgi, "CreateDXGIFactory1");

    ComPtr<IDXGIFactory2> factory;
    check(createFactory(IID_PPV_ARGS(&factory)),
          "swapchain CreateDXGIFactory1");
    check(factory->MakeWindowAssociation(window, DXGI_MWA_NO_ALT_ENTER),
          "swapchain MakeWindowAssociation");

    DXGI_SWAP_CHAIN_DESC1 description{};
    description.Width = kWidth;
    description.Height = kHeight;
    description.Format = format;
    description.SampleDesc.Count = 1;
    description.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    description.BufferCount = 3;
    description.Scaling = DXGI_SCALING_STRETCH;
    description.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    description.AlphaMode = DXGI_ALPHA_MODE_IGNORE;

    ComPtr<IDXGISwapChain1> existing1;
    check(factory->CreateSwapChainForHwnd(
              gpu.queue.Get(), window, &description, nullptr, nullptr,
              &existing1),
          "swapchain CreateSwapChainForHwnd");

    ComPtr<IDXGISwapChain4> existing;
    check(existing1.As(&existing), "swapchain QueryInterface IDXGISwapChain4");
    existing1.Reset();

    // WRAP consumes the caller reference and returns the replacement reference.
    IDXGISwapChain4* wrapped = existing.Detach();
    IDXGISwapChain4* const originalSwapchain = wrapped;
    ffxCreateContextDescFrameGenerationSwapChainVersionDX12 swapVersion{};
    swapVersion.header.type =
        FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_VERSION_DX12;
    swapVersion.version = FFX_FRAMEGENERATION_SWAPCHAIN_DX12_VERSION;

    ffxCreateContextDescFrameGenerationSwapChainWrapDX12 wrap{};
    wrap.header.type =
        FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_WRAP_DX12;
    wrap.header.pNext = &swapVersion.header;
    wrap.swapchain = &wrapped;
    wrap.gameQueue = gpu.queue.Get();

    ffxContext swapContext = nullptr;
    requireFfx(api.create(&swapContext, &wrap.header, nullptr),
               FFX_API_RETURN_OK, path, "wrap existing DXGI swapchain");
    require(swapContext != nullptr && wrapped != nullptr, path,
            "wrap returned a null context or swapchain");
    require(wrapped != originalSwapchain, path,
            "wrap did not replace the DXGI swapchain");

    ComPtr<IDXGISwapChain4> swapchain;
    swapchain.Attach(wrapped);

    ffxCreateBackendDX12Desc backend{};
    backend.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12;
    backend.device = gpu.device.Get();

    ffxCreateContextDescFrameGenerationVersion version{};
    version.header.type =
        FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION_VERSION;
    version.header.pNext = &backend.header;
    version.version = FFX_FRAMEGENERATION_VERSION;

    ffxCreateContextDescFrameGeneration create{};
    create.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION;
    create.header.pNext = &version.header; // Automatic provider selection.
    create.displaySize = {kWidth, kHeight};
    create.maxRenderSize = {kWidth, kHeight};
    create.backBufferFormat = ffxApiGetSurfaceFormatDX12(format);

    ffxContext context = nullptr;
    requireFfx(api.create(&context, &create.header, nullptr),
               FFX_API_RETURN_OK, path, "create automatic FG");
    require(context != nullptr, path, "null FG context");

    SwapchainSmokeCallbacks callbacks{};
    callbacks.api = &api;
    callbacks.context = &context;

    ffxConfigureDescFrameGeneration configure{};
    configure.header.type = FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATION;
    configure.swapChain = swapchain.Get();
    configure.frameGenerationEnabled = true;
    configure.allowAsyncWorkloads = false;
    configure.flags = 0; // Swapchain notification must remain enabled.
    configure.generationRect = {0, 0, kWidth, kHeight};
    configure.frameGenerationCallback = swapchainSmokeGenerate;
    configure.frameGenerationCallbackUserContext = &callbacks;
    // Use the provider's normal presentation/UI-composition path.
    configure.presentCallback = nullptr;
    configure.presentCallbackUserContext = nullptr;

    std::vector<ComPtr<ID3D12Resource>> resources;
    resources.reserve(frameCount * 3);
    const std::size_t pixelCount =
        static_cast<std::size_t>(kWidth) * kHeight;
    const std::vector<float> depthPixels(pixelCount, 0.5f);

    for (UINT frame = 0; frame < frameCount; ++frame) {
        swapchainSmokePump(window);

        const auto pixels = makePattern(0, static_cast<float>(frame));
        const Motion velocity = patternMotion(0);
        std::vector<std::uint16_t> vectors(pixelCount * 2);
        for (std::size_t i = 0; i < pixelCount; ++i) {
            vectors[2 * i] = half(frame ? -velocity.x : 0.0f);
            vectors[2 * i + 1] = half(frame ? -velocity.y : 0.0f);
        }

        auto color = makeTexture(
            gpu, kWidth, kHeight, format, D3D12_RESOURCE_FLAG_NONE,
            D3D12_RESOURCE_STATE_COPY_DEST);
        auto depth = makeTexture(
            gpu, kWidth, kHeight, DXGI_FORMAT_R32_FLOAT,
            D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
        auto motion = makeTexture(
            gpu, kWidth, kHeight, DXGI_FORMAT_R16G16_FLOAT,
            D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);

        resources.push_back(color);
        resources.push_back(depth);
        resources.push_back(motion);

        // uploadTexture already transitions COPY_DEST -> COMPUTE_READ and
        // waits for completion. Do not repeat that transition afterward.
        uploadTexture(gpu, color.Get(), pixels.data(), kWidth * 8);
        uploadTexture(gpu, depth.Get(), depthPixels.data(), kWidth * 4);
        uploadTexture(gpu, motion.Get(), vectors.data(), kWidth * 4);

        configure.frameID = frame;
        configure.frameGenerationEnabled = frame >= disabledFrames;
        requireFfx(api.configure(&context, &configure.header),
                   FFX_API_RETURN_OK, path, "configure FG callbacks");

        ComPtr<ID3D12Resource> backbuffer;
        check(swapchain->GetBuffer(
                  swapchain->GetCurrentBackBufferIndex(),
                  IID_PPV_ARGS(&backbuffer)),
              "swapchain GetBuffer");

        gpu.begin();
        transition(gpu.list.Get(), color.Get(),
                   D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE,
                   D3D12_RESOURCE_STATE_COPY_SOURCE);
        transition(gpu.list.Get(), backbuffer.Get(),
                   D3D12_RESOURCE_STATE_PRESENT,
                   D3D12_RESOURCE_STATE_COPY_DEST);
        gpu.list->CopyResource(backbuffer.Get(), color.Get());
        transition(gpu.list.Get(), backbuffer.Get(),
                   D3D12_RESOURCE_STATE_COPY_DEST,
                   D3D12_RESOURCE_STATE_PRESENT);
        transition(gpu.list.Get(), color.Get(),
                   D3D12_RESOURCE_STATE_COPY_SOURCE,
                   D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);

        ffxDispatchDescFrameGenerationPrepareV2 prepare{};
        prepare.header.type =
            FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_V2;
        prepare.frameID = frame;
        prepare.flags = 0;
        prepare.commandList = gpu.list.Get();
        prepare.renderSize = {kWidth, kHeight};
        prepare.motionVectorScale = {1.0f, 1.0f};
        prepare.frameTimeDelta = 16.6667f;
        prepare.reset = frame == 0;
        prepare.cameraNear = 0.1f;
        prepare.cameraFar = 1000.0f;
        prepare.cameraFovAngleVertical = 1.04719755f;
        prepare.viewSpaceToMetersFactor = 1.0f;
        prepare.depth = ffxApiGetResourceDX12(
            depth.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
        prepare.motionVectors = ffxApiGetResourceDX12(
            motion.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
        prepare.cameraUp[1] = 1.0f;
        prepare.cameraRight[0] = 1.0f;
        prepare.cameraForward[2] = 1.0f;

        requireFfx(api.dispatch(&context, &prepare.header),
                   FFX_API_RETURN_OK, path, "PrepareV2");

        ffxQueryGetProviderVersion provider{};
        provider.header.type = FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION;
        requireFfx(api.query(&context, &provider.header),
                   FFX_API_RETURN_OK, path, "query prepared provider");
        require(provider.versionId == 0x4d46584647000001ull &&
                    provider.versionName != nullptr &&
                    std::strstr(provider.versionName, "MetalFX") != nullptr,
                path, "Prepare did not select MetalFX");

        gpu.submit();
        check(swapchain->Present(1, 0), "swapchain Present");
        swapchainSmokeDrain(gpu, api, swapContext);
        backbuffer.Reset();

        require(InterlockedCompareExchange(&callbacks.failures, 0, 0) == 0,
                path, "interpolation callback dispatch failed");
    }

    // Drain before changing callback registration or destroying its context.
    swapchainSmokeDrain(gpu, api, swapContext);
    configure.frameGenerationEnabled = false;
    requireFfx(api.configure(&context, &configure.header),
               FFX_API_RETURN_OK, path, "disable FG");
    swapchainSmokeDrain(gpu, api, swapContext);

    const LONG calls = InterlockedCompareExchange(&callbacks.calls, 0, 0);
    const LONG successes =
        InterlockedCompareExchange(&callbacks.successes, 0, 0);
    const LONG generated =
        InterlockedCompareExchange(&callbacks.generated, 0, 0);
    require(calls >= 3 && successes == calls && generated >= 3, path,
            "insufficient successful real interpolation callbacks");

    requireFfx(api.destroy(&context, nullptr), FFX_API_RETURN_OK,
               path, "destroy FG");
    require(context == nullptr, path, "FG context was not cleared");

    requireFfx(api.destroy(&swapContext, nullptr), FFX_API_RETURN_OK,
               path, "destroy swapchain context");
    require(swapContext == nullptr, path, "swapchain context was not cleared");

    swapchain.Reset();
    existing.Reset();
    resources.clear();
    factory.Reset();

    require(DestroyWindow(window) != FALSE, path, "DestroyWindow failed");
    FreeLibrary(dxgi);

    std::printf(
        "FSR_FRAMEGENERATION_PATH_PASS path=%s presents=%u "
        "interpolationCallbacks=%ld successfulDispatches=%ld "
        "dispatchedGeneratedFrames=%ld\n",
        path, frameCount, calls, successes, generated);
}

} // namespace

int main() {
    HMODULE module = LoadLibraryW(L"amd_fidelityfx_framegeneration_dx12.dll");
    if (!module)
        fail("LoadLibrary amd_fidelityfx_framegeneration_dx12", GetLastError());

    const FrameGenerationApi api{
        load<PfnFfxCreateContext>(module, "ffxCreateContext"),
        load<PfnFfxDestroyContext>(module, "ffxDestroyContext"),
        load<PfnFfxConfigure>(module, "ffxConfigure"),
        load<PfnFfxQuery>(module, "ffxQuery"),
        load<PfnFfxDispatch>(module, "ffxDispatch")};

    {
        Gpu gpu;
        runProvider(gpu, api, false);

        // Exercise native routing through the same builtin's public override
        // chain. Do not load a second DLL or alter production environment state.
        runProvider(gpu, api, true);
        runProvider(gpu, api, false, true);
        runSwapchain(gpu, api);
    }

    FreeLibrary(module);
    std::printf("FSR_FRAMEGENERATION_D3D12_PASS "
                "builtinIntermediates=4 nativeIntermediates=4 fallbackIntermediates=4\n");
    return 0;
}