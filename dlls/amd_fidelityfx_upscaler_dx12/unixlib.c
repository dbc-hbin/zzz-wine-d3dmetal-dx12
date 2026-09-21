/* FSR 4 API to MetalFX bridge. */
#if 0
#pragma makedep unix
#endif

#include "config.h"
#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "ntstatus.h"
#include "unixlib.h"

typedef uint32_t (*yaagl_fsr_api_fn)(uint32_t operation, void *arguments);

static void *sidecar_handle;
static yaagl_fsr_api_fn sidecar_api;
static pthread_mutex_t sidecar_mutex = PTHREAD_MUTEX_INITIALIZER;

static void load_sidecar(void)
{
    Dl_info info;
    char path[PATH_MAX];
    char *slash;

    pthread_mutex_lock(&sidecar_mutex);
    if (sidecar_api) { pthread_mutex_unlock(&sidecar_mutex); return; }
    if (!dladdr((const void *)&load_sidecar, &info) || !info.dli_fname) goto done;
    if (strlen(info.dli_fname) + sizeof("/../../external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib") >= sizeof(path)) goto done;
    strcpy(path, info.dli_fname);
    slash = strrchr(path, '/');
    if (!slash) goto done;
    strcpy(slash + 1, "../../external/D3DMetal.framework/Versions/A/Resources/libYaaglNativePsoCache.dylib");
    sidecar_handle = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
    if (!sidecar_handle) goto done;
    sidecar_api = (yaagl_fsr_api_fn)dlsym(sidecar_handle, "yaagl_fsr_api");
    if (!sidecar_api)
    {
        dlclose(sidecar_handle);
        sidecar_handle = NULL;
    }
done:
    pthread_mutex_unlock(&sidecar_mutex);
}

static NTSTATUS fsr_api(void *args)
{
    struct yaagl_fsr_packet_header *header = args;
    uint32_t operation;

    if (!header || header->size < sizeof(*header)) return STATUS_INVALID_PARAMETER;
    operation = header->operation;
    load_sidecar();
    if (!sidecar_api)
    {
        header->result = 3; /* FFX_API_RETURN_ERROR_RUNTIME_ERROR */
        return STATUS_DLL_NOT_FOUND;
    }
    header->result = sidecar_api(operation, args);
    return STATUS_SUCCESS;
}

const unixlib_entry_t __wine_unix_call_funcs[] =
{
    fsr_api,
};

C_ASSERT(ARRAYSIZE(__wine_unix_call_funcs) == unix_fsr_funcs_count);
