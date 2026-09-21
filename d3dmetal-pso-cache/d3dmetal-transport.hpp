#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <variant>
#include <type_traits>
#include <utility>

namespace yaagl::pso::fsr::framegeneration {
class PreparedFrame;
class ExecutionLease;
}

namespace yaagl::pso::metalfx {
class PreparedFrame;
class ExecutionLease;
}

namespace yaagl::pso::d3dmetal {

enum class CommandListKind : std::uint8_t {
    unsupported = 0,
    mpl = 1,
    legacy = 2,
};

// Native MPL view descriptor.  Keep this layout exact: D3DMetal passes it in
// the last two integer argument registers to BeginUseTexture/EndUseTexture.
struct TextureView {
    std::uint16_t firstMip = 0;
    std::uint16_t mipCount = 1;
    std::uint16_t firstSlice = 0;
    std::uint16_t sliceCount = 1;
    std::uint8_t planes = 1;
    std::uint8_t padding[7]{};
};
static_assert(sizeof(TextureView) == 16);

// A +1 Objective-C reference to the exact Metal texture view returned by
// D3DMetal's own D3D12 resource bridge.  releaseResource() consumes it.
struct MetalResource {
    void* texture = nullptr;
    TextureView view{};
};

// RAII is explicit because this header is consumed by both C++ and ObjC++.
// qiOwner is the temporary private D3DMetal interface acquired while unwrapping
// the public ID3D12GraphicsCommandList.  releaseCommandList() balances it.
struct NativeCommandList {
    CommandListKind kind = CommandListKind::unsupported;
    void* wrapper = nullptr;
    void* list = nullptr;
    void* allocator = nullptr;
    // Borrowed from the active MPLContext. The independent backend retains
    // these when it creates a Feature; they are valid while this command list
    // transport is held.
    void* device = nullptr;
    void* compiler = nullptr;
    void* qiOwner = nullptr;
};

enum class ResourceAccess : std::uint8_t {
    read = 0,
    write = 1,
};

struct ResourceUse {
    const MetalResource* resource = nullptr;
    ResourceAccess access = ResourceAccess::read;
};

struct PreparedWork {
    using Variant = std::variant<
        std::monostate,
        std::shared_ptr<const metalfx::PreparedFrame>,
        std::shared_ptr<const fsr::framegeneration::PreparedFrame>>;

    Variant value{};

    PreparedWork() = default;
    PreparedWork(std::shared_ptr<const metalfx::PreparedFrame> frame) noexcept
        : value(std::move(frame)) {}
    PreparedWork(std::shared_ptr<const fsr::framegeneration::PreparedFrame> frame) noexcept
        : value(std::move(frame)) {}

    explicit operator bool() const noexcept {
        return std::visit([](const auto& frame) noexcept {
            using T = std::decay_t<decltype(frame)>;
            if constexpr (std::is_same_v<T, std::monostate>) return false;
            else return static_cast<bool>(frame);
        }, value);
    }

    void reset() noexcept { value = std::monostate{}; }
};

struct RecordRequest {
    PreparedWork prepared;
    const ResourceUse* resources = nullptr;
    std::size_t resourceCount = 0;
    std::uint64_t featureID = 0;
    std::uint64_t evaluationID = 0;
};

// Pins every private D3DMetal code/data contract used below.  Passing nullptr
// locates D3DMetal from MPLCreateContext in the current process.
bool initialize(const void* d3dmetalImageBase = nullptr) noexcept;
bool available() noexcept;

// Public DX12 command-list -> private MPL/legacy transport.  MPL returns the
// current IMPLCommandList and IMPLCommandAllocator.  Legacy is identified but
// intentionally has no custom replay transport in this implementation.
bool unwrapCommandList(void* d3d12CommandList, NativeCommandList& out) noexcept;
void releaseCommandList(NativeCommandList& commandList) noexcept;

// Use D3DMetal's native D3D12 resource bridge.  The temporary D3D12Texture COM
// ownership is balanced before return; the Metal texture itself is retained.
bool mapResource(void* d3d12Resource, MetalResource& out) noexcept;
void releaseResource(MetalResource& resource) noexcept;

// Records one immutable custom temporal command through MPL's normal compute
// scheduler.  The supplied prepared object is retained once and is released
// when the D3D12 command allocator can legally reset.
bool record(NativeCommandList& commandList, const RecordRequest& request) noexcept;

// Called first from the existing ReplayTemporalScaleMPL hook.  A true result
// from isRecordedCommand() means the native TemporalScale parser must not run.
bool isRecordedCommand(const void* command) noexcept;
bool replay(void* mplReplayer, const void* command) noexcept;

} // namespace yaagl::pso::d3dmetal
