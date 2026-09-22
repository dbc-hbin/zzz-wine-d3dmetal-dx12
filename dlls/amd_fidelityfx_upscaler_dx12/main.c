/* AMD FidelityFX Upscaler API builtin backed by the Yaagl MetalFX translator. */
#include <math.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#include "windef.h"
#include "winbase.h"
#include "unixlib.h"
#include "../../d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/api/include/ffx_api.h"
#include "../../d3dmetal-pso-cache/third-party/fidelityfx/Kits/FidelityFX/upscalers/include/ffx_upscale.h"

#define PROVIDER_ID 0x4d46580000000001ull
#define FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12 2u
struct local_backend_dx12_desc { ffxCreateContextDescHeader header; void *device; };
static const char provider_name[] = "MetalFX (FSR 4 API)";

struct fsr_context
{
    struct fsr_context *next;
    uint64_t native;
    void *device;
    ffxAllocationCallbacks allocation;
    ffxApiMessage message;
    uint32_t debug_level;
    LONG references;
};

static SRWLOCK contexts_lock = SRWLOCK_INIT;
static struct fsr_context *contexts;
static ffxApiMessage global_message;
static uint32_t global_debug_level;

static ffxReturnCode_t unix_call(void *packet)
{
    struct yaagl_fsr_packet_header *header = packet;
    NTSTATUS status = WINE_UNIX_CALL(unix_fsr_api, packet);
    return status ? FFX_API_RETURN_ERROR_RUNTIME_ERROR : header->result;
}

static struct fsr_context *find_context(ffxContext *context)
{
    struct fsr_context *found = NULL, *candidate;
    if (!context || !*context) return NULL;
    AcquireSRWLockShared(&contexts_lock);
    for (candidate = contexts; candidate; candidate = candidate->next)
        if (candidate == *context) { InterlockedIncrement(&candidate->references); found = candidate; break; }
    ReleaseSRWLockShared(&contexts_lock);
    return found;
}

static void report(struct fsr_context *context, uint32_t type, const WCHAR *message)
{
    ffxApiMessage callback = context && context->message ? context->message : global_message;
    uint32_t level = context && context->message ? context->debug_level : global_debug_level;
    if (!callback) return;
    if (type == FFX_API_MESSAGE_TYPE_ERROR && !(level & FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_ERRORS)) return;
    if (type == FFX_API_MESSAGE_TYPE_WARNING && !(level & FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_WARNINGS)) return;
    callback(type, message);
}

static void *context_alloc(const ffxAllocationCallbacks *callbacks, uint64_t size)
{
    return callbacks && callbacks->alloc ? callbacks->alloc(callbacks->pUserData, size) : malloc((size_t)size);
}

static void context_free(const ffxAllocationCallbacks *callbacks, void *memory)
{
    if (callbacks && callbacks->dealloc) callbacks->dealloc(callbacks->pUserData, memory);
    else free(memory);
}

static void release_context(struct fsr_context *context)
{
    if (InterlockedDecrement(&context->references) == 0)
        context_free(&context->allocation, context);
}

static int allocation_compatible(const ffxAllocationCallbacks *a, const ffxAllocationCallbacks *b)
{
    if (!b) return !a->alloc && !a->dealloc;
    return a->pUserData == b->pUserData && a->alloc == b->alloc && a->dealloc == b->dealloc;
}

ffxReturnCode_t WINAPI ffxCreateContext(ffxContext *output, ffxCreateContextDescHeader *desc,
                                        const ffxAllocationCallbacks *callbacks)
{
    const ffxApiHeader *entry;
    const struct ffxCreateContextDescUpscale *upscale = NULL;
    const struct local_backend_dx12_desc *backend = NULL;
    uint64_t provider = PROVIDER_ID;
    struct fsr_context *context;
    struct yaagl_fsr_create_packet packet;
    ffxReturnCode_t result;

    if (!output || !desc || (callbacks && (!!callbacks->alloc != !!callbacks->dealloc)))
        return FFX_API_RETURN_ERROR_PARAMETER;
    *output = NULL;
    for (entry = desc; entry; entry = entry->pNext)
    {
        switch (entry->type)
        {
        case FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE:
            if (upscale) return FFX_API_RETURN_ERROR_PARAMETER;
            upscale = (const struct ffxCreateContextDescUpscale *)entry;
            break;
        case FFX_API_CREATE_CONTEXT_DESC_TYPE_BACKEND_DX12:
            if (backend) return FFX_API_RETURN_ERROR_PARAMETER;
            backend = (const struct local_backend_dx12_desc *)entry;
            break;
        case FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE_VERSION:
            if (((const struct ffxCreateContextDescUpscaleVersion *)entry)->version != FFX_UPSCALER_VERSION)
                return FFX_API_RETURN_ERROR_PARAMETER;
            break;
        case FFX_API_DESC_TYPE_OVERRIDE_VERSION:
            provider = ((const struct ffxOverrideVersion *)entry)->versionId;
            break;
        default:
            return (entry->type & FFX_API_EFFECT_MASK) == FFX_API_EFFECT_ID_UPSCALE
                ? FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE : FFX_API_RETURN_NO_PROVIDER;
        }
    }
    if (!upscale || !backend || !backend->device || !upscale->maxRenderSize.width ||
        !upscale->maxRenderSize.height || !upscale->maxUpscaleSize.width ||
        !upscale->maxUpscaleSize.height || provider != PROVIDER_ID)
        return FFX_API_RETURN_ERROR_PARAMETER;
    if (upscale->maxRenderSize.width > upscale->maxUpscaleSize.width ||
        upscale->maxRenderSize.height > upscale->maxUpscaleSize.height)
        return FFX_API_RETURN_ERROR_PARAMETER;

    context = context_alloc(callbacks, sizeof(*context));
    if (!context) return FFX_API_RETURN_ERROR_MEMORY;
    memset(context, 0, sizeof(*context));
    if (callbacks) context->allocation = *callbacks;
    context->message = upscale->fpMessage;
    context->debug_level = FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_ERRORS;
    context->references = 1;
    memset(&packet, 0, sizeof(packet));
    packet.header.size = sizeof(packet);
    packet.header.operation = YAAGL_FSR_CREATE;
    packet.device = (uint64_t)(uintptr_t)backend->device;
    packet.flags = upscale->flags;
    packet.max_render_width = upscale->maxRenderSize.width;
    packet.max_render_height = upscale->maxRenderSize.height;
    packet.max_upscale_width = upscale->maxUpscaleSize.width;
    packet.max_upscale_height = upscale->maxUpscaleSize.height;
    packet.provider_version = provider;
    result = unix_call(&packet);
    if (result != FFX_API_RETURN_OK || !packet.header.context)
    {
        context_free(callbacks, context);
        return result == FFX_API_RETURN_OK ? FFX_API_RETURN_ERROR_RUNTIME_ERROR : result;
    }
    context->native = packet.header.context;
    context->device = backend->device;
    ((ULONG (WINAPI *)(void *))(*(void ***)context->device)[1])(context->device);
    AcquireSRWLockExclusive(&contexts_lock);
    context->next = contexts;
    contexts = context;
    ReleaseSRWLockExclusive(&contexts_lock);
    *output = context;
    return FFX_API_RETURN_OK;
}

ffxReturnCode_t WINAPI ffxDestroyContext(ffxContext *handle, const ffxAllocationCallbacks *callbacks)
{
    struct fsr_context **link, *context = NULL;
    struct yaagl_fsr_packet_header packet;
    ffxReturnCode_t result;
    if (!handle || !*handle) return FFX_API_RETURN_ERROR_PARAMETER;
    AcquireSRWLockExclusive(&contexts_lock);
    for (link = &contexts; *link; link = &(*link)->next)
        if (*link == *handle) { context = *link; *link = context->next; break; }
    ReleaseSRWLockExclusive(&contexts_lock);
    if (!context) return FFX_API_RETURN_ERROR_PARAMETER;
    *handle = NULL;
    if (!allocation_compatible(&context->allocation, callbacks))
    {
        AcquireSRWLockExclusive(&contexts_lock);
        context->next = contexts; contexts = context;
        ReleaseSRWLockExclusive(&contexts_lock);
        *handle = context;
        return FFX_API_RETURN_ERROR_PARAMETER;
    }
    memset(&packet, 0, sizeof(packet));
    packet.size = sizeof(packet); packet.operation = YAAGL_FSR_DESTROY; packet.context = context->native;
    result = unix_call(&packet);
    ((ULONG (WINAPI *)(void *))(*(void ***)context->device)[2])(context->device);
    release_context(context);
    return result;
}

ffxReturnCode_t WINAPI ffxConfigure(ffxContext *handle, const ffxConfigureDescHeader *desc)
{
    const struct ffxConfigureDescGlobalDebug1 *debug;
    struct fsr_context *context = NULL;
    struct yaagl_fsr_configure_packet packet;
    if (!desc) return FFX_API_RETURN_ERROR_PARAMETER;
    if (desc->type != FFX_API_CONFIGURE_DESC_TYPE_GLOBALDEBUG1)
        return (desc->type & FFX_API_EFFECT_MASK) == FFX_API_EFFECT_ID_UPSCALE
            ? FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE : FFX_API_RETURN_NO_PROVIDER;
    debug = (const struct ffxConfigureDescGlobalDebug1 *)desc;
    if (debug->debugLevel != FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_SILENCE &&
        debug->debugLevel != FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_ERRORS &&
        debug->debugLevel != FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_WARNINGS &&
        debug->debugLevel != FFX_API_CONFIGURE_GLOBALDEBUG_LEVEL_VERBOSE)
        return FFX_API_RETURN_ERROR_PARAMETER;
    if (handle && !(context = find_context(handle))) return FFX_API_RETURN_ERROR_PARAMETER;
    if (context) { context->message = debug->fpMessage; context->debug_level = debug->debugLevel; }
    else { global_message = debug->fpMessage; global_debug_level = debug->debugLevel; }
    memset(&packet, 0, sizeof(packet));
    packet.header.size = sizeof(packet); packet.header.operation = YAAGL_FSR_CONFIGURE;
    packet.header.context = context ? context->native : 0; packet.debug_level = debug->debugLevel;
    if (!context) return FFX_API_RETURN_OK;
    { ffxReturnCode_t result = unix_call(&packet); release_context(context); return result; }
}

static float upscale_ratio(uint32_t quality)
{
    static const float ratios[] = {1.0f, 1.5f, 1.7f, 2.0f, 3.0f};
    return quality < sizeof(ratios) / sizeof(ratios[0]) ? ratios[quality] : 0.0f;
}

static float radical_inverse(uint32_t index, uint32_t base)
{
    float value = 0.0f, fraction = 1.0f / base;
    while (index) { value += (index % base) * fraction; index /= base; fraction /= base; }
    return value;
}


static volatile LONG pe_log_count;
static SRWLOCK pe_log_lock = SRWLOCK_INIT;

static void pe_log_result(const char *api, const ffxContext *handle, uint64_t type,
                          ffxReturnCode_t result, const char *reason) {
    const char *path = getenv("YAAGL_FSR_LOG");
    FILE *file;
    LONG sequence;
    if (!path || path[0] != '/') return;
    sequence = InterlockedIncrement(&pe_log_count);
    if (sequence > 120) return;
    AcquireSRWLockExclusive(&pe_log_lock);
    file = fopen(path, "a");
    if (file) {
        fprintf(file, "{\"schema\":1,\"component\":\"fsr-pe\",\"event\":\"api\","
                      "\"sequence\":%ld,\"api\":\"%s\",\"type\":%llu,"
                      "\"handleAddress\":%llu,\"contextValue\":%llu,\"result\":%u,\"reason\":\"%s\"}\n",
                sequence, api, (unsigned long long)type, (unsigned long long)(uintptr_t)handle,
                (unsigned long long)(uintptr_t)(handle ? *handle : NULL), result, reason);
        fclose(file);
    }
    ReleaseSRWLockExclusive(&pe_log_lock);
}

static ffxReturnCode_t query_impl(ffxContext *handle, ffxQueryDescHeader *desc)
{
    struct fsr_context *context = NULL;
    BOOL has_context = FALSE;
    if (!desc) return FFX_API_RETURN_ERROR_PARAMETER;
    if (handle)
    {
        if (!(context = find_context(handle))) return FFX_API_RETURN_ERROR_PARAMETER;
        has_context = TRUE;
        release_context(context);
        context = NULL;
    }
    switch (desc->type)
    {
    case FFX_API_QUERY_DESC_TYPE_GET_VERSIONS:
    {
        struct ffxQueryDescGetVersions *query = (struct ffxQueryDescGetVersions *)desc;
        uint64_t capacity;
        if (query->createDescType != FFX_API_CREATE_CONTEXT_DESC_TYPE_UPSCALE)
            return FFX_API_RETURN_ERROR_PARAMETER;
        if (!query->outputCount) return FFX_API_RETURN_OK;
        capacity = *query->outputCount; *query->outputCount = 1;
        if (!capacity) return FFX_API_RETURN_OK;
        if (query->versionIds) query->versionIds[0] = PROVIDER_ID;
        if (query->versionNames) query->versionNames[0] = provider_name;
        return FFX_API_RETURN_OK;
    }
    case FFX_API_QUERY_DESC_TYPE_GET_PROVIDER_VERSION:
    {
        struct ffxQueryGetProviderVersion *query = (struct ffxQueryGetProviderVersion *)desc;
        if (!has_context) return FFX_API_RETURN_ERROR_PARAMETER;
        query->versionId = PROVIDER_ID; query->versionName = provider_name;
        return FFX_API_RETURN_OK;
    }
    case FFX_API_QUERY_DESC_TYPE_UPSCALE_GETUPSCALERATIOFROMQUALITYMODE:
    {
        struct ffxQueryDescUpscaleGetUpscaleRatioFromQualityMode *query = (void *)desc;
        float ratio = upscale_ratio(query->qualityMode);
        if (!ratio) return FFX_API_RETURN_ERROR_PARAMETER;
        if (query->pOutUpscaleRatio) *query->pOutUpscaleRatio = ratio;
        return FFX_API_RETURN_OK;
    }
    case FFX_API_QUERY_DESC_TYPE_UPSCALE_GETRENDERRESOLUTIONFROMQUALITYMODE:
    {
        struct ffxQueryDescUpscaleGetRenderResolutionFromQualityMode *query = (void *)desc;
        float ratio = upscale_ratio(query->qualityMode);
        if (!ratio || !query->displayWidth || !query->displayHeight)
            return FFX_API_RETURN_ERROR_PARAMETER;
        if (query->pOutRenderWidth) *query->pOutRenderWidth = (uint32_t)(query->displayWidth / ratio);
        if (query->pOutRenderHeight) *query->pOutRenderHeight = (uint32_t)(query->displayHeight / ratio);
        return FFX_API_RETURN_OK;
    }
    case FFX_API_QUERY_DESC_TYPE_UPSCALE_GETJITTERPHASECOUNT:
    {
        struct ffxQueryDescUpscaleGetJitterPhaseCount *query = (void *)desc;
        float ratio;
        if (!query->renderWidth || !query->displayWidth) return FFX_API_RETURN_ERROR_PARAMETER;
        ratio = (float)query->displayWidth / query->renderWidth;
        if (query->pOutPhaseCount) *query->pOutPhaseCount = (int32_t)(8.0f * powf(ratio, 2.0f));
        return FFX_API_RETURN_OK;
    }
    case FFX_API_QUERY_DESC_TYPE_UPSCALE_GETJITTEROFFSET:
    {
        struct ffxQueryDescUpscaleGetJitterOffset *query = (void *)desc;
        uint32_t index;
        if (query->phaseCount <= 0) return FFX_API_RETURN_ERROR_PARAMETER;
        index = (uint32_t)((query->index % query->phaseCount + query->phaseCount) % query->phaseCount) + 1;
        if (query->pOutX) *query->pOutX = radical_inverse(index, 2) - 0.5f;
        if (query->pOutY) *query->pOutY = radical_inverse(index, 3) - 0.5f;
        return FFX_API_RETURN_OK;
    }
    case FFX_API_QUERY_DESC_TYPE_UPSCALE_GET_RESOURCE_REQUIREMENTS:
    {
        struct ffxQueryDescUpscaleGetResourceRequirements *query = (void *)desc;
        query->required_resources = FFX_API_QUERY_RESOURCE_INPUT_COLOR | FFX_API_QUERY_RESOURCE_INPUT_DEPTH |
                                    FFX_API_QUERY_RESOURCE_INPUT_MV | FFX_API_QUERY_RESOURCE_INPUT_EXPOSURE;
        query->optional_resources = FFX_API_QUERY_RESOURCE_INPUT_REACTIVEMASK |
                                    FFX_API_QUERY_RESOURCE_INPUT_TRANSPARENCYCOMPOSITION;
        return FFX_API_RETURN_OK;
    }
    case FFX_API_QUERY_DESC_TYPE_UPSCALE_GPU_MEMORY_USAGE:
    case FFX_API_QUERY_DESC_TYPE_UPSCALE_GPU_MEMORY_USAGE_V2:
        return FFX_API_RETURN_ERROR_RUNTIME_ERROR; /* MetalFX does not expose truthful allocation totals. */
    default:
        return (desc->type & FFX_API_EFFECT_MASK) == FFX_API_EFFECT_ID_UPSCALE
            ? FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE : FFX_API_RETURN_NO_PROVIDER;
    }
}

static ffxReturnCode_t dispatch_impl(ffxContext *handle, const ffxDispatchDescHeader *desc)
{
    const struct ffxDispatchDescUpscale *dispatch;
    struct fsr_context *context;
    struct yaagl_fsr_dispatch_packet packet;
    ffxReturnCode_t result;
    if (!desc) return FFX_API_RETURN_ERROR_PARAMETER;
    if (desc->type != FFX_API_DISPATCH_DESC_TYPE_UPSCALE)
        return (desc->type & FFX_API_EFFECT_MASK) != FFX_API_EFFECT_ID_UPSCALE
            ? FFX_API_RETURN_NO_PROVIDER : FFX_API_RETURN_ERROR_UNKNOWN_DESCTYPE;
    if (!(context = find_context(handle))) return FFX_API_RETURN_ERROR_PARAMETER;
    dispatch = (const struct ffxDispatchDescUpscale *)desc;
    memset(&packet, 0, sizeof(packet));
    packet.header.size = sizeof(packet); packet.header.operation = YAAGL_FSR_DISPATCH; packet.header.context = context->native;
    packet.command_list = (uint64_t)(uintptr_t)dispatch->commandList;
    packet.color = (uint64_t)(uintptr_t)dispatch->color.resource;
    packet.depth = (uint64_t)(uintptr_t)dispatch->depth.resource;
    packet.motion_vectors = (uint64_t)(uintptr_t)dispatch->motionVectors.resource;
    packet.exposure = (uint64_t)(uintptr_t)dispatch->exposure.resource;
    packet.reactive = (uint64_t)(uintptr_t)dispatch->reactive.resource;
    packet.composition = (uint64_t)(uintptr_t)dispatch->transparencyAndComposition.resource;
    packet.output = (uint64_t)(uintptr_t)dispatch->output.resource;
    packet.color_state = dispatch->color.state; packet.depth_state = dispatch->depth.state;
    packet.motion_state = dispatch->motionVectors.state; packet.exposure_state = dispatch->exposure.state;
    packet.reactive_state = dispatch->reactive.state;
    packet.composition_state = dispatch->transparencyAndComposition.state;
    packet.output_state = dispatch->output.state;
    packet.render_width = dispatch->renderSize.width; packet.render_height = dispatch->renderSize.height;
    packet.upscale_width = dispatch->upscaleSize.width; packet.upscale_height = dispatch->upscaleSize.height;
    packet.jitter_x = dispatch->jitterOffset.x; packet.jitter_y = dispatch->jitterOffset.y;
    packet.motion_scale_x = dispatch->motionVectorScale.x; packet.motion_scale_y = dispatch->motionVectorScale.y;
    packet.sharpness = dispatch->sharpness; packet.frame_time_delta = dispatch->frameTimeDelta;
    packet.pre_exposure = dispatch->preExposure; packet.reset = dispatch->reset;
    packet.enable_sharpening = dispatch->enableSharpening; packet.flags = dispatch->flags;
    packet.camera_near = dispatch->cameraNear; packet.camera_far = dispatch->cameraFar;
    packet.camera_fov_vertical = dispatch->cameraFovAngleVertical;
    packet.view_space_to_meters = dispatch->viewSpaceToMetersFactor;
    result = unix_call(&packet);
    if (result != FFX_API_RETURN_OK) report(context, FFX_API_MESSAGE_TYPE_ERROR, L"MetalFX FSR dispatch failed");
    release_context(context);
    return result;
}

ffxReturnCode_t WINAPI ffxQuery(ffxContext *handle, ffxQueryDescHeader *desc)
{
    ffxReturnCode_t result = query_impl(handle, desc);
    const char *reason = result == FFX_API_RETURN_OK ? "ok" : "query_rejected";
    if (!desc) reason = "null_descriptor";
    else if (result == FFX_API_RETURN_ERROR_PARAMETER && handle) {
        struct fsr_context *context = find_context(handle);
        if (!context) reason = "context_not_found";
        else release_context(context);
    }
    pe_log_result("query", handle, desc ? desc->type : 0, result, reason);
    return result;
}

ffxReturnCode_t WINAPI ffxDispatch(ffxContext *handle, const ffxDispatchDescHeader *desc)
{
    struct fsr_context *known_context = find_context(handle);
    BOOL context_known = known_context != NULL;
    ffxReturnCode_t result;
    const char *reason;
    if (known_context) release_context(known_context);
    result = dispatch_impl(handle, desc);
    reason = result == FFX_API_RETURN_OK ? "ok" : "dispatch_rejected";
    if (!desc) reason = "null_descriptor";
    else if (desc->type != FFX_API_DISPATCH_DESC_TYPE_UPSCALE) reason = "unsupported_descriptor";
    else if (result == FFX_API_RETURN_ERROR_PARAMETER)
        reason = context_known ? "native_parameter" : "context_not_found";
    pe_log_result("dispatch", handle, desc ? desc->type : 0, result, reason);
    return result;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void *reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH)
    {
        DisableThreadLibraryCalls(instance);
        if (__wine_init_unix_call()) return FALSE;
    }
    return TRUE;
}
