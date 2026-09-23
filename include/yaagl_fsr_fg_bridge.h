/* Fixed-width private PE/Unix/native contract for FSR frame generation. */
#pragma once

#include <stdint.h>

#define YAAGL_FSR_FG_BRIDGE_VERSION 3u

enum yaagl_fsr_fg_create_flags
{
    YAAGL_FSR_FG_DEPTH_INVERTED = 1u << 0,
    YAAGL_FSR_FG_DEPTH_INFINITE = 1u << 1,
    YAAGL_FSR_FG_DISPLAY_RESOLUTION_MOTION_VECTORS = 1u << 2,
    YAAGL_FSR_FG_MOTION_VECTORS_JITTERED = 1u << 3
};

enum yaagl_fsr_fg_operation
{
    YAAGL_FSR_FG_PROBE = 0,
    YAAGL_FSR_FG_CREATE = 1,
    YAAGL_FSR_FG_PREPARE = 2,
    YAAGL_FSR_FG_DISPATCH = 3,
    YAAGL_FSR_FG_DESTROY = 4,
    YAAGL_FSR_FG_CONFIGURE = 5
};

struct yaagl_fsr_fg_packet_header
{
    uint32_t size;
    uint32_t version;
    uint32_t operation;
    uint32_t result;
    uint64_t context;
};

struct yaagl_fsr_fg_probe_packet
{
    struct yaagl_fsr_fg_packet_header header;
    uint64_t device;
    uint32_t display_width;
    uint32_t display_height;
    uint32_t backbuffer_format;
    uint32_t flags;
    uint32_t legacy_supported;
    uint32_t metal4_supported;
};

struct yaagl_fsr_fg_create_packet
{
    struct yaagl_fsr_fg_packet_header header;
    uint64_t device;
    uint32_t display_width;
    uint32_t display_height;
    uint32_t max_render_width;
    uint32_t max_render_height;
    uint32_t backbuffer_format;
    uint32_t flags;
};

struct yaagl_fsr_fg_prepare_packet
{
    struct yaagl_fsr_fg_packet_header header;
    uint64_t command_list;
    uint64_t frame_id;
    uint64_t depth;
    uint64_t motion_vectors;
    uint32_t depth_state;
    uint32_t motion_vectors_state;
    uint32_t render_width;
    uint32_t render_height;
    uint32_t flags;
    uint32_t reset;
    float jitter_x;
    float jitter_y;
    float motion_scale_x;
    float motion_scale_y;
    float frame_time_delta_ms;
    float camera_near;
    float camera_far;
    float camera_fov_vertical_radians;
    float view_space_to_meters;
    float camera_position[3];
    float camera_up[3];
    float camera_right[3];
    float camera_forward[3];
    uint32_t camera_info_present;
};

struct yaagl_fsr_fg_dispatch_packet
{
    struct yaagl_fsr_fg_packet_header header;
    uint64_t command_list;
    uint64_t frame_id;
    uint64_t present_color;
    uint64_t output;
    uint64_t hudless_color;
    uint32_t present_color_state;
    uint32_t output_state;
    uint32_t hudless_color_state;
    uint32_t num_generated_frames;
    uint32_t reset;
    uint32_t backbuffer_transfer_function;
    int32_t generation_rect_left;
    int32_t generation_rect_top;
    int32_t generation_rect_width;
    int32_t generation_rect_height;
    float min_luminance;
    float max_luminance;
};

/* Configure changes metadata ownership; recorded commands retain their own snapshots. */
struct yaagl_fsr_fg_configure_packet
{
    struct yaagl_fsr_fg_packet_header header;
    uint32_t enabled;
};

struct yaagl_fsr_fg_destroy_packet
{
    struct yaagl_fsr_fg_packet_header header;
};
