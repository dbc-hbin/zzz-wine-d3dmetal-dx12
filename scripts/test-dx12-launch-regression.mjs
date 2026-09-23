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
    const string = stringValue(ts, attribute.initializer);
    const value = attribute.initializer.kind === ts.SyntaxKind.TrueKeyword
      ? true
      : attribute.initializer.kind === ts.SyntaxKind.FalseKeyword
        ? false
        : string;
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
    if (ts.isFunctionDeclaration(node) && node.name && (node.name.text === "oc" || node.name.text === "V_" || node.name.text === "K_")) {
      found.set(node.name.text, source.slice(node.getStart(file), node.end));
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  assert.equal(found.size, 3, "fixture must retain its runner, launch, and D3D12 setting functions");
  return { factory: found.get("oc"), launch: found.get("V_"), settings: found.get("K_") };
}

async function settingHarness(ts, source, distro, stored = new Map(), storageError = null) {
  const functions = upstreamFunctions(ts, source);
  const config = {};
  let effect;
  let setSignal;
  const context = vm.createContext({
    Neutralino: { storage: { getKeys: async () => {
      if (storageError === "keys") throw new Error("storage enumeration unavailable");
      return [...stored.keys()];
    } } },
    we: async key => {
      if (storageError === "read") throw new Error("storage read unavailable");
      if (!stored.has(key)) throw new Error("key absent");
      return stored.get(key);
    },
    he: async (key, value) => {
      if (storageError === "write") throw new Error("storage write unavailable");
      stored.set(key, value);
    },
    le: initial => {
      let value = initial;
      setSignal = next => { value = typeof next === "function" ? next(value) : next; };
      return [() => value, setSignal];
    },
    De: callback => { effect = callback; },
    ke: value => assert.notEqual(value, undefined),
    pe: undefined,
  });
  vm.runInContext(["const bl=\"config_use_d3d12\";", functions.settings, "globalThis.__settings=K_;"].join("\n"), context);
  await context.__settings({ locale: {}, config, wine: { attributes: distro.attributes } });
  return { config, stored, toggle: () => setSignal(value => !value), runEffect: () => effect() };
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
    async run(steamPatch, useD3D12) {
      const runner = await context.__runnerFactory({
        prefix: "/safe/prefix",
        distro,
      });

      const config = {
        resolutionCustom: false,
        steamPatch,
        useD3D12,
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

async function assertLaunchArguments(ts, transformedSource, distro, steamPatch, useD3D12, expectedCount) {
  const harness = launchHarness(ts, transformedSource, distro);
  const result = await harness.run(steamPatch, useD3D12);
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
      for (const useD3D12 of [false, true]) {
        await assertLaunchArguments(ts, source, entry, steamPatch, useD3D12, expectedCount(entry, useD3D12));
      }
    }
  }
}

function generatedGuard() {
  return "r.useD3D12&&n.attributes.supportsD3d12===true&&u.push(\"-use-d3d12\");";
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
  const transformedCatalog = catalogEntries(transformer.ts, first.source);
  const target = transformedCatalog.find(entry => entry.id === targetId);
  assert.ok(target, "transformed catalog must contain the requested target");
  assert.deepEqual(transformedCatalog.filter(entry => entry.id !== targetId), originalCatalog, "unrelated and prior Wine catalog entries must remain byte-equivalent data");

  await assertCatalogLaunches(transformer.ts, first.source, transformedCatalog, (entry, enabled) => enabled && entry.attributes.supportsD3d12 === true ? 1 : 0);
  await assertCatalogLaunches(transformer.ts, first.source, [{
    id: experimentalId,
    attributes: { id: experimentalId, renderBackend: "d3dmetal", winePath: "wine", supportsD3d12: true },
  }], (_entry, enabled) => enabled ? 1 : 0);
  await assertCatalogLaunches(transformer.ts, first.source, [{
    id: experimentalId,
    attributes: { id: experimentalId, renderBackend: "dxmt", winePath: "wine" },
  }], () => 0);

  const second = transformSource(transformer, first.source);
  assert.equal(second.changed, false, "re-registering an already transformed frontend must be idempotent");
  assert.equal(second.source, first.source, "idempotent registration must retain the transformed frontend byte-for-byte");

}

async function assertLegacyUpgrade(transformer, source, replacement, priorCount) {
  const historical = historicLaunchSource(transformer, source, replacement);
  const historicalCatalog = catalogEntries(transformer.ts, historical);
  await assertCatalogLaunches(transformer.ts, historical, historicalCatalog, priorCount);

  const upgraded = transformSource(transformer, historical);
  assert.equal(upgraded.changed, true, "current transformer must upgrade the prior launch guard");
  const upgradedCatalog = catalogEntries(transformer.ts, upgraded.source);
  await assertCatalogLaunches(transformer.ts, upgraded.source, upgradedCatalog, (entry, enabled) => enabled && entry.attributes.supportsD3d12 === true ? 1 : 0);

  const repeatedUpgrade = transformSource(transformer, upgraded.source);
  assert.equal(repeatedUpgrade.changed, false, "upgrading a historical frontend must become idempotent");
}

const upstreamSource = readFileSync(fixturePath, "utf8");
const transformer = loadTransformer(transformerPath);

test("DX12 launch registration uses transformed catalog entries and leaves prior Wine entries unforced", async () => {
  await assertFixedTransformer(transformer, upstreamSource);
});

test("v1.0.5 forced DX12 upgrade migrates only an absent preference and preserves later OFF", async () => {
  const forced = "n.attributes.id===" + JSON.stringify(targetId) + "&&n.attributes.renderBackend===\"d3dmetal\"&&u.push(\"-use-d3d12\");";
  const historical = historicLaunchSource(transformer, upstreamSource, forced).replace("\"supportsD3d12\":true}", "}");
  const oldTarget = catalogEntries(transformer.ts, historical).find(entry => entry.id === targetId);
  assert.equal(oldTarget.attributes.supportsD3d12, undefined, "v1.0.5 target predates capability metadata");
  const oldSetting = await settingHarness(transformer.ts, historical, oldTarget);
  assert.equal(oldSetting.config.useD3D12, false);
  for (const steam of [false, true]) await assertLaunchArguments(transformer.ts, historical, oldTarget, steam, oldSetting.config.useD3D12, 1);

  const upgraded = transformSource(transformer, historical);
  const target = catalogEntries(transformer.ts, upgraded.source).find(entry => entry.id === targetId);
  const priorOnStorage = new Map([["config_use_d3d12", "true"]]);
  const priorOn = await settingHarness(transformer.ts, upgraded.source, target, priorOnStorage);
  assert.equal(priorOn.config.useD3D12, true, "old explicit ON must survive the upgrade");
  assert.equal(priorOnStorage.get("config_use_d3d12"), "true");
  for (const steam of [false, true]) await assertLaunchArguments(transformer.ts, upgraded.source, target, steam, priorOn.config.useD3D12, 1);

  const priorOffStorage = new Map([["config_use_d3d12", "false"]]);
  const priorOff = await settingHarness(transformer.ts, upgraded.source, target, priorOffStorage);
  assert.equal(priorOff.config.useD3D12, false, "old explicit OFF must survive the upgrade");
  assert.equal(priorOffStorage.get("config_use_d3d12"), "false");
  for (const steam of [false, true]) await assertLaunchArguments(transformer.ts, upgraded.source, target, steam, priorOff.config.useD3D12, 0);

  const stored = new Map();
  const migrated = await settingHarness(transformer.ts, upgraded.source, target, stored);
  assert.equal(migrated.config.useD3D12, true, "missing old preference retains effective DX12");
  assert.equal(stored.get("config_use_d3d12"), "true", "migration must persist before launch");
  for (const steam of [false, true]) await assertLaunchArguments(transformer.ts, upgraded.source, target, steam, migrated.config.useD3D12, 1);

  migrated.toggle();
  migrated.runEffect();
  assert.equal(stored.get("config_use_d3d12"), "false", "the actual setting lifecycle must persist user OFF");
  const explicitOff = await settingHarness(transformer.ts, upgraded.source, target, stored);
  assert.equal(explicitOff.config.useD3D12, false);
  for (const steam of [false, true]) await assertLaunchArguments(transformer.ts, upgraded.source, target, steam, explicitOff.config.useD3D12, 0);

  const otherSupported = { attributes: { id: experimentalId, renderBackend: "d3dmetal", winePath: "wine", supportsD3d12: true } };
  const unrelatedStorage = new Map();
  const unrelatedSetting = await settingHarness(transformer.ts, upgraded.source, otherSupported, unrelatedStorage);
  assert.equal(unrelatedSetting.config.useD3D12, false, "another supported runtime was not forced by v1.0.5");
  assert.equal(unrelatedStorage.size, 0, "another supported runtime must not consume the one-time migration");
  for (const steam of [false, true]) await assertLaunchArguments(transformer.ts, upgraded.source, otherSupported, steam, unrelatedSetting.config.useD3D12, 0);
  const selectedLater = await settingHarness(transformer.ts, upgraded.source, target, unrelatedStorage);
  assert.equal(selectedLater.config.useD3D12, true, "selecting the legacy target later must still migrate");
  assert.equal(unrelatedStorage.get("config_use_d3d12"), "true");
  const unsupported = { attributes: { id: targetId, renderBackend: "dxmt", winePath: "wine", supportsD3d12: true } };
  const absentUnsupported = await settingHarness(transformer.ts, upgraded.source, unsupported);
  assert.equal(absentUnsupported.config.useD3D12, false);
  for (const failure of ["keys", "write"]) {
    const failedStorage = await settingHarness(transformer.ts, upgraded.source, target, new Map(), failure);
    assert.equal(failedStorage.config.useD3D12, false, failure + " failure must not masquerade as a missing preference");
  }
  const failedRead = await settingHarness(transformer.ts, upgraded.source, target, new Map([["config_use_d3d12", "true"]]), "read");
  assert.equal(failedRead.config.useD3D12, false, "stored preference read failure must fail safe");
  const fresh = transformSource(transformer, upstreamSource);
  const freshTarget = catalogEntries(transformer.ts, fresh.source).find(entry => entry.id === targetId);
  assert.equal((await settingHarness(transformer.ts, fresh.source, freshTarget)).config.useD3D12, false, "fresh/settings-driven frontend has no forced history");
  const repeated = transformSource(transformer, upgraded.source);
  assert.equal(repeated.changed, false);
  assert.equal((await settingHarness(transformer.ts, repeated.source, target, stored)).config.useD3D12, false);
});

test("DX12 launch registration upgrades the historical absent-runner-id guard", async () => {
  const replacement = "n.id===\"" + targetId + "\"&&u.push(\"-use-d3d12\");";
  await assertLegacyUpgrade(transformer, upstreamSource, replacement, () => 0);
});

test("DX12 launch registration upgrades the historical backend-only guard", async () => {
  const replacement = "n.attributes.renderBackend===\"d3dmetal\"&&u.push(\"-use-d3d12\");";
  await assertLegacyUpgrade(transformer, upstreamSource, replacement, entry => entry.attributes.renderBackend === "d3dmetal" ? 1 : 0);
});
