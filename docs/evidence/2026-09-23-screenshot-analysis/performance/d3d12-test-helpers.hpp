#pragma once

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d12.h>
#include <wrl/client.h>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <chrono>
#include <vector>

using Microsoft::WRL::ComPtr;

[[noreturn]] inline void fail(const char* what, long code = 0) {
    std::fprintf(stderr, "D3D12_TEST_FAIL %s code=0x%08lx\n", what,
                 static_cast<unsigned long>(code));
    std::exit(1);
}

inline void check(HRESULT hr, const char* what) {
    if (FAILED(hr)) fail(what, hr);
}

template<typename T>
T load(HMODULE module, const char* name) {
    const FARPROC address = GetProcAddress(module, name);
    if (!address) fail(name, GetLastError());
    T result{};
    static_assert(sizeof(result) == sizeof(address));
    std::memcpy(&result, &address, sizeof(result));
    return result;
}

inline std::uint16_t half(float value) {
    std::uint32_t bits{};
    std::memcpy(&bits, &value, sizeof(bits));
    const std::uint32_t sign = (bits >> 16) & 0x8000u;
    int exponent = static_cast<int>((bits >> 23) & 0xffu) - 127 + 15;
    std::uint32_t mantissa = bits & 0x7fffffu;
    if (exponent <= 0) {
        if (exponent < -10) return static_cast<std::uint16_t>(sign);
        mantissa = (mantissa | 0x800000u) >> (1 - exponent);
        return static_cast<std::uint16_t>(sign | ((mantissa + 0x1000u) >> 13));
    }
    if (exponent >= 31) return static_cast<std::uint16_t>(sign | 0x7c00u);
    return static_cast<std::uint16_t>(sign | (static_cast<std::uint32_t>(exponent) << 10) |
                                      ((mantissa + 0x1000u) >> 13));
}

inline float unhalf(std::uint16_t value) {
    const std::uint32_t sign = static_cast<std::uint32_t>(value & 0x8000u) << 16;
    std::uint32_t exponent = (value >> 10) & 0x1fu;
    std::uint32_t mantissa = value & 0x3ffu;
    std::uint32_t bits{};
    if (exponent == 0) {
        if (mantissa == 0) {
            bits = sign;
        } else {
            exponent = 113;
            while ((mantissa & 0x400u) == 0) {
                mantissa <<= 1;
                --exponent;
            }
            bits = sign | (exponent << 23) | ((mantissa & 0x3ffu) << 13);
        }
    } else if (exponent == 31) {
        bits = sign | 0x7f800000u | (mantissa << 13);
    } else {
        bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
    }
    float result{};
    std::memcpy(&result, &bits, sizeof(result));
    return result;
}

class Gpu final {
public:
    Gpu() {
        check(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&device)),
              "D3D12CreateDevice");
        D3D12_COMMAND_QUEUE_DESC description{};
        description.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        check(device->CreateCommandQueue(&description, IID_PPV_ARGS(&queue)),
              "CreateCommandQueue");
        check(device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)),
              "CreateFence");
        event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!event) fail("CreateEvent", GetLastError());
    }

    ~Gpu() {
        if (event) CloseHandle(event);
    }

    void begin() {
        allocator.Reset();
        list.Reset();
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,
                                              IID_PPV_ARGS(&allocator)),
              "CreateCommandAllocator");
        check(device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr,
                                        IID_PPV_ARGS(&list)),
              "CreateCommandList");
    }

    void close() { check(list->Close(), "Close command list"); }

    void executeClosed() {
        ID3D12CommandList* lists[] = {list.Get()};
        auto started = std::chrono::steady_clock::now();
        queue->ExecuteCommandLists(1, lists);
        const std::uint64_t value = ++fenceValue;
        check(queue->Signal(fence.Get(), value), "Signal");
        executeSignalMs = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - started).count();
        fenceArmMs = 0.0; fenceWaitMs = 0.0;
        if (fence->GetCompletedValue() < value) {
            started = std::chrono::steady_clock::now();
            check(fence->SetEventOnCompletion(value, event), "SetEventOnCompletion");
            fenceArmMs = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - started).count();
            started = std::chrono::steady_clock::now();
            if (WaitForSingleObject(event, 30000) != WAIT_OBJECT_0) fail("GPU timeout");
            fenceWaitMs = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - started).count();
        }
    }

    void submit() {
        close();
        executeClosed();
    }

    double executeSignalMs = 0.0;
    double fenceArmMs = 0.0;
    double fenceWaitMs = 0.0;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> list;

private:
    ComPtr<ID3D12Fence> fence;
    HANDLE event = nullptr;
    std::uint64_t fenceValue = 0;
};

inline D3D12_HEAP_PROPERTIES heapProps(D3D12_HEAP_TYPE type) {
    D3D12_HEAP_PROPERTIES properties{};
    properties.Type = type;
    properties.CreationNodeMask = 1;
    properties.VisibleNodeMask = 1;
    return properties;
}

inline D3D12_RESOURCE_DESC bufferDesc(UINT64 size) {
    D3D12_RESOURCE_DESC description{};
    description.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
    description.Width = size;
    description.Height = 1;
    description.DepthOrArraySize = 1;
    description.MipLevels = 1;
    description.SampleDesc.Count = 1;
    description.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
    return description;
}

inline ComPtr<ID3D12Resource> makeBuffer(Gpu& gpu, UINT64 size, D3D12_HEAP_TYPE heap,
                                         D3D12_RESOURCE_STATES state) {
    auto properties = heapProps(heap);
    auto description = bufferDesc(size);
    ComPtr<ID3D12Resource> result;
    check(gpu.device->CreateCommittedResource(&properties, D3D12_HEAP_FLAG_NONE, &description,
                                               state, nullptr, IID_PPV_ARGS(&result)),
          "CreateCommittedResource(buffer)");
    return result;
}

inline D3D12_RESOURCE_DESC textureDesc(UINT width, UINT height, DXGI_FORMAT format,
                                       D3D12_RESOURCE_FLAGS flags = D3D12_RESOURCE_FLAG_NONE) {
    D3D12_RESOURCE_DESC description{};
    description.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    description.Width = width;
    description.Height = height;
    description.DepthOrArraySize = 1;
    description.MipLevels = 1;
    description.Format = format;
    description.SampleDesc.Count = 1;
    description.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
    description.Flags = flags;
    return description;
}

inline ComPtr<ID3D12Resource> makeTexture(Gpu& gpu, UINT width, UINT height, DXGI_FORMAT format,
                                          D3D12_RESOURCE_FLAGS flags,
                                          D3D12_RESOURCE_STATES state,
                                          const D3D12_CLEAR_VALUE* clear = nullptr) {
    auto properties = heapProps(D3D12_HEAP_TYPE_DEFAULT);
    auto description = textureDesc(width, height, format, flags);
    ComPtr<ID3D12Resource> result;
    check(gpu.device->CreateCommittedResource(&properties, D3D12_HEAP_FLAG_NONE, &description,
                                               state, clear, IID_PPV_ARGS(&result)),
          "CreateCommittedResource(texture)");
    return result;
}

inline void transition(ID3D12GraphicsCommandList* list, ID3D12Resource* resource,
                       D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after) {
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = resource;
    barrier.Transition.StateBefore = before;
    barrier.Transition.StateAfter = after;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    list->ResourceBarrier(1, &barrier);
}

inline void uploadTexture(Gpu& gpu, ID3D12Resource* texture, const void* pixels,
                          std::size_t sourceRowBytes) {
    const auto description = texture->GetDesc();
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT rows = 0;
    UINT64 rowBytes = 0;
    UINT64 total = 0;
    gpu.device->GetCopyableFootprints(&description, 0, 1, 0, &footprint, &rows, &rowBytes, &total);
    auto upload = makeBuffer(gpu, total, D3D12_HEAP_TYPE_UPLOAD,
                             D3D12_RESOURCE_STATE_GENERIC_READ);
    std::uint8_t* mapped = nullptr;
    check(upload->Map(0, nullptr, reinterpret_cast<void**>(&mapped)), "Map texture upload");
    for (UINT y = 0; y < rows; ++y) {
        std::memcpy(mapped + footprint.Offset + y * footprint.Footprint.RowPitch,
                    static_cast<const std::uint8_t*>(pixels) + y * sourceRowBytes,
                    static_cast<std::size_t>(rowBytes));
    }
    upload->Unmap(0, nullptr);
    D3D12_TEXTURE_COPY_LOCATION destination{};
    destination.pResource = texture;
    destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION source{};
    source.pResource = upload.Get();
    source.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    source.PlacedFootprint = footprint;
    gpu.begin();
    gpu.list->CopyTextureRegion(&destination, 0, 0, 0, &source, nullptr);
    transition(gpu.list.Get(), texture, D3D12_RESOURCE_STATE_COPY_DEST,
               D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE);
    gpu.submit();
}

struct ReadbackTexture {
    ComPtr<ID3D12Resource> buffer;
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};
    UINT64 size = 0;
};

inline ReadbackTexture makeReadback(Gpu& gpu, ID3D12Resource* texture) {
    ReadbackTexture result;
    const auto description = texture->GetDesc();
    gpu.device->GetCopyableFootprints(&description, 0, 1, 0, &result.footprint, nullptr, nullptr,
                                      &result.size);
    result.buffer = makeBuffer(gpu, result.size, D3D12_HEAP_TYPE_READBACK,
                               D3D12_RESOURCE_STATE_COPY_DEST);
    return result;
}

inline void copyToReadback(ID3D12GraphicsCommandList* list, ID3D12Resource* source,
                           const ReadbackTexture& readback) {
    D3D12_TEXTURE_COPY_LOCATION sourceLocation{};
    sourceLocation.pResource = source;
    sourceLocation.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION destination{};
    destination.pResource = readback.buffer.Get();
    destination.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    destination.PlacedFootprint = readback.footprint;
    list->CopyTextureRegion(&destination, 0, 0, 0, &sourceLocation, nullptr);
}
