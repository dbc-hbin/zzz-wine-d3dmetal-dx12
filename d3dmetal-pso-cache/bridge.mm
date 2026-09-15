#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <fcntl.h>
#include <limits.h>
#include <unistd.h>

#include <array>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <new>
#include <string>

#include "cache.hpp"
#include "function-cache.hpp"
#include "function-hooks.hpp"
#include "key.hpp"
#include "layout.hpp"
#include "ngx-hooks.hpp"
#include "persistent-cache.hpp"
#include "rt-key.hpp"
#include "stage-cache.hpp"

namespace yaagl::pso {
namespace {

using CreateNative = id (*)(const void*, id, std::uint64_t, id*, NSError**);
using GetRender = id (*)(const void*, std::uint32_t, std::uint64_t);
using CompileCompute = void (*)(const void*, bool);
using DestroyDevice = void (*)(const void*, const void*);
constexpr std::size_t kHookCount = static_cast<std::size_t>(layout::Hook::Count);
std::array<std::uintptr_t, kHookCount> originalFunctions{};
std::array<std::uintptr_t, kHookCount> dispatchTable{};
thread_local Context currentContext{};
thread_local FunctionContext currentFunctionContext{};
std::uintptr_t functionImageBase = 0;

struct ContextScope final {
    explicit ContextScope(const Context& next) noexcept : previous(currentContext) {
        currentContext = next;
    }
    ~ContextScope() { currentContext = previous; }
    Context previous;
};

struct FunctionContextScope final {
    explicit FunctionContextScope(const FunctionContext& next) noexcept
        : previous(currentFunctionContext) {
        currentFunctionContext = next;
    }
    ~FunctionContextScope() { currentFunctionContext = previous; }
    FunctionContext previous;
};

#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
struct ProbeCounters final {
    std::atomic<std::uint64_t> requests{0};
    std::atomic<std::uint64_t> creates{0};
    std::atomic<std::uint64_t> reuses{0};
};
#endif

struct Runtime final {
    Cache cache;
    FunctionCache functions;

#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
    Runtime() {
        const char* path = std::getenv("YAAGL_NATIVE_PSO_CACHE_PROBE");
        if (path != nullptr && path[0] == '/' && std::strlen(path) < PATH_MAX - 64) {
            probePath = path;
            const char* bypass = std::getenv("YAAGL_NATIVE_PSO_CACHE_PROBE_BYPASS");
            probeBypass = bypass != nullptr && std::strcmp(bypass, "1") == 0;
        }
    }

    ~Runtime() { publishProbe(); }

    void publishProbe() noexcept {
        if (probePath.empty()) return;
        try {
            std::lock_guard lock(probeMutex);
            if (counters[0].requests.load(std::memory_order_relaxed) == 0 &&
                counters[1].requests.load(std::memory_order_relaxed) == 0 &&
                counters[2].requests.load(std::memory_order_relaxed) == 0 &&
                functionCounters.requests.load(std::memory_order_relaxed) == 0) return;
            char payload[1024];
            const int length = std::snprintf(payload, sizeof(payload),
                "{\"schemaVersion\":2,\"active\":true,\"pid\":%d,"
                "\"renderRequests\":%llu,\"renderCreates\":%llu,\"renderReuses\":%llu,"
                "\"computeRequests\":%llu,\"computeCreates\":%llu,\"computeReuses\":%llu,"
                "\"rtRequests\":%llu,\"rtCreates\":%llu,\"rtReuses\":%llu,"
                "\"functionRequests\":%llu,\"functionCreates\":%llu,"
                "\"functionReuses\":%llu,\"functionBypasses\":%llu}\n",
                getpid(),
                static_cast<unsigned long long>(counters[0].requests.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(counters[0].creates.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(counters[0].reuses.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(counters[1].requests.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(counters[1].creates.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(counters[1].reuses.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(counters[2].requests.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(counters[2].creates.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(counters[2].reuses.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(functionCounters.requests.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(functionCounters.creates.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(functionCounters.reuses.load(std::memory_order_relaxed)),
                static_cast<unsigned long long>(functionBypasses.load(std::memory_order_relaxed)));
            if (length < 0 || static_cast<std::size_t>(length) >= sizeof(payload)) return;
            char temporary[PATH_MAX];
            const int pathLength = std::snprintf(temporary, sizeof(temporary), "%s.tmp.%d.%llu",
                probePath.c_str(), getpid(), static_cast<unsigned long long>(++probeSequence));
            if (pathLength < 0 || static_cast<std::size_t>(pathLength) >= sizeof(temporary)) return;
            const int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (fd < 0) return;
            std::size_t written = 0;
            while (written < static_cast<std::size_t>(length)) {
                const ssize_t count = write(fd, payload + written, static_cast<std::size_t>(length) - written);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                written += static_cast<std::size_t>(count);
            }
            const bool closed = close(fd) == 0;
            if (written != static_cast<std::size_t>(length) || !closed ||
                rename(temporary, probePath.c_str()) != 0) {
                unlink(temporary);
            }
        } catch (...) {
            // Explicit probe output must never change native compilation semantics.
        }
    }

    std::string probePath;
    bool probeBypass = false;
    std::array<ProbeCounters, 3> counters;
    ProbeCounters functionCounters;
    std::atomic<std::uint64_t> functionBypasses{0};
    std::mutex probeMutex;
    std::uint64_t probeSequence = 0;
#else
    void publishProbe() noexcept {}
#endif
};

Runtime& runtime() {
    static Runtime value;
    return value;
}

struct Invocation final {
    CreateNative original;
    const void* device;
    id descriptor;
    std::uint64_t options;
    bool reflectionRequested;
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
    ProbeCounters* counters;
    bool created = false;
#endif

    NativeResult create() {
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
        created = true;
        if (counters != nullptr) counters->creates.fetch_add(1, std::memory_order_relaxed);
#endif
        id reflection = nil;
        NSError* error = nil;
        id state = original(device, descriptor, options,
            reflectionRequested ? &reflection : nullptr, &error);
        return NativeResult(state, reflection, error);
    }
};

id createPipeline(Api api, const void* device, id descriptor, std::uint64_t options,
                  id* reflection, NSError** error) {
    const auto original = reinterpret_cast<CreateNative>(originalFunctions[static_cast<std::size_t>(api)]);
    if (api == Api::Metal4Render) {
        if (@available(macOS 26.0, *)) {
            MTL4PipelineOptions* effective = [(MTL4RenderPipelineDescriptor*)descriptor options];
            effective.shaderReflection = static_cast<MTL4ShaderReflection>(effective.shaderReflection | 1);
        }
    }

    Key key;
    bool recognized = false;
    bool keyAllocationFailed = false;
    try {
        @try {
            recognized = makeKey(api, device, descriptor, options, reflection != nullptr, currentContext, key);
        } @catch (NSException* exception) {
            if (![exception.name isEqualToString:NSMallocException]) @throw;
            keyAllocationFailed = true;
        }
    } catch (const std::bad_alloc&) {
        keyAllocationFailed = true;
    }
    if (keyAllocationFailed || !recognized) {
        return original(device, descriptor, options, reflection, error);
    }

    Runtime& state = runtime();
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
    ProbeCounters* counters = nullptr;
    if (!state.probePath.empty()) {
        const std::size_t category = api != Api::Compute ? 0 :
            (currentContext.kind == ContextKind::Compute ? 1 : 2);
        counters = &state.counters[category];
        counters->requests.fetch_add(1, std::memory_order_relaxed);
    }
    Invocation invocation{original, device, descriptor, options, reflection != nullptr, counters};
    NativeResult result = state.probeBypass ? invocation.create() :
        state.cache.getOrCreate(device, key.bytes, key.resources, [&invocation] { return invocation.create(); });
    if (counters != nullptr && !invocation.created) {
        counters->reuses.fetch_add(1, std::memory_order_relaxed);
    }
#else
    Invocation invocation{original, device, descriptor, options, reflection != nullptr};
    NativeResult result = state.cache.getOrCreate(
        device, key.bytes, key.resources, [&invocation] { return invocation.create(); });
#endif
    if (reflection != nullptr) *reflection = [result.takeReflection() autorelease];
    if (error != nullptr) *error = [result.takeError() autorelease];
    state.publishProbe();
    return result.takeState();
}

id createMetal4Render(const void* device, id descriptor, std::uint64_t options, id* reflection, NSError** error) {
    return createPipeline(Api::Metal4Render, device, descriptor, options, reflection, error);
}
id createRender(const void* device, id descriptor, std::uint64_t options, id* reflection, NSError** error) {
    return createPipeline(Api::Render, device, descriptor, options, reflection, error);
}
id createMesh(const void* device, id descriptor, std::uint64_t options, id* reflection, NSError** error) {
    return createPipeline(Api::Mesh, device, descriptor, options, reflection, error);
}
id createCompute(const void* device, id descriptor, std::uint64_t options, id* reflection, NSError** error) {
    return createPipeline(Api::Compute, device, descriptor, options, reflection, error);
}

struct ExtractionInvocation final {
    ExtractFunctionsEntry original;
    std::uintptr_t ignoredDevice;
    id library;
    std::uintptr_t rawFlag;
    const void* reflection;
    std::uintptr_t ignoredNames;
    MTLFunctionConstantValues* constants;
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
    ProbeCounters* counters;
    bool created = false;
#endif

    static FunctionResult create(void* opaque) {
        auto& call = *static_cast<ExtractionInvocation*>(opaque);
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
        call.created = true;
        if (call.counters != nullptr) call.counters->creates.fetch_add(1, std::memory_order_relaxed);
#endif
        NSMutableArray* functions = nil;
        call.original(&functions, call.ignoredDevice, call.library, call.rawFlag,
            call.reflection, call.ignoredNames, call.constants);
        // The pinned native helper discards the whole array on NSError. Other
        // exceptions propagate; a nonnil return is a complete extraction.
        return FunctionResult(functions, functions != nil);
    }
};

__attribute__((noinline)) void* extractFunctions(
    void* output, std::uintptr_t ignoredDevice, id library,
    std::uintptr_t rawFlag, const void* reflection,
    std::uintptr_t ignoredNames, MTLFunctionConstantValues* constants) {
    const auto caller = reinterpret_cast<std::uintptr_t>(
        __builtin_extract_return_addr(__builtin_return_address(0)));
    const auto original = reinterpret_cast<ExtractFunctionsEntry>(
        originalFunctions[static_cast<std::size_t>(layout::Hook::ExtractFunctions)]);
    Runtime& state = runtime();
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
    ProbeCounters* counters = state.probePath.empty() ? nullptr : &state.functionCounters;
    if (counters != nullptr) counters->requests.fetch_add(1, std::memory_order_relaxed);
    ExtractionInvocation invocation {original, ignoredDevice, library, rawFlag,
        reflection, ignoredNames, constants, counters};
#else
    ExtractionInvocation invocation {original, ignoredDevice, library, rawFlag,
        reflection, ignoredNames, constants};
#endif
    KeyBytes key;
    const void* device = nullptr;
    bool recognized = false;
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
    if (!state.probeBypass && functionImageBase != 0 && caller >= functionImageBase) {
#else
    if (functionImageBase != 0 && caller >= functionImageBase) {
#endif
        try {
            recognized = makeFunctionExtractionKey(library, rawFlag, reflection, constants,
                caller - functionImageBase, currentFunctionContext, key, device);
        } catch (const std::bad_alloc&) {
            // A cache-key allocation must not replace the native operation.
        }
    }
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
    if (!recognized && counters != nullptr) {
        state.functionBypasses.fetch_add(1, std::memory_order_relaxed);
    }
#endif
    FunctionResult result = recognized ? state.functions.getOrCreate(
        device, key, library, &ExtractionInvocation::create, &invocation) :
        ExtractionInvocation::create(&invocation);
#ifdef YAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS
    if (counters != nullptr && !invocation.created) {
        counters->reuses.fetch_add(1, std::memory_order_relaxed);
    }
#endif
    NSMutableArray* functions = result.takeFunctions();
    std::memcpy(output, &functions, sizeof(functions));
    state.publishProbe();
    return output;
}

void loadGraphicsFunctions(const void* owner, const void* stages) {
    const FunctionContextScope scope({ContextKind::Graphics, owner, stages});
    const auto original = reinterpret_cast<LoadGraphicsFunctionsEntry>(
        originalFunctions[static_cast<std::size_t>(layout::Hook::LoadGraphicsFunctions)]);
    original(owner, stages);
}

id getRender(const void* owner, std::uint32_t dynamicFlags, std::uint64_t formats) {
    const ContextScope scope({ContextKind::Graphics, owner, dynamicFlags, formats});
    const auto original = reinterpret_cast<GetRender>(originalFunctions[static_cast<std::size_t>(layout::Hook::GetRender)]);
    return original(owner, dynamicFlags, formats);
}

void compileCompute(const void* owner, bool indirect) {
    const ContextScope scope({ContextKind::Compute, owner, static_cast<std::uint32_t>(indirect), 0});
    const FunctionContextScope functionScope({ContextKind::Compute, owner, nullptr});
    const auto original = reinterpret_cast<CompileCompute>(originalFunctions[static_cast<std::size_t>(layout::Hook::CompileCompute)]);
    original(owner, indirect);
}

void destroyWithFunctionCacheRetired(const void* device, const void* vtt) {
    Runtime& state = runtime();
    const auto original = reinterpret_cast<DestroyDevice>(originalFunctions[static_cast<std::size_t>(layout::Hook::DestroyDevice)]);
    state.cache.withDeviceRetired(device, original, vtt);
}

void destroyDevice(const void* device, const void* vtt) {
    Runtime& state = runtime();
    state.functions.withDeviceRetired(device, &destroyWithFunctionCacheRetired, vtt);
    state.publishProbe();
}

bool matchesImage(const mach_header* untyped) noexcept {
    if (untyped->magic != MH_MAGIC_64 || untyped->cputype != CPU_TYPE_X86_64 ||
        untyped->filetype != MH_DYLIB) return false;
    const auto* header = reinterpret_cast<const mach_header_64*>(untyped);
    if (header->ncmds != layout::kCommandCount || header->sizeofcmds != layout::kCommandsSize ||
        sizeof(*header) + header->sizeofcmds > layout::kFirstTextOffset) return false;
    const auto* base = reinterpret_cast<const std::uint8_t*>(header);
    std::size_t position = sizeof(*header);
    bool uuidMatches = false;
    bool textMatches = false;
    bool slotWritable = false;
    for (std::uint32_t index = 0; index < header->ncmds; ++index) {
        if (position + sizeof(load_command) > sizeof(*header) + header->sizeofcmds) return false;
        const auto* command = reinterpret_cast<const load_command*>(base + position);
        if (command->cmdsize < sizeof(load_command) || (command->cmdsize & 7) != 0 ||
            command->cmdsize > sizeof(*header) + header->sizeofcmds - position) return false;
        if (command->cmd == LC_UUID && command->cmdsize == sizeof(uuid_command)) {
            const auto* uuid = reinterpret_cast<const uuid_command*>(command);
            if (uuidMatches || std::memcmp(uuid->uuid, layout::kUuid, sizeof(layout::kUuid)) != 0) return false;
            uuidMatches = true;
        }
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(segment_command_64)) {
            const auto* segment = reinterpret_cast<const segment_command_64*>(command);
            if (std::strncmp(segment->segname, "__TEXT", sizeof(segment->segname)) == 0) {
                textMatches = segment->vmaddr == 0 && segment->vmsize == 0x4ae000 &&
                    segment->fileoff == 0 && segment->filesize == 0x4ae000 && segment->initprot == 5;
            } else if (std::strncmp(segment->segname, "__DATA", sizeof(segment->segname)) == 0) {
                slotWritable = segment->vmaddr <= layout::kDataSlot &&
                    layout::kDataSlot + sizeof(std::uintptr_t) <= segment->vmaddr + segment->vmsize &&
                    segment->initprot == 3;
            }
        }
        position += command->cmdsize;
    }
    if (!uuidMatches || !textMatches || !slotWritable || position != sizeof(*header) + header->sizeofcmds) return false;
    const auto* common = reinterpret_cast<const section_64*>(base + layout::kCommonSectionOffset);
    if (std::strncmp(common->sectname, "__common", sizeof(common->sectname)) != 0 ||
        std::strncmp(common->segname, "__DATA", sizeof(common->segname)) != 0 ||
        common->addr != layout::kCommonAddress || common->size != layout::kCommonSize ||
        (common->flags & SECTION_TYPE) != S_ZEROFILL) return false;
    for (const auto& span : layout::kVerificationSpans) {
        if (std::memcmp(base + span.offset, span.bytes, span.size) != 0) return false;
    }
    auto& slot = *reinterpret_cast<std::uintptr_t*>(const_cast<std::uint8_t*>(base) + layout::kDataSlot);
    return std::atomic_ref<std::uintptr_t>(slot).load(std::memory_order_acquire) == 0;
}

__attribute__((constructor)) void initialize() noexcept {
    try {
        const std::uint8_t* base = nullptr;
        for (std::uint32_t index = 0; index < _dyld_image_count(); ++index) {
            const mach_header* header = _dyld_get_image_header(index);
            if (!matchesImage(header)) continue;
            if (base != nullptr) return;
            base = reinterpret_cast<const std::uint8_t*>(header);
        }
        if (base == nullptr) return;
        static_cast<void>(warmPersistentCachesFromEnvironment());
        static_cast<void>(runtime());
        for (std::size_t index = 0; index < kHookCount; ++index) {
            originalFunctions[index] = reinterpret_cast<std::uintptr_t>(base + layout::kTrampolines[index]);
        }
        const void* rtOriginals[] = {
            reinterpret_cast<const void*>(originalFunctions[7]),
            reinterpret_cast<const void*>(originalFunctions[8]),
            reinterpret_cast<const void*>(originalFunctions[9]),
            reinterpret_cast<const void*>(originalFunctions[10]),
        };
        const RtHookEntryPoints rt = initializeRtHooks(base, rtOriginals);
        if (rt.createFunction == nullptr || rt.createCombinedAnyHitIntersectionFunction == nullptr ||
            rt.createIntersectionWrapperFunction == nullptr || rt.getAndRetainLibrary == nullptr) return;
        const void* stageOriginals[] = {
            reinterpret_cast<const void*>(originalFunctions[11]),
            reinterpret_cast<const void*>(originalFunctions[12]),
            reinterpret_cast<const void*>(originalFunctions[13]),
            reinterpret_cast<const void*>(originalFunctions[14]),
        };
        const StageHookEntryPoints stage = initializeStageHooks(base, stageOriginals);
        if (stage.compileComputeStages == nullptr || stage.compileGraphicsStages == nullptr ||
            stage.createComputeStageKey == nullptr || stage.createGraphicsStageKey == nullptr) return;
        std::array<std::uintptr_t, ngx::kHookCount> ngxOriginals{};
        for (std::size_t index = 0; index < ngx::kHookCount; ++index) {
            ngxOriginals[index] = originalFunctions[17 + index];
        }
        const auto ngxHooks = ngx::initializeHooks(base, ngxOriginals);
        for (const auto hook : ngxHooks) {
            if (hook == 0) return;
        }
        functionImageBase = reinterpret_cast<std::uintptr_t>(base);
        dispatchTable = {
            reinterpret_cast<std::uintptr_t>(&createMetal4Render),
            reinterpret_cast<std::uintptr_t>(&createRender),
            reinterpret_cast<std::uintptr_t>(&createMesh),
            reinterpret_cast<std::uintptr_t>(&createCompute),
            reinterpret_cast<std::uintptr_t>(&getRender),
            reinterpret_cast<std::uintptr_t>(&compileCompute),
            reinterpret_cast<std::uintptr_t>(&destroyDevice),
            reinterpret_cast<std::uintptr_t>(rt.createFunction),
            reinterpret_cast<std::uintptr_t>(rt.createCombinedAnyHitIntersectionFunction),
            reinterpret_cast<std::uintptr_t>(rt.createIntersectionWrapperFunction),
            reinterpret_cast<std::uintptr_t>(rt.getAndRetainLibrary),
            reinterpret_cast<std::uintptr_t>(stage.compileComputeStages),
            reinterpret_cast<std::uintptr_t>(stage.compileGraphicsStages),
            reinterpret_cast<std::uintptr_t>(stage.createComputeStageKey),
            reinterpret_cast<std::uintptr_t>(stage.createGraphicsStageKey),
            reinterpret_cast<std::uintptr_t>(&extractFunctions),
            reinterpret_cast<std::uintptr_t>(&loadGraphicsFunctions),
            ngxHooks[0],
            ngxHooks[1],
            ngxHooks[2],
            ngxHooks[3],
            ngxHooks[4],
            ngxHooks[5],
            ngxHooks[6],
            ngxHooks[7],
        };
        auto& slot = *reinterpret_cast<std::uintptr_t*>(const_cast<std::uint8_t*>(base) + layout::kDataSlot);
        std::atomic_ref<std::uintptr_t>(slot).store(
            reinterpret_cast<std::uintptr_t>(dispatchTable.data()), std::memory_order_release);
    } catch (...) {
        // Unpublished gates retain the byte-for-byte original helper path.
    }
}

} // namespace
} // namespace yaagl::pso
