/* Fixed-width private PE/Unix/native contract for the FSR translator. */
#pragma once
#include <stdint.h>

enum yaagl_fsr_operation
{
    YAAGL_FSR_CREATE = 0,
    YAAGL_FSR_DESTROY = 1,
    YAAGL_FSR_CONFIGURE = 2,
    YAAGL_FSR_QUERY = 3,
    YAAGL_FSR_DISPATCH = 4
};

struct yaagl_fsr_packet_header
{
    uint32_t size;
    uint32_t result;
    uint32_t operation;
    uint32_t reserved;
    uint64_t context;
};

struct yaagl_fsr_create_packet
{
    struct yaagl_fsr_packet_header header;
    uint64_t device;
    uint32_t flags;
    uint32_t max_render_width, max_render_height;
    uint32_t max_upscale_width, max_upscale_height;
    uint64_t provider_version;
};

struct yaagl_fsr_configure_packet
{
    struct yaagl_fsr_packet_header header;
    uint32_t debug_level;
    uint32_t reserved;
};

struct yaagl_fsr_query_packet
{
    struct yaagl_fsr_packet_header header;
    uint64_t type;
    uint64_t required_resources;
    uint64_t optional_resources;
};

struct yaagl_fsr_dispatch_packet
{
    struct yaagl_fsr_packet_header header;
    uint64_t command_list, color, depth, motion_vectors, exposure;
    uint64_t reactive, composition, output;
    uint32_t color_state, depth_state, motion_state, exposure_state;
    uint32_t reactive_state, composition_state, output_state, state_reserved;
    uint32_t render_width, render_height, upscale_width, upscale_height;
    float jitter_x, jitter_y, motion_scale_x, motion_scale_y;
    float sharpness, frame_time_delta, pre_exposure;
    float camera_near, camera_far, camera_fov_vertical, view_space_to_meters;
    uint32_t reset, enable_sharpening, flags, reserved;
};
