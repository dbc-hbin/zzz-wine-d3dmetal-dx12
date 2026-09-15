import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join, posix, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import { test } from "node:test";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fixturePath = join(repoRoot, "scripts/fixtures/dx12-launch-regression-upstream-0.3.18.js");
const transformerOption = process.argv.indexOf("--transformer");
assert.ok(transformerOption === -1 || process.argv[transformerOption + 1], "--transformer requires a path");
const transformerPath = transformerOption === -1
  ? join(repoRoot, "installer/resources/AsarTransform.js")
  : resolve(process.argv[transformerOption + 1]);
const targetId = "11.17-zzz-dx12-tuned-stage-parallel-cache-warmup-cursor-rollback-gptk4b2-arm64server";
const experimentalId = "wine-11.17-gptk4.0b2-metalfx-experimental";
const protectedRuntimeIds = [targetId, experimentalId];
const transformerOptions = {
  registrationHelperPath: "/safe/zzz-wine-register",
  archivePath: "/safe/wine.tar.xz",
  protectedRuntimeIds,
};

function staticPropertyName(ts, name) {
  return name && (ts.isIdentifier(name) || ts.isStringLiteralLike(name)) ? name.text : undefined;
}

function property(ts, object, name) {
  return object.properties.find(item => ts.isPropertyAssignment(item) && staticPropertyName(ts, item.name) === name);
}

function stringValue(ts, node) {
  return ts.isStringLiteralLike(node) ? node.text : undefined;
}

function catalogEntry(ts, node) {
  if (!ts.isObjectLiteralExpression(node)) return undefined;
  const id = property(ts, node, "id");
  const displayName = property(ts, node, "displayName");
  const remoteUrl = property(ts, node, "remoteUrl");
  const attributes = property(ts, node, "attributes");
  if (!id || !displayName || !remoteUrl || !attributes || !ts.isObjectLiteralExpression(attributes.initializer)) return undefined;
  const entry = {
    id: stringValue(ts, id.initializer),
    displayName: stringValue(ts, displayName.initializer),
    remoteUrl: stringValue(ts, remoteUrl.initializer),
    attributes: {},
  };
  if (!entry.id || !entry.displayName || !entry.remoteUrl) return undefined;
  for (const attribute of attributes.initializer.properties) {
    if (!ts.isPropertyAssignment(attribute)) continue;
    const name = staticPropertyName(ts, attribute.name);
    const value = stringValue(ts, attribute.initializer);
    if (name && value !== undefined) entry.attributes[name] = value;
  }
  return entry.attributes.renderBackend && entry.attributes.winePath ? entry : undefined;
}

function catalogEntries(ts, source) {
  const file = ts.createSourceFile("upstream.js", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
  assert.equal(file.parseDiagnostics.length, 0, "fixture or transformed source must parse");
  const candidates = [];
  const visit = node => {
    if (ts.isArrayLiteralExpression(node)) {
      const entries = node.elements.map(element => catalogEntry(ts, element));
      if (entries.length && entries.every(Boolean)) candidates.push(entries);
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  candidates.sort((left, right) => right.length - left.length);
  assert.ok(candidates.length, "supported upstream fixture must retain a Wine distribution catalog");
  assert.ok(candidates.length === 1 || candidates[0].length > candidates[1].length, "Wine distribution catalog is ambiguous");
  return candidates[0];
}

function loadTransformer(pathname) {
  const typeScriptPath = join(repoRoot, "installer/resources/typescript.js");
  const context = vm.createContext({ URL });
  vm.runInContext(readFileSync(typeScriptPath, "utf8"), context, { filename: typeScriptPath });
  vm.runInContext(readFileSync(pathname, "utf8"), context, { filename: pathname });
  assert.equal(typeof context.__asarTransform, "function", "transformer did not register its entry point");
  return { transform: context.__asarTransform, ts: context.ts };
}

function transformSource(transformer, source) {
  const transformed = transformer.transform(
    source,
    targetId,
    "Wine 11.17 ZZZ DX12",
    "file:///safe/wine.tar.xz",
    transformerOptions,
  );
  assert.equal(transformed.error, undefined, transformed.error);
  return transformed;
}

function upstreamFunctions(ts, source) {
  const file = ts.createSourceFile("upstream.js", source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
  const found = new Map();
  const visit = node => {
    if (ts.isFunctionDeclaration(node) && node.name && (node.name.text === "oc" || node.name.text === "V_")) {
      found.set(node.name.text, source.slice(node.getStart(file), node.end));
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  assert.equal(found.size, 2, "supported upstream fixture must retain its runner factory and game launch function");
  return { factory: found.get("oc"), launch: found.get("V_") };
}

function launchHarness(ts, source, distro) {
  const writes = new Map();
  const executions = [];
  const functions = upstreamFunctions(ts, source);
  const context = vm.createContext({
    H: {
      join: posix.join,
      dirname: value => {
        if (typeof value !== "string") throw new Error("unexpected dirname input: " + JSON.stringify(value));
        return posix.dirname(value);
      },
    },
    E4: async () => "/safe/wine/bin/wine",
    $e: async (...args) => {
      executions.push(args);
      return { stdout: "", stderr: "" };
    },
    Fr: async (...args) => {
      executions.push(args);
      return { stdout: "", stderr: "" };
    },
    hr: "/safe/wine",
    Vl: async () => "/safe/wine/bin/wine",
    xe: error => {
      throw error;
    },
    ge: async () => {},
    z_: async () => {},
    O_: async function* () {},
    xd: async function* () {},
    Mt: async () => {},
    ct: async () => {},
    Ut: async (pathname, contents) => {
      writes.set(pathname, contents);
    },
    Y: pathname => posix.join("/safe/working", pathname),
    atob: value => Buffer.from(value, "base64").toString("binary"),
    Ve: async error => {
      throw new Error(error);
    },
    j_: async () => {},
    Date,
  });
  vm.runInContext([functions.factory, "globalThis.__runnerFactory=oc;", functions.launch, "globalThis.__launch=V_;"].join("\n"), context, {
    filename: "transformed-upstream-launch.js",
  });

  return {
    async run(steamPatch) {
      const runner = await context.__runnerFactory({
        prefix: "/safe/prefix",
        distro,
      });

      const config = {
        resolutionCustom: false,
        steamPatch,
        metalHud: false,
        timeoutFix: false,
        proxyEnabled: false,
        blockNet: false,
      };
      for await (const _ of context.__launch({
        gameDir: "/safe/game",
        gameExecutable: "ZenlessZoneZero.exe",
        wine: runner,
        config,
        server: { id: "nap_global" },
      })) {
        // UI state yields are outside this launch-boundary regression.
      }
      return { writes, executions };
    },
  };
}

function useD3D12Count(value) {
  return Array.isArray(value)
    ? value.flat(Infinity).filter(argument => argument === "-use-d3d12").length
    : value.split("-use-d3d12").length - 1;
}

async function assertLaunchArguments(ts, transformedSource, distro, steamPatch, expectedCount) {
  const harness = launchHarness(ts, transformedSource, distro);
  const result = await harness.run(steamPatch);
  if (steamPatch) {
    const steam = result.executions.find(call => call.flat(Infinity).includes("C:\\windows\\system32\\steam.exe"));
    assert.ok(steam, "Steam launch must reach the stubbed process boundary");
    assert.equal(useD3D12Count(steam), expectedCount, "Steam game arguments must contain the expected number of DX12 flags");
    assert.ok(steam.flat(Infinity).includes("Z:\\safe\\game\\ZenlessZoneZero.exe"), "Steam must receive the game executable");
  } else {
    const batch = result.writes.get("/safe/working/config.bat");
    assert.ok(batch, "normal launch must write its game batch file");
    assert.equal(useD3D12Count(batch), expectedCount, "normal game batch must contain the expected number of DX12 flags");
    assert.match(batch, /ZenlessZoneZero\.exe/, "normal game batch must invoke the game executable");
  }
}

async function assertCatalogLaunches(ts, source, entries, expectedCount) {
  for (const entry of entries) {
    for (const steamPatch of [false, true]) {
      await assertLaunchArguments(ts, source, entry, steamPatch, expectedCount(entry));
    }
  }
}

function generatedGuard() {
  return JSON.stringify(protectedRuntimeIds) + ".includes(n.attributes.id)&&n.attributes.renderBackend===\"d3dmetal\"&&u.push(\"-use-d3d12\");";
}

function historicLaunchSource(transformer, source, replacement) {
  const baseline = transformSource(transformer, source);
  const guard = generatedGuard();
  assert.ok(baseline.source.includes(guard), "baseline transform must install the current launch guard");
  const historical = baseline.source.replace(guard, replacement);
  assert.notEqual(historical, baseline.source, "historical launch guard replacement must apply");
  catalogEntries(transformer.ts, historical);
  return historical;
}

async function assertFixedTransformer(transformer, source) {
  const originalCatalog = catalogEntries(transformer.ts, source);
  assert.equal(originalCatalog.some(entry => entry.id === targetId), false, "historical catalog fixture must not pre-seed the target");
  assert.ok(originalCatalog.filter(entry => entry.attributes.renderBackend === "d3dmetal").length >= 3, "fixture must retain prior D3DMetal menu entries");

  const first = transformSource(transformer, source);
  assert.equal(first.changed, true, "first registration must modify the pristine upstream frontend");
  const localArchiveGuard = JSON.stringify(protectedRuntimeIds) + ".includes(n.id)&&n.remoteUrl.startsWith(\"file:\")";
  assert.ok(first.source.includes(localArchiveGuard), "local archive installation must use the exact protected runtime allowlist");
  const transformedCatalog = catalogEntries(transformer.ts, first.source);
  const target = transformedCatalog.find(entry => entry.id === targetId);
  assert.ok(target, "transformed catalog must contain the requested target");
  assert.deepEqual(transformedCatalog.filter(entry => entry.id !== targetId), originalCatalog, "unrelated and prior Wine catalog entries must remain byte-equivalent data");

  await assertCatalogLaunches(transformer.ts, first.source, transformedCatalog, entry => protectedRuntimeIds.includes(entry.id) ? 1 : 0);
  await assertCatalogLaunches(transformer.ts, first.source, [{
    id: experimentalId,
    attributes: { id: experimentalId, renderBackend: "d3dmetal", winePath: "wine" },
  }], () => 1);
  await assertCatalogLaunches(transformer.ts, first.source, [{
    id: experimentalId,
    attributes: { id: experimentalId, renderBackend: "dxmt", winePath: "wine" },
  }], () => 0);

  const second = transformSource(transformer, first.source);
  assert.equal(second.changed, false, "re-registering an already transformed frontend must be idempotent");
  assert.equal(second.source, first.source, "idempotent registration must retain the transformed frontend byte-for-byte");

  const historicalLocalGuard = "n.id===\"" + targetId + "\"&&n.remoteUrl.startsWith(\"file:\")";
  const historicalLocal = first.source.replace(localArchiveGuard, historicalLocalGuard);
  assert.notEqual(historicalLocal, first.source, "historical local archive guard replacement must apply");
  const migratedLocal = transformSource(transformer, historicalLocal);
  assert.equal(migratedLocal.source.includes(historicalLocalGuard), false, "historical local archive guard must be removed");
  assert.ok(migratedLocal.source.includes(localArchiveGuard), "historical local archive guard must migrate to the exact allowlist");
  assert.equal(transformSource(transformer, migratedLocal.source).changed, false, "migrated local archive guard must be idempotent");
}

async function assertLegacyUpgrade(transformer, source, replacement, priorCount, expectedReplacementOccurrences) {
  const historical = historicLaunchSource(transformer, source, replacement);
  const historicalCatalog = catalogEntries(transformer.ts, historical);
  await assertCatalogLaunches(transformer.ts, historical, historicalCatalog, priorCount);

  const upgraded = transformSource(transformer, historical);
  assert.equal(upgraded.changed, true, "current transformer must upgrade the prior launch guard");
  assert.equal(upgraded.source.split(replacement).length - 1, expectedReplacementOccurrences, "current transformer must replace the prior launch guard instead of adding another one");
  const upgradedCatalog = catalogEntries(transformer.ts, upgraded.source);
  await assertCatalogLaunches(transformer.ts, upgraded.source, upgradedCatalog, entry => entry.id === targetId ? 1 : 0);

  const repeatedUpgrade = transformSource(transformer, upgraded.source);
  assert.equal(repeatedUpgrade.changed, false, "upgrading a historical frontend must become idempotent");
}

const upstreamSource = readFileSync(fixturePath, "utf8");
const transformer = loadTransformer(transformerPath);

test("DX12 launch registration uses transformed catalog entries and leaves prior Wine entries unforced", async () => {
  await assertFixedTransformer(transformer, upstreamSource);
});

test("DX12 launch registration upgrades the historical absent-runner-id guard", async () => {
  const replacement = "n.id===\"" + targetId + "\"&&u.push(\"-use-d3d12\");";
  await assertLegacyUpgrade(transformer, upstreamSource, replacement, () => 0, 0);
});

test("DX12 launch registration upgrades the historical backend-only guard", async () => {
  const replacement = "n.attributes.renderBackend===\"d3dmetal\"&&u.push(\"-use-d3d12\");";
  await assertLegacyUpgrade(transformer, upstreamSource, replacement, entry => entry.attributes.renderBackend === "d3dmetal" ? 1 : 0, 1);
});
