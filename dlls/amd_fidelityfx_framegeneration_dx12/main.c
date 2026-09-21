/*
 * FidelityFX frame-generation builtin.
 *
 * The native DLL owns every frame-interpolation swapchain.  Only the
 * interpolation workload is replaced; presentation, pacing and UI composition
 * remain in the native implementation.
 */
#define COBJMACROS

#include <stdbool.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "windef.h"
#include "winbase.h"
#include "objbase.h"
#include "d3d12.h"
#include "dxgi1_6.h"
#include "unixlib.h"

#include "../../d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api.h"
#include "../../d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/framegeneration/include/ffx_framegeneration.h"
#include "../../d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/framegeneration/include/dx12/ffx_api_framegeneration_dx12.h"

#define AUTOMATIC_PROVIDER_ID UINT64_C(0x5941474647000001)
#define METALFX_PROVIDER_ID   UINT64_C(0x4d46584647000001)
#define BACKEND_DX12_DESC_TYPE 2u
#define BRIDGE_INELIGIBLE 4u
#define MAX_DESCRIPTOR_CHAIN 64u

static const char automatic_provider_name[] =
    "Yaagl automatic frame generation (MetalFX or native FSR)";
static const char metalfx_provider_name[] = "MetalFX frame generation";

struct backend_dx12_desc
{
    ffxCreateContextDescHeader header;
    void *device;
};

/*
 * This is the stable SDK 2.1 interface, not the old concrete C++ class.
 *
 * IDXGISwapChain4 contributes its complete inherited vtable (41 entries).
 * The Microsoft C++ ABI then contributes one deleting-destructor entry.
 * The custom methods follow in their declaration order.  In particular,
 * setFrameGenerationConfig and waitForPresents are entries 54 and 55.
 *
 * Embedding the SDK's C IDXGISwapChain4Vtbl derives the inherited portion
 * rather than duplicating or guessing its offsets.  Unused custom methods
 * still have their real signatures.
 */
#if defined(__i386__)
# define FG_METHOD __attribute__((thiscall))
#else
# define FG_METHOD
#endif

struct stable_swapchain;

struct stable_swapchain_vtbl
{
    IDXGISwapChain4Vtbl dxgi;
    void *(FG_METHOD *deleting_destructor)(struct stable_swapchain *, unsigned int);
    void (FG_METHOD *present_passthrough)(struct stable_swapchain *, UINT, UINT);
    void (FG_METHOD *present_with_ui)(struct stable_swapchain *, UINT, UINT);
    void (FG_METHOD *dispatch_interpolation)(struct stable_swapchain *,
                                            struct FfxApiResource *,
                                            struct FfxApiResource *);
    void (FG_METHOD *present_interpolated)(struct stable_swapchain *, UINT, UINT);
    bool (FG_METHOD *verify_ui)(struct stable_swapchain *);
    void (FG_METHOD *copy_ui)(struct stable_swapchain *);
    bool (FG_METHOD *verify_backbuffers)(struct stable_swapchain *);
    bool (FG_METHOD *destroy_replacements)(struct stable_swapchain *);
    bool (FG_METHOD *kill_presenter)(struct stable_swapchain *);
    bool (FG_METHOD *spawn_presenter)(struct stable_swapchain *);
    void (FG_METHOD *discard_command_lists)(struct stable_swapchain *);
    IDXGISwapChain4 *(FG_METHOD *real)(struct stable_swapchain *);
    void (FG_METHOD *set_config)(struct stable_swapchain *, const FfxFrameGenerationConfig *);
    bool (FG_METHOD *wait_for_presents)(struct stable_swapchain *);
};

struct stable_swapchain
{
    const struct stable_swapchain_vtbl *lpVtbl;
};

typedef char check_swapchain4_vtable_size[
    sizeof(IDXGISwapChain4Vtbl) == 41 * sizeof(void *) ? 1 : -1];
typedef char check_config_slot[
    offsetof(struct stable_swapchain_vtbl, set_config) == 54 * sizeof(void *) ? 1 : -1];
typedef char check_wait_slot[
    offsetof(struct stable_swapchain_vtbl, wait_for_presents) == 55 * sizeof(void *) ? 1 : -1];

static const GUID stable_swapchain_iid =
{
    0x5f5fa2f5, 0x3bc5, 0x48d8,
    {0xa6, 0x3b, 0xe6, 0x03, 0x18, 0xe3, 0x80, 0x00}
};

struct native_api
{
    HMODULE module;
    ffxReturnCode_t (WINAPI *create)(ffxContext *, ffxCreateContextDescHeader *,
                                    const ffxAllocationCallbacks *);
    ffxReturnCode_t (WINAPI *destroy)(ffxContext *, const ffxAllocationCallbacks *);
    ffxReturnCode_t (WINAPI *configure)(ffxContext *, const ffxConfigureDescHeader *);
    ffxReturnCode_t (WINAPI *query)(ffxContext *, ffxQueryDescHeader *);
    ffxReturnCode_t (WINAPI *dispatch)(ffxContext *, const ffxDispatchDescHeader *);
};

static HINSTANCE builtin_instance;
static INIT_ONCE native_once = INIT_ONCE_STATIC_INIT;
static struct native_api native;
static DWORD callback_tls = TLS_OUT_OF_INDEXES;

enum context_mode
{
    CONTEXT_NATIVE,
    MODE_PENDING,
    CONTEXT_METALFX,
    CONTEXT_SWAPCHAIN
};

struct fg_context;

struct callback_binding
{
    struct fg_context *context;
    FfxApiPresentCallbackFunc present;
    void *present_user;
    FfxApiFrameGenerationDispatchFunc generate;
    void *generate_user;
};

struct callback_scope
{
    struct callback_scope *previous;
    struct fg_context *context;
};

struct fg_context
{
    struct fg_context *next;
    ffxAllocationCallbacks allocation;
    BOOL custom_allocation;
    enum context_mode mode;

    ffxContext original;
    uint64_t translated;
    IUnknown *device;

    SRWLOCK configure_lock;
    CRITICAL_SECTION dispatch_lock;

    LONG references;
    LONG closing;

    struct stable_swapchain *swapchain;
    struct callback_binding *binding;
    FfxFrameGenerationConfig swapchain_config;
    struct ffxConfigureDescFrameGeneration native_config;
    BOOL native_config_valid;

    struct FfxApiResource hudless;
    BOOL enabled;
};

static SRWLOCK contexts_lock = SRWLOCK_INIT;
static CONDITION_VARIABLE contexts_changed = CONDITION_VARIABLE_INIT;
static struct fg_context *contexts;

static BOOL CALLBACK initialize_native(INIT_ONCE *once, void *parameter, void **result)
{
    WCHAR *path;
    DWORD length;
    HMODULE module;
    struct native_api api;

    (void)once;
    (void)parameter;
    (void)result;

    path = malloc(32768 * sizeof(*path));
    if (!path) return FALSE;
    /* Builtin module names are virtual system32 paths, not runtime paths. */
    length = GetEnvironmentVariableW(L"YAAGL_FSR_FG_NATIVE_DLL", path, 32768);
    if (length < 3 || length >= 32768 || path[1] != ':' ||
        (path[2] != '\\' && path[2] != '/'))
    {
        free(path);
        return FALSE;
    }
    module = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    free(path);

    if (!module || module == builtin_instance)
    {
        if (module) FreeLibrary(module);
        return FALSE;
    }

    memset(&api, 0, sizeof(api));
    api.module = module;
    api.create = (void *)GetProcAddress(module, "ffxCreateContext");
    api.destroy = (void *)GetProcAddress(module, "ffxDestroyContext");
    api.configure = (void *)GetProcAddress(module, "ffxConfigure");
    api.query = (void *)GetProcAddress(module, "ffxQuery");
    api.dispatch = (void *)GetProcAddress(module, "ffxDispatch");

    if (!api.create || !api.destroy || !api.configure || !api.query || !api.dispatch)
    {
        FreeLibrary(module);
        return FALSE;
    }

    /*
     * Keep the module loaded for process lifetime.  Native swapchain objects,
     * their presenter threads and default UI callbacks can outlive contexts.
     */
    native = api;
    return TRUE;
}

static BOOL have_native(void)
{
    return InitOnceExecuteOnce(&native_once, initialize_native, NULL, NULL);
}

static BOOL valid_chain(const ffxApiHeader *header)
{
    unsigned int count = 0;
    while (header)
    {
        if (++count > MAX_DESCRIPTOR_CHAIN) return FALSE;
        header = header->pNext;
    }
    return TRUE;
}

static void initialize_packet(struct yaagl_fsr_fg_packet_header *header,
                              uint32_t size, uint32_t operation, uint64_t context)
{
    header->size = size;
    header->version = YAAGL_FSR_FG_BRIDGE_VERSION;
    header->operation = operation;
    header->result = FFX_API_RETURN_ERROR_RUNTIME_ERROR;
    header->context = context;
}

static ffxReturnCode_t bridge_call(void *packet)
{
    struct yaagl_fsr_fg_packet_header *header = packet;
    NTSTATUS status = WINE_UNIX_CALL(unix_fsr_fg_api, packet);
    return status ? FFX_API_RETURN_ERROR_RUNTIME_ERROR : header->result;
}

static ffxReturnCode_t destroy_translation(uint64_t context)
{
    struct yaagl_fsr_fg_destroy_packet packet;
    memset(&packet, 0, sizeof(packet));
    initialize_packet(&packet.header, sizeof(packet), YAAGL_FSR_FG_DESTROY, context);
    return bridge_call(&packet);
}

static void *allocate_memory(const ffxAllocationCallbacks *callbacks, size_t size)
{
    if (callbacks && callbacks->alloc)
        return callbacks->alloc(callbacks->pUserData, size);
    return malloc(size);
}

static void free_memory(const ffxAllocationCallbacks *callbacks, void *memory)
{
    if (!memory) return;
    if (callbacks && callbacks->dealloc)
        callbacks->dealloc(callbacks->pUserData, memory);
    else
        free(memory);
}

static const ffxAllocationCallbacks *context_allocator(const struct fg_context *context)
{
    return context->custom_allocation ? &context->allocation : NULL;
}

static BOOL matching_allocator(const struct fg_context *context,
                               const ffxAllocationCallbacks *callbacks)
{
    if (!callbacks)
        return !context->allocation.alloc && !context->allocation.dealloc;

    return context->allocation.alloc == callbacks->alloc &&
           context->allocation.dealloc == callbacks->dealloc &&
           context->allocation.pUserData == callbacks->pUserData;
}

static struct fg_context *acquire_context(ffxContext *handle)
{
    struct fg_context *context, *found = NULL;

    if (!handle || !*handle) return NULL;
    AcquireSRWLockExclusive(&contexts_lock);
    for (context = contexts; context; context = context->next)
    {
        if (context == *handle && !context->closing)
        {
            ++context->references;
            found = context;
            break;
        }
    }
    ReleaseSRWLockExclusive(&contexts_lock);
    return found;
}

static void release_context(struct fg_context *context)
{
    AcquireSRWLockExclusive(&contexts_lock);
    --context->references;
    WakeAllConditionVariable(&contexts_changed);
    ReleaseSRWLockExclusive(&contexts_lock);
}

static BOOL in_callback(void)
{
    return callback_tls != TLS_OUT_OF_INDEXES && TlsGetValue(callback_tls) != NULL;
}

static void enter_callback(struct callback_scope *scope, struct fg_context *context)
{
    scope->previous = TlsGetValue(callback_tls);
    scope->context = context;
    TlsSetValue(callback_tls, scope);

    AcquireSRWLockExclusive(&contexts_lock);
    ++context->references;
    ReleaseSRWLockExclusive(&contexts_lock);
}

static void leave_callback(struct callback_scope *scope)
{
    TlsSetValue(callback_tls, scope->previous);
    release_context(scope->context);
}

static void release_swapchain(struct stable_swapchain *swapchain)
{
    if (swapchain)
        swapchain->lpVtbl->dxgi.Release((IDXGISwapChain4 *)swapchain);
}

static struct stable_swapchain *get_stable_swapchain(void *object)
{
    struct stable_swapchain *result = NULL;
    HRESULT hr;

    if (!object) return NULL;
    hr = IUnknown_QueryInterface((IUnknown *)object, &stable_swapchain_iid,
                                (void **)&result);
    return SUCCEEDED(hr) ? result : NULL;
}

static BOOL claim_swapchain(struct fg_context *context,
                           struct stable_swapchain *swapchain)
{
    struct fg_context *other;
    BOOL available = TRUE;

    AcquireSRWLockExclusive(&contexts_lock);
    for (other = contexts; other; other = other->next)
    {
        if (other != context && other->mode != CONTEXT_SWAPCHAIN &&
            other->swapchain == swapchain)
        {
            available = FALSE;
            break;
        }
    }
    if (available) context->swapchain = swapchain;
    ReleaseSRWLockExclusive(&contexts_lock);
    return available;
}

static void clear_swapchain_claim(struct fg_context *context)
{
    AcquireSRWLockExclusive(&contexts_lock);
    context->swapchain = NULL;
    ReleaseSRWLockExclusive(&contexts_lock);
}

static ffxReturnCode_t translated_dispatch(struct fg_context *context,
                                         const ffxDispatchDescHeader *header)
{
    struct yaagl_fsr_fg_dispatch_packet packet;
    const ffxDispatchDescFrameGeneration *desc = (const void *)header;

    if (header->pNext) return FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
    if (!desc->commandList || !desc->presentColor.resource ||
        desc->numGeneratedFrames != 1 || !desc->outputs[0].resource)
        return FFX_API_RETURN_ERROR_PARAMETER;

    memset(&packet, 0, sizeof(packet));
    initialize_packet(&packet.header, sizeof(packet), YAAGL_FSR_FG_DISPATCH,
                      context->translated);

    packet.command_list = (uint64_t)(uintptr_t)desc->commandList;
    packet.frame_id = desc->frameID;
    packet.present_color = (uint64_t)(uintptr_t)desc->presentColor.resource;
    packet.present_color_state = desc->presentColor.state;
    packet.output = (uint64_t)(uintptr_t)desc->outputs[0].resource;
    packet.output_state = desc->outputs[0].state;
    packet.num_generated_frames = desc->numGeneratedFrames;
    packet.reset = desc->reset;
    packet.backbuffer_transfer_function = desc->backbufferTransferFunction;
    packet.generation_rect_left = desc->generationRect.left;
    packet.generation_rect_top = desc->generationRect.top;
    packet.generation_rect_width = desc->generationRect.width;
    packet.generation_rect_height = desc->generationRect.height;
    packet.min_luminance = desc->minMaxLuminance[0];
    packet.max_luminance = desc->minMaxLuminance[1];

    /*
     * A dispatch error, including result 4, is an error in this already
     * selected mode.  Never run native interpolation for the same frame.
     */
    return bridge_call(&packet);
}

#define COPY_PREPARE_FIELDS(packet, desc) do \
{ \
    (packet).command_list = (uint64_t)(uintptr_t)(desc)->commandList; \
    (packet).frame_id = (desc)->frameID; \
    (packet).depth = (uint64_t)(uintptr_t)(desc)->depth.resource; \
    (packet).motion_vectors = (uint64_t)(uintptr_t)(desc)->motionVectors.resource; \
    (packet).depth_state = (desc)->depth.state; \
    (packet).motion_vectors_state = (desc)->motionVectors.state; \
    (packet).render_width = (desc)->renderSize.width; \
    (packet).render_height = (desc)->renderSize.height; \
    (packet).flags = (desc)->flags; \
    (packet).jitter_x = (desc)->jitterOffset.x; \
    (packet).jitter_y = (desc)->jitterOffset.y; \
    (packet).motion_scale_x = (desc)->motionVectorScale.x; \
    (packet).motion_scale_y = (desc)->motionVectorScale.y; \
    (packet).frame_time_delta_ms = (desc)->frameTimeDelta; \
    (packet).camera_near = (desc)->cameraNear; \
    (packet).camera_far = (desc)->cameraFar; \
    (packet).camera_fov_vertical_radians = (desc)->cameraFovAngleVertical; \
    (packet).view_space_to_meters = (desc)->viewSpaceToMetersFactor; \
} while (0)

#define COPY_CAMERA_FIELDS(packet, desc) do \
{ \
    memcpy((packet).camera_position, (desc)->cameraPosition, sizeof((packet).camera_position)); \
    memcpy((packet).camera_up, (desc)->cameraUp, sizeof((packet).camera_up)); \
    memcpy((packet).camera_right, (desc)->cameraRight, sizeof((packet).camera_right)); \
    memcpy((packet).camera_forward, (desc)->cameraForward, sizeof((packet).camera_forward)); \
} while (0)

static ffxReturnCode_t translated_prepare(struct fg_context *context,
                                        const ffxDispatchDescHeader *header)
{
    struct yaagl_fsr_fg_prepare_packet packet;
    const ffxApiHeader *entry;
    BOOL have_camera = FALSE;

    memset(&packet, 0, sizeof(packet));
    initialize_packet(&packet.header, sizeof(packet), YAAGL_FSR_FG_PREPARE,
                      context->translated);

    if (header->type == FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_V2)
    {
        const struct ffxDispatchDescFrameGenerationPrepareV2 *desc = (const void *)header;
        if (header->pNext) return FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
        COPY_PREPARE_FIELDS(packet, desc);
        COPY_CAMERA_FIELDS(packet, desc);
        packet.reset = desc->reset;
        have_camera = TRUE;
    }
    else
    {
        const struct ffxDispatchDescFrameGenerationPrepare *desc = (const void *)header;
        COPY_PREPARE_FIELDS(packet, desc);
        packet.reset = desc->unused_reset;

        for (entry = header->pNext; entry; entry = entry->pNext)
        {
            const struct ffxDispatchDescFrameGenerationPrepareCameraInfo *camera;
            if (entry->type != FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_CAMERAINFO)
                return FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
            if (have_camera) return FFX_API_RETURN_ERROR_PARAMETER;
            camera = (const void *)entry;
            COPY_CAMERA_FIELDS(packet, camera);
            have_camera = TRUE;
        }
    }

    if (!packet.command_list || !packet.depth || !packet.motion_vectors ||
        !packet.render_width || !packet.render_height)
        return FFX_API_RETURN_ERROR_PARAMETER;

    /*
     * Legacy applications may omit camera vectors.  Keep these explicitly
     * zero; the bridge decides eligibility/validity, rather than inventing a
     * camera basis.
     */
    (void)have_camera;
    return bridge_call(&packet);
}

#undef COPY_PREPARE_FIELDS
#undef COPY_CAMERA_FIELDS

static ffxReturnCode_t configure_frame_generation(
    struct fg_context *context, const struct ffxConfigureDescFrameGeneration *desc);

/* configure_lock is held; no dispatch lock may be held while installing callbacks. */
static ffxReturnCode_t select_native(struct fg_context *context)
{
    ffxReturnCode_t result = FFX_API_RETURN_OK;

    context->mode = CONTEXT_NATIVE;
    if (context->native_config_valid)
    {
        struct ffxConfigureDescFrameGeneration config = context->native_config;
        result = configure_frame_generation(context, &config);
    }
    return result;
}

static ffxReturnCode_t dispatch_context(struct fg_context *context,
                                      const ffxDispatchDescHeader *desc)
{
    ffxReturnCode_t result;

    if (!in_callback())
    {
        AcquireSRWLockExclusive(&context->configure_lock);
        if (context->mode == MODE_PENDING)
        {
            if (desc->type != FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE &&
                desc->type != FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_V2)
            {
                ReleaseSRWLockExclusive(&context->configure_lock);
                return FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
            }

            EnterCriticalSection(&context->dispatch_lock);
            result = translated_prepare(context, desc);
            LeaveCriticalSection(&context->dispatch_lock);
            if (result == BRIDGE_INELIGIBLE)
            {
                result = select_native(context);
                if (result == FFX_API_RETURN_OK)
                    result = native.dispatch(&context->original, desc);
            }
            else if (result == FFX_API_RETURN_OK)
            {
                context->mode = CONTEXT_METALFX;
                if (context->native_config_valid)
                {
                    struct ffxConfigureDescFrameGeneration config = context->native_config;
                    result = configure_frame_generation(context, &config);
                }
            }
            ReleaseSRWLockExclusive(&context->configure_lock);
            return result;
        }
        ReleaseSRWLockExclusive(&context->configure_lock);
    }

    EnterCriticalSection(&context->dispatch_lock);
    if (context->mode != CONTEXT_METALFX)
    {
        result = native.dispatch(&context->original, desc);
    }
    else
    {
        switch (desc->type)
        {
        case FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE:
        case FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION_PREPARE_V2:
            result = translated_prepare(context, desc);
            break;
        case FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATION:
            result = translated_dispatch(context, desc);
            break;
        default:
            result = FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
            break;
        }
    }
    LeaveCriticalSection(&context->dispatch_lock);
    return result;
}

static ffxReturnCode_t present_callback(ffxCallbackDescFrameGenerationPresent *desc,
                                       void *user)
{
    struct callback_binding *binding = user;
    struct callback_scope scope;
    ffxReturnCode_t result;

    if (!binding || !desc || !binding->present)
        return FFX_API_RETURN_ERROR_PARAMETER;

    enter_callback(&scope, binding->context);
    result = binding->present(desc, binding->present_user);
    leave_callback(&scope);
    return result;
}

static ffxReturnCode_t generation_callback(ffxDispatchDescFrameGeneration *desc,
                                          void *user)
{
    struct callback_binding *binding = user;
    struct callback_scope scope;
    ffxReturnCode_t result;

    if (!binding || !desc) return FFX_API_RETURN_ERROR_PARAMETER;

    enter_callback(&scope, binding->context);

    /*
     * Preserve application callbacks, including their edits to the dispatch
     * descriptor.  Their ffxDispatch calls resolve through the context wrapper.
     * With no application callback, dispatch the selected provider directly.
     */
    if (binding->generate)
        result = binding->generate(desc, binding->generate_user);
    else
        result = dispatch_context(binding->context, &desc->header);

    /*
     * The native swapchain tests numGeneratedFrames even after a failing
     * callback.  Suppress presentation of an unwritten interpolation target.
     */
    if (result != FFX_API_RETURN_OK) desc->numGeneratedFrames = 0;

    leave_callback(&scope);
    return result;
}

static void build_swapchain_config(FfxFrameGenerationConfig *output,
                                  const struct ffxConfigureDescFrameGeneration *input,
                                  struct callback_binding *binding)
{
    memset(output, 0, sizeof(*output));
    output->header.type = FFX_API_FRAME_GENERATION_CONFIG;
    output->swapChain = input->swapChain;
    output->presentCallback = input->presentCallback;
    output->presentCallbackContext = input->presentCallbackUserContext;
    output->frameGenerationCallback = input->frameGenerationCallback;
    output->frameGenerationCallbackContext = input->frameGenerationCallbackUserContext;
    output->frameGenerationEnabled = input->frameGenerationEnabled;
    output->allowAsyncWorkloads = input->allowAsyncWorkloads;
    output->HUDLessColor = input->HUDLessColor;
    output->flags = input->flags;
    output->onlyPresentInterpolated = input->onlyPresentGenerated;
    output->interpolationRect = input->generationRect;
    output->frameID = input->frameID;
    output->drawDebugPacingLines =
        !!(input->flags & FFX_FRAMEGENERATION_FLAG_DRAW_DEBUG_PACING_LINES);

    if (binding)
    {
        /*
         * NULL preserves the native swapchain's official default UI
         * composition function, including its premultiplied-alpha extension.
         */
        output->presentCallback = binding->present ? present_callback : NULL;
        output->presentCallbackContext = binding->present ? binding : NULL;
        output->frameGenerationCallback = generation_callback;
        output->frameGenerationCallbackContext = binding;
    }
}

/*
 * Called with configure_lock held, but never with dispatch_lock or
 * contexts_lock held.  Native set_config can wait for application callbacks.
 */
static ffxReturnCode_t detach_swapchain(struct fg_context *context)
{
    struct stable_swapchain *swapchain = context->swapchain;
    FfxFrameGenerationConfig disabled;
    ffxReturnCode_t result = FFX_API_RETURN_OK, native_result;
    BOOL waited;

    if (!swapchain) return FFX_API_RETURN_OK;

    if (context->mode == CONTEXT_NATIVE && context->native_config_valid)
    {
        struct ffxConfigureDescFrameGeneration config = context->native_config;
        config.header.pNext = NULL;
        config.frameGenerationEnabled = false;
        config.frameGenerationCallback = NULL;
        config.frameGenerationCallbackUserContext = NULL;
        config.presentCallback = NULL;
        config.presentCallbackUserContext = NULL;
        config.HUDLessColor.resource = NULL;
        config.flags &= ~FFX_FRAMEGENERATION_FLAG_NO_SWAPCHAIN_CONTEXT_NOTIFY;
        native_result = native.configure(&context->original, &config.header);
        if (native_result != FFX_API_RETURN_OK) result = native_result;
    }

    memset(&disabled, 0, sizeof(disabled));
    disabled.header.type = FFX_API_FRAME_GENERATION_CONFIG;
    disabled.swapChain = swapchain;
    swapchain->lpVtbl->set_config(swapchain, &disabled);
    waited = swapchain->lpVtbl->wait_for_presents(swapchain);

    if (!waited)
        return FFX_API_RETURN_ERROR_RUNTIME_ERROR;

    clear_swapchain_claim(context);
    release_swapchain(swapchain);
    free_memory(context_allocator(context), context->binding);
    context->binding = NULL;
    context->native_config_valid = FALSE;
    context->enabled = FALSE;
    memset(&context->swapchain_config, 0, sizeof(context->swapchain_config));
    memset(&context->native_config, 0, sizeof(context->native_config));

    return result;
}

static ffxReturnCode_t configure_frame_generation(
    struct fg_context *context, const struct ffxConfigureDescFrameGeneration *desc)
{
    struct stable_swapchain *swapchain = NULL;
    struct callback_binding *binding = NULL, *old_binding;
    FfxFrameGenerationConfig config;
    ffxReturnCode_t result;
    BOOL notify = !(desc->flags & FFX_FRAMEGENERATION_FLAG_NO_SWAPCHAIN_CONTEXT_NOTIFY);

    if (context->mode == MODE_PENDING)
    {
        if (desc->header.pNext || desc->HUDLessColor.resource ||
            (desc->flags & ~FFX_FRAMEGENERATION_FLAG_NO_SWAPCHAIN_CONTEXT_NOTIFY))
        {
            result = select_native(context);
            if (result != FFX_API_RETURN_OK) return result;
        }
        else
        {
            if (notify && !desc->swapChain)
                return FFX_API_RETURN_ERROR_PARAMETER;
            context->native_config = *desc;
            context->native_config.header.pNext = NULL;
            context->native_config_valid = TRUE;
            return FFX_API_RETURN_OK;
        }
    }

    if (context->mode == CONTEXT_METALFX && desc->header.pNext)
        return FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;

    /*
     * UI extraction from an arbitrary HUD-less render target is not present
     * in the fixed MetalFX packet contract.  Do not silently ignore it or
     * start native interpolation in a translated context.
     */
    if (context->mode == CONTEXT_METALFX && desc->HUDLessColor.resource)
        return FFX_API_RETURN_ERROR_PARAMETER;

    if (!notify)
    {
        if (context->mode == CONTEXT_NATIVE)
            return native.configure(&context->original, &desc->header);
        return FFX_API_RETURN_OK;
    }

    if (!desc->swapChain) return FFX_API_RETURN_ERROR_PARAMETER;
    swapchain = get_stable_swapchain(desc->swapChain);
    if (!swapchain) return FFX_API_RETURN_ERROR_PARAMETER;

    /*
     * A context must be explicitly disabled before moving to another
     * swapchain.  This avoids leaving callbacks registered on an old object.
     */
    if (context->swapchain && context->swapchain != swapchain)
    {
        if (context->enabled)
        {
            release_swapchain(swapchain);
            return FFX_API_RETURN_ERROR_PARAMETER;
        }
        result = detach_swapchain(context);
        if (result != FFX_API_RETURN_OK)
        {
            release_swapchain(swapchain);
            return result;
        }
    }

    if (context->mode == CONTEXT_METALFX)
    {
        binding = allocate_memory(context_allocator(context), sizeof(*binding));
        if (!binding)
        {
            release_swapchain(swapchain);
            return FFX_API_RETURN_ERROR_MEMORY;
        }

        memset(binding, 0, sizeof(*binding));
        binding->context = context;
        binding->present = desc->presentCallback;
        binding->present_user = desc->presentCallbackUserContext;
        binding->generate = desc->frameGenerationCallback;
        binding->generate_user = desc->frameGenerationCallbackUserContext;
    }

    if (!context->swapchain)
    {
        if (!claim_swapchain(context, swapchain))
        {
            free_memory(context_allocator(context), binding);
            release_swapchain(swapchain);
            return FFX_API_RETURN_ERROR_PARAMETER;
        }
    }
    else
    {
        release_swapchain(swapchain);
        swapchain = context->swapchain;
    }

    if (context->mode == CONTEXT_NATIVE)
    {
        result = native.configure(&context->original, &desc->header);
        if (result == FFX_API_RETURN_OK)
        {
            context->native_config = *desc;
            context->native_config.header.pNext = NULL;
            context->native_config_valid = TRUE;
            context->enabled = desc->frameGenerationEnabled;
            build_swapchain_config(&context->swapchain_config, desc, NULL);
        }
        return result;
    }

    /*
     * Mode was selected by the first successful Prepare, before any callback could be
     * registered.  No call to the original FG provider occurs on this path.
     */
    build_swapchain_config(&config, desc, binding);
    old_binding = context->binding;

    /*
     * Changing the binding pointer forces the official native implementation
     * to drain the old callback configuration before installing the new one.
     * It does so under its own presentation/configuration locks.
     */
    swapchain->lpVtbl->set_config(swapchain, &config);
    context->binding = binding;
    context->swapchain_config = config;
    context->enabled = desc->frameGenerationEnabled;

    free_memory(context_allocator(context), old_binding);

    if (!desc->frameGenerationEnabled &&
        !swapchain->lpVtbl->wait_for_presents(swapchain))
        return FFX_API_RETURN_ERROR_RUNTIME_ERROR;

    return FFX_API_RETURN_OK;
}

static void free_context_storage(struct fg_context *context)
{
    ffxAllocationCallbacks allocation = context->allocation;
    BOOL custom = context->custom_allocation;

    if (context->device) IUnknown_Release(context->device);
    DeleteCriticalSection(&context->dispatch_lock);
    free_memory(custom ? &allocation : NULL, context);
}

static ffxReturnCode_t select_translation(
    struct fg_context *context,
    const struct ffxCreateContextDescFrameGeneration *desc,
    const struct backend_dx12_desc *backend)
{
    struct yaagl_fsr_fg_create_packet create;
    ffxReturnCode_t result;

    memset(&create, 0, sizeof(create));
    initialize_packet(&create.header, sizeof(create), YAAGL_FSR_FG_CREATE, 0);
    create.device = (uint64_t)(uintptr_t)backend->device;
    create.display_width = desc->displaySize.width;
    create.display_height = desc->displaySize.height;
    create.max_render_width = desc->maxRenderSize.width;
    create.max_render_height = desc->maxRenderSize.height;
    create.backbuffer_format = desc->backBufferFormat;
    create.flags = (desc->flags & FFX_FRAMEGENERATION_ENABLE_DEPTH_INVERTED
                    ? YAAGL_FSR_FG_DEPTH_INVERTED : 0) |
                   (desc->flags & FFX_FRAMEGENERATION_ENABLE_DEPTH_INFINITE
                    ? YAAGL_FSR_FG_DEPTH_INFINITE : 0);
    /* MetalFX has no equivalent for jittered/display-sized motion input or AMD debug views. */
    if (desc->flags & ~(FFX_FRAMEGENERATION_ENABLE_ASYNC_WORKLOAD_SUPPORT |
                        FFX_FRAMEGENERATION_ENABLE_DEPTH_INVERTED |
                        FFX_FRAMEGENERATION_ENABLE_DEPTH_INFINITE |
                        FFX_FRAMEGENERATION_ENABLE_HIGH_DYNAMIC_RANGE))
        return BRIDGE_INELIGIBLE;

    result = bridge_call(&create);
    if (result != FFX_API_RETURN_OK)
    {
        if (create.header.context)
        {
            ffxReturnCode_t cleanup = destroy_translation(create.header.context);
            if (cleanup != FFX_API_RETURN_OK) return cleanup;
        }
        return result;
    }
    if (!create.header.context) return FFX_API_RETURN_ERROR_RUNTIME_ERROR;

    context->translated = create.header.context;
    context->mode = MODE_PENDING;
    return FFX_API_RETURN_OK;
}

/*
 * Preserve the caller's actual descriptor order and all native extensions.
 * The create API accepts a mutable chain; restore the one spliced link before
 * returning, including on failure.  No native provider override is removed.
 */
static ffxReturnCode_t create_original(struct fg_context *context,
                                      ffxCreateContextDescHeader *desc,
                                      const struct ffxOverrideVersion *override,
                                      const ffxAllocationCallbacks *callbacks)
{
    ffxApiHeader *entry, *previous = NULL;
    ffxReturnCode_t result;

    if (!have_native()) return FFX_API_RETURN_NO_PROVIDER;
    if (!override || (override->versionId != AUTOMATIC_PROVIDER_ID &&
                      override->versionId != METALFX_PROVIDER_ID))
        return native.create(&context->original, desc, callbacks);

    for (entry = desc; entry && entry != &override->header;
         entry = (ffxApiHeader *)entry->pNext)
        previous = entry;

    if (previous) previous->pNext = override->header.pNext;
    else desc = (ffxCreateContextDescHeader *)override->header.pNext;
    result = native.create(&context->original, desc, callbacks);
    if (previous) previous->pNext = &override->header;
    return result;
}

ffxReturnCode_t WINAPI ffxCreateContext(ffxContext *output,
                                      ffxCreateContextDescHeader *desc,
                                      const ffxAllocationCallbacks *callbacks)
{
    const ffxApiHeader *entry;
    const struct ffxCreateContextDescFrameGeneration *fg = NULL;
    const struct backend_dx12_desc *backend = NULL;
    const struct ffxCreateContextDescFrameGenerationVersion *version = NULL;
    const struct ffxCreateContextDescFrameGenerationHudless *hudless = NULL;
    const struct ffxOverrideVersion *override = NULL;
    struct fg_context *context;
    BOOL is_swapchain = FALSE, native_only = FALSE;
    ffxReturnCode_t result;

    if (!output) return FFX_API_RETURN_ERROR_PARAMETER;
    *output = NULL;
    if (!desc || !valid_chain(desc) ||
        (callbacks && (!!callbacks->alloc != !!callbacks->dealloc)))
        return FFX_API_RETURN_ERROR_PARAMETER;

    for (entry = desc; entry; entry = entry->pNext)
    {
        switch (entry->type)
        {
        case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION:
            if (fg) return FFX_API_RETURN_ERROR_PARAMETER;
            fg = (const void *)entry;
            break;
        case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_WRAP_DX12:
        case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_NEW_DX12:
        case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_FOR_HWND_DX12:
            if (is_swapchain) return FFX_API_RETURN_ERROR_PARAMETER;
            is_swapchain = TRUE;
            break;
        default:
            break;
        }
    }

    if (fg && is_swapchain) return FFX_API_RETURN_ERROR_PARAMETER;
    if (!fg && !is_swapchain) return FFX_API_RETURN_NO_PROVIDER;

    if (fg)
    {
        for (entry = desc; entry; entry = entry->pNext)
        {
            switch (entry->type)
            {
            case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION:
                break;
            case BACKEND_DX12_DESC_TYPE:
                if (backend) return FFX_API_RETURN_ERROR_PARAMETER;
                backend = (const void *)entry;
                break;
            case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION_VERSION:
                if (version) return FFX_API_RETURN_ERROR_PARAMETER;
                version = (const void *)entry;
                if (version->version != FFX_FRAMEGENERATION_VERSION)
                    native_only = TRUE;
                break;
            case FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION_HUDLESS:
                if (hudless) return FFX_API_RETURN_ERROR_PARAMETER;
                hudless = (const void *)entry;
                break;
            case FFX_API_DESC_TYPE_OVERRIDE_VERSION:
                if (override) return FFX_API_RETURN_ERROR_PARAMETER;
                override = (const void *)entry;
                if (override->versionId != AUTOMATIC_PROVIDER_ID &&
                    override->versionId != METALFX_PROVIDER_ID)
                    native_only = TRUE;
                break;
            default:
                native_only = TRUE;
                break;
            }
        }

        if (!backend || !backend->device ||
            !fg->displaySize.width || !fg->displaySize.height ||
            !fg->maxRenderSize.width || !fg->maxRenderSize.height)
            return FFX_API_RETURN_ERROR_PARAMETER;

        /*
         * A distinct HUD-less format cannot be represented by the private
         * create packet.  Leave this request to the native provider.
         */
        if (hudless && hudless->hudlessBackBufferFormat &&
            hudless->hudlessBackBufferFormat != fg->backBufferFormat)
            native_only = TRUE;
    }

    context = allocate_memory(callbacks, sizeof(*context));
    if (!context) return FFX_API_RETURN_ERROR_MEMORY;
    memset(context, 0, sizeof(*context));
    if (callbacks)
    {
        context->allocation = *callbacks;
        context->custom_allocation = TRUE;
    }
    InitializeSRWLock(&context->configure_lock);
    InitializeCriticalSection(&context->dispatch_lock);
    context->references = 1;

    if (is_swapchain)
    {
        context->mode = CONTEXT_SWAPCHAIN;
        if (!have_native())
        {
            free_context_storage(context);
            return FFX_API_RETURN_NO_PROVIDER;
        }
        result = native.create(&context->original, desc, callbacks);
    }
    else
    {
        context->device = backend->device;
        IUnknown_AddRef(context->device);

        context->mode = CONTEXT_NATIVE;
        result = create_original(context, desc, override, callbacks);
        if (result == FFX_API_RETURN_OK && !context->original)
            result = FFX_API_RETURN_ERROR_RUNTIME_ERROR;
        if (result == FFX_API_RETURN_OK && !native_only)
        {
            result = select_translation(context, fg, backend);
            if (result == BRIDGE_INELIGIBLE)
                result = FFX_API_RETURN_OK;
        }
    }

    if (result == FFX_API_RETURN_OK &&
        context->mode != CONTEXT_METALFX && !context->original)
        result = FFX_API_RETURN_ERROR_RUNTIME_ERROR;

    if (result != FFX_API_RETURN_OK)
    {
        if (context->translated) destroy_translation(context->translated);
        if (context->original && native.destroy)
            native.destroy(&context->original, callbacks);
        free_context_storage(context);
        return result;
    }

    AcquireSRWLockExclusive(&contexts_lock);
    context->next = contexts;
    contexts = context;
    ReleaseSRWLockExclusive(&contexts_lock);

    *output = context;
    return FFX_API_RETURN_OK;
}

ffxReturnCode_t WINAPI ffxDestroyContext(ffxContext *handle,
                                       const ffxAllocationCallbacks *callbacks)
{
    struct fg_context *context, **link;
    ffxReturnCode_t result, detach_result;

    /*
     * Destruction/reconfiguration from a native presenter callback would
     * wait for that same callback.  Reject it instead of deadlocking.
     */
    if (!handle || !*handle || in_callback())
        return FFX_API_RETURN_ERROR_PARAMETER;

    AcquireSRWLockExclusive(&contexts_lock);
    for (context = contexts; context; context = context->next)
        if (context == *handle) break;

    if (!context || context->closing || !matching_allocator(context, callbacks))
    {
        ReleaseSRWLockExclusive(&contexts_lock);
        return FFX_API_RETURN_ERROR_PARAMETER;
    }

    context->closing = TRUE;
    ReleaseSRWLockExclusive(&contexts_lock);

    AcquireSRWLockExclusive(&context->configure_lock);
    detach_result = detach_swapchain(context);
    ReleaseSRWLockExclusive(&context->configure_lock);

    /*
     * A failed wait cannot prove that callback user data is no longer live.
     * Leave the context owned by the caller so destruction can be retried.
     */
    if (context->swapchain)
    {
        AcquireSRWLockExclusive(&contexts_lock);
        context->closing = FALSE;
        ReleaseSRWLockExclusive(&contexts_lock);
        return detach_result;
    }

    AcquireSRWLockExclusive(&contexts_lock);
    while (context->references != 1)
        SleepConditionVariableSRW(&contexts_changed, &contexts_lock, INFINITE, 0);
    ReleaseSRWLockExclusive(&contexts_lock);

    result = FFX_API_RETURN_OK;
    if (context->translated)
    {
        result = destroy_translation(context->translated);
        if (result == FFX_API_RETURN_OK) context->translated = 0;
    }
    if (result == FFX_API_RETURN_OK && context->original)
        result = native.destroy(&context->original, context_allocator(context));

    if (result != FFX_API_RETURN_OK)
    {
        AcquireSRWLockExclusive(&contexts_lock);
        context->closing = FALSE;
        ReleaseSRWLockExclusive(&contexts_lock);
        return result;
    }

    AcquireSRWLockExclusive(&contexts_lock);
    for (link = &contexts; *link; link = &(*link)->next)
    {
        if (*link == context)
        {
            *link = context->next;
            break;
        }
    }
    ReleaseSRWLockExclusive(&contexts_lock);

    *handle = NULL;
    free_context_storage(context);
    return detach_result;
}

ffxReturnCode_t WINAPI ffxConfigure(ffxContext *handle,
                                   const ffxConfigureDescHeader *desc)
{
    struct fg_context *context;
    ffxReturnCode_t result;

    if (!desc || !valid_chain(desc)) return FFX_API_RETURN_ERROR_PARAMETER;
    if (in_callback()) return FFX_API_RETURN_ERROR_PARAMETER;

    if (!handle)
    {
        if (!have_native()) return FFX_API_RETURN_NO_PROVIDER;
        return native.configure(NULL, desc);
    }

    context = acquire_context(handle);
    if (!context) return FFX_API_RETURN_ERROR_PARAMETER;

    AcquireSRWLockExclusive(&context->configure_lock);
    if (InterlockedCompareExchange(&context->closing, 0, 0))
    {
        result = FFX_API_RETURN_ERROR_PARAMETER;
    }
    else if (context->mode == CONTEXT_SWAPCHAIN)
    {
        /*
         * This includes UI resources, premultiplied alpha, double buffering,
         * wait callbacks and pacing tuning.  Preserve all official Ffx types
         * and extension chains unchanged.
         */
        result = native.configure(&context->original, desc);
    }
    else if (desc->type == FFX_API_CONFIGURE_DESC_TYPE_FRAMEGENERATION)
    {
        result = configure_frame_generation(context, (const void *)desc);
    }
    else if (context->mode == CONTEXT_NATIVE || context->mode == MODE_PENDING)
    {
        result = native.configure(&context->original, desc);
        if (result == FFX_API_RETURN_OK && context->mode == MODE_PENDING)
            result = select_native(context);
    }
    else
    {
        /*
         * No configure packet exists in version 1 of this bridge.
         * In particular, do not claim native debug-view or distortion
         * support for a translated context.
         */
        result = FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
    }
    ReleaseSRWLockExclusive(&context->configure_lock);

    release_context(context);
    return result;
}

static ffxReturnCode_t query_versions(ffxQueryDescHeader *desc)
{
    struct ffxQueryDescGetVersions *query = (void *)desc;
    struct ffxQueryDescGetVersions original;
    ffxReturnCode_t result;
    uint64_t native_count;
    uint64_t capacity;

    if (query->createDescType != FFX_API_CREATE_CONTEXT_DESC_TYPE_FRAMEGENERATION)
    {
        if (!have_native()) return FFX_API_RETURN_NO_PROVIDER;
        return native.query(NULL, desc);
    }

    if (desc->pNext) return FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
    if (!query->outputCount) return FFX_API_RETURN_OK;

    capacity = *query->outputCount;
    if (!have_native()) return FFX_API_RETURN_NO_PROVIDER;
    original = *query;
    native_count = capacity > 1 ? capacity - 1 : 0;
    original.outputCount = &native_count;
    original.versionIds = capacity > 1 && query->versionIds ? query->versionIds + 1 : NULL;
    original.versionNames = capacity > 1 && query->versionNames ? query->versionNames + 1 : NULL;
    result = native.query(NULL, &original.header);
    if (result != FFX_API_RETURN_OK) return result;
    *query->outputCount = native_count + 1;
    if (capacity)
    {
        if (query->versionIds) query->versionIds[0] = AUTOMATIC_PROVIDER_ID;
        if (query->versionNames) query->versionNames[0] = automatic_provider_name;
    }
    return FFX_API_RETURN_OK;
}

ffxReturnCode_t WINAPI ffxQuery(ffxContext *handle, ffxQueryDescHeader *desc)
{
    struct fg_context *context;
    ffxReturnCode_t result;

    if (!desc || !valid_chain(desc)) return FFX_API_RETURN_ERROR_PARAMETER;

    if (!handle)
    {
        if (desc->type == FFX_API_QUERY_DESC_TYPE_GET_VERSIONS)
            return query_versions(desc);

        if (desc->type == FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION)
            return FFX_API_RETURN_ERROR_PARAMETER;

        /*
         * An automatic provider cannot report native-only FG memory totals
         * before eligibility and provider selection are known.
         */
        if (desc->type == FFX_API_QUERY_DESC_TYPE_FRAMEGENERATION_GPU_MEMORY_USAGE ||
            desc->type == FFX_API_QUERY_DESC_TYPE_FRAMEGENERATION_GPU_MEMORY_USAGE_V2)
            return FFX_API_RETURN_ERROR_RUNTIME_ERROR;

        if (!have_native()) return FFX_API_RETURN_NO_PROVIDER;
        return native.query(NULL, desc);
    }

    context = acquire_context(handle);
    if (!context) return FFX_API_RETURN_ERROR_PARAMETER;

    if (context->mode != CONTEXT_METALFX && context->mode != MODE_PENDING)
    {
        /*
         * Always unwrap context queries, including provider-version queries.
         * A fallback context reports the actual native provider's identity.
         */
        result = native.query(&context->original, desc);
    }
    else if (desc->type == FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION)
    {
        struct ffxQueryGetProviderVersion *query = (void *)desc;
        if (desc->pNext)
            result = FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
        else
        {
            query->versionId = context->mode == MODE_PENDING ?
                AUTOMATIC_PROVIDER_ID : METALFX_PROVIDER_ID;
            query->versionName = context->mode == MODE_PENDING ?
                automatic_provider_name : metalfx_provider_name;
            result = FFX_API_RETURN_OK;
        }
    }
    else if (desc->type == FFX_API_QUERY_DESC_TYPE_GET_VERSIONS)
    {
        result = query_versions(desc);
    }
    else if (desc->type == FFX_API_QUERY_DESC_TYPE_FRAMEGENERATION_GPU_MEMORY_USAGE ||
             desc->type == FFX_API_QUERY_DESC_TYPE_FRAMEGENERATION_GPU_MEMORY_USAGE_V2)
    {
        result = FFX_API_RETURN_ERROR_RUNTIME_ERROR;
    }
    else
    {
        result = FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
    }

    release_context(context);
    return result;
}

ffxReturnCode_t WINAPI ffxDispatch(ffxContext *handle,
                                  const ffxDispatchDescHeader *desc)
{
    struct fg_context *context;
    ffxReturnCode_t result;

    if (!desc || !valid_chain(desc)) return FFX_API_RETURN_ERROR_PARAMETER;
    context = acquire_context(handle);
    if (!context) return FFX_API_RETURN_ERROR_PARAMETER;

    /*
     * Waiting from a presenter callback would wait for itself.  Normal
     * Prepare/Dispatch callback reentry is required and remains permitted.
     */
    if (in_callback() &&
        desc->type == FFX_API_DISPATCH_DESC_TYPE_FRAMEGENERATIONSWAPCHAIN_WAIT_FOR_PRESENTS_DX12)
        result = FFX_API_RETURN_ERROR_PARAMETER;
    else
        result = dispatch_context(context, desc);

    release_context(context);
    return result;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    switch (reason)
    {
    case DLL_PROCESS_ATTACH:
        builtin_instance = instance;
        DisableThreadLibraryCalls(instance);
        callback_tls = TlsAlloc();
        if (callback_tls == TLS_OUT_OF_INDEXES) return FALSE;
        if (__wine_init_unix_call())
        {
            TlsFree(callback_tls);
            callback_tls = TLS_OUT_OF_INDEXES;
            return FALSE;
        }
        break;

    case DLL_PROCESS_DETACH:
        /*
         * Never wait for presenter threads or unload the original module
         * under the loader lock.  At process termination the OS reclaims TLS.
         */
        if (!reserved && callback_tls != TLS_OUT_OF_INDEXES)
        {
            TlsFree(callback_tls);
            callback_tls = TLS_OUT_OF_INDEXES;
        }
        break;
    }
    return TRUE;
}