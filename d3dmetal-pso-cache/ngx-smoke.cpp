#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>

#include <nvsdk_ngx.h>
#include <nvsdk_ngx_defs.h>
#include <nvsdk_ngx_params.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <vector>

using Microsoft::WRL::ComPtr;

extern "C" {
void ngx_smoke_set_float(NVSDK_NGX_Parameter*, const char*, float);
void ngx_smoke_set_uint(NVSDK_NGX_Parameter*, const char*, unsigned int);
void ngx_smoke_set_int(NVSDK_NGX_Parameter*, const char*, int);
void ngx_smoke_set_resource(NVSDK_NGX_Parameter*, const char*, ID3D12Resource*);
NVSDK_NGX_Result ngx_smoke_get_float(const NVSDK_NGX_Parameter*, const char*, float*);
NVSDK_NGX_Result ngx_smoke_get_uint(const NVSDK_NGX_Parameter*, const char*, unsigned int*);
NVSDK_NGX_Result ngx_smoke_get_int(const NVSDK_NGX_Parameter*, const char*, int*);
NVSDK_NGX_Result ngx_smoke_get_resource(const NVSDK_NGX_Parameter*, const char*, ID3D12Resource**);
void ngx_smoke_reset(NVSDK_NGX_Parameter*);
}


namespace {

using Init = NVSDK_NGX_Result (NVSDK_CONV *)(
    unsigned long long, const wchar_t*, ID3D12Device*,
    const NVSDK_NGX_FeatureCommonInfo*, NVSDK_NGX_Version);
using Shutdown = NVSDK_NGX_Result (NVSDK_CONV *)();
using GetParameters = NVSDK_NGX_Result (NVSDK_CONV *)(NVSDK_NGX_Parameter**);
using CreateFeature = NVSDK_NGX_Result (NVSDK_CONV *)(
    ID3D12GraphicsCommandList*, NVSDK_NGX_Feature,
    const NVSDK_NGX_Parameter*, NVSDK_NGX_Handle**);
using EvaluateFeature = NVSDK_NGX_Result (NVSDK_CONV *)(
    ID3D12GraphicsCommandList*, const NVSDK_NGX_Handle*,
    const NVSDK_NGX_Parameter*, PFN_NVSDK_NGX_ProgressCallback);
using ReleaseFeature = NVSDK_NGX_Result (NVSDK_CONV *)(const NVSDK_NGX_Handle*);

[[noreturn]] void fail(const char* message, long code = 0) {
    std::fprintf(stderr, "NGX_SMOKE_FAIL %s code=0x%08lx\n", message,
                 static_cast<unsigned long>(code));
    std::exit(1);
}

void check(HRESULT result, const char* message) {
    if (FAILED(result)) fail(message, result);
}

void checkNgx(NVSDK_NGX_Result result, const char* message) {
    if (NVSDK_NGX_FAILED(result)) fail(message, result);
}

template<typename T>
T load(HMODULE module, const char* name) {
    FARPROC address = GetProcAddress(module, name);
    if (address == nullptr) fail(name, GetLastError());
    T result;
    static_assert(sizeof(result) == sizeof(address));
    std::memcpy(&result, &address, sizeof(result));
    return result;
}

std::uint16_t half(float value) {
    std::uint32_t bits;
    std::memcpy(&bits, &value, sizeof(bits));
    const std::uint32_t sign = (bits >> 16) & 0x8000;
    int exponent = static_cast<int>((bits >> 23) & 0xff) - 127 + 15;
    std::uint32_t mantissa = bits & 0x7fffff;
    if (exponent <= 0) {
        if (exponent < -10) return static_cast<std::uint16_t>(sign);
        mantissa = (mantissa | 0x800000) >> (1 - exponent);
        return static_cast<std::uint16_t>(sign | ((mantissa + 0x1000) >> 13));
    }
    if (exponent >= 31) return static_cast<std::uint16_t>(sign | 0x7c00);
    return static_cast<std::uint16_t>(sign | (static_cast<std::uint32_t>(exponent) << 10) |
                                      ((mantissa + 0x1000) >> 13));
}

float unhalf(std::uint16_t value) {
    const std::uint32_t sign = static_cast<std::uint32_t>(value & 0x8000) << 16;
    std::uint32_t exponent = (value >> 10) & 0x1f;
    std::uint32_t mantissa = value & 0x3ff;
    std::uint32_t bits;
    if (exponent == 0) {
        if (mantissa == 0) bits = sign;
        else {
            exponent = 113;
            while ((mantissa & 0x400) == 0) { mantissa <<= 1; --exponent; }
            bits = sign | (exponent << 23) | ((mantissa & 0x3ff) << 13);
        }
    } else if (exponent == 31) {
        bits = sign | 0x7f800000 | (mantissa << 13);
    } else {
        bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
    }
    float result;
    std::memcpy(&result, &bits, sizeof(result));
    return result;
}

struct Gpu {
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Fence> fence;
    HANDLE event = nullptr;
    std::uint64_t fenceValue = 0;

    Gpu() {
        check(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0,
                                IID_PPV_ARGS(&device)), "D3D12CreateDevice");
        D3D12_COMMAND_QUEUE_DESC queueDesc{};
        queueDesc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        check(device->CreateCommandQueue(&queueDesc, IID_PPV_ARGS(&queue)), "CreateCommandQueue");
        check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)), "CreateFence");
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (event == nullptr) fail("CreateEvent", GetLastError());
    }

    ~Gpu() { if (event != nullptr) CloseHandle(event); }

    void executeClosed() {
        ID3D12CommandList* lists[] = {commands.Get()};
        queue->ExecuteCommandLists(1, lists);
        const std::uint64_t value = ++fenceValue;
        check(queue->Signal(fence.Get(), value), "Signal");
        if (fence->GetCompletedValue() < value) {
            check(fence->SetEventOnCompletion(value, event), "SetEventOnCompletion");
            if (WaitForSingleObject(event, 30000) != WAIT_OBJECT_0) fail("GPU timeout");
        }
    }

    void submit() {
        check(commands->Close(), "Close command list");
        executeClosed();
    }

    void begin() {
        allocator.Reset();
        commands.Reset();
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                              IID_PPV_ARGS(&allocator)),
              "CreateCommandAllocator");
        check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr,
                                        IID_PPV_ARGS(&commands)),
              "CreateCommandList");
    }
};

D3D12_RESOURCE_DESC textureDesc(UINT width, UINT height, DXGI_FORMAT format,
                                D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
    D3D12_RESOURCE_DESC desc{};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    desc.Width = width;
    desc.Height = height;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.Format = format;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    desc.Flags = flags;
    return desc;
}

ComPtr<ID3D12Resource> makeTexture(Gpu& gpu, UINT width, UINT height, DXGI_FORMAT format,
                                   D3D12_RESOURCE_FLAGS flags,
                                   D3D12_RESOURCE_STATES state) {
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = D3D12_HEAP_TYPE_DEFAULT;
    ComPtr<ID3D12Resource> result;
    const auto desc = textureDesc(width, height, format, flags);
    check(gpu.device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, state,
                                               nullptr, IID_PPV_ARGS(&result)),
          "Create texture");
    return result;
}

ComPtr<ID3D12Resource> makeBuffer(Gpu& gpu, std::uint64_t size, D3D12_HEAP_TYPE heapType,
                                  D3D12_RESOURCE_STATES state) {
    D3D12_HEAP_PROPERTIES heap{};
    heap.Type = heapType;
    D3D12_RESOURCE_DESC desc{};
    desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = size;
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    ComPtr<ID3D12Resource> result;
    check(gpu.device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &desc, state,
                                               nullptr, IID_PPV_ARGS(&result)),
          "Create buffer");
    return result;
}

void uploadTexture(Gpu& gpu, ID3D12Resource* texture, const void* pixels,
                   std::size_t sourceRowBytes) {
    gpu.begin();
    const D3D12_RESOURCE_DESC desc = texture->GetDesc();
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT rows = 0;
    UINT64 rowBytes = 0;
    UINT64 total = 0;
    gpu.device->GetCopyableFootprints(&desc, 0, 1, 0, &footprint, &rows, &rowBytes, &total);
    auto upload = makeBuffer(gpu, total, D3D12_HEAP_TYPE_UPLOAD, D3D12_RESOURCE_STATE_GENERIC_READ);
    std::uint8_t* mapped = nullptr;
    check(upload->Map(0, nullptr, reinterpret_cast<void**>(&mapped)), "Map upload");
    for (UINT row = 0; row < rows; ++row) {
        std::memcpy(mapped + footprint.Offset + row * footprint.Footprint.RowPitch,
                    static_cast<const std::uint8_t*>(pixels) + row * sourceRowBytes,
                    static_cast<std::size_t>(rowBytes));
    }
    upload->Unmap(0, nullptr);
    D3D12_TEXTURE_COPY_LOCATION dst{};
    dst.pResource = texture;
    dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION src{};
    src.pResource = upload.Get();
    src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    src.PlacedFootprint = footprint;
    gpu.commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = texture;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_DEST;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    gpu.commands->ResourceBarrier(1, &barrier);
    gpu.submit();
    gpu.begin();
}


float readExposureTexture(Gpu& gpu, ID3D12Resource* texture) {
    gpu.begin();
    const D3D12_RESOURCE_DESC desc = texture->GetDesc();
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT rows = 0;
    UINT64 rowBytes = 0;
    UINT64 total = 0;
    gpu.device->GetCopyableFootprints(&desc, 0, 1, 0, &footprint, &rows, &rowBytes, &total);
    auto readback = makeBuffer(gpu, total, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST);
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = texture;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    gpu.commands->ResourceBarrier(1, &barrier);
    D3D12_TEXTURE_COPY_LOCATION src{};
    src.pResource = texture;
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION dst{};
    dst.pResource = readback.Get();
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint = footprint;
    gpu.commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE;
    gpu.commands->ResourceBarrier(1, &barrier);
    gpu.submit();
    const std::uint16_t* mapped = nullptr;
    D3D12_RANGE range{static_cast<SIZE_T>(footprint.Offset),
                      static_cast<SIZE_T>(footprint.Offset + sizeof(std::uint16_t))};
    check(readback->Map(0, &range, reinterpret_cast<void**>(const_cast<std::uint16_t**>(&mapped))),
          "Map exposure readback");
    std::uint16_t value;
    std::memcpy(&value, reinterpret_cast<const std::uint8_t*>(mapped) + footprint.Offset,
                sizeof(value));
    readback->Unmap(0, nullptr);
    return unhalf(value);
}

struct ReadbackStats {
    double mean = 0;
    double maximumDeviation = 0;
    std::size_t finite = 0;
};

ReadbackStats readOutput(Gpu& gpu, ID3D12Resource* output, UINT width, UINT height) {
    const auto desc = output->GetDesc();
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT rows = 0;
    UINT64 rowBytes = 0;
    UINT64 total = 0;
    gpu.device->GetCopyableFootprints(&desc, 0, 1, 0, &footprint, &rows, &rowBytes, &total);
    auto readback = makeBuffer(gpu, total, D3D12_HEAP_TYPE_READBACK, D3D12_RESOURCE_STATE_COPY_DEST);
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = output;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_COPY_SOURCE;
    gpu.commands->ResourceBarrier(1, &barrier);
    D3D12_TEXTURE_COPY_LOCATION src{};
    src.pResource = output;
    src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION dst{};
    dst.pResource = readback.Get();
    dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    dst.PlacedFootprint = footprint;
    gpu.commands->CopyTextureRegion(&dst, 0, 0, 0, &src, nullptr);
    gpu.submit();

    const std::uint8_t* mapped = nullptr;
    D3D12_RANGE range{0, static_cast<SIZE_T>(total)};
    check(readback->Map(0, &range, reinterpret_cast<void**>(const_cast<std::uint8_t**>(&mapped))),
          "Map readback");
    std::vector<float> values;
    values.reserve(static_cast<std::size_t>(width) * height * 3);
    for (UINT y = 0; y < height; ++y) {
        const auto* row = reinterpret_cast<const std::uint16_t*>(
            mapped + footprint.Offset + y * footprint.Footprint.RowPitch);
        for (UINT x = 0; x < width; ++x) {
            for (UINT channel = 0; channel < 3; ++channel) values.push_back(unhalf(row[x * 4 + channel]));
        }
    }
    readback->Unmap(0, nullptr);
    ReadbackStats stats;
    double sum = 0;
    for (float value : values) {
        if (std::isfinite(value)) { sum += value; ++stats.finite; }
    }
    if (stats.finite != values.size()) fail("non-finite output");
    stats.mean = sum / static_cast<double>(values.size());
    for (float value : values) stats.maximumDeviation = std::max(stats.maximumDeviation,
                                                                  std::abs(value - stats.mean));

    gpu.begin();
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COPY_SOURCE;
    barrier.Transition.StateAfter = D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    gpu.commands->ResourceBarrier(1, &barrier);
    gpu.submit();
    return stats;
}

void setCreateParameters(NVSDK_NGX_Parameter* params, UINT width, UINT height, int flags) {
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_Width, width);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_Height, height);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_OutWidth, width);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_OutHeight, height);
    ngx_smoke_set_int(params, NVSDK_NGX_Parameter_PerfQualityValue,
                      static_cast<int>(NVSDK_NGX_PerfQuality_Value_Balanced));
    ngx_smoke_set_int(params, NVSDK_NGX_Parameter_DLSS_Feature_Create_Flags, flags);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_CreationNodeMask, 1u);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_VisibilityNodeMask, 1u);
}

void setEvaluationParameters(NVSDK_NGX_Parameter* params,
                             ID3D12Resource* color, ID3D12Resource* output,
                             ID3D12Resource* depth, ID3D12Resource* motion,
                             ID3D12Resource* exposure, UINT width, UINT height,
                             float preExposure, float exposureScale, bool setExposureScale,
                             float jitterX, float jitterY, int reset) {
    ngx_smoke_set_resource(params, NVSDK_NGX_Parameter_Color, color);
    ngx_smoke_set_resource(params, NVSDK_NGX_Parameter_Output, output);
    ngx_smoke_set_resource(params, NVSDK_NGX_Parameter_Depth, depth);
    ngx_smoke_set_resource(params, NVSDK_NGX_Parameter_MotionVectors, motion);
    ngx_smoke_set_resource(params, NVSDK_NGX_Parameter_ExposureTexture, exposure);
    ngx_smoke_set_float(params, NVSDK_NGX_Parameter_Jitter_Offset_X, jitterX);
    ngx_smoke_set_float(params, NVSDK_NGX_Parameter_Jitter_Offset_Y, jitterY);
    ngx_smoke_set_int(params, NVSDK_NGX_Parameter_Reset, reset);
    ngx_smoke_set_float(params, NVSDK_NGX_Parameter_MV_Scale_X, 1.0f);
    ngx_smoke_set_float(params, NVSDK_NGX_Parameter_MV_Scale_Y, 1.0f);
    ngx_smoke_set_float(params, NVSDK_NGX_Parameter_DLSS_Pre_Exposure, preExposure);
    if (setExposureScale) ngx_smoke_set_float(params, NVSDK_NGX_Parameter_DLSS_Exposure_Scale, exposureScale);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Width, width);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_DLSS_Render_Subrect_Dimensions_Height, height);
}


void verifyEvaluationParameters(const NVSDK_NGX_Parameter* params,
                                ID3D12Resource* color, ID3D12Resource* output,
                                ID3D12Resource* depth, ID3D12Resource* motion,
                                ID3D12Resource* exposure, float preExposure,
                                float exposureScale, bool hasExposureScale) {
    const struct { const char* name; ID3D12Resource* expected; } resources[] = {
        {NVSDK_NGX_Parameter_Color, color},
        {NVSDK_NGX_Parameter_Output, output},
        {NVSDK_NGX_Parameter_Depth, depth},
        {NVSDK_NGX_Parameter_MotionVectors, motion},
        {NVSDK_NGX_Parameter_ExposureTexture, exposure},
    };
    for (const auto& resource : resources) {
        ID3D12Resource* actual = nullptr;
        const NVSDK_NGX_Result result = ngx_smoke_get_resource(params, resource.name, &actual);
        if (resource.expected == nullptr) {
            if (!NVSDK_NGX_FAILED(result) && actual != nullptr) fail("unexpected resource parameter");
        } else if (NVSDK_NGX_FAILED(result) || actual != resource.expected) {
            fail("resource parameter ABI mismatch", result);
        }
    }
    float actualPreExposure = 0;
    NVSDK_NGX_Result result = ngx_smoke_get_float(
        params, NVSDK_NGX_Parameter_DLSS_Pre_Exposure, &actualPreExposure);
    if (NVSDK_NGX_FAILED(result) || actualPreExposure != preExposure) {
        fail("PreExposure parameter ABI mismatch", result);
    }
    float actualScale = 0;
    result = ngx_smoke_get_float(params, NVSDK_NGX_Parameter_DLSS_Exposure_Scale, &actualScale);
    if (hasExposureScale) {
        if (NVSDK_NGX_FAILED(result) || actualScale != exposureScale) {
            fail("Exposure.Scale parameter ABI mismatch", result);
        }
    } else if (!NVSDK_NGX_FAILED(result)) {
        fail("omitted Exposure.Scale unexpectedly present", result);
    }
}

} // namespace

int main() {
    constexpr UINT renderWidth = 64;
    constexpr UINT renderHeight = 64;
    constexpr UINT outputWidth = 128;
    constexpr UINT outputHeight = 128;
    constexpr UINT inputTextureWidth = outputWidth;
    constexpr UINT inputTextureHeight = outputHeight;
    std::fprintf(stderr, "NGX_SMOKE_PHASE load\n");
    HMODULE module = LoadLibraryW(L"nvngx.dll");
    if (module == nullptr) fail("LoadLibrary(nvngx.dll)", GetLastError());
    const auto init = load<Init>(module, "NVSDK_NGX_D3D12_Init");
    const auto shutdown = load<Shutdown>(module, "NVSDK_NGX_D3D12_Shutdown");
    const auto getParameters = load<GetParameters>(module, "NVSDK_NGX_D3D12_GetParameters");
    const auto createFeature = load<CreateFeature>(module, "NVSDK_NGX_D3D12_CreateFeature");
    const auto evaluateFeature = load<EvaluateFeature>(module, "NVSDK_NGX_D3D12_EvaluateFeature");
    const auto releaseFeature = load<ReleaseFeature>(module, "NVSDK_NGX_D3D12_ReleaseFeature");

    Gpu gpu;
    wchar_t dataPath[MAX_PATH];
    if (GetTempPathW(MAX_PATH, dataPath) == 0) fail("GetTempPath", GetLastError());
    checkNgx(init(0x594141474c4e4758ull, dataPath, gpu.device.Get(), nullptr,
                  NVSDK_NGX_Version_API), "NGX init");

    NVSDK_NGX_Parameter* params = nullptr;
    checkNgx(getParameters(&params), "GetParameters");
    if (params == nullptr) fail("GetParameters returned null");
    setCreateParameters(params, renderWidth, renderHeight,
                        static_cast<int>(NVSDK_NGX_DLSS_Feature_Flags_MVLowRes |
                                         NVSDK_NGX_DLSS_Feature_Flags_IsHDR));
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_OutWidth, outputWidth);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_OutHeight, outputHeight);

    auto color = makeTexture(gpu, inputTextureWidth, inputTextureHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                             D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    auto depth = makeTexture(gpu, inputTextureWidth, inputTextureHeight, DXGI_FORMAT_R32_FLOAT,
                             D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    auto motion = makeTexture(gpu, inputTextureWidth, inputTextureHeight, DXGI_FORMAT_R16G16_FLOAT,
                              D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    auto exposureHalf = makeTexture(gpu, 1, 1, DXGI_FORMAT_R16_FLOAT,
                                    D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    auto exposureOneAndHalf = makeTexture(gpu, 1, 1, DXGI_FORMAT_R16_FLOAT,
                                          D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    auto output = makeTexture(gpu, outputWidth, outputHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                              D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,
                              D3D12_RESOURCE_STATE_UNORDERED_ACCESS);

    std::vector<std::uint16_t> colorPixels(static_cast<std::size_t>(inputTextureWidth) * inputTextureHeight * 4);
    for (UINT y = 0; y < inputTextureHeight; ++y) {
        for (UINT x = 0; x < inputTextureWidth; ++x) {
            const float value = ((x / 8 + y / 8) & 1) ? 0.25f : 0.5f;
            const std::size_t index = (static_cast<std::size_t>(y) * inputTextureWidth + x) * 4;
            colorPixels[index] = half(value);
            colorPixels[index + 1] = half(value);
            colorPixels[index + 2] = half(value);
            colorPixels[index + 3] = half(1.0f);
        }
    }
    std::vector<std::uint16_t> constantPixels(static_cast<std::size_t>(inputTextureWidth) * inputTextureHeight * 4);
    for (std::size_t index = 0; index < constantPixels.size(); index += 4) {
        constantPixels[index] = half(0.375f);
        constantPixels[index + 1] = half(0.375f);
        constantPixels[index + 2] = half(0.375f);
        constantPixels[index + 3] = half(1.0f);
    }
    auto constantColor = makeTexture(gpu, inputTextureWidth, inputTextureHeight, DXGI_FORMAT_R16G16B16A16_FLOAT,
                                     D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATE_COPY_DEST);
    std::vector<float> depthPixels(static_cast<std::size_t>(inputTextureWidth) * inputTextureHeight, 0.5f);
    std::vector<std::uint16_t> motionPixels(static_cast<std::size_t>(inputTextureWidth) * inputTextureHeight * 2, half(0.0f));
    const std::uint16_t exposureHalfBits = half(0.5f);
    const std::uint16_t exposureOneAndHalfBits = half(1.5f);
    const float exposureHalfValue = 0.5f;
    const float exposureOneAndHalfValue = 1.5f;
    uploadTexture(gpu, color.Get(), colorPixels.data(), inputTextureWidth * 8);
    uploadTexture(gpu, constantColor.Get(), constantPixels.data(), inputTextureWidth * 8);
    uploadTexture(gpu, depth.Get(), depthPixels.data(), inputTextureWidth * 4);
    uploadTexture(gpu, motion.Get(), motionPixels.data(), inputTextureWidth * 4);
    uploadTexture(gpu, exposureHalf.Get(), &exposureHalfBits, 2);
    uploadTexture(gpu, exposureOneAndHalf.Get(), &exposureOneAndHalfBits, 2);
    const float verifiedHalf = readExposureTexture(gpu, exposureHalf.Get());
    const float verifiedOneAndHalf = readExposureTexture(gpu, exposureOneAndHalf.Get());
    if (verifiedHalf != exposureHalfValue || verifiedOneAndHalf != exposureOneAndHalfValue) {
        fail("exposure texture GPU readback mismatch");
    }

    gpu.begin();
    std::fprintf(stderr, "NGX_SMOKE_PHASE create\n");
    NVSDK_NGX_Handle* handle = nullptr;
    checkNgx(createFeature(gpu.commands.Get(), NVSDK_NGX_Feature_SuperSampling, params, &handle),
             "CreateFeature");
    if (handle == nullptr) fail("CreateFeature returned null");
    gpu.submit();
    gpu.begin();
    ngx_smoke_reset(params);
    setCreateParameters(params, renderWidth, renderHeight,
                        static_cast<int>(NVSDK_NGX_DLSS_Feature_Flags_MVLowRes |
                                         NVSDK_NGX_DLSS_Feature_Flags_IsHDR |
                                         NVSDK_NGX_DLSS_Feature_Flags_AutoExposure));
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_OutWidth, outputWidth);
    ngx_smoke_set_uint(params, NVSDK_NGX_Parameter_OutHeight, outputHeight);
    NVSDK_NGX_Handle* autoExposureHandle = nullptr;
    checkNgx(createFeature(gpu.commands.Get(), NVSDK_NGX_Feature_SuperSampling, params,
                           &autoExposureHandle), "CreateFeature auto exposure");
    if (autoExposureHandle == nullptr) fail("CreateFeature auto exposure returned null");
    gpu.submit();
    gpu.begin();

    struct Variant {
        const char* name;
        float preExposure;
        float exposureScale;
        bool setExposureScale;
        ID3D12Resource* exposure;
        bool autoExposure;
        bool constant;
        bool repeatExecute;
        float jitter;
        int reset;
    };
    const Variant variants[] = {
        {"missing-neutral", 1.0f, 1.0f, true, nullptr, false, true, true, 0.0f, 1},
        {"fallback-half", 1.0f, 0.5f, true, nullptr, false, true, false, 0.0f, 1},
        {"texture-half", 1.0f, 1.0f, true, exposureHalf.Get(), false, true, false, 0.0f, 1},
        {"fallback-one-and-half", 1.0f, 1.5f, true, nullptr, false, true, false, 0.0f, 1},
        {"texture-one-and-half", 1.0f, 1.0f, true, exposureOneAndHalf.Get(), false, true, false, 0.0f, 1},
        {"explicit-texture-scale-unmodified", 1.0f, 0.5f, true, exposureOneAndHalf.Get(), false, false, false, 0.25f, 1},
        {"auto-exposure-scale-unmodified", 1.0f, 0.5f, true, nullptr, true, false, false, -0.25f, 1},
        {"preexposure-frame-zero", 2.0f, 1.0f, true, nullptr, false, true, false, 0.0f, 1},
        {"preexposure-frame-one", 2.0f, 1.0f, true, nullptr, false, true, false, 0.25f, 0},
        {"omitted-neutral", 1.0f, 0.0f, false, nullptr, false, true, false, 0.0f, 1},
    };
    double fallbackHalfMean = std::numeric_limits<double>::quiet_NaN();
    double textureHalfMean = std::numeric_limits<double>::quiet_NaN();
    double fallbackOneAndHalfMean = std::numeric_limits<double>::quiet_NaN();
    double textureOneAndHalfMean = std::numeric_limits<double>::quiet_NaN();
    for (const Variant& variant : variants) {
        gpu.begin();
        ngx_smoke_reset(params);
        ID3D12Resource* input = variant.constant ? constantColor.Get() : color.Get();
        setEvaluationParameters(params, input, output.Get(), depth.Get(), motion.Get(),
                                variant.exposure, renderWidth, renderHeight, variant.preExposure,
                                variant.exposureScale, variant.setExposureScale,
                                variant.jitter, -variant.jitter, variant.reset);
        verifyEvaluationParameters(params, input, output.Get(), depth.Get(), motion.Get(),
                                   variant.exposure, variant.preExposure,
                                   variant.exposureScale, variant.setExposureScale);
        std::fprintf(stderr,
                     "NGX_SMOKE_PHASE evaluate name=%s preExposure=%.6g exposureScale=%.6g reset=%d jitter=(%.6g,%.6g)\n",
                     variant.name, variant.preExposure, variant.exposureScale, variant.reset,
                     variant.jitter, -variant.jitter);
        NVSDK_NGX_Handle* evaluationHandle = variant.autoExposure ? autoExposureHandle : handle;
        checkNgx(evaluateFeature(gpu.commands.Get(), evaluationHandle, params, nullptr),
                 "EvaluateFeature");
        if (variant.repeatExecute) {
            gpu.submit();
            std::fprintf(stderr, "NGX_SMOKE_PHASE repeat-execute name=%s\n", variant.name);
            gpu.executeClosed();
            gpu.begin();
        }
        const ReadbackStats stats = readOutput(gpu, output.Get(), outputWidth, outputHeight);
        if (!(stats.mean >= -0.01 && stats.mean <= 16.0) ||
            !(stats.maximumDeviation <= 16.0)) fail("implausible output");
        if (variant.constant &&
            (std::abs(stats.mean - 0.375) > 0.02 || stats.maximumDeviation > 0.02)) {
            fail("constant-color output was not restored");
        }
        if (std::strcmp(variant.name, "fallback-half") == 0) fallbackHalfMean = stats.mean;
        if (std::strcmp(variant.name, "texture-half") == 0) textureHalfMean = stats.mean;
        if (std::strcmp(variant.name, "fallback-one-and-half") == 0) fallbackOneAndHalfMean = stats.mean;
        if (std::strcmp(variant.name, "texture-one-and-half") == 0) textureOneAndHalfMean = stats.mean;
        std::printf("NGX_SMOKE_RESULT name=%s finite=%zu mean=%.9g maxDeviation=%.9g\n",
                    variant.name, stats.finite, stats.mean, stats.maximumDeviation);
    }
    gpu.begin();
    std::fprintf(stderr, "NGX_SMOKE_PHASE discard-after-executed-cases\n");
    ngx_smoke_reset(params);
    setEvaluationParameters(params, constantColor.Get(), output.Get(), depth.Get(), motion.Get(),
                            nullptr, renderWidth, renderHeight, 1.0f, 0.5f, true,
                            0.0f, 0.0f, 1);
    verifyEvaluationParameters(params, constantColor.Get(), output.Get(), depth.Get(),
                               motion.Get(), nullptr, 1.0f, 0.5f, true);
    checkNgx(evaluateFeature(gpu.commands.Get(), handle, params, nullptr),
             "EvaluateFeature discard-after-executed-cases");
    check(gpu.commands->Close(), "Close discarded command list");

    const auto equivalent = [](double fallback, double explicitTexture) {
        return std::abs(fallback - explicitTexture) <=
            0.03 + 0.1 * std::max(std::abs(fallback), std::abs(explicitTexture));
    };
    if (!equivalent(fallbackHalfMean, textureHalfMean) ||
        !equivalent(fallbackOneAndHalfMean, textureOneAndHalfMean)) {
        fail("experimental fallback does not match explicit exposure texture");
    }

    checkNgx(releaseFeature(autoExposureHandle), "ReleaseFeature auto exposure");
    checkNgx(releaseFeature(handle), "ReleaseFeature");
    checkNgx(shutdown(), "Shutdown");
    FreeLibrary(module);
    std::puts("NGX_SMOKE_PASS");
    return 0;
}
