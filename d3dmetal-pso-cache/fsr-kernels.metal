// Derived from AMD FidelityFX SDK v2.1.0 RCAS at commit
// 0836aa7f24058b3f8d035a88c0774457d78fc98e.
// Copyright (C) 2025 Advanced Micro Devices, Inc.
// SPDX-License-Identifier: MIT

#include <metal_stdlib>
using namespace metal;

struct YaaglFsrParams {
    uint2 sourceOrigin;
    uint2 destinationOrigin;
    uint2 extent;
    uint2 dispatchOrigin;
    uint2 dispatchExtent;
    uint transfer;
    uint flags;
    float sharpness;
    float exposure;
};

enum : uint {
    YaaglFsrHasReactive = 1u << 0,
    YaaglFsrHasComposition = 1u << 1,
    YaaglFsrSharpen = 1u << 2,
    YaaglFsrHasExposure = 1u << 3,
    YaaglFsrCenteredOutput = 1u << 4,
};

static float3 inverse_srgb(float3 value) {
    return select(value / 12.92f, powr((value + 0.055f) / 1.055f, 2.4f),
                  value > 0.04045f);
}

static float3 forward_srgb(float3 value) {
    value = max(value, 0.0f);
    return select(value * 12.92f, 1.055f * powr(value, 1.0f / 2.4f) - 0.055f,
                  value > 0.0031308f);
}

static float3 inverse_pq(float3 value) {
    constexpr float m1 = 0.1593017578125f;
    constexpr float m2 = 78.84375f;
    constexpr float c1 = 0.8359375f;
    constexpr float c2 = 18.8515625f;
    constexpr float c3 = 18.6875f;
    float3 p = powr(clamp(value, 0.0f, 1.0f), 1.0f / m2);
    return powr(max(p - c1, 0.0f) / max(c2 - c3 * p, 1.0e-7f), 1.0f / m1);
}

static float3 forward_pq(float3 value) {
    constexpr float m1 = 0.1593017578125f;
    constexpr float m2 = 78.84375f;
    constexpr float c1 = 0.8359375f;
    constexpr float c2 = 18.8515625f;
    constexpr float c3 = 18.6875f;
    float3 p = powr(max(value, 0.0f), m1);
    return powr((c1 + c2 * p) / (1.0f + c3 * p), m2);
}

static float3 inverse_transfer(float3 value, uint transfer) {
    if (transfer == 1u) return inverse_srgb(value);
    if (transfer == 2u) return inverse_pq(value);
    return value;
}

static float3 forward_transfer(float3 value, uint transfer) {
    if (transfer == 1u) return forward_srgb(value);
    if (transfer == 2u) return forward_pq(value);
    return value;
}

kernel void yaagl_fsr_linearize(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant YaaglFsrParams& params [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if (any(tid >= params.extent)) return;
    uint2 sourcePosition = params.sourceOrigin + tid;
    uint2 destinationPosition = params.destinationOrigin + tid;
    float4 color = source.read(sourcePosition);
    color.rgb = inverse_transfer(color.rgb, params.transfer);
    destination.write(color, destinationPosition);
}

kernel void yaagl_fsr_combine_masks(
    texture2d<float, access::read> reactive [[texture(0)]],
    texture2d<float, access::read> composition [[texture(1)]],
    texture2d<float, access::write> destination [[texture(2)]],
    constant YaaglFsrParams& params [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if (any(tid >= params.extent)) return;
    uint2 sourcePosition = params.sourceOrigin + tid;
    uint2 destinationPosition = params.destinationOrigin + tid;
    float r = (params.flags & YaaglFsrHasReactive) ? reactive.read(sourcePosition).r : 0.0f;
    float c = (params.flags & YaaglFsrHasComposition) ? composition.read(sourcePosition).r : 0.0f;
    destination.write(float4(max(clamp(r, 0.0f, 1.0f), clamp(c, 0.0f, 1.0f))),
                      destinationPosition);
}

static float3 rcas_load(texture2d<float, access::read> source, int2 position,
                        uint2 lower, uint2 upper, float exposure) {
    int2 bounded = clamp(position, int2(lower), int2(upper - 1u));
    return source.read(uint2(bounded)).rgb * exposure;
}

static float3 rcas(texture2d<float, access::read> source, uint2 position,
                   uint2 lower, uint2 upper, float sharpness, float exposure) {
    int2 p = int2(position);
    float3 b = rcas_load(source, p + int2(0, -1), lower, upper, exposure);
    float3 d = rcas_load(source, p + int2(-1, 0), lower, upper, exposure);
    float3 e = rcas_load(source, p, lower, upper, exposure);
    float3 f = rcas_load(source, p + int2(1, 0), lower, upper, exposure);
    float3 h = rcas_load(source, p + int2(0, 1), lower, upper, exposure);

    float bL = b.b * 0.5f + (b.r * 0.5f + b.g);
    float dL = d.b * 0.5f + (d.r * 0.5f + d.g);
    float eL = e.b * 0.5f + (e.r * 0.5f + e.g);
    float fL = f.b * 0.5f + (f.r * 0.5f + f.g);
    float hL = h.b * 0.5f + (h.r * 0.5f + h.g);

    float range = max(max(max(bL, dL), max(eL, fL)), hL) -
                  min(min(min(bL, dL), min(eL, fL)), hL);
    float nz = saturate(abs(0.25f * (bL + dL + fL + hL) - eL) / range);
    nz = -0.5f * nz + 1.0f;

    float3 mn4 = min(min(b, d), min(f, h));
    float3 mx4 = max(max(b, d), max(f, h));
    float lowerLimiterMultiplier = saturate(eL / min(min(bL, dL), min(fL, hL)));
    float3 hitMin = mn4 / (4.0f * mx4) * lowerLimiterMultiplier;
    float3 hitMax = (1.0f - mx4) / (4.0f * mn4 - 4.0f);
    float3 lobes = max(-hitMin, hitMax);
    float lobe = max(-0.1875f, min(max(max(lobes.r, lobes.g), lobes.b), 0.0f));

    // FidelityFX maps API sharpness [0,1] to stops (2 - 2*sharpness), then FsrRcasCon
    // maps stops with exp2(-stops).
    lobe *= exp2(-((-2.0f * sharpness) + 2.0f)) * nz;
    float reciprocal = 1.0f / (4.0f * lobe + 1.0f);
    return (lobe * (b + d + h + f) + e) * reciprocal / exposure;
}

kernel void yaagl_fsr_finish(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    texture2d<float, access::read> exposureTexture [[texture(2)]],
    constant YaaglFsrParams& params [[buffer(0)]],
    uint2 tid [[thread_position_in_grid]]) {
    if (any(tid >= params.dispatchExtent)) return;
    uint2 destinationPosition = params.dispatchOrigin + tid;
    if ((params.flags & YaaglFsrCenteredOutput) &&
        (any(destinationPosition < params.destinationOrigin) ||
         any(destinationPosition >= params.destinationOrigin + params.extent))) {
        destination.write(float4(0.0f, 0.0f, 0.0f, 1.0f), destinationPosition);
        return;
    }
    uint2 sourcePosition = params.sourceOrigin + destinationPosition - params.destinationOrigin;
    float4 color = source.read(sourcePosition);
    float exposure = params.exposure;
    if (params.flags & YaaglFsrHasExposure)
        exposure = max(exposureTexture.read(uint2(0)).r, 1.0e-7f);
    if (params.flags & YaaglFsrSharpen)
        color.rgb = rcas(source, sourcePosition, params.sourceOrigin,
                         params.sourceOrigin + params.extent, params.sharpness, exposure);
    color.rgb = forward_transfer(color.rgb, params.transfer);
    destination.write(color, destinationPosition);
}
