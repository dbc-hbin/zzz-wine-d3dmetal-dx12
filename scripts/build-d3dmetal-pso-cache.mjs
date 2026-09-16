#!/usr/bin/env node

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const testControls = process.argv[2] === "--test-controls";
const output = process.argv[testControls ? 3 : 2];
if (!output || process.argv.length !== (testControls ? 4 : 3)) {
  throw new Error("usage: node scripts/build-d3dmetal-pso-cache.mjs [--test-controls] <output-dir>");
}
const outputDirectory = resolve(output);
const sourceDirectory = resolve(root, "d3dmetal-pso-cache");
const sourcePaths = [
  "d3dmetal-pso-cache/cache.hpp", "d3dmetal-pso-cache/cache.mm",
  "d3dmetal-pso-cache/function-cache.hpp", "d3dmetal-pso-cache/function-cache.mm",
  "d3dmetal-pso-cache/exposure.hpp", "d3dmetal-pso-cache/exposure.mm",
  "d3dmetal-pso-cache/temporal.hpp", "d3dmetal-pso-cache/temporal.mm",
  "d3dmetal-pso-cache/temporal-contract.hpp",
  "d3dmetal-pso-cache/frame-probe.hpp", "d3dmetal-pso-cache/frame-probe.mm",
  "d3dmetal-pso-cache/frame-probe-core.hpp",
  "d3dmetal-pso-cache/function-hooks.hpp", "d3dmetal-pso-cache/function-hooks.mm",
  "d3dmetal-pso-cache/key.hpp", "d3dmetal-pso-cache/key.mm",
  "d3dmetal-pso-cache/ngx-hooks.hpp", "d3dmetal-pso-cache/ngx-hooks.mm",
  "d3dmetal-pso-cache/persistent-cache.hpp", "d3dmetal-pso-cache/persistent-cache.mm",
  "d3dmetal-pso-cache/rt-key.hpp", "d3dmetal-pso-cache/rt-key.mm",
  "d3dmetal-pso-cache/stage-cache.hpp", "d3dmetal-pso-cache/stage-cache.mm",
  "d3dmetal-pso-cache/bridge.mm", "d3dmetal-pso-cache/layout.json",
  "scripts/build-d3dmetal-pso-cache.mjs", "scripts/d3dmetal-pso-cache-patch.mjs",
  "scripts/d3dmetal-stage-lock-patch.mjs",
];
const sources = sourcePaths.map((path) => ({
  path, sha256: createHash("sha256").update(readFileSync(resolve(root, path))).digest("hex"),
}));
const layout = JSON.parse(readFileSync(resolve(sourceDirectory, "layout.json"), "utf8"));
const hookNames = [
  "Metal4Render", "Render", "Mesh", "Compute", "GetRender", "CompileCompute",
  "DestroyDevice", "CreateRTFunction", "CreateRTCombined", "CreateRTIntersection",
  "GetAndRetainLibrary",
  "CompileComputeStages", "CompileGraphicsStages",
  "CreateComputeStageKey", "CreateGraphicsStageKey",
  "ExtractFunctions", "LoadGraphicsFunctions",
  "NgxEvaluateMPL", "NgxEvaluateMTL", "TemporalScaleMPL",
  "ReplayTemporalScaleMPL", "EncodeTemporalScaleMTL",
  "LegacyRecordComplete", "MplRecordComplete", "NgxD3D12EvaluateFeature",
];
if (layout.formatVersion !== 4 || layout.hooks.length !== hookNames.length ||
    layout.hooks.some((hook, index) => hook.id !== hookNames[index] || hook.dispatchFieldOffset !== index * 8)) {
  throw new Error("unsupported native PSO dispatch layout");
}
const spans = [
  { offset: layout.dependency.commandOffset, hex: layout.dependency.commandHex },
  { offset: layout.constructorVerification.markerOffset, hex: layout.constructorVerification.markerHex },
  ...layout.verificationSpans.map((span) => ({ offset: span.offset, hex: span.expectedHex })),
  ...layout.hooks.flatMap((hook) => [
    { offset: hook.entryOffset, hex: hook.entryPatchHex },
    { offset: hook.gateOffset, hex: hook.gateHex },
    { offset: hook.trampolineOffset, hex: hook.trampolineHex },
  ]),
  ...layout.binaryPatches.map((patch) => ({ offset: patch.offset, hex: patch.patchedHex })),
];
for (const span of spans) {
  if (!Number.isSafeInteger(span.offset) || span.offset < 0 || !/^(?:[0-9a-f]{2})+$/.test(span.hex)) {
    throw new Error("invalid native PSO verification span");
  }
}
const bytes = (hex) => Array.from(Buffer.from(hex, "hex"), (byte) => `0x${byte.toString(16).padStart(2, "0")}`).join(", ");
const header = [
  "#pragma once", "#include <array>", "#include <cstddef>", "#include <cstdint>",
  "namespace yaagl::pso::layout {",
  `enum class Hook : std::size_t { ${hookNames.join(", ")}, Count };`,
  `inline constexpr std::uint32_t kCommandCount = ${layout.dependency.patchedCommandCount};`,
  `inline constexpr std::uint32_t kCommandsSize = ${layout.dependency.patchedCommandsSize};`,
  `inline constexpr std::uintptr_t kFirstTextOffset = ${layout.dependency.firstTextOffset};`,
  `inline constexpr std::uintptr_t kDataSlot = ${layout.dispatch.dataSlotVMAddr};`,
  `inline constexpr std::uintptr_t kCommonSectionOffset = ${layout.dispatch.commonSectionCommandOffset};`,
  `inline constexpr std::uint64_t kCommonAddress = ${layout.dispatch.commonSectionOldEndVMAddr - layout.dispatch.commonSectionOldSize};`,
  `inline constexpr std::uint64_t kCommonSize = ${layout.dispatch.commonSectionNewSize};`,
  `inline constexpr std::uint8_t kUuid[] = { ${bytes(layout.source.machUuid)} };`,
  `inline constexpr std::array<std::uintptr_t, ${hookNames.length}> kTrampolines = { ${layout.hooks.map((hook) => hook.trampolineOffset).join(", ")} };`,
  ...spans.map((span, index) => `inline constexpr std::uint8_t kSpan${index}[] = { ${bytes(span.hex)} };`),
  "struct VerificationSpan { std::uintptr_t offset; const std::uint8_t* bytes; std::size_t size; };",
  `inline constexpr std::array<VerificationSpan, ${spans.length}> kVerificationSpans = {{`,
  ...spans.map((span, index) => `  { ${span.offset}, kSpan${index}, sizeof(kSpan${index}) },`),
  "}};", "} // namespace yaagl::pso::layout", "",
].join("\n");
mkdirSync(outputDirectory, { recursive: true });
writeFileSync(resolve(outputDirectory, "layout.hpp"), header);

const compilerLookup = spawnSync("xcrun", ["--find", "clang++"], { encoding: "utf8" });
if (compilerLookup.status !== 0) throw new Error(compilerLookup.stderr || "clang++ unavailable");
const compiler = compilerLookup.stdout.trim();
const compilerVersion = spawnSync(compiler, ["--version"], { encoding: "utf8" });
if (compilerVersion.status !== 0) throw new Error("unable to identify clang++");
const sdkLookup = spawnSync("xcrun", ["--sdk", "macosx", "--show-sdk-path"], { encoding: "utf8" });
if (sdkLookup.status !== 0) throw new Error(sdkLookup.stderr || "macOS SDK unavailable");
const sdkPath = sdkLookup.stdout.trim();
const modulePath = resolve(outputDirectory, "libYaaglNativePsoCache.dylib");
const compileArgs = [
  "-arch", "x86_64", "-std=c++20", "-fno-objc-arc", "-fobjc-exceptions", "-fblocks",
  "-isysroot", sdkPath,
  "-mmacosx-version-min=14.0", "-O2", "-Wall", "-Wextra", "-Werror",
  ...(testControls ? ["-DYAAGL_NATIVE_PSO_CACHE_TEST_CONTROLS=1"] : []),
  "-dynamiclib", "-pthread", "-framework", "Foundation", "-framework", "Metal", "-framework", "QuartzCore",
  "-I", sourceDirectory, "-I", outputDirectory,
  ...["cache.mm", "exposure.mm", "temporal.mm", "frame-probe.mm", "function-cache.mm", "function-hooks.mm", "key.mm", "ngx-hooks.mm", "persistent-cache.mm", "rt-key.mm", "stage-cache.mm", "bridge.mm"].map((file) => resolve(sourceDirectory, file)),
  "-Wl,-install_name,@rpath/libYaaglNativePsoCache.dylib", "-o", modulePath,
];
const compiled = spawnSync(compiler, compileArgs, { cwd: root, stdio: "inherit" });
if (compiled.error) throw compiled.error;
if (compiled.status !== 0) process.exit(compiled.status ?? 1);

const moduleBytes = readFileSync(modulePath);
const diagnosticControls = [
  "YAAGL_METALFX_DIAGNOSTICS",
  "YAAGL_METALFX_LOG",
  "YAAGL_METALFX_EXPOSURE_SCALE_FIX",
  "YAAGL_METALFX_FRAME_PROBE",
  "YAAGL_METALFX_PROBE_DIR",
  "YAAGL_METALFX_PROBE_RESET_HISTORY",
  "YAAGL_METALFX_TEMPORAL",
];
for (const control of diagnosticControls) {
  if (!moduleBytes.includes(Buffer.from(control))) {
    throw new Error(`native cache is missing production diagnostic control: ${control}`);
  }
}
const environmentControls = [
  "YAAGL_NATIVE_PSO_CACHE_PROBE",
  "YAAGL_NATIVE_PSO_CACHE_PROBE_BYPASS",
  "YAAGL_D3DMETAL_CACHE_ROOT",
  "YAAGL_D3DMETAL_CACHE_EXECUTABLE",
];
if (testControls) {
  for (const control of environmentControls) {
    if (!moduleBytes.includes(Buffer.from(control))) {
      throw new Error(`test native cache is missing test control: ${control}`);
    }
  }
} else {
  const forbiddenMarkers = [
    ...environmentControls,
    "setFdopendirFailureForTest",
    "lastFdopendirFdForTest",
    "_NSGetArgv",
  ];
  for (const marker of forbiddenMarkers) {
    if (moduleBytes.includes(Buffer.from(marker))) {
      throw new Error(`production native cache contains test control: ${marker}`);
    }
  }
}

for (const source of sources) {
  const current = createHash("sha256").update(readFileSync(resolve(root, source.path))).digest("hex");
  if (current !== source.sha256) throw new Error(`native cache source changed during compilation: ${source.path}`);
}
const manifest = {
  schemaVersion: 1,
  architecture: "x86_64",
  deploymentTarget: "14.0",
  testControls,
  sources,
  compiler: { path: compiler, version: compilerVersion.stdout.trim(), sdkPath },
  compileArgs,
  module: {
    file: "libYaaglNativePsoCache.dylib",
    sha256: createHash("sha256").update(readFileSync(modulePath)).digest("hex"),
  },
};
writeFileSync(resolve(outputDirectory, "build-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
console.log(JSON.stringify({ module: modulePath, manifest: resolve(outputDirectory, "build-manifest.json") }, null, 2));
