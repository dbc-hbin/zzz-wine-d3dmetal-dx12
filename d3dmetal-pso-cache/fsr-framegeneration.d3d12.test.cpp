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
#include <limits>
#include <vector>

namespace {

constexpr UINT kWidth = 640;
constexpr UINT kHeight = 384;
constexpr UINT kMargin = 48;
constexpr FfxApiRect2D kPartialRect{64, 40, 512, 288};
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

volatile LONG gDebugErrors = 0;

void debugMessage(uint32_t type, const wchar_t* message) {
    if (type == FFX_API_MESSAGE_TYPE_ERROR && message && message[0] != L'\0')
        InterlockedIncrement(&gDebugErrors);
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

bool inUiPatch(UINT x, UINT y) {
    return (x >= 176 && x < 288 && y >= 112 && y < 184) ||
           (x >= 352 && x < 464 && y >= 208 && y < 280);
}

std::vector<std::uint16_t> makeComposedPattern(unsigned pattern, float time) {
    auto pixels = makePattern(pattern, time);
    for (UINT y = 0; y < kHeight; ++y) {
        for (UINT x = 0; x < kWidth; ++x) {
            if (!inUiPatch(x, y))
                continue;
            const std::size_t offset =
                (static_cast<std::size_t>(y) * kWidth + x) * 4;
            const bool opaque = x < 288;
            const float alpha = opaque ? 1.0f : 0.375f;
            const float ui[3] = {0.92f, 0.14f, 0.73f};
            for (unsigned channel = 0; channel < 3; ++channel) {
                const float scene = unhalf(pixels[offset + channel]);
                pixels[offset + channel] = half(
                    ui[channel] * alpha + scene * (1.0f - alpha));
            }
            // Keep a deliberately non-opaque source alpha. MetalFX does not
            // document output-alpha semantics for a precomposited UI texture.
            pixels[offset + 3] = half(alpha);
        }
    }
    return pixels;
}

std::vector<float> makeFloatPattern(unsigned pattern, float time) {
    std::vector<float> pixels(
        static_cast<std::size_t>(kWidth) * kHeight * 4);
    for (UINT y = 0; y < kHeight; ++y) {
        for (UINT x = 0; x < kWidth; ++x) {
            const std::size_t offset =
                (static_cast<std::size_t>(y) * kWidth + x) * 4;
            for (unsigned channel = 0; channel < 3; ++channel)
                pixels[offset + channel] = patternValue(
                    pattern, time, x, y, channel);
            pixels[offset + 3] = 1.0f;
        }
    }
    return pixels;
}

std::vector<std::uint16_t> makeUiLayer() {
    std::vector<std::uint16_t> pixels(
        static_cast<std::size_t>(kWidth) * kHeight * 4, half(0.0f));
    for (UINT y = 0; y < kHeight; ++y) {
        for (UINT x = 0; x < kWidth; ++x) {
            if (!inUiPatch(x, y))
                continue;
            const std::size_t offset =
                (static_cast<std::size_t>(y) * kWidth + x) * 4;
            const float alpha = x < 288 ? 1.0f : 0.375f;
            pixels[offset] = half(0.92f * alpha);
            pixels[offset + 1] = half(0.14f * alpha);
            pixels[offset + 2] = half(0.73f * alpha);
            pixels[offset + 3] = half(alpha);
        }
    }
    return pixels;
}

enum class TransferCase { SDR, PQ, ScRgb };

float encodeFixtureValue(float linear, TransferCase transfer) {
    if (transfer == TransferCase::ScRgb)
        return (0.5f + linear * 399.5f) / 80.0f;
    if (transfer != TransferCase::PQ)
        return linear;
    const double luminance = 0.5 + static_cast<double>(linear) * 399.5;
    constexpr double m1 = 2610.0 / 16384.0;
    constexpr double m2 = 2523.0 / 32.0;
    constexpr double c1 = 3424.0 / 4096.0;
    constexpr double c2 = 2413.0 / 128.0;
    constexpr double c3 = 2392.0 / 128.0;
    const double powered = std::pow(luminance / 10000.0, m1);
    return static_cast<float>(std::pow((c1 + c2 * powered) /
                                       (1.0 + c3 * powered), m2));
}

float decodeFixtureValue(float encoded, TransferCase transfer) {
    if (transfer == TransferCase::ScRgb)
        return (encoded * 80.0f - 0.5f) / 399.5f;
    if (transfer != TransferCase::PQ)
        return encoded;
    constexpr double m1 = 2610.0 / 16384.0;
    constexpr double m2 = 2523.0 / 32.0;
    constexpr double c1 = 3424.0 / 4096.0;
    constexpr double c2 = 2413.0 / 128.0;
    constexpr double c3 = 2392.0 / 128.0;
    const double powered = std::pow(std::max(0.0f, encoded), 1.0 / m2);
    const double ratio = std::max(powered - c1, 0.0) /
                         (c2 - c3 * powered);
    const double luminance = 10000.0 * std::pow(ratio, 1.0 / m1);
    return static_cast<float>((luminance - 0.5) / 399.5);
}

std::vector<std::uint16_t> makeTransferPattern(
    unsigned pattern, float time, TransferCase transfer) {
    auto pixels = makePattern(pattern, time);
    for (std::size_t offset = 0; offset < pixels.size(); offset += 4) {
        for (unsigned channel = 0; channel < 3; ++channel)
            pixels[offset + channel] = half(encodeFixtureValue(
                unhalf(pixels[offset + channel]), transfer));
        pixels[offset + 3] = half(0.625f);
    }
    return pixels;
}

struct ProviderOptions {
    bool native = false;
    bool hudless = false;
    bool displayJitter = false;
    bool finiteDepthReversed = false;
    bool distortionFallback = false;
    bool cameraAbsent = false;
    bool preselectionRejections = false;
    bool longDirectSequence = false;
    TransferCase transfer = TransferCase::SDR;
};

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
                           const char* path, bool hudlessRect,
                           TransferCase transfer, bool implicitGap) {
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
            const bool inRect =
                x >= kPartialRect.left &&
                x < kPartialRect.left + kPartialRect.width &&
                y >= kPartialRect.top &&
                y < kPartialRect.top + kPartialRect.height;
            const bool ui = hudlessRect && inUiPatch(x, y);
            const bool interior =
                x >= kMargin && x < kWidth - kMargin &&
                y >= kMargin && y < kHeight - kMargin &&
                (!hudlessRect || (inRect && !ui));

            for (unsigned channel = 0; channel < 4; ++channel) {
                const float value = unhalf(row[x * 4 + channel]);
                require(std::isfinite(value), path, "non-finite output");
                require(std::fabs(value - kSentinel) > 0.01f, path,
                        "output contains untouched sentinel");

                if (hudlessRect && !inRect) {
                    const float expected = unhalf(current[offset + channel]);
                    require(std::fabs(value - expected) < 0.012f, path,
                            "pixels outside generationRect were modified");
                    continue;
                }
                if (ui) {
                    // MetalFX documents RGB de/recomposition for a
                    // precomposited UI texture, but no output-alpha contract.
                    if (channel == 3)
                        continue;
                    const float alpha = x < 288 ? 1.0f : 0.375f;
                    const float uiValue = channel == 0 ? 0.92f :
                                          channel == 1 ? 0.14f : 0.73f;
                    const float generatedScene = patternValue(
                        pattern, static_cast<float>(step) - 0.5f,
                        x, y, channel);
                    const float midpointComposed = uiValue * alpha +
                        generatedScene * (1.0f - alpha);
                    const float expected = unhalf(current[offset + channel]);
                    const float doubleComposed = uiValue * alpha +
                                                 expected * (1.0f - alpha);
                    if (std::fabs(value - expected) >= 0.012f) {
                        std::fprintf(stderr,
                            "FSR_FRAMEGENERATION_UI_SAMPLE path=%s step=%u "
                            "x=%u y=%u channel=%u actual=%.6f current=%.6f "
                            "midpoint_once=%.6f double=%.6f\n",
                            path, step, x, y, channel, value, expected,
                            midpointComposed, doubleComposed);
                        require(false, path,
                                "HUDless UI was omitted or composed twice");
                    }
                    continue;
                }
                if (channel == 3) {
                    if (transfer != TransferCase::SDR)
                        require(std::fabs(value - 1.0f) < 0.012f, path,
                                "HDR generated output alpha was not one");
                    continue;
                }

                require(value > -0.25f && value < 5.25f, path,
                        "output is outside the permitted reconstruction range");

                // Reset output is read back and checked for writes. A frame-ID
                // discontinuity without an explicit reset must independently
                // produce the current-frame baseline rather than stale history.
                if (!interior || (step < 3 && !implicitGap))
                    continue;
                if (implicitGap) {
                    result.currentError += std::fabs(
                        static_cast<double>(value) -
                        unhalf(current[offset + channel]));
                    ++result.samples;
                    continue;
                }

                const double measured = decodeFixtureValue(value, transfer);
                const double a = decodeFixtureValue(
                    unhalf(previous[offset + channel]), transfer);
                const double b = decodeFixtureValue(
                    unhalf(current[offset + channel]), transfer);
                const double midpoint = patternValue(
                    pattern, static_cast<float>(step) - 0.5f,
                    x, y, channel);
                const double errorA = std::fabs(measured - a);
                const double errorB = std::fabs(measured - b);
                result.previousError += errorA;
                result.currentError += errorB;
                result.midpointError +=
                    std::fabs(measured - midpoint);
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

    if (implicitGap) {
        require(result.samples != 0, path, "empty implicit-gap region");
        result.currentError /= static_cast<double>(result.samples);
        require(result.currentError < 0.03, path,
                "frame-ID gap without explicit reset reused stale history");
    } else if (step >= 3) {
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

void runProvider(Gpu& gpu, const FrameGenerationApi& api,
                 const ProviderOptions& options = {}) {
    const bool native = options.native;
    const bool hudless = options.hudless;
    const char* const path = options.longDirectSequence ? "metalfx-direct-retirement" :
        hudless ? "metalfx-hudless-rect-ui" :
        options.preselectionRejections ? "metalfx-preselection-rejections" :
        options.cameraAbsent ? "metalfx-camera-v1-absent" :
        options.finiteDepthReversed ? "metalfx-finite-depth-reversed" :
        options.displayJitter ? "metalfx-display-jitter" :
        options.transfer == TransferCase::PQ ? "metalfx-pq" :
        options.transfer == TransferCase::ScRgb ? "metalfx-scrgb" :
        options.distortionFallback ? "native-distortion-fallback" :
        native ? "native-override" : "builtin";
    const bool debugScenario = !native && !hudless &&
        !options.displayJitter && !options.finiteDepthReversed &&
        !options.distortionFallback && !options.cameraAbsent &&
        !options.preselectionRejections &&
        options.transfer == TransferCase::SDR;

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

    ffxCreateContextDescFrameGenerationHudless hudlessFormat{};
    hudlessFormat.header.type =
        FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION_HUDLESS;
    hudlessFormat.header.pNext = native ? &original.header : &version.header;
    hudlessFormat.hudlessBackBufferFormat = ffxApiGetSurfaceFormatDX12(
        DXGI_FORMAT_R32G32B32A32_FLOAT);

    ffxCreateContextDescFrameGeneration create{};
    create.header.type = FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION;
    create.header.pNext = hudless ? &hudlessFormat.header :
        native ? &original.header : &version.header;
    create.flags = options.displayJitter
        ? FFX_FRAMEGENERATION_ENABLE_DISPLAY_RESOLUTION_MOTION_VECTORS |
              FFX_FRAMEGENERATION_ENABLE_MOTION_VECTORS_JITTER_CANCELLATION |
              FFX_FRAMEGENERATION_ENABLE_DEPTH_INVERTED |
              FFX_FRAMEGENERATION_ENABLE_DEPTH_INFINITE
        : options.finiteDepthReversed
            ? FFX_FRAMEGENERATION_ENABLE_DEPTH_INVERTED
        : options.transfer != TransferCase::SDR
            ? FFX_FRAMEGENERATION_ENABLE_HIGH_DYNAMIC_RANGE
            : debugScenario ? FFX_FRAMEGENERATION_ENABLE_DEBUG_CHECKING : 0u;
    create.displaySize = {kWidth, kHeight};
    create.maxRenderSize = options.displayJitter
        ? FfxApiDimensions2D{kWidth / 2, kHeight / 2}
        : FfxApiDimensions2D{kWidth, kHeight};
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

    const bool verifyDebugCallback = debugScenario;
    if (options.preselectionRejections) {
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
    if (verifyDebugCallback) {
        InterlockedExchange(&gDebugErrors, 0);
        ffxConfigureDescGlobalDebug1 debug{};
        debug.header.type = FFX_API_CONFIGURE_DESC_TYPE_GLOBALDEBUG1;
        debug.fpMessage = debugMessage;
        debug.debugLevel = FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_ERRORS;
        requireFfx(api.configure(&context, &debug.header), FFX_API_RETURN_OK,
                   path, "configure global debug callback");
    }

    using Texture = decltype(makeTexture(
        gpu, kWidth, kHeight, DXGI_FORMAT_R32_FLOAT,
        D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST));

    // Keep all caller resources alive through context destruction, including
    // endpoints used as history. Every output starts with a fresh sentinel.
    std::vector<Texture> resources;
    resources.reserve(40);
    const UINT renderWidth = options.displayJitter ? kWidth / 2 : kWidth;
    const UINT renderHeight = options.displayJitter ? kHeight / 2 : kHeight;
    const std::size_t pixelCount =
        static_cast<std::size_t>(kWidth) * kHeight;
    const std::size_t depthPixelCount =
        static_cast<std::size_t>(renderWidth) * renderHeight;
    const std::vector<float> depthPixels(depthPixelCount, 0.5f);
    const std::vector<std::uint16_t> sentinel(pixelCount * 4, half(kSentinel));
    std::uint64_t frameID = 0;
    unsigned verifiedIntermediates = 0;

    for (unsigned pattern = 0; pattern < 2; ++pattern) {
        if (pattern == 1 && !native)
            frameID += 2; // A real frame-ID discontinuity paired with reset.
        std::vector<std::uint16_t> previous;
        // The measured MetalFX reset sequence needs two further warm-up frames.
        // Verify writes throughout warm-up and actual interpolation thereafter.
        for (unsigned step = 0; step < (options.longDirectSequence && !pattern ? 70u : 5u);
             ++step, ++frameID) {
            const bool implicitGap = options.displayJitter &&
                pattern == 1 && step == 0;
            const bool reset = step == 0 && !implicitGap;
            const auto scene = options.transfer == TransferCase::SDR
                ? makePattern(pattern, static_cast<float>(step))
                : makeTransferPattern(pattern, static_cast<float>(step),
                                      options.transfer);
            const auto current = hudless
                ? makeComposedPattern(pattern, static_cast<float>(step))
                : scene;
            const auto hudlessPixels = makeFloatPattern(
                pattern, static_cast<float>(step));
            const Motion velocity = patternMotion(pattern);

            // FFX motion vectors map the current sample to the previous frame.
            // Pixel-valued vectors are converted to UV by the prepare scale.
            const float jitterX = options.displayJitter
                ? (step % 2 == 0 ? 0.25f : -0.25f) : 0.0f;
            const float jitterY = options.displayJitter
                ? (step % 2 == 0 ? -0.375f : 0.375f) : 0.0f;
            const float previousJitterX = options.displayJitter
                ? (step % 2 == 0 ? -0.25f : 0.25f) : 0.0f;
            const float previousJitterY = options.displayJitter
                ? (step % 2 == 0 ? 0.375f : -0.375f) : 0.0f;
            std::vector<std::uint16_t> motionPixels(pixelCount * 2);
            for (std::size_t i = 0; i < pixelCount; ++i) {
                motionPixels[i * 2] = half(reset ? 0.0f :
                    -velocity.x + previousJitterX - jitterX);
                motionPixels[i * 2 + 1] = half(reset ? 0.0f :
                    -velocity.y + previousJitterY - jitterY);
            }

            auto color = makeTexture(
                gpu, kWidth, kHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
            auto hudlessColor = makeTexture(
                gpu, kWidth, kHeight, hudless
                    ? DXGI_FORMAT_R32G32B32A32_FLOAT
                    : DXGI_FORMAT_R16G16B16A16_FLOAT,
                D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
            auto depth = makeTexture(
                gpu, renderWidth, renderHeight, DXGI_FORMAT_R32_FLOAT,
                D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
            auto motion = makeTexture(
                gpu, kWidth, kHeight, DXGI_FORMAT_R16G16_FLOAT,
                D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
            auto distortion = makeTexture(
                gpu, kWidth, kHeight, DXGI_FORMAT_R16G16_FLOAT,
                D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
            auto output = makeTexture(
                gpu, kWidth, kHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
                D3D12_RESOURCE_STATE_COPY_DEST);

            resources.push_back(color);
            resources.push_back(hudlessColor);
            resources.push_back(depth);
            resources.push_back(motion);
            resources.push_back(distortion);
            resources.push_back(output);

            uploadTexture(gpu, color.Get(), current.data(), kWidth * 8);
            if (hudless)
                uploadTexture(gpu, hudlessColor.Get(), hudlessPixels.data(),
                              kWidth * 16);
            else
                uploadTexture(gpu, hudlessColor.Get(), scene.data(), kWidth * 8);
            uploadTexture(gpu, depth.Get(), depthPixels.data(), renderWidth * 4);
            uploadTexture(gpu, motion.Get(), motionPixels.data(), kWidth * 4);
            const std::vector<std::uint16_t> zeroDistortion(pixelCount * 2);
            uploadTexture(gpu, distortion.Get(), zeroDistortion.data(), kWidth * 4);
            uploadTexture(gpu, output.Get(), sentinel.data(), kWidth * 8);

            ffxConfigureDescFrameGeneration configure{};
            configure.header.type =
                FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATION;
            ffxConfigureDescFrameGenerationRegisterDistortionFieldResource
                distortionConfiguration{};
            distortionConfiguration.header.type =
                FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATION_REGISTERDISTORTIONRESOURCE;
            distortionConfiguration.distortionField = ffxApiGetResourceDX12(
                distortion.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
            if (options.distortionFallback)
                configure.header.pNext = &distortionConfiguration.header;
            configure.swapChain = nullptr;
            configure.frameGenerationEnabled = true;
            configure.allowAsyncWorkloads = false;
            configure.flags = kDispatchFlags;
            configure.generationRect = hudless
                ? kPartialRect : FfxApiRect2D{0, 0, kWidth, kHeight};
            configure.frameID = frameID;
            if (hudless) {
                configure.HUDLessColor = ffxApiGetResourceDX12(
                    hudlessColor.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
                if (frameID == 0) {
                    auto badHudlessFormat = configure;
                    badHudlessFormat.HUDLessColor = ffxApiGetResourceDX12(
                        color.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
                    requireFfx(api.configure(&context, &badHudlessFormat.header),
                               FFX_API_RETURN_ERROR_PARAMETER, path,
                               "HUDless resource contradicts declared format");
                }
            }
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
            prepare.renderSize = {renderWidth, renderHeight};
            prepare.jitterOffset = {jitterX, jitterY};
            prepare.motionVectorScale = {1.0f, 1.0f};
            prepare.frameTimeDelta = 16.6667f;
            prepare.reset = reset;
            prepare.cameraNear = options.finiteDepthReversed ? 5000.0f : 0.1f;
            prepare.cameraFar = options.displayJitter
                ? std::numeric_limits<float>::infinity()
                : options.finiteDepthReversed ? 0.1f : 1000.0f;
            prepare.cameraFovAngleVertical = 1.04719755f;
            prepare.viewSpaceToMetersFactor =
                options.cameraAbsent && frameID == 0 ? 0.0f :
                debugScenario ? (step == 0 ? -1.0f : 0.0f) : 1.0f;
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
                options.transfer == TransferCase::PQ
                    ? FFX_API_BACKBUFFER_TRANSFER_FUNCTION_PQ
                    : options.transfer == TransferCase::ScRgb
                        ? FFX_API_BACKBUFFER_TRANSFER_FUNCTION_SCRGB
                        : FFX_API_BACKBUFFER_TRANSFER_FUNCTION_SRGB;
            dispatch.minMaxLuminance[0] = 0.5f;
            dispatch.minMaxLuminance[1] = 400.0f;
            dispatch.generationRect = hudless
                ? kPartialRect : FfxApiRect2D{0, 0, kWidth, kHeight};
            dispatch.frameID = frameID;

            if (options.preselectionRejections && frameID == 0) {
                // Rejected pending-provider calls must not latch native fallback.
                auto badPrepare = prepare;
                badPrepare.commandList = nullptr;
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "pending PrepareV2 without command list");
                badPrepare = prepare;
                badPrepare.depth = {};
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "pending PrepareV2 without depth");
                badPrepare = prepare;
                badPrepare.motionVectors = {};
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "pending PrepareV2 without motion vectors");
            }

            if (options.cameraAbsent && frameID == 0) {
                // V1 without the optional CameraInfo chain is valid and must
                // explicitly reach the provider as camera-info-absent.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                ffxDispatchDescFrameGenerationPrepare prepareV1{};
#pragma clang diagnostic pop
                prepareV1.header.type =
                    FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE;
                prepareV1.frameID = prepare.frameID;
                prepareV1.flags = prepare.flags;
                prepareV1.commandList = prepare.commandList;
                prepareV1.renderSize = prepare.renderSize;
                prepareV1.jitterOffset = prepare.jitterOffset;
                prepareV1.motionVectorScale = prepare.motionVectorScale;
                prepareV1.frameTimeDelta = prepare.frameTimeDelta;
                prepareV1.cameraNear = prepare.cameraNear;
                prepareV1.cameraFar = prepare.cameraFar;
                prepareV1.cameraFovAngleVertical = prepare.cameraFovAngleVertical;
                prepareV1.viewSpaceToMetersFactor = prepare.viewSpaceToMetersFactor;
                prepareV1.depth = prepare.depth;
                prepareV1.motionVectors = prepare.motionVectors;
                requireFfx(api.dispatch(&context, &prepareV1.header),
                           FFX_API_RETURN_OK, path, "PrepareV1 without CameraInfo");
                if (frameID == 0 && !options.preselectionRejections) {
                    requireFfx(api.query(&context, &provider.header),
                               FFX_API_RETURN_OK, path,
                               "query provider before rejected PrepareV1");
                    const std::uint64_t selectedProvider = provider.versionId;
                    auto rejectedPrepare = prepareV1;
                    rejectedPrepare.viewSpaceToMetersFactor =
                        std::numeric_limits<float>::quiet_NaN();
                    requireFfx(api.dispatch(&context, &rejectedPrepare.header),
                               FFX_API_RETURN_ERROR_PARAMETER, path,
                               "PrepareV1 with non-finite world scale");
                    rejectedPrepare = prepareV1;
                    rejectedPrepare.cameraFar =
                        std::numeric_limits<float>::infinity();
                    requireFfx(api.dispatch(&context, &rejectedPrepare.header),
                               FFX_API_RETURN_ERROR_PARAMETER, path,
                               "PrepareV1 with infinite far plane");
                    requireFfx(api.query(&context, &provider.header),
                               FFX_API_RETURN_OK, path,
                               "query provider after rejected PrepareV1");
                    require(provider.versionId == selectedProvider, path,
                            "rejected PrepareV1 changed provider state");
                }
            } else {
                requireFfx(api.dispatch(&context, &prepare.header),
                           FFX_API_RETURN_OK, path, "PrepareV2 with CameraInfo");
            }
            requireFfx(api.query(&context, &provider.header), FFX_API_RETURN_OK, path,
                       "query actual prepared provider");
            require(provider.versionId == (native || options.distortionFallback
                        ? kOriginalProvider : 0x4d46584647000001ull),
                    path, "Prepare selected the wrong provider");

            if (verifyDebugCallback && frameID == 0) {
                // Malformed calls are checked only after a valid V2 Prepare has
                // selected MetalFX; rejection must not steer provider choice.
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
                const std::uint64_t selectedProvider = provider.versionId;
                badPrepare = prepare;
                badPrepare.viewSpaceToMetersFactor =
                    std::numeric_limits<float>::quiet_NaN();
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "PrepareV2 with non-finite world scale");
                badPrepare = prepare;
                badPrepare.cameraFar =
                    std::numeric_limits<float>::infinity();
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "PrepareV2 with infinite far plane");
                badPrepare = prepare;
                badPrepare.cameraFar = badPrepare.cameraNear;
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "PrepareV2 with equal finite planes");
                badPrepare = prepare;
                badPrepare.cameraNear = 0.0f;
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "PrepareV2 with nonpositive near plane");
                badPrepare = prepare;
                badPrepare.cameraFar = 0.0f;
                requireFfx(api.dispatch(&context, &badPrepare.header),
                           FFX_API_RETURN_ERROR_PARAMETER, path,
                           "PrepareV2 with nonpositive far plane");
                requireFfx(api.query(&context, &provider.header),
                           FFX_API_RETURN_OK, path,
                           "query provider after rejected PrepareV2");
                require(provider.versionId == selectedProvider, path,
                        "rejected PrepareV2 changed provider state");
            }

            if (verifyDebugCallback && frameID == 0) {
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
                const std::uint64_t selectedProvider = provider.versionId;
                requireFfx(api.query(&context, &provider.header),
                           FFX_API_RETURN_OK, path,
                           "query provider after rejected generation calls");
                require(provider.versionId == selectedProvider, path,
                        "rejected generation call changed provider state");
                if (verifyDebugCallback)
                    require(InterlockedCompareExchange(&gDebugErrors, 0, 0) > 0,
                            path, "debug callback did not report public API errors");
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
            if (!options.longDirectSequence || step < 5) {
                inspectOutput(readback, pattern, step, previous, current, path, hudless,
                              options.transfer, implicitGap);
                if (step >= 3) ++verifiedIntermediates;
            }
            previous = current;
            // The direct dispatch completed and retired its frame-ID snapshot.
            // Do not retain 70 sets of application resources in this boundary test.
            if (options.longDirectSequence) resources.clear();
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
    HANDLE callbackEntered = nullptr;
    HANDLE callbackRelease = nullptr;
    volatile LONG blockNext = 0;
    volatile LONG calls = 0;
    volatile LONG successes = 0;
    volatile LONG generated = 0;
    volatile LONG failures = 0;
    void* volatile generatedOutput = nullptr;
};

struct ConfigureThreadCall {
    const FrameGenerationApi* api = nullptr;
    ffxContext* context = nullptr;
    ffxConfigureDescFrameGeneration configure{};
    HANDLE started = nullptr;
    HANDLE done = nullptr;
    ffxReturnCode_t result = FFX_API_RETURN_ERROR_RUNTIME_ERROR;
};

DWORD WINAPI swapchainConfigureThread(void* parameter) {
    auto& call = *static_cast<ConfigureThreadCall*>(parameter);
    SetEvent(call.started);
    call.result = call.api->configure(call.context, &call.configure.header);
    SetEvent(call.done);
    return 0;
}

struct PresentThreadCall {
    IDXGISwapChain4* swapchain = nullptr;
    HANDLE done = nullptr;
    HRESULT result = E_FAIL;
};

DWORD WINAPI swapchainPresentThread(void* parameter) {
    auto& call = *static_cast<PresentThreadCall*>(parameter);
    call.result = call.swapchain->Present(1, 0);
    SetEvent(call.done);
    return 0;
}

ffxReturnCode_t swapchainSmokeGenerate(
    ffxDispatchDescFrameGeneration* params, void* user) {
    auto& state = *static_cast<SwapchainSmokeCallbacks*>(user);
    InterlockedIncrement(&state.calls);

    if (InterlockedCompareExchange(&state.blockNext, 0, 1) == 1) {
        SetEvent(state.callbackEntered);
        WaitForSingleObject(state.callbackRelease, INFINITE);
    }

    // Dispatch exactly the resources and command list supplied by the real
    // swapchain. In particular, do not substitute an application-owned output.
    const ffxReturnCode_t result =
        state.api->dispatch(state.context, &params->header);
    if (result == FFX_API_RETURN_OK) {
        auto* output = static_cast<ID3D12Resource*>(params->outputs[0].resource);
        if (output) output->AddRef();
        auto* previous = static_cast<ID3D12Resource*>(
            InterlockedExchangePointer(&state.generatedOutput, output));
        if (previous) previous->Release();
        InterlockedIncrement(&state.successes);
        InterlockedExchangeAdd(
            &state.generated, static_cast<LONG>(params->numGeneratedFrames));
    } else {
        InterlockedIncrement(&state.failures);
    }
    return result;
}

void runBlockedConfigure(
    IDXGISwapChain4* swapchain, const FrameGenerationApi& api,
    ffxContext& context, SwapchainSmokeCallbacks& blockedCallback,
    const ffxConfigureDescFrameGeneration& configure,
    bool shouldCompleteWhileBlocked) {
    ResetEvent(blockedCallback.callbackEntered);
    ResetEvent(blockedCallback.callbackRelease);
    InterlockedExchange(&blockedCallback.blockNext, 1);

    PresentThreadCall present{swapchain, CreateEventW(nullptr, TRUE, FALSE, nullptr)};
    require(present.done != nullptr, "swapchain", "present completion event failed");
    HANDLE presentThread = CreateThread(
        nullptr, 0, swapchainPresentThread, &present, 0, nullptr);
    require(presentThread != nullptr, "swapchain", "present thread creation failed");

    DWORD entered = WaitForSingleObject(blockedCallback.callbackEntered, 30000);
    if (entered != WAIT_OBJECT_0) {
        SetEvent(blockedCallback.callbackRelease);
        WaitForSingleObject(presentThread, 30000);
        CloseHandle(presentThread);
        CloseHandle(present.done);
        require(false, "swapchain", "generation callback barrier was not reached");
    }

    ConfigureThreadCall call{&api, &context, configure};
    call.started = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    call.done = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(call.started && call.done, "swapchain",
            "configure synchronization event failed");
    HANDLE configureThread = CreateThread(
        nullptr, 0, swapchainConfigureThread, &call, 0, nullptr);
    require(configureThread != nullptr, "swapchain",
            "configure thread creation failed");
    require(WaitForSingleObject(call.started, 30000) == WAIT_OBJECT_0,
            "swapchain", "configure thread did not start");

    const bool observed = !shouldCompleteWhileBlocked ||
        WaitForSingleObject(call.done, 30000) == WAIT_OBJECT_0;

    // Always release and join before reporting a failed overlap assertion.
    SetEvent(blockedCallback.callbackRelease);
    const DWORD presentDone = WaitForSingleObject(present.done, 30000);
    const DWORD configureDone = WaitForSingleObject(call.done, 30000);
    WaitForSingleObject(presentThread, 30000);
    WaitForSingleObject(configureThread, 30000);
    CloseHandle(presentThread);
    CloseHandle(configureThread);
    CloseHandle(present.done);
    CloseHandle(call.started);
    CloseHandle(call.done);

    require(observed, "swapchain",
            "unchanged callback configuration drained an active frame");
    require(presentDone == WAIT_OBJECT_0 && configureDone == WAIT_OBJECT_0,
            "swapchain", "blocked presenter/configure cleanup timed out");
    check(present.result, "swapchain overlapped Present");
    requireFfx(call.result, FFX_API_RETURN_OK, "swapchain",
               "overlapped configure");
}

void inspectGeneratedSwapchainOutput(
    Gpu& gpu, SwapchainSmokeCallbacks& callbacks, unsigned frame,
    const std::vector<std::uint16_t>& previous,
    const std::vector<std::uint16_t>& current, bool reset) {
    auto* resource = static_cast<ID3D12Resource*>(
        InterlockedExchangePointer(&callbacks.generatedOutput, nullptr));
    require(resource != nullptr, "swapchain",
            "generation callback did not retain its output");
    ComPtr<ID3D12Resource> output;
    output.Attach(resource);
    auto readback = makeReadback(gpu, output.Get());
    gpu.begin();
    transition(gpu.list.Get(), output.Get(),
               D3D12_RESOURCE_STATE_UNORDERED_ACCESS,
               D3D12_RESOURCE_STATE_COPY_SOURCE);
    copyToReadback(gpu.list.Get(), output.Get(), readback);
    transition(gpu.list.Get(), output.Get(),
               D3D12_RESOURCE_STATE_COPY_SOURCE,
               D3D12_RESOURCE_STATE_UNORDERED_ACCESS);
    gpu.submit();
    inspectOutput(readback, 0, frame, previous, current, "swapchain",
                  false, TransferCase::SDR, reset);
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

void inspectSwapchainUi(const ReadbackTexture& readback, UINT lastFrame) {
    void* mapping = nullptr;
    D3D12_RANGE readRange{0, static_cast<SIZE_T>(readback.size)};
    check(readback.buffer->Map(0, &readRange, &mapping),
          "Map presented swapchain image");
    const auto* bytes = static_cast<const std::uint8_t*>(mapping);
    double bestSingle = 1e9;
    double bestDouble = 1e9;
    for (unsigned phase = 2 * (lastFrame - 9); phase <= 2 * lastFrame; ++phase) {
        const float time = static_cast<float>(phase) * 0.5f;
        double singleError = 0.0;
        double doubleError = 0.0;
        std::size_t samples = 0;
        for (UINT y = 224; y < 264; y += 4) {
            const auto* row = reinterpret_cast<const std::uint16_t*>(
                bytes + readback.footprint.Offset +
                static_cast<SIZE_T>(y) * readback.footprint.Footprint.RowPitch);
            for (UINT x = 368; x < 448; x += 4) {
                for (unsigned channel = 0; channel < 3; ++channel) {
                    const float scene = patternValue(0, time, x, y, channel);
                    const float ui = channel == 0 ? 0.92f :
                                     channel == 1 ? 0.14f : 0.73f;
                    const float once = ui * 0.375f + scene * 0.625f;
                    const float twice = ui * 0.375f + once * 0.625f;
                    const float actual = unhalf(row[x * 4 + channel]);
                    singleError += std::fabs(actual - once);
                    doubleError += std::fabs(actual - twice);
                    ++samples;
                }
            }
        }
        bestSingle = std::min(bestSingle, singleError / samples);
        bestDouble = std::min(bestDouble, doubleError / samples);
    }
    D3D12_RANGE writtenRange{0, 0};
    readback.buffer->Unmap(0, &writtenRange);
    require(bestSingle < 0.04, "swapchain",
            "presented translucent UI does not match one composition");
    require(bestSingle < bestDouble * 0.65, "swapchain",
            "registered translucent UI was composed twice");
}

void runSwapchain(Gpu& gpu, const FrameGenerationApi& api) {
    const char* const path = "swapchain";
    // Exceed the former 64-snapshot ceiling (64 RGBA16F textures ~= 120 MiB).
    constexpr UINT disabledFrames = 128;
    constexpr UINT overlapFrame = disabledFrames + 3;
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
    create.flags = FFX_FRAMEGENERATION_ENABLE_DEPTH_INVERTED;
    create.displaySize = {kWidth, kHeight};
    create.maxRenderSize = {kWidth, kHeight};
    create.backBufferFormat = ffxApiGetSurfaceFormatDX12(format);

    ffxContext context = nullptr;
    requireFfx(api.create(&context, &create.header, nullptr),
               FFX_API_RETURN_OK, path, "create automatic FG");
    require(context != nullptr, path, "null FG context");

    auto ui = makeTexture(
        gpu, kWidth, kHeight, format, D3D12_RESOURCE_FLAG_NONE,
        D3D12_RESOURCE_STATE_COPY_DEST);
    const auto uiPixels = makeUiLayer();
    uploadTexture(gpu, ui.Get(), uiPixels.data(), kWidth * 8);
    ffxConfigureDescFrameGenerationSwapChainRegisterUiResourceDX12 registerUi{};
    registerUi.header.type =
        FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_REGISTERUIRESOURCE_DX12;
    registerUi.uiResource = ffxApiGetResourceDX12(
        ui.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
    registerUi.flags = FFX_FRAMEGENERATION_UI_COMPOSITION_FLAG_USE_PREMUL_ALPHA;
    requireFfx(api.configure(&swapContext, &registerUi.header),
               FFX_API_RETURN_OK, path, "register premultiplied UI resource");

    SwapchainSmokeCallbacks callbacks{};
    callbacks.api = &api;
    callbacks.context = &context;
    callbacks.callbackEntered = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    callbacks.callbackRelease = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    require(callbacks.callbackEntered && callbacks.callbackRelease, path,
            "callback synchronization event creation failed");
    SwapchainSmokeCallbacks replacementCallbacks{};
    replacementCallbacks.api = &api;
    replacementCallbacks.context = &context;
    replacementCallbacks.callbackEntered = callbacks.callbackEntered;
    replacementCallbacks.callbackRelease = callbacks.callbackRelease;

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
    resources.reserve(frameCount * 4 + 1);
    resources.push_back(ui);
    const std::size_t pixelCount =
        static_cast<std::size_t>(kWidth) * kHeight;
    const std::vector<float> depthPixels(pixelCount, 0.5f);
    ComPtr<ID3D12Resource> queuedHudless;
    std::vector<std::uint16_t> previousScene;
    LONG oldCallsAfterReplacement = 0;

    for (UINT frame = 0; frame < frameCount; ++frame) {
        swapchainSmokePump(window);

        const auto scenePixels = makePattern(0, static_cast<float>(frame));
        const auto pixels = makeComposedPattern(0, static_cast<float>(frame));
        const Motion velocity = patternMotion(0);
        std::vector<std::uint16_t> vectors(pixelCount * 2);
        for (std::size_t i = 0; i < pixelCount; ++i) {
            vectors[2 * i] = half(frame ? -velocity.x : 0.0f);
            vectors[2 * i + 1] = half(frame ? -velocity.y : 0.0f);
        }

        auto color = makeTexture(
            gpu, kWidth, kHeight, format, D3D12_RESOURCE_FLAG_NONE,
            D3D12_RESOURCE_STATE_COPY_DEST);
        ComPtr<ID3D12Resource> hudlessColor;
        const bool reusedQueuedHudless =
            frame == overlapFrame + 1 && queuedHudless;
        if (reusedQueuedHudless) {
            hudlessColor = queuedHudless;
            queuedHudless.Reset();
        } else {
            hudlessColor = makeTexture(
                gpu, kWidth, kHeight, format, D3D12_RESOURCE_FLAG_NONE,
                D3D12_RESOURCE_STATE_COPY_DEST);
        }
        auto depth = makeTexture(
            gpu, kWidth, kHeight, DXGI_FORMAT_R32_FLOAT,
            D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
        auto motion = makeTexture(
            gpu, kWidth, kHeight, DXGI_FORMAT_R16G16_FLOAT,
            D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);

        resources.push_back(color);
        if (frame != overlapFrame)
            resources.push_back(hudlessColor);
        resources.push_back(depth);
        resources.push_back(motion);

        // uploadTexture already transitions COPY_DEST -> COMPUTE_READ and
        // waits for completion. Do not repeat that transition afterward.
        uploadTexture(gpu, color.Get(), pixels.data(), kWidth * 8);
        if (!reusedQueuedHudless)
            uploadTexture(gpu, hudlessColor.Get(), scenePixels.data(), kWidth * 8);
        uploadTexture(gpu, depth.Get(), depthPixels.data(), kWidth * 4);
        uploadTexture(gpu, motion.Get(), vectors.data(), kWidth * 4);
        if (frame == overlapFrame) {
            queuedHudless = makeTexture(
                gpu, kWidth, kHeight, format, D3D12_RESOURCE_FLAG_NONE,
                D3D12_RESOURCE_STATE_COPY_DEST);
            const auto queuedScene = makePattern(
                0, static_cast<float>(frame + 1));
            uploadTexture(gpu, queuedHudless.Get(), queuedScene.data(), kWidth * 8);
        }

        configure.frameID = frame;
        configure.frameGenerationEnabled = frame >= disabledFrames;
        configure.HUDLessColor = ffxApiGetResourceDX12(
            hudlessColor.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
        requireFfx(api.configure(&context, &configure.header),
                   FFX_API_RETURN_OK, path, "configure FG callbacks");
        if (frame == overlapFrame)
            hudlessColor.Reset();

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
        prepare.cameraNear = 5000.0f;
        prepare.cameraFar = 0.1f;
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
        if (frame == overlapFrame) {
            auto queued = configure;
            queued.frameID = frame + 1;
            queued.HUDLessColor = ffxApiGetResourceDX12(
                queuedHudless.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
            runBlockedConfigure(swapchain.Get(), api, context, callbacks,
                                queued, true);
        } else if (frame == overlapFrame + 1) {
            auto replacement = configure;
            replacement.frameGenerationCallbackUserContext =
                &replacementCallbacks;
            runBlockedConfigure(swapchain.Get(), api, context, callbacks,
                                replacement, false);
            configure.frameGenerationCallbackUserContext =
                &replacementCallbacks;
            oldCallsAfterReplacement = InterlockedCompareExchange(
                &callbacks.calls, 0, 0);
        } else {
            check(swapchain->Present(1, 0), "swapchain Present");
        }
        swapchainSmokeDrain(gpu, api, swapContext);
        backbuffer.Reset();

        require(InterlockedCompareExchange(&callbacks.failures, 0, 0) == 0 &&
                    InterlockedCompareExchange(
                        &replacementCallbacks.failures, 0, 0) == 0,
                path, "interpolation callback dispatch failed");
        if (frame == disabledFrames || frame >= overlapFrame) {
            auto& source = frame <= overlapFrame + 1
                ? callbacks : replacementCallbacks;
            inspectGeneratedSwapchainOutput(
                gpu, source, frame, previousScene, scenePixels,
                frame == disabledFrames);
        }
        previousScene = scenePixels;
    }

    // Drain before examining real swapchain buffers or changing callbacks.
    swapchainSmokeDrain(gpu, api, swapContext);
    for (UINT bufferIndex = 0; bufferIndex < description.BufferCount; ++bufferIndex) {
        ComPtr<ID3D12Resource> presented;
        check(swapchain->GetBuffer(bufferIndex, IID_PPV_ARGS(&presented)),
              "swapchain GetBuffer for UI readback");
        auto readback = makeReadback(gpu, presented.Get());
        gpu.begin();
        transition(gpu.list.Get(), presented.Get(), D3D12_RESOURCE_STATE_PRESENT,
                   D3D12_RESOURCE_STATE_COPY_SOURCE);
        copyToReadback(gpu.list.Get(), presented.Get(), readback);
        transition(gpu.list.Get(), presented.Get(), D3D12_RESOURCE_STATE_COPY_SOURCE,
                   D3D12_RESOURCE_STATE_PRESENT);
        gpu.submit();
        inspectSwapchainUi(readback, frameCount);
    }
    configure.frameGenerationEnabled = false;
    requireFfx(api.configure(&context, &configure.header),
               FFX_API_RETURN_OK, path, "disable FG");
    swapchainSmokeDrain(gpu, api, swapContext);

    const LONG oldCalls = InterlockedCompareExchange(&callbacks.calls, 0, 0);
    const LONG oldSuccesses =
        InterlockedCompareExchange(&callbacks.successes, 0, 0);
    const LONG oldGenerated =
        InterlockedCompareExchange(&callbacks.generated, 0, 0);
    const LONG replacementCalls =
        InterlockedCompareExchange(&replacementCallbacks.calls, 0, 0);
    const LONG replacementSuccesses =
        InterlockedCompareExchange(&replacementCallbacks.successes, 0, 0);
    const LONG replacementGenerated =
        InterlockedCompareExchange(&replacementCallbacks.generated, 0, 0);
    const LONG calls = oldCalls + replacementCalls;
    const LONG successes = oldSuccesses + replacementSuccesses;
    const LONG generated = oldGenerated + replacementGenerated;
    require(oldCalls == oldCallsAfterReplacement, path,
            "retired callback binding was invoked again");
    require(replacementCalls > 0, path,
            "replacement callback binding was never invoked");
    require(calls >= 3 && successes == calls && generated >= 3, path,
            "insufficient successful real interpolation callbacks");

    // With no Present/callback to retire these IDs, preserve all 64 future
    // configurations and fail the next one instead of silently rebinding it.
    configure.frameGenerationEnabled = true;
    configure.HUDLessColor = ffxApiGetResourceDX12(
        ui.Get(), FFX_API_RESOURCE_STATE_COMPUTE_READ);
    for (UINT pending = 0; pending < 64; ++pending) {
        configure.frameID = 10000 + pending;
        requireFfx(api.configure(&context, &configure.header),
                   FFX_API_RETURN_OK, path, "queue future FG config");
    }
    configure.frameID = 10063;
    requireFfx(api.configure(&context, &configure.header),
               FFX_API_RETURN_OK, path, "replace same frame at capacity");
    configure.frameID = 10064;
    requireFfx(api.configure(&context, &configure.header),
               FFX_API_RETURN_ERROR_RUNTIME_ERROR, path, "future FG backpressure");
    configure.frameGenerationEnabled = false;
    requireFfx(api.configure(&context, &configure.header),
               FFX_API_RETURN_OK, path, "clear queued FG configs");

    auto* oldOutput = static_cast<ID3D12Resource*>(
        InterlockedExchangePointer(&callbacks.generatedOutput, nullptr));
    auto* replacementOutput = static_cast<ID3D12Resource*>(
        InterlockedExchangePointer(
            &replacementCallbacks.generatedOutput, nullptr));
    if (oldOutput) oldOutput->Release();
    if (replacementOutput) replacementOutput->Release();
    CloseHandle(callbacks.callbackEntered);
    CloseHandle(callbacks.callbackRelease);

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
        // The game supplies reversed finite plane distances in SDK order.
        // Exercise that contract first so a rejection cannot hide behind a
        // previously selected provider, then retain the ascending finite case.
        runProvider(gpu, api, ProviderOptions{.finiteDepthReversed = true});
        runProvider(gpu, api, ProviderOptions{.finiteDepthReversed = true,
                                               .longDirectSequence = true});
        runProvider(gpu, api);
        runProvider(gpu, api, ProviderOptions{.cameraAbsent = true});
        runProvider(gpu, api, ProviderOptions{
            .cameraAbsent = true, .preselectionRejections = true});

        // Exercise native routing through both an explicit override and a
        // genuine unsupported MetalFX feature. The distortion field is a valid
        // zero-offset RG resource, not a malformed-descriptor shortcut.
        runProvider(gpu, api, ProviderOptions{.native = true});
        runProvider(gpu, api, ProviderOptions{.hudless = true});
        runProvider(gpu, api, ProviderOptions{.distortionFallback = true});
        runProvider(gpu, api, ProviderOptions{.displayJitter = true});
        runProvider(gpu, api, ProviderOptions{.transfer = TransferCase::PQ});
        runProvider(gpu, api, ProviderOptions{.transfer = TransferCase::ScRgb});
        runSwapchain(gpu, api);
    }

    FreeLibrary(module);
    std::printf("FSR_FRAMEGENERATION_D3D12_PASS "
                "builtin=4 cameraV1Absent=4 preselectionRejections=4 native=4 "
                "hudlessRectUi=4 distortionFallback=4 displayJitter=4 pq=4 "
                "scrgb=4 finiteDepthReversed=4 directRetirement=4 swapchainUiReadback=3\n");
    return 0;
}