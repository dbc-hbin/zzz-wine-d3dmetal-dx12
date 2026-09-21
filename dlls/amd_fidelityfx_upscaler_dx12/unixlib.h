/* FSR 4 API to MetalFX bridge. */
#pragma once

#include <stdarg.h>
#include "windef.h"
#include "winternl.h"
#include "wine/unixlib.h"
#include "../../include/yaagl_fsr_bridge.h"

enum yaagl_fsr_unix_func
{
    unix_fsr_api,
    unix_fsr_funcs_count
};
