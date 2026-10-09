/**
 * Tests for stack-ai/ccr/ccr-tool-schema-sanitizer.cjs (the tool-schema
 * rewriting), stack-ai/ccr/ccr-tool-schema-plugin.cjs (the core-gateway
 * request transform that applies it) and stack-ai/ccr/ccr-enable-plugins.mjs
 * (the startup step that registers the bundled plugins).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const CCR = resolve(here, "../../stack-ai/ccr");
const require = createRequire(import.meta.url);
const sanitizer = require(join(CCR, "ccr-tool-schema-sanitizer.cjs"));
const plugin = require(join(CCR, "ccr-tool-schema-plugin.cjs"));

/** Claude Code's Artifact tool, cut to the part that matters. */
function artifactTool() {
  return {
    name: "Artifact",
    input_schema: {
      type: "object",
      properties: {
        file_paths: { type: "array", items: { type: "string", pattern: "^[^\\0]*$", maxLength: 1024 } },
        asset_ids: { type: "array", items: { type: "string", pattern: "^[0-9a-f]{32}$" } },
        // A property named "pattern" is a schema, not a regex.
        pattern: { type: "string", description: "a field called pattern" },
      },
    },
  };
}

const quiet = { info() {} };
const names = (tools) => tools.map((t) => t.name ?? t.function?.name);

test("backtracking-only syntax is unportable; ordinary syntax is not", () => {
  const unportable = [
    "^[^\\0]*$", "^(a)\\1$", "\\0",
    "^(?!\\.)[a-z]+$", "^(?=a)a$", "(?<=a)b", "(?<!a)b", "(?>a+)b", "(?<n>a)\\k<n>",
    // ArtifactData's collection id, verbatim.
    "^(?!\\.\\.?(?:\\/|$))[A-Za-z0-9_\\-.~:@+]{1,200}$",
  ];
  for (const p of unportable) {
    assert.ok(sanitizer.isUnportablePattern(p), p);
  }
  const portable = [
    "^[0-9a-f]{32}$", "^[^\\n\\r]*$", "^[\\s\\S]{0,300}$", "^\\d+$", "^a\\\\0$",
    "^(?:a|b)$", "^(?<n>a)$", "^a\\(?!b$", "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$",
  ];
  for (const p of portable) {
    assert.ok(!sanitizer.isUnportablePattern(p), p);
  }
});

test("prefixItems and propertyNames go; properties with those names stay", () => {
  const schema = {
    type: "object",
    properties: {
      where: { type: "array", items: { type: "array", prefixItems: [{ type: "string" }, { enum: ["eq"] }, {}] } },
      files: { type: "object", propertyNames: { maxLength: 512 }, additionalProperties: { type: "string" } },
      prefixItems: { type: "string", description: "a field called prefixItems" },
    },
  };
  assert.equal(sanitizer.sanitizeSchema(schema), 2);
  assert.deepEqual(schema.properties.where.items, { type: "array" });
  assert.deepEqual(schema.properties.files, { type: "object", additionalProperties: { type: "string" } });
  assert.deepEqual(schema.properties.prefixItems, { type: "string", description: "a field called prefixItems" });
});

test("only the unportable pattern goes; the tool and the rest of its schema stay", () => {
  const tools = sanitizer.sanitizeTools([artifactTool(), { name: "Read", input_schema: { type: "object" } }], { log: quiet });
  assert.deepEqual(names(tools), ["Artifact", "Read"]);
  const props = tools[0].input_schema.properties;
  assert.equal(props.file_paths.items.pattern, undefined);
  assert.equal(props.file_paths.items.maxLength, 1024);
  assert.equal(props.asset_ids.items.pattern, "^[0-9a-f]{32}$");
  assert.deepEqual(props.pattern, { type: "string", description: "a field called pattern" });
});

test("OpenAI-shaped tools are covered too", () => {
  const tool = { type: "function", function: { name: "Artifact", parameters: artifactTool().input_schema } };
  sanitizer.sanitizeTools([tool], { log: quiet });
  assert.equal(tool.function.parameters.properties.file_paths.items.pattern, undefined);
});

test("CCR_DROP_TOOLS drops tools by routed target; off when unset", () => {
  const env = { CCR_DROP_TOOLS: "deepseek=Artifact,ArtifactData; gemini = Monitor" };
  const tools = () => [artifactTool(), { name: "ArtifactData" }, { type: "function", function: { name: "Monitor" } }, { name: "Read" }];
  const run = (target, e = env) => names(sanitizer.sanitizeTools(tools(), { target, env: e, log: quiet }));
  assert.deepEqual(run("deepseek-v4.1-flash OpenCode Go"), ["Monitor", "Read"]);
  assert.deepEqual(run("models/gemini-2.5-pro Google"), ["Artifact", "ArtifactData", "Read"], "OpenAI-shaped names match too");
  assert.deepEqual(run("claude-opus-4 Claude Code API"), ["Artifact", "ArtifactData", "Monitor", "Read"]);
  assert.deepEqual(run("deepseek-v4.1-flash", {}), ["Artifact", "ArtifactData", "Monitor", "Read"]);
});

test("a malformed tool list is left alone", () => {
  assert.equal(sanitizer.sanitizeTools(undefined), undefined);
  assert.deepEqual(sanitizer.sanitizeTools([null, 3, { name: "x" }], { log: quiet }), [null, 3, { name: "x" }]);
});

// --- the core-gateway plugin ----------------------------------------------

/** A beforeUpstream transform input, as the core gateway builds it. */
function upstreamInput(model, providerName = "OpenCode Go") {
  return {
    stage: "beforeUpstream",
    model,
    targetProviderConfig: { name: providerName },
    requestBody: { model, tools: [artifactTool(), { name: "ArtifactData" }, { name: "Read" }] },
    standardRequest: { model, tools: [artifactTool(), { name: "ArtifactData" }, { name: "Read" }] },
  };
}

test("the transform cleans both the passthrough body and the standard request, in place", () => {
  const previous = process.env.CCR_DROP_TOOLS;
  process.env.CCR_DROP_TOOLS = "deepseek=ArtifactData";
  try {
    const input = upstreamInput("deepseek-v4.1-flash");
    assert.equal(plugin.transform(input), undefined, "returns nothing: the gateway keeps its passthrough/convert choice");
    for (const request of [input.requestBody, input.standardRequest]) {
      assert.deepEqual(names(request.tools), ["Artifact", "Read"]);
      assert.equal(request.tools[0].input_schema.properties.file_paths.items.pattern, undefined);
    }
    const claude = upstreamInput("claude-sonnet-5", "Claude Code API");
    plugin.transform(claude);
    assert.deepEqual(names(claude.requestBody.tools), ["Artifact", "ArtifactData", "Read"], "drops follow the routed target");
  } finally {
    if (previous === undefined) delete process.env.CCR_DROP_TOOLS;
    else process.env.CCR_DROP_TOOLS = previous;
  }
  assert.equal(plugin.transform({ stage: "beforeUpstream", requestBody: { model: "x" } }), undefined);
  assert.equal(plugin.transform({}), undefined);
});

test("setup hands this file to the core gateway, which gets a fail-open beforeUpstream transform", async () => {
  const registered = [];
  await plugin.setup({ registerCoreGatewayPlugin: (entry) => registered.push(entry), logger: quiet });
  assert.deepEqual(registered, [{ key: "bastion-tool-schema-sanitizer", enabled: true, modulePath: join(CCR, "ccr-tool-schema-plugin.cjs") }]);

  const imported = await import(pathToFileURL(join(CCR, "ccr-tool-schema-plugin.cjs")).href);
  const module = imported.createGatewayPlugin();
  const [transform] = module.requestTransforms;
  assert.equal(transform.key, "bastion-tool-schema-sanitizer");
  assert.equal(transform.stage, "beforeUpstream", "after routing, subagent-tag routing included");
  assert.equal(transform.execution.failureMode, "fail_open");
  // The gateway rejects a manifest naming a capability the module does not return.
  for (const capability of imported.manifest.capabilities) {
    assert.ok(Array.isArray(module[capability]) && module[capability].length > 0, capability);
  }
});

// --- the startup step ---------------------------------------------------

let DatabaseSync;
try {
  ({ DatabaseSync } = await import("node:sqlite"));
} catch {
  DatabaseSync = undefined;
}
const LEGACY_ROUTER = "/usr/local/lib/ccr/ccr-tool-schema-sanitizer.cjs";
const SURFACES = { apps: false, gateway: true, provider: false };
const PERMISSIONS = ["trusted-code", "core-gateway-plugins"];
const SANITIZER_PLUGIN = {
  id: "bastion-tool-schema-sanitizer",
  enabled: true,
  module: "/usr/local/lib/ccr/ccr-tool-schema-plugin.cjs",
  surfaces: SURFACES,
  permissions: PERMISSIONS,
};
const OAUTH_PLUGIN = {
  id: "bastion-claude-oauth-refresh",
  enabled: true,
  module: "/usr/local/lib/ccr/ccr-oauth-refresh-plugin.cjs",
  surfaces: SURFACES,
  permissions: PERMISSIONS,
};

function withDb(row, run) {
  const dir = mkdtempSync(join(tmpdir(), "ccr-enable-"));
  const file = join(dir, "config.sqlite");
  try {
    const db = new DatabaseSync(file);
    db.exec("CREATE TABLE app_config (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at TEXT NOT NULL)");
    if (row !== undefined) {
      db.prepare("INSERT INTO app_config VALUES ('default', ?, 'then')").run(JSON.stringify(row));
    }
    db.close();
    const out = execFileSync(process.execPath, [join(CCR, "ccr-enable-plugins.mjs")], {
      env: { ...process.env, CCR_CONFIG_DB: file },
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
    });
    const after = new DatabaseSync(file);
    const stored = after.prepare("SELECT value_json FROM app_config WHERE key = 'default'").get();
    after.close();
    return run(out, stored ? JSON.parse(stored.value_json) : undefined);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

test("the startup step registers both plugins once, keeping everything else", { skip: !DatabaseSync }, () => {
  const other = { id: "someone-else", enabled: true, module: "/data/x.cjs" };
  withDb({ Providers: [{ name: "p" }], plugins: [other] }, (out, config) => {
    assert.match(out, /enabled tool-schema sanitizer plugin/);
    assert.match(out, /enabled OAuth refresh plugin/);
    assert.deepEqual(config.plugins, [other, SANITIZER_PLUGIN, OAUTH_PLUGIN]);
    assert.deepEqual(config.Providers, [{ name: "p" }]);
  });
  withDb({ plugins: [SANITIZER_PLUGIN, OAUTH_PLUGIN] }, (out, config) => {
    assert.match(out, /tool-schema sanitizer plugin already set up \(enabled\)/);
    assert.match(out, /OAuth refresh plugin already set up \(enabled\)/);
    assert.deepEqual(config.plugins, [SANITIZER_PLUGIN, OAUTH_PLUGIN]);
  });
});

test("an upgrade moves the sanitizer off the custom router and the CCR-side transform", { skip: !DatabaseSync }, () => {
  // What earlier images set up: the sanitizer as CUSTOM_ROUTER_PATH plus a
  // CCR-side request transform, which forced CCR's compatibility server.
  const old = { ...SANITIZER_PLUGIN, enabled: false, permissions: ["trusted-code", "gateway-request-transforms"] };
  withDb({ CUSTOM_ROUTER_PATH: LEGACY_ROUTER, plugins: [old, OAUTH_PLUGIN] }, (out, config) => {
    assert.match(out, /removed CUSTOM_ROUTER_PATH/);
    assert.match(out, /updated tool-schema sanitizer plugin permissions \(disabled by the operator\)/);
    assert.equal(config.CUSTOM_ROUTER_PATH, "");
    assert.deepEqual(config.plugins[0], { ...SANITIZER_PLUGIN, enabled: false }, "the operator's enabled=false is kept");
  });
});

test("the startup step leaves an operator's own router and moved plugins alone", { skip: !DatabaseSync }, () => {
  const moved = { ...OAUTH_PLUGIN, module: "/data/my-refresh.cjs", permissions: ["trusted-code"] };
  withDb({ CUSTOM_ROUTER_PATH: "/data/my-router.js", plugins: [moved] }, (out, config) => {
    assert.equal(config.CUSTOM_ROUTER_PATH, "/data/my-router.js");
    assert.match(out, /plugin bastion-claude-oauth-refresh loads \/data\/my-refresh\.cjs.*leaving it/);
    assert.deepEqual(config.plugins.find((p) => p.id === OAUTH_PLUGIN.id), moved);
  });
});

test("the startup step finds the config under CCR_DATA_DIR, whatever HOME is", { skip: !DatabaseSync }, () => {
  const dataDir = mkdtempSync(join(tmpdir(), "ccr-data-"));
  try {
    const configDir = join(dataDir, ".claude-code-router");
    mkdirSync(configDir);
    const db = new DatabaseSync(join(configDir, "config.sqlite"));
    db.exec("CREATE TABLE app_config (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at TEXT NOT NULL)");
    db.prepare("INSERT INTO app_config VALUES ('default', '{}', 'then')").run();
    db.close();
    const env = { ...process.env, CCR_DATA_DIR: dataDir, HOME: join(tmpdir(), "not-the-data-dir") };
    delete env.CCR_CONFIG_DB;
    const out = execFileSync(process.execPath, [join(CCR, "ccr-enable-plugins.mjs")], { env, encoding: "utf8" });
    assert.match(out, /enabled tool-schema sanitizer plugin/);
    assert.match(out, /enabled OAuth refresh plugin/);
  } finally {
    rmSync(dataDir, { recursive: true, force: true });
  }
});

test("the startup step waits for CCR's first start, and never fails", () => {
  if (DatabaseSync) {
    withDb(undefined, (out, config) => {
      assert.match(out, /next start/);
      assert.equal(config, undefined);
    });
  }
  const out = execFileSync(process.execPath, [join(CCR, "ccr-enable-plugins.mjs")], {
    env: { ...process.env, CCR_CONFIG_DB: join(tmpdir(), "no-such-dir", "config.sqlite") },
    encoding: "utf8",
  });
  assert.match(out, /next start/);
});
