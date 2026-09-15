#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { execFile } from "node:child_process";
import { createReadStream } from "node:fs";
import {
  link,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, join, relative, resolve } from "node:path";
import { promisify } from "node:util";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const CURRENT_P3_ID = "11.0-d3dmetal-gptk4.0b2-rtx5060-i1";
const WINE_VERSION = "wine-11.17";
const require = createRequire(import.meta.url);
const ts = require("typescript");
const execFileAsync = promisify(execFile);
const RUNTIME_MANIFEST_MEMBER = "wine/yaagl-wine-runtime-files.json";
const RUNTIME_PROVENANCE_MEMBER = "wine/yaagl-wine-p3-provenance.json";

function fail(message) {
  throw new Error(message);
}

function staticPropertyName(name) {
  if (ts.isIdentifier(name) || ts.isStringLiteralLike(name)) return name.text;
  return undefined;
}

function property(object, name) {
  return object.properties.find(
    item =>
      ts.isPropertyAssignment(item) && staticPropertyName(item.name) === name
  );
}

function stringLiteralValue(node) {
  return ts.isStringLiteralLike(node) ? node.text : undefined;
}

function wineDistributionId(node) {
  if (!ts.isObjectLiteralExpression(node)) return undefined;
  const id = property(node, "id");
  const displayName = property(node, "displayName");
  const remoteUrl = property(node, "remoteUrl");
  const attributes = property(node, "attributes");
  if (
    !id ||
    !displayName ||
    !remoteUrl ||
    !attributes ||
    !ts.isObjectLiteralExpression(attributes.initializer)
  ) {
    return undefined;
  }
  const renderBackend = property(attributes.initializer, "renderBackend");
  if (!renderBackend) return undefined;
  return stringLiteralValue(id.initializer);
}

function visit(node, callback) {
  callback(node);
  ts.forEachChild(node, child => visit(child, callback));
}

function parseJavascript(path, source) {
  const sourceFile = ts.createSourceFile(
    path,
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.JS
  );
  if (sourceFile.parseDiagnostics.length > 0) {
    const diagnostic = sourceFile.parseDiagnostics[0];
    const detail = ts.flattenDiagnosticMessageText(diagnostic.messageText, "\n");
    fail(`refusing malformed bundled JavaScript ${path}: ${detail}`);
  }
  return sourceFile;
}

async function javascriptFiles(root) {
  const files = [];
  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        await walk(path);
      } else if (entry.isFile() && entry.name.endsWith(".js")) {
        files.push(path);
      } else if (!entry.isFile()) {
        fail(`refusing unexpected non-file resource member: ${path}`);
      }
    }
  }
  await walk(root);
  return files;
}

async function inspectBundle(root, soughtId) {
  const matches = [];
  const distributions = [];
  for (const path of await javascriptFiles(root)) {
    const source = await readFile(path, "utf8");
    const sourceFile = parseJavascript(path, source);
    visit(sourceFile, node => {
      const id = wineDistributionId(node);
      if (id === undefined) return;
      distributions.push({ id, path, node, source, sourceFile });
      if (id === soughtId) matches.push({ id, path, node, source, sourceFile });
    });
  }
  return { matches, distributions };
}

function directArrayElement(node) {
  return ts.isArrayLiteralExpression(node.parent) &&
    node.parent.elements.some(element => element === node)
    ? { array: node.parent, element: node }
    : undefined;
}

function distributionArrayElement(distribution) {
  const direct = directArrayElement(distribution.node);
  if (direct) return direct;

  const declaration = distribution.node.parent;
  if (
    !ts.isVariableDeclaration(declaration) ||
    declaration.initializer !== distribution.node ||
    !ts.isIdentifier(declaration.name)
  ) {
    return undefined;
  }
  const declarationList = declaration.parent;
  if (
    !ts.isVariableDeclarationList(declarationList) ||
    !(declarationList.flags & ts.NodeFlags.Const) ||
    declarationList.declarations.length !== 1 ||
    !ts.isVariableStatement(declarationList.parent) ||
    declarationList.parent.parent !== distribution.sourceFile
  ) {
    return undefined;
  }

  const occurrences = [];
  visit(distribution.sourceFile, node => {
    if (ts.isIdentifier(node) && node.text === declaration.name.text) {
      occurrences.push(node);
    }
  });
  const references = occurrences.filter(node => node !== declaration.name);
  if (occurrences.length !== 2 || references.length !== 1) return undefined;
  return directArrayElement(references[0]);
}

function literalWineDistribution(node) {
  if (!ts.isObjectLiteralExpression(node)) return undefined;
  const id = property(node, "id");
  const displayName = property(node, "displayName");
  const remoteUrl = property(node, "remoteUrl");
  const archiveSha256 = property(node, "archiveSha256");
  const archiveSize = property(node, "archiveSize");
  const wineVersion = property(node, "wineVersion");
  const runtimeManifestSha256 = property(node, "runtimeManifestSha256");
  const attributes = property(node, "attributes");
  if (
    !id ||
    !displayName ||
    !remoteUrl ||
    !archiveSha256 ||
    !archiveSize ||
    !wineVersion ||
    !runtimeManifestSha256 ||
    !attributes ||
    !ts.isNumericLiteral(archiveSize.initializer) ||
    !ts.isObjectLiteralExpression(attributes.initializer)
  ) {
    return undefined;
  }
  const renderBackend = property(attributes.initializer, "renderBackend");
  const winePath = property(attributes.initializer, "winePath");
  const precomposedD3DMetal = property(attributes.initializer, "precomposedD3DMetal");
  const d3dMetalGraphicsCache = property(attributes.initializer, "d3dMetalGraphicsCache");
  if (!renderBackend || !winePath || !precomposedD3DMetal || !d3dMetalGraphicsCache) return undefined;
  if (precomposedD3DMetal.initializer.kind !== ts.SyntaxKind.TrueKeyword) return undefined;
  if (![ts.SyntaxKind.TrueKeyword, ts.SyntaxKind.FalseKeyword].includes(d3dMetalGraphicsCache.initializer.kind)) return undefined;
  const strings = [
    id.initializer,
    displayName.initializer,
    remoteUrl.initializer,
    archiveSha256.initializer,
    wineVersion.initializer,
    runtimeManifestSha256.initializer,
    renderBackend.initializer,
    winePath.initializer,
  ].map(stringLiteralValue);
  if (strings.some(value => value === undefined)) return undefined;
  return {
    id: strings[0],
    displayName: strings[1],
    remoteUrl: strings[2],
    archiveSha256: strings[3],
    archiveSize: Number(archiveSize.initializer.text),
    wineVersion: strings[4],
    runtimeManifestSha256: strings[5],
    attributes: {
      renderBackend: strings[6],
      winePath: strings[7],
      precomposedD3DMetal: true,
      d3dMetalGraphicsCache: d3dMetalGraphicsCache.initializer.kind === ts.SyntaxKind.TrueKeyword,
    },
  };
}

async function sha256File(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

async function extractTrustedRuntimeMetadata(archivePath, requestedId) {
  const options = { encoding: "buffer", maxBuffer: 64 * 1024 * 1024 };
  const listed = await execFileAsync("/usr/bin/tar", ["-tJf", archivePath], options);
  const members = listed.stdout.toString("utf8").split("\n").filter(Boolean);
  for (const required of [RUNTIME_MANIFEST_MEMBER, RUNTIME_PROVENANCE_MEMBER]) {
    const count = members.filter(member => member === required).length;
    if (count !== 1) fail("archive must contain exactly one " + required + ", found " + count);
  }
  const [manifestResult, provenanceResult] = await Promise.all([
    execFileAsync("/usr/bin/tar", ["-xJOf", archivePath, RUNTIME_MANIFEST_MEMBER], options),
    execFileAsync("/usr/bin/tar", ["-xJOf", archivePath, RUNTIME_PROVENANCE_MEMBER], options),
  ]);
  const manifestBytes = manifestResult.stdout;
  let manifest;
  let provenance;
  try {
    manifest = JSON.parse(manifestBytes.toString("utf8"));
    provenance = JSON.parse(provenanceResult.stdout.toString("utf8"));
  } catch {
    fail("archive runtime manifest or provenance is not valid JSON");
  }
  if (manifest?.schemaVersion !== 1 || manifest.runtimeId !== requestedId || manifest.wineVersion !== WINE_VERSION || !Array.isArray(manifest.entries)) {
    fail("archive runtime manifest ID, version, or schema does not match the requested distribution");
  }
  if (!Number.isSafeInteger(provenance?.schemaVersion) || provenance.schemaVersion < 1 || provenance.runtimeId !== requestedId || provenance.wineVersion !== WINE_VERSION || provenance.precomposedD3DMetal !== true || typeof provenance.d3dMetalGraphicsCache !== "boolean" || !Array.isArray(provenance.authenticatedArtifacts)) {
    fail("archive package provenance does not match its requested runtime ID and version");
  }
  const byPath = new Map();
  let previousPath = "";
  for (const entry of manifest.entries) {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) fail("archive runtime manifest contains a non-object entry");
    const path = entry.path;
    if (typeof path !== "string" || path.length === 0 || path.startsWith("/") || path.includes("\\") || path.split("/").some(component => component === "" || component === "." || component === "..") || path <= previousPath) {
      fail("archive runtime manifest paths must be unique, safe, and strictly sorted");
    }
    previousPath = path;
    if (entry.type === "file") {
      if (!Number.isSafeInteger(entry.size) || entry.size < 0 || typeof entry.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(entry.sha256) || Object.keys(entry).sort().join(",") !== "path,sha256,size,type") fail("invalid regular-file manifest entry: " + path);
    } else if (entry.type === "symlink") {
      if (typeof entry.target !== "string" || entry.target.length === 0 || Object.keys(entry).sort().join(",") !== "path,target,type") fail("invalid symlink manifest entry: " + path);
    } else {
      fail("invalid runtime manifest entry type: " + path);
    }
    byPath.set(path, entry);
  }
  for (const required of ["bin/wine", "bin/wine.real", "bin/wineserver"]) {
    const entry = byPath.get(required);
    if (!entry || entry.type !== "file") fail("runtime manifest does not authenticate " + required);
    const authenticated = provenance.authenticatedArtifacts.find(item => item?.path === required);
    if (!authenticated || authenticated.size !== entry.size || authenticated.sha256 !== entry.sha256) fail("package provenance does not authenticate the final " + required);
  }
  return {
    runtimeManifestSha256: createHash("sha256").update(manifestBytes).digest("hex"),
    d3dMetalGraphicsCache: provenance.d3dMetalGraphicsCache,
  };
}

async function memberHashes(root) {
  const hashes = new Map();
  async function walk(directory) {
    const entries = await readdir(directory, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory()) {
        await walk(path);
      } else if (entry.isFile()) {
        hashes.set(relative(root, path), await sha256File(path));
      } else {
        fail(`refusing unexpected non-file resource member: ${path}`);
      }
    }
  }
  await walk(root);
  return hashes;
}

function compareMembers(before, after, expectedChangedPath) {
  if (before.size !== after.size) {
    fail(`resource member count changed from ${before.size} to ${after.size}`);
  }
  const changed = [];
  for (const [path, hash] of before) {
    const candidateHash = after.get(path);
    if (candidateHash === undefined) fail(`candidate lost resource member: ${path}`);
    if (candidateHash !== hash) changed.push(path);
  }
  if (changed.length !== 1 || changed[0] !== expectedChangedPath) {
    fail(`unexpected changed resource members: ${JSON.stringify(changed)}`);
  }
  return changed;
}

function resolveAsar() {
  const neuManifest = require.resolve("@neutralinojs/neu/package.json");
  const neuRequire = createRequire(neuManifest);
  return {
    module: neuRequire("asar"),
    path: neuRequire.resolve("asar"),
  };
}

async function requireRegularFile(path, description) {
  const info = await stat(path);
  if (!info.isFile()) fail(`${description} is not a regular file: ${path}`);
  if (info.size === 0) fail(`${description} is empty: ${path}`);
  return info;
}

async function main(argv) {
  if (argv.length !== 5) {
    fail(
      "Usage: register-local-wine-resource.mjs <source-resources.neu> <wine-archive.tar.xz> <new-id> <display-name> <output-candidate.neu>"
    );
  }

  const [sourceArgument, archiveArgument, id, displayName, outputArgument] = argv;
  const sourcePath = resolve(sourceArgument);
  const archivePath = resolve(archiveArgument);
  const outputPath = resolve(outputArgument);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) {
    fail("new id must contain only letters, digits, dots, underscores, and hyphens");
  }
  if (!displayName || displayName.trim() !== displayName) {
    fail("display name must be non-empty with no leading or trailing whitespace");
  }
  if (sourcePath === archivePath) fail("source resources and Wine archive must differ");
  if (sourcePath === outputPath) fail("output candidate must differ from source resources");
  if (archivePath === outputPath) fail("output candidate must differ from source archive");
  await requireRegularFile(sourcePath, "source resources");
  const archiveInfo = await requireRegularFile(archivePath, "Wine archive");
  if (!Number.isSafeInteger(archiveInfo.size)) fail("Wine archive size is not a safe integer");
  try {
    await lstat(outputPath);
    fail(`refusing to replace existing output: ${outputPath}`);
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const [archiveSha256, runtimeMetadata] = await Promise.all([
    sha256File(archivePath),
    extractTrustedRuntimeMetadata(archivePath, id),
  ]);
  const record = {
    id,
    displayName,
    remoteUrl: pathToFileURL(archivePath).href,
    archiveSha256,
    archiveSize: archiveInfo.size,
    wineVersion: WINE_VERSION,
    runtimeManifestSha256: runtimeMetadata.runtimeManifestSha256,
    attributes: {
      renderBackend: "d3dmetal",
      winePath: "wine",
      precomposedD3DMetal: true,
      d3dMetalGraphicsCache: runtimeMetadata.d3dMetalGraphicsCache,
    },
  };

  const { module: asar, path: asarPath } = resolveAsar();
  const temporaryRoot = await mkdtemp(join(tmpdir(), "yaagl-register-wine-"));
  const extractedRoot = join(temporaryRoot, "source");
  const readbackRoot = join(temporaryRoot, "readback");
  const temporaryOutput = join(
    dirname(outputPath),
    `.${basename(outputPath)}.tmp-${randomUUID()}`
  );
  try {
    await mkdir(extractedRoot);
    asar.extractAll(sourcePath, extractedRoot);
    const beforeHashes = await memberHashes(extractedRoot);
    const inspected = await inspectBundle(extractedRoot, CURRENT_P3_ID);
    if (inspected.matches.length !== 1) {
      fail(
        `expected exactly one current P3 WineDistribution ${CURRENT_P3_ID}, found ${inspected.matches.length}`
      );
    }
    const current = inspected.matches[0];
    const currentAttributes = property(current.node, "attributes");
    const currentRenderBackend = property(
      currentAttributes.initializer,
      "renderBackend"
    );
    const currentWinePath = property(currentAttributes.initializer, "winePath");
    if (
      stringLiteralValue(currentRenderBackend?.initializer) !== "d3dmetal" ||
      stringLiteralValue(currentWinePath?.initializer) !== "wine"
    ) {
      fail("current P3 WineDistribution has an unexpected structure");
    }
    const currentArrayElement = distributionArrayElement(current);
    if (!currentArrayElement) {
      fail(
        "current P3 WineDistribution is not a direct array element or an unambiguous top-level const object binding"
      );
    }
    const existing = inspected.distributions.filter(
      distribution => distribution.id === id
    );
    if (existing.length > 1) {
      fail(`WineDistribution id is duplicated: ${id}`);
    }
    const operation = existing.length === 0 ? "insert" : "replace";
    const existingArrayElement = existing[0]
      ? distributionArrayElement(existing[0])
      : undefined;
    if (
      existing[0] &&
      (!existingArrayElement || existingArrayElement.array !== currentArrayElement.array)
    ) {
      fail(`WineDistribution is not adjacent to the current P3 catalog: ${id}`);
    }
    const mutation = existing[0] ?? current;
    const insertionAnchor = currentArrayElement.element;
    const candidateSource =
      operation === "insert"
        ? current.source.slice(0, insertionAnchor.end) +
          `,${JSON.stringify(record)}` +
          current.source.slice(insertionAnchor.end)
        : mutation.source.slice(
            0,
            mutation.node.getStart(mutation.sourceFile)
          ) +
          JSON.stringify(record) +
          mutation.source.slice(mutation.node.end);
    const candidateSourceFile = parseJavascript(mutation.path, candidateSource);
    const insertedNodes = [];
    visit(candidateSourceFile, node => {
      if (wineDistributionId(node) === id) insertedNodes.push(node);
    });
    if (insertedNodes.length !== 1) {
      fail(`inserted WineDistribution did not parse exactly once: ${id}`);
    }
    const parsedRecord = literalWineDistribution(insertedNodes[0]);
    if (JSON.stringify(parsedRecord) !== JSON.stringify(record)) {
      fail("inserted WineDistribution did not parse back to the requested record");
    }
    await writeFile(mutation.path, candidateSource, "utf8");

    await mkdir(dirname(outputPath), { recursive: true });
    await asar.createPackage(extractedRoot, temporaryOutput);
    await mkdir(readbackRoot);
    asar.extractAll(temporaryOutput, readbackRoot);

    const assetRelativePath = relative(extractedRoot, mutation.path);
    const changedMembers = compareMembers(
      beforeHashes,
      await memberHashes(readbackRoot),
      assetRelativePath
    );
    const readbackAsset = join(readbackRoot, assetRelativePath);
    const readbackSource = await readFile(readbackAsset, "utf8");
    if (readbackSource !== candidateSource) {
      fail("candidate asset bytes differ after ASAR readback");
    }
    const readback = await inspectBundle(readbackRoot, id);
    if (readback.matches.length !== 1) {
      fail(`candidate readback contains ${readback.matches.length} entries for ${id}`);
    }
    const readbackRecord = literalWineDistribution(readback.matches[0].node);
    if (JSON.stringify(readbackRecord) !== JSON.stringify(record)) {
      fail("candidate readback WineDistribution differs from the requested record");
    }
    const expectedDistributionCount =
      inspected.distributions.length + (operation === "insert" ? 1 : 0);
    if (readback.distributions.length !== expectedDistributionCount) {
      fail("candidate readback changed the WineDistribution count unexpectedly");
    }
    const preservedP3 = readback.distributions.filter(
      distribution => distribution.id === CURRENT_P3_ID
    );
    if (preservedP3.length !== 1) {
      fail("candidate readback did not preserve the current P3 WineDistribution");
    }
    const sourceP3Text = current.node.getText(current.sourceFile);
    const readbackP3 = preservedP3[0];
    if (readbackP3.node.getText(readbackP3.sourceFile) !== sourceP3Text) {
      fail("candidate readback changed the current P3 WineDistribution");
    }

    try {
      await link(temporaryOutput, outputPath);
    } catch (error) {
      if (error.code === "EEXIST") {
        fail(`refusing to replace existing output: ${outputPath}`);
      }
      throw error;
    }
    await rm(temporaryOutput);
    const outputInfo = await stat(outputPath);
    console.log(
      JSON.stringify(
        {
          source: sourcePath,
          output: outputPath,
          asarModule: asarPath,
          changedMembers,
          untouchedMemberCount: beforeHashes.size - changedMembers.length,
          currentP3Preserved: CURRENT_P3_ID,
          bundleOperation: operation,
          wineDistributionCount: {
            before: inspected.distributions.length,
            after: readback.distributions.length,
          },
          inserted: readbackRecord,
          candidate: {
            sha256: await sha256File(outputPath),
            size: outputInfo.size,
          },
        },
        null,
        2
      )
    );
  } catch (error) {
    await rm(temporaryOutput, { force: true });
    throw error;
  } finally {
    await rm(temporaryRoot, { recursive: true, force: true });
  }
}

export { extractTrustedRuntimeMetadata };

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
