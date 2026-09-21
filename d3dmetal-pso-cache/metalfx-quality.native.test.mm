#import "metalfx-contract.hpp"
#import "metalfx-backend.hpp"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <memory>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

using namespace yaagl::pso::metalfx;

namespace {

constexpr NSUInteger W = 96;
constexpr NSUInteger H = 64;
constexpr NSUInteger OW = 192;
constexpr NSUInteger OH = 128;
constexpr unsigned Frames = 16;
constexpr float Scale = 2.0f;

[[noreturn]] void fail(const std::string& message) {
    std::fprintf(stderr, "FAIL %s\n", message.c_str());
    std::exit(1);
}

void require(bool value, const std::string& message) {
    if (!value) fail(message);
}

float clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

float srgbEncode(float linear) {
    linear = clamp01(linear);
    if (linear <= 0.0031308f) return 12.92f * linear;
    return 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
}

float srgbDecode(float encoded) {
    encoded = clamp01(encoded);
    if (encoded <= 0.04045f) return encoded / 12.92f;
    return std::pow((encoded + 0.055f) / 1.055f, 2.4f);
}

float halton(unsigned index, unsigned base) {
    float result = 0.0f;
    float weight = 1.0f;
    for (; index; index /= base) {
        weight /= static_cast<float>(base);
        result += weight * static_cast<float>(index % base);
    }
    return result - 0.5f;
}

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;
};

struct Rgb {
    float r = 0.0f;
    float g = 0.0f;
    float b = 0.0f;
};

enum class Pattern {
    ThinText,
    SubpixelPan,
    Disocclusion,
    HdrPreExposure,
    SrgbThinText,
    OutputResJittered,
    FrameReset,
};

struct Scenario {
    const char* name = nullptr;
    Pattern pattern = Pattern::ThinText;
    MTLPixelFormat format = MTLPixelFormatRGBA8Unorm;
    bool hdr = false;
    bool outputResolutionMotion = false;
    bool jitteredMotion = false;
    float preExposure = 1.0f;
    int resetFrame = -1;
};

constexpr std::array<Scenario, 7> Scenarios{{
    {"stationary-thin-text-unorm", Pattern::ThinText, MTLPixelFormatRGBA8Unorm,
     false, false, false, 1.0f, -1},
    {"subpixel-pan-unorm", Pattern::SubpixelPan, MTLPixelFormatRGBA8Unorm,
     false, false, false, 1.0f, -1},
    {"moving-foreground-disocclusion", Pattern::Disocclusion, MTLPixelFormatRGBA8Unorm,
     false, false, false, 1.0f, -1},
    {"hdr-preexposure-rgba16f", Pattern::HdrPreExposure, MTLPixelFormatRGBA16Float,
     true, false, false, 2.0f, -1},
    {"stationary-thin-text-srgb", Pattern::SrgbThinText, MTLPixelFormatRGBA8Unorm_sRGB,
     false, false, false, 1.0f, -1},
    {"outputres-jittered-subpixel-pan", Pattern::OutputResJittered, MTLPixelFormatRGBA8Unorm,
     false, true, true, 1.0f, -1},
    {"explicit-frame-reset", Pattern::FrameReset, MTLPixelFormatRGBA8Unorm,
     false, false, false, 1.0f, 8},
}};

std::string modeName(CommandMode mode) {
    return mode == CommandMode::Metal4 ? "metal4" : "legacy";
}

std::string formatName(MTLPixelFormat format) {
    switch (format) {
    case MTLPixelFormatRGBA8Unorm: return "rgba8unorm";
    case MTLPixelFormatRGBA8Unorm_sRGB: return "rgba8unorm-srgb";
    case MTLPixelFormatRGBA16Float: return "rgba16float";
    default: return "unknown";
    }
}

NSUInteger bytesPerPixel(MTLPixelFormat format) {
    if (format == MTLPixelFormatRGBA16Float) return 8;
    if (format == MTLPixelFormatRGBA8Unorm || format == MTLPixelFormatRGBA8Unorm_sRGB) return 4;
    fail("unsupported color format in quality test");
}

bool isSrgb(MTLPixelFormat format) {
    return format == MTLPixelFormatRGBA8Unorm_sRGB;
}

Vec2 jitterFor(unsigned frame) {
    return {halton(frame + 1, 2), halton(frame + 1, 3)};
}

Vec2 translationFor(const Scenario& scenario, unsigned frame) {
    switch (scenario.pattern) {
    case Pattern::SubpixelPan:
    case Pattern::OutputResJittered:
        return {0.375f * frame, 0.1875f * frame};
    case Pattern::FrameReset:
        if (frame < 8) return {0.25f * frame, 0.125f * frame};
        return {10.0f + 0.25f * static_cast<float>(frame - 8),
                -3.0f + 0.125f * static_cast<float>(frame - 8)};
    default:
        return {};
    }
}

Vec2 foregroundTranslation(unsigned frame) {
    return {1.25f * frame, 0.375f * frame};
}

float distanceToPeriodicLine(float value, float period) {
    float wrapped = std::fmod(value, period);
    if (wrapped < 0.0f) wrapped += period;
    return std::min(wrapped, period - wrapped);
}

float rectCoverage(float x, float y, float x0, float y0, float x1, float y1) {
    const float dx = std::max(std::max(x0 - x, 0.0f), x - x1);
    const float dy = std::max(std::max(y0 - y, 0.0f), y - y1);
    const float outside = std::sqrt(dx * dx + dy * dy);
    const float insideX = std::min(x - x0, x1 - x);
    const float insideY = std::min(y - y0, y1 - y);
    const float signedDistance = (x >= x0 && x <= x1 && y >= y0 && y <= y1)
        ? -std::min(insideX, insideY) : outside;
    return clamp01(0.5f - signedDistance);
}

float glyphStroke(float x, float y) {
    // Two tiny vector glyphs resembling "HI", built from subpixel rectangles.
    const float hLeft = rectCoverage(x, y, 24.0f, 20.0f, 25.0f, 31.0f);
    const float hRight = rectCoverage(x, y, 31.0f, 20.0f, 32.0f, 31.0f);
    const float hBar = rectCoverage(x, y, 24.0f, 25.0f, 32.0f, 26.0f);
    const float iTop = rectCoverage(x, y, 36.0f, 20.0f, 42.0f, 21.0f);
    const float iStem = rectCoverage(x, y, 38.5f, 20.0f, 39.5f, 31.0f);
    const float iBottom = rectCoverage(x, y, 36.0f, 30.0f, 42.0f, 31.0f);
    return std::max({hLeft, hRight, hBar, iTop, iStem, iBottom});
}

Rgb baseScene(float x, float y) {
    const float grid = std::max(
        clamp01(0.75f - distanceToPeriodicLine(x + 1.25f, 9.0f)),
        clamp01(0.75f - distanceToPeriodicLine(y + 0.75f, 11.0f)));
    const float diagonal = clamp01(0.8f - distanceToPeriodicLine(x + 0.5f * y, 13.0f));
    const float text = glyphStroke(x, y);
    const float background = 0.045f + 0.012f * std::sin(x * 0.31f) +
                             0.009f * std::cos(y * 0.27f);
    const float value = clamp01(background + 0.46f * grid + 0.18f * diagonal + 0.42f * text);
    return {value, value * 0.92f, value * 0.78f};
}

Rgb markerColor(float x, float y, Vec2 center) {
    const float dx = x - center.x;
    const float dy = y - center.y;
    const float radius = std::sqrt(dx * dx + dy * dy);
    const float coverage = clamp01(3.0f - radius);
    return {coverage, coverage * 0.04f, coverage};
}

bool foregroundAt(float x, float y, unsigned frame) {
    const Vec2 offset = foregroundTranslation(frame);
    const float cx = 39.0f + offset.x;
    const float cy = 35.0f + offset.y;
    return x >= cx - 9.5f && x <= cx + 9.5f && y >= cy - 7.0f && y <= cy + 7.0f;
}

Rgb sceneColor(const Scenario& scenario, float sampleX, float sampleY, unsigned frame) {
    if (scenario.pattern == Pattern::Disocclusion) {
        Rgb background = baseScene(sampleX, sampleY);
        if (!foregroundAt(sampleX, sampleY, frame)) return background;
        const Vec2 offset = foregroundTranslation(frame);
        const Vec2 center{39.0f + offset.x, 35.0f + offset.y};
        const Rgb marker = markerColor(sampleX, sampleY, center);
        const float stripe = 0.12f * std::sin((sampleX - offset.x) * 1.6f);
        return {clamp01(0.82f + stripe + marker.r * 0.18f),
                clamp01(0.10f + marker.g * 0.1f),
                clamp01(0.08f + marker.b * 0.55f)};
    }

    const Vec2 translation = translationFor(scenario, frame);
    const float worldX = sampleX - translation.x;
    const float worldY = sampleY - translation.y;
    Rgb value = baseScene(worldX, worldY);
    const Vec2 marker{61.0f, 40.0f};
    const Rgb markerValue = markerColor(worldX, worldY, marker);
    value.r = clamp01(std::max(value.r, markerValue.r));
    value.g = clamp01(value.g * (1.0f - 0.95f * markerValue.r));
    value.b = clamp01(std::max(value.b, markerValue.b));
    if (scenario.pattern == Pattern::HdrPreExposure) {
        value.r *= 0.72f;
        value.g *= 0.68f;
        value.b *= 0.64f;
    }
    return value;
}

Vec2 markerWorldCenter(const Scenario& scenario, unsigned frame) {
    if (scenario.pattern == Pattern::Disocclusion) {
        const Vec2 t = foregroundTranslation(frame);
        return {39.0f + t.x, 35.0f + t.y};
    }
    const Vec2 t = translationFor(scenario, frame);
    return {61.0f + t.x, 40.0f + t.y};
}

float depthAt(const Scenario& scenario, float sampleX, float sampleY, unsigned frame) {
    if (scenario.pattern == Pattern::Disocclusion && foregroundAt(sampleX, sampleY, frame))
        return 0.88f;
    return 0.18f;
}

Vec2 geometricMotionAt(const Scenario& scenario, float sampleX, float sampleY,
                       unsigned frame) {
    if (frame == 0) return {};
    if (scenario.pattern == Pattern::Disocclusion) {
        if (!foregroundAt(sampleX, sampleY, frame)) return {};
        const Vec2 now = foregroundTranslation(frame);
        const Vec2 previous = foregroundTranslation(frame - 1);
        return {previous.x - now.x, previous.y - now.y};
    }
    const Vec2 now = translationFor(scenario, frame);
    const Vec2 previous = translationFor(scenario, frame - 1);
    if (scenario.pattern == Pattern::FrameReset && static_cast<int>(frame) == scenario.resetFrame)
        return {};
    return {previous.x - now.x, previous.y - now.y};
}

struct FramePixels {
    std::vector<std::uint8_t> color8;
    std::vector<_Float16> color16;
    std::vector<float> depth;
    std::vector<_Float16> motion;
    Vec2 jitter{};
    Vec2 previousJitter{};
    Vec2 expectedInputMarker{};
    Vec2 expectedOutputMarker{};
    Vec2 backgroundMotion{};
    Vec2 foregroundMotion{};
    bool callerReset = false;
};

FramePixels generateFrame(const Scenario& scenario, unsigned frame) {
    FramePixels result;
    result.jitter = jitterFor(frame);
    result.previousJitter = frame ? jitterFor(frame - 1) : result.jitter;
    result.callerReset = scenario.resetFrame >= 0 && static_cast<int>(frame) == scenario.resetFrame;
    const Vec2 marker = markerWorldCenter(scenario, frame);
    result.expectedInputMarker = {marker.x + result.jitter.x, marker.y + result.jitter.y};
    result.expectedOutputMarker = {marker.x * Scale, marker.y * Scale};

    const NSUInteger colorPixels = W * H;
    if (scenario.format == MTLPixelFormatRGBA16Float) result.color16.resize(colorPixels * 4);
    else result.color8.resize(colorPixels * 4);
    result.depth.resize(colorPixels);

    for (NSUInteger y = 0; y < H; ++y) {
        for (NSUInteger x = 0; x < W; ++x) {
            const float sampleX = static_cast<float>(x) + 0.5f - result.jitter.x;
            const float sampleY = static_cast<float>(y) + 0.5f - result.jitter.y;
            Rgb color = sceneColor(scenario, sampleX, sampleY, frame);
            const std::size_t index = y * W + x;
            result.depth[index] = depthAt(scenario, sampleX, sampleY, frame);
            if (scenario.format == MTLPixelFormatRGBA16Float) {
                const float scale = scenario.preExposure;
                result.color16[index * 4 + 0] = static_cast<_Float16>(color.r * scale);
                result.color16[index * 4 + 1] = static_cast<_Float16>(color.g * scale);
                result.color16[index * 4 + 2] = static_cast<_Float16>(color.b * scale);
                result.color16[index * 4 + 3] = static_cast<_Float16>(1.0f);
            } else {
                if (isSrgb(scenario.format)) {
                    color.r = srgbEncode(color.r);
                    color.g = srgbEncode(color.g);
                    color.b = srgbEncode(color.b);
                }
                result.color8[index * 4 + 0] = static_cast<std::uint8_t>(std::lround(clamp01(color.r) * 255.0f));
                result.color8[index * 4 + 1] = static_cast<std::uint8_t>(std::lround(clamp01(color.g) * 255.0f));
                result.color8[index * 4 + 2] = static_cast<std::uint8_t>(std::lround(clamp01(color.b) * 255.0f));
                result.color8[index * 4 + 3] = 255;
            }
        }
    }

    const NSUInteger motionWidth = scenario.outputResolutionMotion ? OW : W;
    const NSUInteger motionHeight = scenario.outputResolutionMotion ? OH : H;
    result.motion.resize(motionWidth * motionHeight * 2);
    const Vec2 jitterDelta = scenario.jitteredMotion
        ? Vec2{result.previousJitter.x - result.jitter.x,
               result.previousJitter.y - result.jitter.y}
        : Vec2{};
    for (NSUInteger y = 0; y < motionHeight; ++y) {
        for (NSUInteger x = 0; x < motionWidth; ++x) {
            float sampleX = static_cast<float>(x) + 0.5f;
            float sampleY = static_cast<float>(y) + 0.5f;
            if (scenario.outputResolutionMotion) {
                sampleX /= Scale;
                sampleY /= Scale;
            }
            sampleX -= result.jitter.x;
            sampleY -= result.jitter.y;
            Vec2 motion = geometricMotionAt(scenario, sampleX, sampleY, frame);
            motion.x += jitterDelta.x;
            motion.y += jitterDelta.y;
            const std::size_t index = y * motionWidth + x;
            result.motion[index * 2 + 0] = static_cast<_Float16>(motion.x);
            result.motion[index * 2 + 1] = static_cast<_Float16>(motion.y);
        }
    }
    result.backgroundMotion = jitterDelta;
    if (scenario.pattern == Pattern::Disocclusion) {
        Vec2 objectMotion = geometricMotionAt(scenario, marker.x, marker.y, frame);
        objectMotion.x += jitterDelta.x;
        objectMotion.y += jitterDelta.y;
        result.foregroundMotion = objectMotion;
    } else {
        Vec2 allMotion = geometricMotionAt(scenario, marker.x, marker.y, frame);
        allMotion.x += jitterDelta.x;
        allMotion.y += jitterDelta.y;
        result.foregroundMotion = allMotion;
    }
    return result;
}

id<MTLTexture> makeTexture(id<MTLDevice> device, MTLPixelFormat format,
                           NSUInteger width, NSUInteger height,
                           MTLStorageMode storage, MTLTextureUsage usage) {
    MTLTextureDescriptor* descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                           width:width
                                                          height:height
                                                       mipmapped:NO];
    descriptor.storageMode = storage;
    descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
    descriptor.usage = usage;
    return [device newTextureWithDescriptor:descriptor];
}

void completeLegacy(id<MTLCommandBuffer> command, const char* context) {
    [command commit];
    [command waitUntilCompleted];
    if (command.error) NSLog(@"%s: %@", context, command.error);
    require(command.status == MTLCommandBufferStatusCompleted && command.error == nil,
            std::string(context) + " GPU completion");
}

void uploadFrame(id<MTLTexture> color, id<MTLTexture> depth, id<MTLTexture> motion,
                 const Scenario& scenario, const FramePixels& frame) {
    const MTLRegion colorRegion = MTLRegionMake2D(0, 0, W, H);
    if (scenario.format == MTLPixelFormatRGBA16Float) {
        [color replaceRegion:colorRegion mipmapLevel:0
                  withBytes:frame.color16.data() bytesPerRow:W * 8];
    } else {
        [color replaceRegion:colorRegion mipmapLevel:0
                  withBytes:frame.color8.data() bytesPerRow:W * 4];
    }
    [depth replaceRegion:colorRegion mipmapLevel:0
              withBytes:frame.depth.data() bytesPerRow:W * sizeof(float)];
    const NSUInteger motionWidth = scenario.outputResolutionMotion ? OW : W;
    const NSUInteger motionHeight = scenario.outputResolutionMotion ? OH : H;
    [motion replaceRegion:MTLRegionMake2D(0, 0, motionWidth, motionHeight)
               mipmapLevel:0 withBytes:frame.motion.data()
               bytesPerRow:motionWidth * sizeof(_Float16) * 2];
}

std::vector<std::uint8_t> readTexture(id<MTLDevice> device,
                                      id<MTLCommandQueue> transfer,
                                      id<MTLTexture> texture) {
    const NSUInteger bpp = bytesPerPixel(texture.pixelFormat);
    const NSUInteger rowBytes = texture.width * bpp;
    const NSUInteger total = rowBytes * texture.height;
    std::vector<std::uint8_t> bytes(total);
    if (texture.storageMode == MTLStorageModeShared) {
        [texture getBytes:bytes.data() bytesPerRow:rowBytes
               fromRegion:MTLRegionMake2D(0, 0, texture.width, texture.height)
              mipmapLevel:0];
        return bytes;
    }
    id<MTLBuffer> buffer = [device newBufferWithLength:total options:MTLResourceStorageModeShared];
    require(buffer != nil, "readback buffer allocation");
    id<MTLCommandBuffer> command = [transfer commandBuffer];
    id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
    [encoder copyFromTexture:texture sourceSlice:0 sourceLevel:0
                sourceOrigin:MTLOriginMake(0, 0, 0)
                  sourceSize:MTLSizeMake(texture.width, texture.height, 1)
                    toBuffer:buffer destinationOffset:0
           destinationBytesPerRow:rowBytes destinationBytesPerImage:total];
    [encoder endEncoding];
    completeLegacy(command, "readback");
    std::memcpy(bytes.data(), buffer.contents, total);
    [buffer release];
    return bytes;
}

Rgb decodePixel(const std::vector<std::uint8_t>& bytes, MTLPixelFormat format,
                NSUInteger width, NSUInteger x, NSUInteger y) {
    const std::size_t index = y * width + x;
    if (format == MTLPixelFormatRGBA16Float) {
        const auto* half = reinterpret_cast<const _Float16*>(bytes.data());
        return {static_cast<float>(half[index * 4 + 0]),
                static_cast<float>(half[index * 4 + 1]),
                static_cast<float>(half[index * 4 + 2])};
    }
    Rgb result{bytes[index * 4 + 0] / 255.0f,
               bytes[index * 4 + 1] / 255.0f,
               bytes[index * 4 + 2] / 255.0f};
    if (isSrgb(format)) {
        result.r = srgbDecode(result.r);
        result.g = srgbDecode(result.g);
        result.b = srgbDecode(result.b);
    }
    return result;
}

Vec2 markerCentroid(const std::vector<std::uint8_t>& bytes, MTLPixelFormat format,
                    NSUInteger width, NSUInteger height, Vec2 expected,
                    float radius) {
    const int x0 = std::max(0, static_cast<int>(std::floor(expected.x - radius)));
    const int x1 = std::min(static_cast<int>(width), static_cast<int>(std::ceil(expected.x + radius)));
    const int y0 = std::max(0, static_cast<int>(std::floor(expected.y - radius)));
    const int y1 = std::min(static_cast<int>(height), static_cast<int>(std::ceil(expected.y + radius)));
    double sum = 0.0;
    double sumX = 0.0;
    double sumY = 0.0;
    for (int y = y0; y < y1; ++y) {
        for (int x = x0; x < x1; ++x) {
            const Rgb c = decodePixel(bytes, format, width, x, y);
            const double weight = std::max(0.0, double(c.r + c.b - 1.55f * c.g - 0.22f));
            sum += weight;
            sumX += weight * (static_cast<double>(x) + 0.5);
            sumY += weight * (static_cast<double>(y) + 0.5);
        }
    }
    require(sum > 0.25, "marker centroid mass");
    return {static_cast<float>(sumX / sum), static_cast<float>(sumY / sum)};
}

Vec2 inputMarkerCentroid(const Scenario& scenario, const FramePixels& frame) {
    std::vector<std::uint8_t> bytes;
    if (scenario.format == MTLPixelFormatRGBA16Float) {
        bytes.resize(frame.color16.size() * sizeof(_Float16));
        std::memcpy(bytes.data(), frame.color16.data(), bytes.size());
    } else {
        bytes = frame.color8;
    }
    return markerCentroid(bytes, scenario.format, W, H, frame.expectedInputMarker, 8.0f);
}

struct DiffMetrics {
    std::size_t differentBytes = 0;
    unsigned maxByteDelta = 0;
    double rmseBytes = 0.0;
};

DiffMetrics compareBytes(const std::vector<std::uint8_t>& a,
                         const std::vector<std::uint8_t>& b) {
    require(a.size() == b.size(), "output byte sizes match");
    DiffMetrics result{};
    double squared = 0.0;
    for (std::size_t i = 0; i < a.size(); ++i) {
        const unsigned delta = static_cast<unsigned>(std::abs(int(a[i]) - int(b[i])));
        if (delta) ++result.differentBytes;
        result.maxByteDelta = std::max(result.maxByteDelta, delta);
        squared += static_cast<double>(delta) * delta;
    }
    if (!a.empty()) result.rmseBytes = std::sqrt(squared / static_cast<double>(a.size()));
    return result;
}

std::vector<std::uint8_t> ppmRgb(const std::vector<std::uint8_t>& bytes,
                                 MTLPixelFormat format,
                                 NSUInteger width, NSUInteger height) {
    std::vector<std::uint8_t> rgb(width * height * 3);
    for (NSUInteger y = 0; y < height; ++y) {
        for (NSUInteger x = 0; x < width; ++x) {
            Rgb c = decodePixel(bytes, format, width, x, y);
            // PPM is a display artifact. Apply a simple clamp after MetalFX;
            // this conversion is never used by pass/fail comparisons.
            if (format == MTLPixelFormatRGBA16Float) {
                c.r = srgbEncode(c.r);
                c.g = srgbEncode(c.g);
                c.b = srgbEncode(c.b);
            } else if (!isSrgb(format)) {
                c.r = srgbEncode(c.r);
                c.g = srgbEncode(c.g);
                c.b = srgbEncode(c.b);
            }
            const std::size_t index = (y * width + x) * 3;
            rgb[index + 0] = static_cast<std::uint8_t>(std::lround(clamp01(c.r) * 255.0f));
            rgb[index + 1] = static_cast<std::uint8_t>(std::lround(clamp01(c.g) * 255.0f));
            rgb[index + 2] = static_cast<std::uint8_t>(std::lround(clamp01(c.b) * 255.0f));
        }
    }
    return rgb;
}

void writePpm(const std::filesystem::path& path,
              const std::vector<std::uint8_t>& bytes,
              MTLPixelFormat format, NSUInteger width, NSUInteger height) {
    const auto rgb = ppmRgb(bytes, format, width, height);
    std::ofstream stream(path, std::ios::binary);
    require(stream.good(), "open PPM " + path.string());
    stream << "P6\n" << width << " " << height << "\n255\n";
    stream.write(reinterpret_cast<const char*>(rgb.data()), static_cast<std::streamsize>(rgb.size()));
    require(stream.good(), "write PPM " + path.string());
}

void writeDiffPpm(const std::filesystem::path& path,
                  const std::vector<std::uint8_t>& backend,
                  const std::vector<std::uint8_t>& reference,
                  MTLPixelFormat format, NSUInteger width, NSUInteger height) {
    require(backend.size() == reference.size(), "diff output size");
    std::vector<std::uint8_t> rgb(width * height * 3, 0);
    for (NSUInteger y = 0; y < height; ++y) {
        for (NSUInteger x = 0; x < width; ++x) {
            const Rgb a = decodePixel(backend, format, width, x, y);
            const Rgb b = decodePixel(reference, format, width, x, y);
            const float scale = 8.0f;
            const std::size_t index = (y * width + x) * 3;
            rgb[index + 0] = static_cast<std::uint8_t>(std::lround(clamp01(std::fabs(a.r - b.r) * scale) * 255.0f));
            rgb[index + 1] = static_cast<std::uint8_t>(std::lround(clamp01(std::fabs(a.g - b.g) * scale) * 255.0f));
            rgb[index + 2] = static_cast<std::uint8_t>(std::lround(clamp01(std::fabs(a.b - b.b) * scale) * 255.0f));
        }
    }
    std::ofstream stream(path, std::ios::binary);
    require(stream.good(), "open diff PPM " + path.string());
    stream << "P6\n" << width << " " << height << "\n255\n";
    stream.write(reinterpret_cast<const char*>(rgb.data()), static_cast<std::streamsize>(rgb.size()));
}

struct Resources {
    id<MTLTexture> color = nil;
    id<MTLTexture> depth = nil;
    id<MTLTexture> motion = nil;
    id<MTLTexture> backendOutput = nil;
    id<MTLTexture> referenceOutput = nil;

    Resources() = default;
    Resources(const Resources&) = delete;
    Resources& operator=(const Resources&) = delete;
    Resources(Resources&& other) noexcept { *this = std::move(other); }
    Resources& operator=(Resources&& other) noexcept {
        if (this == &other) return *this;
        [referenceOutput release];
        [backendOutput release];
        [motion release];
        [depth release];
        [color release];
        color = other.color; other.color = nil;
        depth = other.depth; other.depth = nil;
        motion = other.motion; other.motion = nil;
        backendOutput = other.backendOutput; other.backendOutput = nil;
        referenceOutput = other.referenceOutput; other.referenceOutput = nil;
        return *this;
    }
    ~Resources() {
        [referenceOutput release];
        [backendOutput release];
        [motion release];
        [depth release];
        [color release];
    }
};

Resources makeResources(id<MTLDevice> device, const Scenario& scenario) {
    Resources result;
    result.color = makeTexture(device, scenario.format, W, H, MTLStorageModeShared,
                               MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    result.depth = makeTexture(device, MTLPixelFormatR32Float, W, H, MTLStorageModeShared,
                               MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
    const NSUInteger motionWidth = scenario.outputResolutionMotion ? OW : W;
    const NSUInteger motionHeight = scenario.outputResolutionMotion ? OH : H;
    result.motion = makeTexture(device, MTLPixelFormatRG16Float, motionWidth, motionHeight,
                                MTLStorageModeShared, MTLTextureUsageShaderRead);
    const MTLTextureUsage outputUsage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                                        MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
    result.backendOutput = makeTexture(device, scenario.format, OW, OH,
                                       MTLStorageModeShared, outputUsage);
    result.referenceOutput = makeTexture(device, scenario.format, OW, OH,
                                         MTLStorageModePrivate, outputUsage);
    require(result.color && result.depth && result.motion && result.backendOutput && result.referenceOutput,
            std::string("scenario texture allocation: ") + scenario.name);
    return result;
}

CreateInfo createInfo(const Scenario& scenario) {
    CreateInfo create{};
    create.input = {static_cast<std::uint32_t>(W), static_cast<std::uint32_t>(H)};
    create.output = {static_cast<std::uint32_t>(OW), static_cast<std::uint32_t>(OH)};
    std::uint32_t flags = FeatureFlagDepthInverted;
    if (!scenario.outputResolutionMotion) flags |= FeatureFlagMVLowRes;
    if (scenario.jitteredMotion) flags |= FeatureFlagMVJittered;
    if (scenario.hdr) flags |= FeatureFlagIsHDR;
    create.featureFlags = {flags, true};
    create.outputSubrects = {false, true};
    return create;
}

FrameInfo frameInfo(const Scenario& scenario, const FramePixels& pixels) {
    FrameInfo frame{};
    frame.color = reinterpret_cast<void*>(0x101);
    frame.depth = reinterpret_cast<void*>(0x102);
    frame.motionVectors = reinterpret_cast<void*>(0x103);
    frame.output = reinterpret_cast<void*>(0x104);
    frame.inputContent = {static_cast<std::uint32_t>(W), static_cast<std::uint32_t>(H)};
    frame.colorRect = {0, 0, static_cast<std::uint32_t>(W), static_cast<std::uint32_t>(H)};
    frame.depthRect = frame.colorRect;
    frame.motionRect = {0, 0,
        static_cast<std::uint32_t>(scenario.outputResolutionMotion ? OW : W),
        static_cast<std::uint32_t>(scenario.outputResolutionMotion ? OH : H)};
    frame.outputRect = {0, 0, static_cast<std::uint32_t>(OW), static_cast<std::uint32_t>(OH)};
    frame.jitterOffsetX = {pixels.jitter.x, true};
    frame.jitterOffsetY = {pixels.jitter.y, true};
    frame.motionVectorScaleX = {1.0f, true};
    frame.motionVectorScaleY = {1.0f, true};
    frame.preExposure = {scenario.preExposure, true};
    frame.resetHistory = {pixels.callerReset, true};
    frame.exposureMode = ExposureMode::None;
    return frame;
}

TextureSet backendTextures(Resources& resources) {
    return {reinterpret_cast<void*>(resources.color), reinterpret_cast<void*>(resources.depth),
            reinterpret_cast<void*>(resources.motion), reinterpret_cast<void*>(resources.backendOutput),
            nullptr, nullptr};
}

struct DirectReference {
    id scaler = nil;
    id residency = nil;

    ~DirectReference() {
        [residency release];
        [scaler release];
    }
};

DirectReference makeDirectReference(id<MTLDevice> device, id compiler,
                                    CommandMode mode, const Scenario& scenario,
                                    const Resources& resources) {
    DirectReference result;
    MTLFXTemporalScalerDescriptor* descriptor = [MTLFXTemporalScalerDescriptor new];
    descriptor.inputWidth = W;
    descriptor.inputHeight = H;
    descriptor.outputWidth = OW;
    descriptor.outputHeight = OH;
    descriptor.colorTextureFormat = scenario.format;
    descriptor.depthTextureFormat = MTLPixelFormatR32Float;
    descriptor.motionTextureFormat = MTLPixelFormatRG16Float;
    descriptor.outputTextureFormat = scenario.format;
    descriptor.autoExposureEnabled = NO;
    descriptor.requiresSynchronousInitialization = YES;
    descriptor.inputContentPropertiesEnabled = YES;
    descriptor.inputContentMinScale =
        [MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:device];
    descriptor.inputContentMaxScale =
        [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:device];
    if (@available(macOS 27.0, *)) {
        descriptor.outputResolutionMotionVectorsEnabled = scenario.outputResolutionMotion;
        descriptor.jitteredMotionVectorsEnabled = scenario.jitteredMotion;
    }

    if (mode == CommandMode::Metal4) {
        if (@available(macOS 26.0, *)) {
            result.scaler = [descriptor newTemporalScalerWithDevice:device
                                                            compiler:reinterpret_cast<id<MTL4Compiler>>(compiler)];
        }
    } else {
        result.scaler = [descriptor newTemporalScalerWithDevice:device];
    }
    [descriptor release];
    require(result.scaler != nil, std::string("direct public MetalFX factory: ") + scenario.name);

    id<MTLFXTemporalScalerBase> scaler = reinterpret_cast<id<MTLFXTemporalScalerBase>>(result.scaler);
    require((resources.color.usage & scaler.colorTextureUsage) == scaler.colorTextureUsage,
            "direct color usage");
    require((resources.depth.usage & scaler.depthTextureUsage) == scaler.depthTextureUsage,
            "direct depth usage");
    require((resources.motion.usage & scaler.motionTextureUsage) == scaler.motionTextureUsage,
            "direct motion usage");
    require((resources.referenceOutput.usage & scaler.outputTextureUsage) == scaler.outputTextureUsage,
            "direct output usage");

    if (mode == CommandMode::Metal4) {
        if (@available(macOS 15.0, *)) {
            MTLResidencySetDescriptor* residencyDescriptor = [MTLResidencySetDescriptor new];
            residencyDescriptor.initialCapacity = 4;
            NSError* error = nil;
            result.residency = [device newResidencySetWithDescriptor:residencyDescriptor error:&error];
            [residencyDescriptor release];
            require(result.residency != nil, "direct Metal4 residency set");
            id<MTLResidencySet> set = reinterpret_cast<id<MTLResidencySet>>(result.residency);
            for (id<MTLAllocation> allocation in @[resources.color, resources.depth,
                                                    resources.motion, resources.referenceOutput])
                [set addAllocation:allocation];
            [set commit];
        }
    }
    return result;
}

void configureDirectFrame(DirectReference& reference, const Scenario& scenario,
                          Resources& resources, const FramePixels& pixels,
                          unsigned frame, id<MTLFence> fence) {
    id<MTLFXTemporalScalerBase> scaler = reinterpret_cast<id<MTLFXTemporalScalerBase>>(reference.scaler);
    scaler.colorTexture = resources.color;
    scaler.depthTexture = resources.depth;
    scaler.motionTexture = resources.motion;
    scaler.outputTexture = resources.referenceOutput;
    scaler.exposureTexture = nil;
    scaler.inputContentWidth = W;
    scaler.inputContentHeight = H;
    if (@available(macOS 27.0, *)) {
        scaler.colorContentOffsetX = 0;
        scaler.colorContentOffsetY = 0;
        scaler.depthContentOffsetX = 0;
        scaler.depthContentOffsetY = 0;
        scaler.motionContentOffsetX = 0;
        scaler.motionContentOffsetY = 0;
        scaler.outputOffsetX = 0;
        scaler.outputOffsetY = 0;
    }
    scaler.preExposure = scenario.preExposure;
    scaler.jitterOffsetX = pixels.jitter.x;
    scaler.jitterOffsetY = pixels.jitter.y;
    scaler.motionVectorScaleX = 1.0f;
    scaler.motionVectorScaleY = 1.0f;
    scaler.reset = frame == 0 || pixels.callerReset;
    scaler.depthReversed = YES;
    scaler.fence = fence;
}

struct LegacyExecutor {
    id<MTLCommandQueue> queue = nil;
    std::vector<std::shared_ptr<const ExecutionLease>> retainedLeases;

    explicit LegacyExecutor(id<MTLDevice> device) : queue([device newCommandQueue]) {
        require(queue != nil, "legacy quality queue");
    }
    ~LegacyExecutor() { [queue release]; }

    void runBackend(const std::shared_ptr<const PreparedFrame>& prepared,
                    Error& error, std::shared_ptr<const ExecutionLease>& lease) {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLFence> fence = [queue.device newFence];
        id<MTLBlitCommandEncoder> producer = [command blitCommandEncoder];
        [producer updateFence:fence];
        [producer endEncoding];
        require(prepared->encode(reinterpret_cast<void*>(command), reinterpret_cast<void*>(fence),
                                 lease, &error),
                error.message.empty() ? "legacy backend encode" : error.message);
        require(lease != nullptr, "legacy backend lease");
        id<MTLBlitCommandEncoder> consumer = [command blitCommandEncoder];
        [consumer waitForFence:fence];
        [consumer endEncoding];
        completeLegacy(command, "legacy backend quality");
        retainedLeases.push_back(lease);
        [fence release];
    }

    void runReference(DirectReference& reference, const Scenario& scenario,
                      Resources& resources, const FramePixels& pixels, unsigned frame) {
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLFence> fence = [queue.device newFence];
        id<MTLBlitCommandEncoder> producer = [command blitCommandEncoder];
        [producer updateFence:fence];
        [producer endEncoding];
        configureDirectFrame(reference, scenario, resources, pixels, frame, fence);
        [reinterpret_cast<id<MTLFXTemporalScaler>>(reference.scaler) encodeToCommandBuffer:command];
        id<MTLBlitCommandEncoder> consumer = [command blitCommandEncoder];
        [consumer waitForFence:fence];
        [consumer endEncoding];
        completeLegacy(command, "legacy direct reference quality");
        [fence release];
    }
};

void submitMetal4(id<MTL4CommandQueue> queue, id<MTL4CommandBuffer> command,
                  const char* context) API_AVAILABLE(macos(26.0)) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError* gpuError = nil;
    MTL4CommitOptions* options = [MTL4CommitOptions new];
    [options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
        gpuError = [feedback.error retain];
        dispatch_semaphore_signal(done);
    }];
    id<MTL4CommandBuffer> commands[] = {command};
    [queue commit:commands count:1 options:options];
    require(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
            std::string(context) + " feedback timeout");
    if (gpuError) NSLog(@"%s: %@", context, gpuError);
    require(gpuError == nil, std::string(context) + " GPU feedback");
    [gpuError release];
    [options release];
    dispatch_release(done);
}

struct Metal4Executor {
    id<MTLDevice> device = nil;
    id queue = nil;
    id backendAllocator = nil;
    id referenceAllocator = nil;
    id backendCommand = nil;
    id referenceCommand = nil;
    bool backendUsed = false;
    bool referenceUsed = false;
    std::vector<std::shared_ptr<const ExecutionLease>> retainedLeases;

    explicit Metal4Executor(id<MTLDevice> input) API_AVAILABLE(macos(26.0)) : device(input) {
        queue = [device newMTL4CommandQueue];
        backendAllocator = [device newCommandAllocator];
        referenceAllocator = [device newCommandAllocator];
        backendCommand = [device newCommandBuffer];
        referenceCommand = [device newCommandBuffer];
        require(queue && backendAllocator && referenceAllocator && backendCommand && referenceCommand,
                "Metal4 quality executor objects");
    }
    ~Metal4Executor() {
        [referenceCommand release];
        [backendCommand release];
        [referenceAllocator release];
        [backendAllocator release];
        [queue release];
    }

    void runBackend(const std::shared_ptr<const PreparedFrame>& prepared,
                    Error& error, std::shared_ptr<const ExecutionLease>& lease)
        API_AVAILABLE(macos(26.0)) {
        id<MTL4CommandQueue> typedQueue = reinterpret_cast<id<MTL4CommandQueue>>(queue);
        id<MTL4CommandAllocator> typedAllocator =
            reinterpret_cast<id<MTL4CommandAllocator>>(backendAllocator);
        id<MTL4CommandBuffer> typedCommand =
            reinterpret_cast<id<MTL4CommandBuffer>>(backendCommand);
        if (backendUsed) [typedAllocator reset];
        backendUsed = true;
        id<MTLFence> fence = [device newFence];
        [typedCommand beginCommandBufferWithAllocator:typedAllocator];
        id<MTL4ComputeCommandEncoder> producer = [typedCommand computeCommandEncoder];
        [producer updateFence:fence afterEncoderStages:MTLStageDispatch];
        [producer endEncoding];
        require(prepared->encode(reinterpret_cast<void*>(typedCommand), reinterpret_cast<void*>(fence),
                                 lease, &error),
                error.message.empty() ? "Metal4 backend encode" : error.message);
        require(lease != nullptr, "Metal4 backend lease");
        id<MTL4ComputeCommandEncoder> consumer = [typedCommand computeCommandEncoder];
        [consumer waitForFence:fence beforeEncoderStages:MTLStageBlit];
        [consumer endEncoding];
        [typedCommand endCommandBuffer];
        submitMetal4(typedQueue, typedCommand, "Metal4 backend quality");
        retainedLeases.push_back(lease);
        [fence release];
    }

    void runReference(DirectReference& reference, const Scenario& scenario,
                      Resources& resources, const FramePixels& pixels, unsigned frame)
        API_AVAILABLE(macos(26.0)) {
        id<MTL4CommandQueue> typedQueue = reinterpret_cast<id<MTL4CommandQueue>>(queue);
        id<MTL4CommandAllocator> typedAllocator =
            reinterpret_cast<id<MTL4CommandAllocator>>(referenceAllocator);
        id<MTL4CommandBuffer> typedCommand =
            reinterpret_cast<id<MTL4CommandBuffer>>(referenceCommand);
        if (referenceUsed) [typedAllocator reset];
        referenceUsed = true;
        id<MTLFence> fence = [device newFence];
        [typedCommand beginCommandBufferWithAllocator:typedAllocator];
        if (reference.residency)
            [typedCommand useResidencySet:reinterpret_cast<id<MTLResidencySet>>(reference.residency)];
        id<MTL4ComputeCommandEncoder> producer = [typedCommand computeCommandEncoder];
        [producer updateFence:fence afterEncoderStages:MTLStageDispatch];
        [producer endEncoding];
        configureDirectFrame(reference, scenario, resources, pixels, frame, fence);
        [reinterpret_cast<id<MTL4FXTemporalScaler>>(reference.scaler)
            encodeToCommandBuffer:typedCommand];
        id<MTL4ComputeCommandEncoder> consumer = [typedCommand computeCommandEncoder];
        [consumer waitForFence:fence beforeEncoderStages:MTLStageBlit];
        [consumer endEncoding];
        [typedCommand endCommandBuffer];
        submitMetal4(typedQueue, typedCommand, "Metal4 direct reference quality");
        [fence release];
    }
};

struct FrameMetrics {
    DiffMetrics diff{};
    Vec2 inputMarker{};
    Vec2 backendMarker{};
    Vec2 referenceMarker{};
    float backendPositionError = 0.0f;
    float referencePositionError = 0.0f;
};

float distance(Vec2 a, Vec2 b) {
    const float dx = a.x - b.x;
    const float dy = a.y - b.y;
    return std::sqrt(dx * dx + dy * dy);
}

struct ScenarioResult {
    std::size_t totalDifferentBytes = 0;
    unsigned maxByteDelta = 0;
    double maxRmse = 0.0;
    float maxBackendPositionError = 0.0f;
    float maxReferencePositionError = 0.0f;
    std::string backendClass;
    std::string referenceClass;
};

void writeMetricHeader(std::ofstream& metrics) {
    metrics << "scenario,mode,frame,format,hdr,pre_exposure,jitter_x,jitter_y,"
               "mv_background_x,mv_background_y,mv_foreground_x,mv_foreground_y,"
               "caller_reset,effective_reset,generation_initialized,"
               "expected_input_x,expected_input_y,input_centroid_x,input_centroid_y,"
               "expected_output_x,expected_output_y,backend_centroid_x,backend_centroid_y,"
               "reference_centroid_x,reference_centroid_y,backend_position_error,"
               "reference_position_error,different_bytes,max_byte_delta,rmse_bytes,"
               "backend_scaler,reference_scaler\n";
}

ScenarioResult runScenario(id<MTLDevice> device, id compiler,
                           id<MTLCommandQueue> transfer, CommandMode mode,
                           const Scenario& scenario,
                           const std::filesystem::path& outputDir,
                           std::ofstream& metrics) {
    Resources resources = makeResources(device, scenario);
    Error error;
    CreateContext context{reinterpret_cast<void*>(device),
                          mode == CommandMode::Metal4 ? reinterpret_cast<void*>(compiler) : nullptr,
                          mode};
    auto backend = Feature::create(context, createInfo(scenario), &error);
    require(backend != nullptr, std::string("backend feature create ") + scenario.name + ": " + error.message);
    DirectReference reference = makeDirectReference(device, compiler, mode, scenario, resources);

    std::unique_ptr<LegacyExecutor> legacy;
    std::unique_ptr<Metal4Executor> metal4;
    if (mode == CommandMode::Legacy) legacy = std::make_unique<LegacyExecutor>(device);
    else if (@available(macOS 26.0, *)) metal4 = std::make_unique<Metal4Executor>(device);

    ScenarioResult result;
    result.referenceClass = object_getClassName(reference.scaler);
    std::vector<std::uint8_t> finalBackend;
    std::vector<std::uint8_t> finalReference;
    std::vector<std::uint8_t> finalInput;
    for (unsigned frame = 0; frame < Frames; ++frame) {
        FramePixels pixels = generateFrame(scenario, frame);
        uploadFrame(resources.color, resources.depth, resources.motion, scenario, pixels);
        const Vec2 inputCentroid = inputMarkerCentroid(scenario, pixels);
        require(distance(inputCentroid, pixels.expectedInputMarker) < 1.15f,
                std::string("CPU current-frame marker position ") + scenario.name +
                " frame=" + std::to_string(frame));

        auto info = frameInfo(scenario, pixels);
        auto prepared = backend->prepare(info, backendTextures(resources), &error);
        require(prepared != nullptr, std::string("backend prepare ") + scenario.name + ": " + error.message);
        std::shared_ptr<const ExecutionLease> lease;
        if (mode == CommandMode::Legacy) {
            legacy->runBackend(prepared, error, lease);
            legacy->runReference(reference, scenario, resources, pixels, frame);
        } else if (@available(macOS 26.0, *)) {
            metal4->runBackend(prepared, error, lease);
            metal4->runReference(reference, scenario, resources, pixels, frame);
        }
        require(lease != nullptr, "backend quality execution lease");
        if (frame == 0) {
            require(lease->effectiveReset() && !lease->generationInitialized(),
                    std::string("fresh generation reset diagnostic ") + scenario.name);
            result.backendClass = object_getClassName(reinterpret_cast<id>(lease->scaler()));
        } else if (!pixels.callerReset) {
            require(!lease->effectiveReset() && lease->generationInitialized(),
                    std::string("continuous history diagnostic ") + scenario.name);
        } else {
            require(lease->effectiveReset() && lease->generationInitialized(),
                    std::string("explicit frame reset diagnostic ") + scenario.name);
        }

        const auto backendBytes = readTexture(device, transfer, resources.backendOutput);
        const auto referenceBytes = readTexture(device, transfer, resources.referenceOutput);
        const DiffMetrics diff = compareBytes(backendBytes, referenceBytes);
        const Vec2 expectedOutput = pixels.expectedOutputMarker;
        const Vec2 backendMarker = markerCentroid(backendBytes, scenario.format, OW, OH,
                                                  expectedOutput, 18.0f);
        const Vec2 referenceMarker = markerCentroid(referenceBytes, scenario.format, OW, OH,
                                                    expectedOutput, 18.0f);
        const float backendError = distance(backendMarker, expectedOutput);
        const float referenceError = distance(referenceMarker, expectedOutput);
        result.totalDifferentBytes += diff.differentBytes;
        result.maxByteDelta = std::max(result.maxByteDelta, diff.maxByteDelta);
        result.maxRmse = std::max(result.maxRmse, diff.rmseBytes);
        result.maxBackendPositionError = std::max(result.maxBackendPositionError, backendError);
        result.maxReferencePositionError = std::max(result.maxReferencePositionError, referenceError);

        metrics << scenario.name << ',' << modeName(mode) << ',' << frame << ','
                << formatName(scenario.format) << ',' << (scenario.hdr ? 1 : 0) << ','
                << scenario.preExposure << ',' << pixels.jitter.x << ',' << pixels.jitter.y << ','
                << pixels.backgroundMotion.x << ',' << pixels.backgroundMotion.y << ','
                << pixels.foregroundMotion.x << ',' << pixels.foregroundMotion.y << ','
                << (pixels.callerReset ? 1 : 0) << ',' << (lease->effectiveReset() ? 1 : 0) << ','
                << (lease->generationInitialized() ? 1 : 0) << ','
                << pixels.expectedInputMarker.x << ',' << pixels.expectedInputMarker.y << ','
                << inputCentroid.x << ',' << inputCentroid.y << ','
                << expectedOutput.x << ',' << expectedOutput.y << ','
                << backendMarker.x << ',' << backendMarker.y << ','
                << referenceMarker.x << ',' << referenceMarker.y << ','
                << backendError << ',' << referenceError << ','
                << diff.differentBytes << ',' << diff.maxByteDelta << ',' << diff.rmseBytes << ','
                << result.backendClass << ',' << result.referenceClass << '\n';

        if (diff.differentBytes != 0) {
            const std::string stem = std::string(scenario.name) + "-" + modeName(mode) +
                                     "-frame" + std::to_string(frame) + "-FAIL";
            writePpm(outputDir / (stem + "-backend.ppm"), backendBytes, scenario.format, OW, OH);
            writePpm(outputDir / (stem + "-reference.ppm"), referenceBytes, scenario.format, OW, OH);
            writeDiffPpm(outputDir / (stem + "-diff.ppm"), backendBytes, referenceBytes,
                         scenario.format, OW, OH);
            fail(std::string("translator/reference output mismatch ") + scenario.name +
                 " " + modeName(mode) + " frame=" + std::to_string(frame) +
                 " bytes=" + std::to_string(diff.differentBytes) +
                 " maxdelta=" + std::to_string(diff.maxByteDelta));
        }

        if (frame + 1 == Frames) {
            finalBackend = backendBytes;
            finalReference = referenceBytes;
            if (scenario.format == MTLPixelFormatRGBA16Float) {
                finalInput.resize(pixels.color16.size() * sizeof(_Float16));
                std::memcpy(finalInput.data(), pixels.color16.data(), finalInput.size());
            } else {
                finalInput = pixels.color8;
            }
        }
    }

    const std::string stem = std::string(scenario.name) + "-" + modeName(mode);
    writePpm(outputDir / (stem + "-input-last.ppm"), finalInput, scenario.format, W, H);
    writePpm(outputDir / (stem + "-backend-last.ppm"), finalBackend, scenario.format, OW, OH);
    writePpm(outputDir / (stem + "-reference-last.ppm"), finalReference, scenario.format, OW, OH);
    writeDiffPpm(outputDir / (stem + "-diff-last.ppm"), finalBackend, finalReference,
                 scenario.format, OW, OH);

    std::printf("QUALITY_PASS scenario=%s mode=%s frames=%u format=%s diff_bytes=%zu "
                "max_delta=%u max_rmse=%.9g backend_pos_err=%.6g ref_pos_err=%.6g "
                "backend_class=%s reference_class=%s\n",
                scenario.name, modeName(mode).c_str(), Frames, formatName(scenario.format).c_str(),
                result.totalDifferentBytes, result.maxByteDelta, result.maxRmse,
                result.maxBackendPositionError, result.maxReferencePositionError,
                result.backendClass.c_str(), result.referenceClass.c_str());
    return result;
}

} // namespace

int main(int argc, char** argv) {
    @autoreleasepool {
        require(argc == 2, "usage: metalfx-quality-native <output-directory>");
        if (@available(macOS 27.0, *)) {
        } else {
            fail("quality regression requires macOS 27 for output-resolution/jittered-MV coverage");
        }

        const std::filesystem::path outputDir(argv[1]);
        std::filesystem::create_directories(outputDir);
        std::ofstream metrics(outputDir / "metrics.csv");
        require(metrics.good(), "metrics.csv open");
        metrics << std::setprecision(9);
        writeMetricHeader(metrics);

        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        require(device != nil && [MTLFXTemporalScalerDescriptor supportsDevice:device],
                "MetalFX temporal device");
        id<MTLCommandQueue> transfer = [device newCommandQueue];
        require(transfer != nil, "quality readback queue");

        id<MTL4Compiler> compiler = nil;
        bool metal4Supported = false;
        if (@available(macOS 26.0, *)) {
            metal4Supported = [MTLFXTemporalScalerDescriptor supportsMetal4FX:device];
            if (metal4Supported) {
                NSError* error = nil;
                MTL4CompilerDescriptor* descriptor = [MTL4CompilerDescriptor new];
                compiler = [device newCompilerWithDescriptor:descriptor error:&error];
                [descriptor release];
                if (error) NSLog(@"Metal4 compiler: %@", error);
                require(compiler != nil, "Metal4 quality compiler");
            }
        }

        std::ofstream summary(outputDir / "summary.txt");
        require(summary.good(), "summary.txt open");
        summary << "MetalFX backend quality regression\n"
                << "frames_per_scenario=" << Frames << "\n"
                << "input=" << W << "x" << H << " output=" << OW << "x" << OH << "\n"
                << "private_model_forcing=0\n";

        for (const Scenario& scenario : Scenarios) {
            const ScenarioResult legacy = runScenario(device, compiler, transfer,
                                                      CommandMode::Legacy, scenario,
                                                      outputDir, metrics);
            summary << scenario.name << " legacy diff_bytes=" << legacy.totalDifferentBytes
                    << " max_delta=" << legacy.maxByteDelta
                    << " backend_position_error=" << legacy.maxBackendPositionError
                    << " reference_position_error=" << legacy.maxReferencePositionError << '\n';
            if (metal4Supported) {
                const ScenarioResult metal4 = runScenario(device, compiler, transfer,
                                                          CommandMode::Metal4, scenario,
                                                          outputDir, metrics);
                summary << scenario.name << " metal4 diff_bytes=" << metal4.totalDifferentBytes
                        << " max_delta=" << metal4.maxByteDelta
                        << " backend_position_error=" << metal4.maxBackendPositionError
                        << " reference_position_error=" << metal4.maxReferencePositionError << '\n';
            }
        }

        summary << "translator_equivalence=bit_exact_for_all_completed_cases\n"
                << "algorithm_quality=reported_as_position_metrics_only_not_pass_fail\n";
        metrics.flush();
        summary.flush();
        require(metrics.good() && summary.good(), "quality report flush");

        std::puts("METALFX_QUALITY_NATIVE_PASS backend_equivalence=bit_exact "
                  "continuous_frames=16 cpu_position_checks=1 artifacts=ppm+csv");
        [compiler release];
        [transfer release];
        [device release];
        return 0;
    }
}
