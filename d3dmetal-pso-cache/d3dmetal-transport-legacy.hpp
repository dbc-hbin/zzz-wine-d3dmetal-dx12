#pragma once

#include "d3dmetal-transport.hpp"

#include <cstdint>

namespace yaagl::pso::d3dmetal::legacy {

struct ResourceMetadata {
    std::uint32_t dxgiFormat = 0;
    std::uint32_t resourceFlags = 0;

    bool allowsUnorderedAccess() const noexcept {
        return (resourceFlags & 0x4u) != 0;
    }
};

// Pins the GPTK 4.0b2 legacy MTL3 command transport. Passing nullptr locates
// D3DMetal through MPLCreateContext, matching the primary transport helper.
bool initialize(const void* d3dmetalImageBase = nullptr) noexcept;
bool available() noexcept;

// Completes the legacy half of d3dmetal::unwrapCommandList(). The primary
// helper identifies D3D12GraphicsCommandListMTL and owns its private interface;
// this resolves its D3DMCommandListMTL, allocator and actual MTLDevice.
bool resolveCommandList(NativeCommandList& commandList) noexcept;

// Mirrors D3D12Texture::GetDesc without calling a public Windows ABI method.
// The returned values are the original DXGI_FORMAT and D3D12_RESOURCE_FLAGS,
// before D3DMetal chooses a Metal view. The temporary native resource owner is
// balanced inside this call.
bool queryResourceMetadata(void* d3d12Resource, ResourceMetadata& out) noexcept;

// Reserve the native legacy temporal opcode as a carrier, replace only its
// payload with our private tag/owner, and retain that owner through the native
// D3DMCommandAllocator resource lifetime list.
bool record(NativeCommandList& commandList, const RecordRequest& request) noexcept;

// Prime's legacy EncodeTemporallyScaleMTLFX hook must branch on this before the
// original command parser. Once true, replay() owns the command; never fall
// through to the native temporal parser even if replay() reports failure.
bool isRecordedCommand(const void* command) noexcept;
bool replay(void* d3dmCommandEncoder, const void* command) noexcept;

} // namespace yaagl::pso::d3dmetal::legacy
