#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { chmod, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  applyD3DMetalStageLockPatch,
  inspectD3DMetalStageLockPatch,
} from "./d3dmetal-stage-lock-patch.mjs";

const layoutText = await readFile(
  new URL("../d3dmetal-pso-cache/layout.json", import.meta.url),
  "utf8"
);
const layoutSha256 = createHash("sha256").update(layoutText).digest("hex");
const expectedLayoutSha256 =
  "9683fca4551df706f10212a1b6a8e88ff9eeb304ff720a0c20ae5135d5b38f9c";
if (layoutSha256 !== expectedLayoutSha256) {
  throw new Error(
    `layout corruption: expected SHA-256 ${expectedLayoutSha256}, got ${layoutSha256}`
  );
}
const layout = JSON.parse(layoutText);
if (layout.formatVersion !== 10) {
  throw new Error(`unsupported layout format ${layout.formatVersion}`);
}

export const D3DMETAL_PSO_CACHE_PATCHED_SHA256 =
  "b9f5985c8f668023e04b3638fd2cacce60a9ff33b07aeb86f0544ac81e827f58";
export const D3DMETAL_PSO_CACHE_PATCHED_PAYLOAD_SHA256 =
  "02b61d8d91b9c6188f89571fd67badcc819b040b87b06c9ad659863037729114";

const LC_SEGMENT_64 = 0x19;
const LC_UUID = 0x1b;
const LC_CODE_SIGNATURE = 0x1d;
const LC_LOAD_DYLIB = 0xc;
const MACH_HEADER_SIZE = 32;
const CODE_SIGNATURE_DATA_OFFSET = 0x727520;
const TEXT_END = layout.textCave.endOffset;
const EH_FRAME_END = layout.textCave.ehFrameEndOffset;

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function readName(bytes, offset) {
  return bytes.subarray(offset, offset + 16).toString("ascii").split("\0", 1)[0];
}

function checkedNumber(value, description) {
  const number = Number(value);
  if (!Number.isSafeInteger(number)) {
    throw new Error(`unsupported binary: invalid ${description}`);
  }
  return number;
}

function parseMachO(bytes) {
  if (bytes.length < MACH_HEADER_SIZE || bytes.readUInt32LE(0) !== 0xfeedfacf) {
    throw new Error("unsupported binary: expected a little-endian 64-bit Mach-O");
  }
  if (
    bytes.readInt32LE(4) !== layout.source.cpuType ||
    bytes.readUInt32LE(12) !== layout.source.fileType
  ) {
    throw new Error("unsupported binary: expected the GPTK x86-64 MH_DYLIB");
  }

  const commandCount = bytes.readUInt32LE(16);
  const commandsSize = bytes.readUInt32LE(20);
  const commandEnd = MACH_HEADER_SIZE + commandsSize;
  if (commandEnd > bytes.length) {
    throw new Error("unsupported binary: truncated Mach-O load commands");
  }

  let cursor = MACH_HEADER_SIZE;
  let uuid;
  let text;
  let data;
  let linkEdit;
  let codeSignature;
  const sections = [];
  const dependencies = [];
  for (let index = 0; index < commandCount; index += 1) {
    if (cursor + 8 > commandEnd) {
      throw new Error("unsupported binary: truncated Mach-O load command");
    }
    const command = bytes.readUInt32LE(cursor);
    const commandSize = bytes.readUInt32LE(cursor + 4);
    if (commandSize < 8 || cursor + commandSize > commandEnd) {
      throw new Error("unsupported binary: invalid Mach-O load command size");
    }

    if (command === LC_UUID) {
      if (commandSize !== 24 || uuid) {
        throw new Error("unsupported binary: invalid or duplicate LC_UUID");
      }
      uuid = bytes.subarray(cursor + 8, cursor + 24).toString("hex");
    }
    if (command === LC_SEGMENT_64) {
      if (commandSize < 72) {
        throw new Error("unsupported binary: truncated LC_SEGMENT_64");
      }
      const segmentName = readName(bytes, cursor + 8);
      const sectionCount = bytes.readUInt32LE(cursor + 64);
      if (sectionCount > Math.floor((commandSize - 72) / 80)) {
        throw new Error("unsupported binary: truncated Mach-O sections");
      }
      const segment = {
        name: segmentName,
        vmAddress: checkedNumber(bytes.readBigUInt64LE(cursor + 24), "segment VM address"),
        vmSize: checkedNumber(bytes.readBigUInt64LE(cursor + 32), "segment VM size"),
        fileOffset: checkedNumber(bytes.readBigUInt64LE(cursor + 40), "segment file offset"),
        fileSize: checkedNumber(bytes.readBigUInt64LE(cursor + 48), "segment file size"),
        maxProtection: bytes.readInt32LE(cursor + 56),
        initialProtection: bytes.readInt32LE(cursor + 60),
      };
      if (segment.fileOffset + segment.fileSize > bytes.length) {
        throw new Error("unsupported binary: invalid Mach-O segment file range");
      }
      if (segmentName === "__TEXT") {
        if (text) throw new Error("unsupported binary: duplicate __TEXT segment");
        text = segment;
      }
      if (segmentName === "__DATA") {
        if (data) throw new Error("unsupported binary: duplicate __DATA segment");
        data = segment;
      }
      if (segmentName === "__LINKEDIT") {
        if (linkEdit) throw new Error("unsupported binary: duplicate __LINKEDIT segment");
        linkEdit = segment;
      }
      for (let sectionIndex = 0; sectionIndex < sectionCount; sectionIndex += 1) {
        const sectionOffset = cursor + 72 + sectionIndex * 80;
        sections.push({
          commandOffset: sectionOffset,
          segment: segmentName,
          name: readName(bytes, sectionOffset),
          address: checkedNumber(bytes.readBigUInt64LE(sectionOffset + 32), "section address"),
          size: checkedNumber(bytes.readBigUInt64LE(sectionOffset + 40), "section size"),
          offset: bytes.readUInt32LE(sectionOffset + 48),
        });
      }
    }
    if (command === LC_LOAD_DYLIB) {
      if (commandSize < 24) {
        throw new Error("unsupported binary: truncated LC_LOAD_DYLIB");
      }
      const nameOffset = bytes.readUInt32LE(cursor + 8);
      if (nameOffset < 24 || nameOffset >= commandSize) {
        throw new Error("unsupported binary: invalid LC_LOAD_DYLIB name offset");
      }
      const terminator = bytes.indexOf(0, cursor + nameOffset);
      if (terminator < 0 || terminator >= cursor + commandSize) {
        throw new Error("unsupported binary: unterminated LC_LOAD_DYLIB name");
      }
      dependencies.push(
        bytes.subarray(cursor + nameOffset, terminator).toString("utf8")
      );
    }
    if (command === LC_CODE_SIGNATURE) {
      if (commandSize !== 16 || codeSignature) {
        throw new Error("unsupported binary: invalid or duplicate LC_CODE_SIGNATURE");
      }
      codeSignature = {
        commandOffset: cursor,
        dataOffset: bytes.readUInt32LE(cursor + 8),
        dataSize: bytes.readUInt32LE(cursor + 12),
      };
    }
    cursor += commandSize;
  }
  if (cursor !== commandEnd) {
    throw new Error("unsupported binary: load command count/size mismatch");
  }
  if (uuid !== layout.source.machUuid) {
    throw new Error(
      `unsupported binary: expected Mach-O UUID ${layout.source.machUuid}, got ${uuid ?? "none"}`
    );
  }
  if (
    !text ||
    text.vmAddress !== 0 ||
    text.vmSize !== TEXT_END ||
    text.fileOffset !== 0 ||
    text.fileSize !== TEXT_END ||
    text.maxProtection !== 5 ||
    text.initialProtection !== 5
  ) {
    throw new Error("unsupported binary: unexpected executable __TEXT segment");
  }
  const ehFrame = sections.find(
    section => section.segment === "__TEXT" && section.name === "__eh_frame"
  );
  if (!ehFrame || ehFrame.offset + ehFrame.size !== EH_FRAME_END) {
    throw new Error("unsupported binary: unexpected __eh_frame boundary");
  }
  if (
    sections.some(
      section =>
        section.segment === "__TEXT" &&
        section.offset < TEXT_END &&
        section.offset + section.size > EH_FRAME_END
    )
  ) {
    throw new Error("unsupported binary: executable cave overlaps live section data");
  }
  const common = sections.find(
    section => section.segment === "__DATA" && section.name === "__common"
  );
  const commonSizeAllowed =
    common?.size === layout.dispatch.commonSectionOldSize ||
    common?.size === layout.dispatch.commonSectionNewSize;
  if (
    !data ||
    data.initialProtection !== 3 ||
    layout.dispatch.dataSlotVMAddr < data.vmAddress + data.fileSize ||
    layout.dispatch.segmentEndVMAddr !== data.vmAddress + data.vmSize ||
    !common ||
    common.commandOffset !== layout.dispatch.commonSectionCommandOffset ||
    !commonSizeAllowed ||
    common.address + layout.dispatch.commonSectionOldSize !==
      layout.dispatch.commonSectionOldEndVMAddr ||
    layout.dispatch.dataSlotVMAddr !== layout.dispatch.commonSectionOldEndVMAddr ||
    layout.dispatch.dataSlotVMAddr % layout.dispatch.pointerSize !== 0 ||
    sections.some(
      section =>
        section !== common &&
        layout.dispatch.dataSlotVMAddr < section.address + section.size &&
        layout.dispatch.dataSlotVMAddr + layout.dispatch.pointerSize > section.address
    )
  ) {
    throw new Error("unsupported binary: unsafe zero-fill dispatch pointer slot");
  }
  if (
    !codeSignature ||
    codeSignature.dataOffset !== CODE_SIGNATURE_DATA_OFFSET ||
    codeSignature.dataSize === 0 ||
    codeSignature.dataOffset + codeSignature.dataSize !== bytes.length ||
    !linkEdit ||
    codeSignature.dataOffset < linkEdit.fileOffset ||
    codeSignature.dataOffset + codeSignature.dataSize > linkEdit.fileOffset + linkEdit.fileSize
  ) {
    throw new Error("unsupported binary: unexpected LC_CODE_SIGNATURE range");
  }
  return {
    commandCount,
    commandsSize,
    commandEnd,
    codeSignature,
    dependencies,
  };
}

function patchPayloadSha256(bytes, codeSignature) {
  return createHash("sha256")
    .update(bytes.subarray(0, codeSignature.commandOffset + 8))
    .update(bytes.subarray(codeSignature.commandOffset + 16, codeSignature.dataOffset))
    .update(bytes.subarray(codeSignature.dataOffset + codeSignature.dataSize))
    .digest("hex");
}

function uint32(value) {
  const bytes = Buffer.alloc(4);
  bytes.writeUInt32LE(value);
  return bytes;
}

function uint64(value) {
  const bytes = Buffer.alloc(8);
  bytes.writeBigUInt64LE(BigInt(value));
  return bytes;
}

const patchSites = [
  {
    name: "mach-header-command-count",
    offset: 16,
    expectedOriginal: uint32(layout.dependency.originalCommandCount),
    patched: uint32(layout.dependency.patchedCommandCount),
  },
  {
    name: "mach-header-command-size",
    offset: 20,
    expectedOriginal: uint32(layout.dependency.originalCommandsSize),
    patched: uint32(layout.dependency.patchedCommandsSize),
  },
  {
    name: "sidecar-load-command",
    offset: layout.dependency.commandOffset,
    expectedOriginal: Buffer.alloc(layout.dependency.commandSize),
    patched: Buffer.from(layout.dependency.commandHex, "hex"),
  },
  {
    name: "common-section-size",
    offset: layout.dispatch.commonSectionCommandOffset + 40,
    expectedOriginal: uint64(layout.dispatch.commonSectionOldSize),
    patched: uint64(layout.dispatch.commonSectionNewSize),
  },
  {
    name: "constructor-verification-marker",
    offset: layout.constructorVerification.markerOffset,
    expectedOriginal: Buffer.alloc(
      Buffer.from(layout.constructorVerification.markerHex, "hex").length
    ),
    patched: Buffer.from(layout.constructorVerification.markerHex, "hex"),
  },
  ...layout.binaryPatches.map(patch => ({
    name: patch.id,
    offset: patch.offset,
    expectedOriginal: Buffer.from(patch.originalHex, "hex"),
    patched: Buffer.from(patch.patchedHex, "hex"),
  })),
  {
    name: `${layout.commitHook.id}-entry`,
    offset: layout.commitHook.entryOffset,
    expectedOriginal: Buffer.from(layout.commitHook.originalHex, "hex"),
    patched: Buffer.from(layout.commitHook.entryPatchHex, "hex"),
  },
  {
    name: `${layout.commitHook.id}-gate`,
    offset: layout.commitHook.gateOffset,
    expectedOriginal: Buffer.alloc(Buffer.from(layout.commitHook.gateHex, "hex").length),
    patched: Buffer.from(layout.commitHook.gateHex, "hex"),
  },
  ...layout.hooks.flatMap(hook => [
    {
      name: `${hook.id}-entry`,
      offset: hook.entryOffset,
      expectedOriginal: Buffer.from(hook.originalHex, "hex"),
      patched: Buffer.from(hook.entryPatchHex, "hex"),
    },
    {
      name: `${hook.id}-gate`,
      offset: hook.gateOffset,
      expectedOriginal: Buffer.alloc(Buffer.from(hook.gateHex, "hex").length),
      patched: Buffer.from(hook.gateHex, "hex"),
    },
    {
      name: `${hook.id}-original-trampoline`,
      offset: hook.trampolineOffset,
      expectedOriginal: Buffer.alloc(
        Buffer.from(hook.trampolineHex, "hex").length
      ),
      patched: Buffer.from(hook.trampolineHex, "hex"),
    },
  ]),
];

for (const site of patchSites) {
  if (site.expectedOriginal.length === 0 ||
      site.expectedOriginal.length !== site.patched.length) {
    throw new Error(`layout corruption: invalid fixed-width span ${site.name}`);
  }
}
const orderedPatchSites = [...patchSites].sort((left, right) => left.offset - right.offset);
for (let index = 1; index < orderedPatchSites.length; index += 1) {
  const previous = orderedPatchSites[index - 1];
  const current = orderedPatchSites[index];
  if (previous.offset + previous.patched.length > current.offset) {
    throw new Error(`layout corruption: overlapping spans ${previous.name} and ${current.name}`);
  }
}
for (const hook of layout.hooks) {
  const original = Buffer.from(hook.originalHex, "hex");
  const entryPatch = Buffer.from(hook.entryPatchHex, "hex");
  const gate = Buffer.from(hook.gateHex, "hex");
  const trampoline = Buffer.from(hook.trampolineHex, "hex");
  if (hook.continuationOffset !== hook.entryOffset + original.length ||
      entryPatch.length !== original.length ||
      !trampoline.subarray(0, original.length).equals(original) ||
      hook.gateOffset < layout.constructorVerification.markerOffset ||
      hook.trampolineOffset < layout.constructorVerification.markerOffset ||
      hook.gateOffset + gate.length > layout.textCave.endOffset ||
      hook.trampolineOffset + trampoline.length > layout.textCave.endOffset ||
      gate[8] !== 0x74 ||
      hook.gateOffset + 8 + gate.readInt32LE(3) !== layout.dispatch.dataSlotVMAddr ||
      hook.gateOffset + 17 + gate.readInt32LE(13) !== layout.dispatch.dataSlotVMAddr ||
      hook.gateOffset + 10 + gate.readInt8(9) !== hook.trampolineOffset) {
    throw new Error(`layout corruption: invalid relocated prologue for ${hook.id}`);
  }
}

const commit = layout.commitHook;
const originalCall = Buffer.from(commit.originalHex, "hex");
const patchedCall = Buffer.from(commit.entryPatchHex, "hex");
const commitGate = Buffer.from(commit.gateHex, "hex");
if (originalCall.length !== 6 || originalCall[0] !== 0xff || originalCall[1] !== 0x15 ||
    commit.entryOffset + 6 + originalCall.readInt32LE(2) !== commit.objcMsgSendGotOffset ||
    patchedCall.length !== 6 || patchedCall[0] !== 0xe8 || patchedCall[5] !== 0x90 ||
    commit.entryOffset + 5 + patchedCall.readInt32LE(1) !== commit.gateOffset ||
    commitGate.length !== 30 || commitGate[8] !== 0x74 || commitGate[9] !== 14 ||
    commitGate.subarray(17, 24).toString("hex") !== "41ffa398000000" ||
    commitGate[24] !== 0xff || commitGate[25] !== 0x25 ||
    commit.gateOffset + 8 + commitGate.readInt32LE(3) !== layout.dispatch.dataSlotVMAddr ||
    commit.gateOffset + 17 + commitGate.readInt32LE(13) !== layout.dispatch.dataSlotVMAddr ||
    commit.gateOffset + 30 + commitGate.readInt32LE(26) !== commit.objcMsgSendGotOffset ||
    commit.gateOffset < layout.constructorVerification.markerOffset ||
    commit.gateOffset + commitGate.length > layout.textCave.endOffset ||
    commit.dispatchFieldOffset !== layout.hooks.length * 8) {
  throw new Error("layout corruption: invalid Metal4 commit call gate");
}

export const D3DMETAL_PSO_CACHE_PATCH_SITES = patchSites;

function valueAt(bytes, site) {
  const length = Math.max(site.expectedOriginal.length, site.patched.length);
  if (site.offset + length > bytes.length) return null;
  return bytes.subarray(site.offset, site.offset + length);
}

function siteInspection(bytes) {
  return patchSites.map(site => {
    const value = valueAt(bytes, site);
    let state = "unknown";
    if (value?.equals(site.expectedOriginal)) state = "original";
    if (value?.equals(site.patched)) state = "patched";
    return {
      name: site.name,
      offset: site.offset,
      state,
      value: value?.toString("hex") ?? "truncated",
    };
  });
}

function reconstructedStageBytes(bytes) {
  const output = Buffer.from(bytes);
  for (const site of patchSites) site.expectedOriginal.copy(output, site.offset);
  return output;
}

export function inspectD3DMetalPsoCachePatch(bytes) {
  let mach;
  let layoutError;
  try {
    mach = parseMachO(bytes);
    for (const span of layout.verificationSpans) {
      const expected = Buffer.from(span.expectedHex, "hex");
      if (!Number.isSafeInteger(span.offset) || span.offset < 0 ||
          expected.length === 0 || span.offset + expected.length > bytes.length ||
          !bytes.subarray(span.offset, span.offset + expected.length).equals(expected)) {
        throw new Error(`unsupported binary: verification span mismatch for ${span.id}`);
      }
    }
  } catch (error) {
    layoutError = error instanceof Error ? error.message : String(error);
  }
  const hash = sha256(bytes);
  const payloadHash = mach
    ? patchPayloadSha256(bytes, mach.codeSignature)
    : undefined;
  const sites = siteInspection(bytes);
  const states = new Set(sites.map(site => site.state));
  const allOriginal = states.size === 1 && states.has("original");
  const allPatched = states.size === 1 && states.has("patched");
  const directStageInspection = inspectD3DMetalStageLockPatch(bytes);
  const reconstructedStageInspection = allPatched
    ? inspectD3DMetalStageLockPatch(reconstructedStageBytes(bytes))
    : undefined;
  const originalHeader =
    mach &&
    mach.commandCount === layout.dependency.originalCommandCount &&
    mach.commandsSize === layout.dependency.originalCommandsSize &&
    !mach.dependencies.includes(layout.dependency.path);
  const patchedHeader =
    mach &&
    mach.commandCount === layout.dependency.originalCommandCount + 1 &&
    mach.commandsSize ===
      layout.dependency.originalCommandsSize + layout.dependency.commandSize &&
    mach.commandEnd === layout.dependency.firstTextOffset - 32 &&
    mach.dependencies.filter(dependency => dependency === layout.dependency.path)
      .length === 1;

  let mode = "unknown-or-partial";
  if (!layoutError && allOriginal && originalHeader) {
    if (directStageInspection.mode === "original") mode = "original";
    if (directStageInspection.mode === "patched") mode = "stage-patched";
    if (directStageInspection.mode === "patched-signed") mode = "stage-patched-signed";
  } else if (
    !layoutError &&
    allPatched &&
    patchedHeader &&
    hash === D3DMETAL_PSO_CACHE_PATCHED_SHA256 &&
    reconstructedStageInspection?.mode === "patched"
  ) {
    mode = "patched";
  } else if (
    !layoutError &&
    allPatched &&
    patchedHeader &&
    payloadHash === D3DMETAL_PSO_CACHE_PATCHED_PAYLOAD_SHA256 &&
    (reconstructedStageInspection?.mode === "patched" ||
      reconstructedStageInspection?.mode === "patched-signed" ||
      reconstructedStageInspection?.mode === "unknown-or-partial")
  ) {
    mode = "patched-signed";
  }

  return {
    sha256: hash,
    payloadSha256: payloadHash,
    mode,
    layoutError,
    codeSignature: mach?.codeSignature,
    stageMode:
      allPatched ? reconstructedStageInspection?.mode : directStageInspection.mode,
    sites,
  };
}

export function applyD3DMetalPsoCachePatch(bytes) {
  const inspection = inspectD3DMetalPsoCachePatch(bytes);
  if (inspection.mode === "patched") return Buffer.from(bytes);
  if (
    inspection.mode !== "original" &&
    inspection.mode !== "stage-patched" &&
    inspection.mode !== "stage-patched-signed"
  ) {
    throw new Error(
      `refusing patch: expected exact GPTK source or validated stage-lock-only input, got ${inspection.sha256} (${inspection.layoutError ?? inspection.mode})`
    );
  }

  const stageBytes =
    inspection.mode === "original"
      ? applyD3DMetalStageLockPatch(bytes)
      : Buffer.from(bytes);
  const output = Buffer.from(stageBytes);
  for (const site of patchSites) site.patched.copy(output, site.offset);
  const outputInspection = inspectD3DMetalPsoCachePatch(output);
  const expectedMode =
    inspection.mode === "stage-patched-signed" ? "patched-signed" : "patched";
  if (outputInspection.mode !== expectedMode) {
    throw new Error(
      `internal patch verification failed: SHA-256 ${outputInspection.sha256}, payload SHA-256 ${outputInspection.payloadSha256}, mode ${outputInspection.mode}, stage ${outputInspection.stageMode}, layout ${outputInspection.layoutError ?? "valid"}, unknown sites ${outputInspection.sites.filter(site => site.state === "unknown").map(site => site.name).join(",") || "none"}`
    );
  }
  return output;
}

async function patchFile(inputPath, outputPath) {
  const input = await readFile(inputPath);
  const output = applyD3DMetalPsoCachePatch(input);
  const inputStat = await stat(inputPath);
  const temporaryPath = `${outputPath}.tmp-${randomUUID()}`;
  let temporaryCreated = false;
  try {
    await writeFile(temporaryPath, output, { flag: "wx" });
    temporaryCreated = true;
    await chmod(temporaryPath, inputStat.mode);
    await rename(temporaryPath, outputPath);
  } finally {
    if (temporaryCreated) await rm(temporaryPath, { force: true });
  }
  return inspectD3DMetalPsoCachePatch(output);
}

const DEFAULT_INPUT =
  "build/wine-p3/gptk-overlay/wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal";
const DEFAULT_OUTPUT = "build/d3dmetal-pso-cache/D3DMetal";

async function main(argv) {
  const [command, ...args] = argv;
  if (command === "inspect" && args.length <= 1) {
    const inputPath = args[0] ?? DEFAULT_INPUT;
    console.log(
      JSON.stringify(inspectD3DMetalPsoCachePatch(await readFile(inputPath)), null, 2)
    );
    return;
  }
  if (command === "patch" && args.length <= 2) {
    const inputPath = args[0] ?? DEFAULT_INPUT;
    const outputPath = args[1] ?? DEFAULT_OUTPUT;
    console.log(JSON.stringify(await patchFile(inputPath, outputPath), null, 2));
    return;
  }
  throw new Error(
    "Usage: d3dmetal-pso-cache-patch.mjs inspect [binary] | patch [pristine-or-stage-locked-binary] [output]"
  );
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
