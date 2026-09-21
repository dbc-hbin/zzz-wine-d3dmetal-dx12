/* FSR frame-generation PE to native bridge. */
#pragma once

#include <stdarg.h>
#include "windef.h"
#include "winternl.h"
#include "wine/unixlib.h"
#include "../../include/yaagl_fsr_fg_bridge.h"

enum yaagl_fsr_fg_unix_func
{
    unix_fsr_fg_api,
    unix_fsr_fg_funcs_count
};
