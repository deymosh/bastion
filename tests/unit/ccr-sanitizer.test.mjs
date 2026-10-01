/**
 * Tests for stack-ai/ccr/ccr-tool-schema-sanitizer.cjs (the custom router
 * that rewrites tool schemas) and stack-ai/ccr/ccr-enable-sanitizer.mjs (the
 * startup step that points CCR's CUSTOM_ROUTER_PATH at it).
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const CCR = resolve(here, "../../stack-ai/ccr");
const require = createRequire(import.meta.url);
const sanitizer = require(join(CCR, "ccr-tool-schema-sanitizer.cjs"));

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

function request(model, tools, extra = {}) {
  return { body: { model, tools }, log: { info() {} }, ...extra };
}

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

test("only the unportable pattern goes; the tool and the rest of its schema stay", async () => {
  const req = request("deepseek-v4.1-flash", [artifactTool(), { name: "Read", input_schema: { type: "object" } }]);
  assert.equal(await sanitizer(req), undefined, "it never picks a model");
  const [artifact, read] = req.body.tools;
  assert.equal(artifact.name, "Artifact");
  assert.equal(read.name, "Read");
  const props = artifact.input_schema.properties;
  assert.equal(props.file_paths.items.pattern, undefined);
  assert.equal(props.file_paths.items.maxLength, 1024);
  assert.equal(props.asset_ids.items.pattern, "^[0-9a-f]{32}$");
  assert.deepEqual(props.pattern, { type: "string", description: "a field called pattern" });
});

test("every model gets the fix, subagents included", async () => {
  for (const model of ["claude-opus-4", "anthropic/claude-ccr-h4f70656e436f6465", undefined]) {
    const req = request(model, [artifactTool()], { builtInSubagentModel: "OpenCode Go/deepseek-v4.1-flash" });
    await sanitizer(req);
    assert.equal(req.body.tools[0].input_schema.properties.file_paths.items.pattern, undefined);
  }
});

test("OpenAI-shaped tools are covered too", () => {
  const tool = { type: "function", function: { name: "Artifact", parameters: artifactTool().input_schema } };
  sanitizer.sanitizeRequest(request("deepseek", [tool]));
  assert.equal(tool.function.parameters.properties.file_paths.items.pattern, undefined);
});

test("CCR_DROP_TOOLS drops tools by target model, hex-encoded client ids included", () => {
  const env = { CCR_DROP_TOOLS: "deepseek=Artifact,ArtifactData; gemini = Monitor" };
  const tools = () => [artifactTool(), { name: "ArtifactData" }, { name: "Monitor" }, { name: "Read" }];
  const names = (req) => req.body.tools.map((t) => t.name);

  const direct = request("OpenCode Go/DeepSeek-v4.1-flash", tools());
  sanitizer.sanitizeRequest(direct, env);
  assert.deepEqual(names(direct), ["Monitor", "Read"]);

  // "anthropic/claude-ccr-h" + hex("OpenCode Go/deepseek-v4.1-flash")
  const hex = Buffer.from("OpenCode Go/deepseek-v4.1-flash").toString("hex");
  const encoded = request(`anthropic/claude-ccr-h${hex}[1m]`, tools());
  sanitizer.sanitizeRequest(encoded, env);
  assert.deepEqual(names(encoded), ["Monitor", "Read"]);

  const subagent = request("claude-opus-4", tools(), { builtInSubagentModel: "Google/gemini-2.5-pro" });
  sanitizer.sanitizeRequest(subagent, env);
  assert.deepEqual(names(subagent), ["Artifact", "ArtifactData", "Read"]);

  const untouched = request("claude-opus-4", tools());
  sanitizer.sanitizeRequest(untouched, env);
  assert.deepEqual(names(untouched), ["Artifact", "ArtifactData", "Monitor", "Read"]);
  sanitizer.sanitizeRequest(untouched, {});
  assert.equal(untouched.body.tools.length, 4, "off when unset");
});

test("the plugin registers a request transform that cleans the routed body", async () => {
  const plugin = require(join(CCR, "ccr-tool-schema-plugin.cjs"));
  const registered = [];
  await plugin.setup({ registerGatewayRequestTransform: (t) => registered.push(t), logger: { info() {} } });
  assert.equal(registered.length, 1);
  assert.equal(registered[0].id, "tool-schema-sanitizer");

  const body = { model: "deepseek-v4.1-flash", tools: [artifactTool()] };
  const result = await registered[0].transform({ body, routedModel: "deepseek-v4.1-flash" }, { logger: { info() {} } });
  assert.equal(result.body.tools[0].input_schema.properties.file_paths.items.pattern, undefined);
  assert.equal(result.body.tools[0].input_schema.properties.asset_ids.items.pattern, "^[0-9a-f]{32}$");

  const clean = { tools: [{ name: "Read", input_schema: { type: "object" } }] };
  assert.equal(plugin.transform({ body: clean }, {}), null, "unchanged bodies are not replaced");
  assert.equal(plugin.transform({ body: { model: "x" } }, {}), null);
  assert.equal(plugin.transform({}, {}), null);
});

test("a request without tools, or a malformed one, is left alone", async () => {
  assert.equal(await sanitizer({ body: { model: "x" } }), undefined);
  assert.equal(await sanitizer({ body: { tools: [null, 3, { name: "x" }] } }), undefined);
  assert.equal(await sanitizer({}), undefined);
});

// --- the startup step ---------------------------------------------------

let DatabaseSync;
try {
  ({ DatabaseSync } = await import("node:sqlite"));
} catch {
  DatabaseSync = undefined;
}
const SANITIZER_PATH = "/usr/local/lib/ccr/ccr-tool-schema-sanitizer.cjs";
const PLUGIN_PATH = "/usr/local/lib/ccr/ccr-tool-schema-plugin.cjs";

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
    const out = execFileSync(process.execPath, [join(CCR, "ccr-enable-sanitizer.mjs")], {
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

test("the startup step sets the path and keeps everything else", { skip: !DatabaseSync }, () => {
  withDb({ Providers: [{ name: "p" }], CUSTOM_ROUTER_PATH: "" }, (out, config) => {
    assert.match(out, /enabled/);
    assert.equal(config.CUSTOM_ROUTER_PATH, SANITIZER_PATH);
    assert.deepEqual(config.Providers, [{ name: "p" }]);
  });
  withDb({ CUSTOM_ROUTER_PATH: SANITIZER_PATH }, (out) => assert.match(out, /already enabled/));
});

test("the startup step registers the request-transform plugin once", { skip: !DatabaseSync }, () => {
  const other = { id: "someone-else", enabled: true, module: "/data/x.cjs" };
  withDb({ CUSTOM_ROUTER_PATH: SANITIZER_PATH, plugins: [other] }, (out, config) => {
    assert.match(out, /enabled request-transform plugin/);
    assert.deepEqual(config.plugins[0], other);
    assert.deepEqual(config.plugins[1], {
      id: "bastion-tool-schema-sanitizer",
      enabled: true,
      module: PLUGIN_PATH,
      surfaces: { apps: false, gateway: true, provider: false },
      permissions: ["trusted-code", "gateway-request-transforms"],
    });
  });
  const ours = { id: "bastion-tool-schema-sanitizer", enabled: true, module: PLUGIN_PATH };
  withDb({ CUSTOM_ROUTER_PATH: SANITIZER_PATH, plugins: [ours] }, (out, config) => {
    assert.match(out, /request-transform plugin already enabled/);
    assert.deepEqual(config.plugins, [ours]);
  });
});

test("the startup step leaves an operator's disabled or moved plugin alone", { skip: !DatabaseSync }, () => {
  const disabled = { id: "bastion-tool-schema-sanitizer", enabled: false, module: PLUGIN_PATH };
  withDb({ CUSTOM_ROUTER_PATH: SANITIZER_PATH, plugins: [disabled] }, (out, config) => {
    assert.match(out, /changed by the operator/);
    assert.deepEqual(config.plugins, [disabled]);
  });
});

test("the startup step leaves an operator's own router alone", { skip: !DatabaseSync }, () => {
  withDb({ CUSTOM_ROUTER_PATH: "/data/my-router.js" }, (out, config) => {
    assert.match(out, /leaving it/);
    assert.equal(config.CUSTOM_ROUTER_PATH, "/data/my-router.js");
  });
});

test("the startup step waits for CCR's first start, and never fails", () => {
  if (DatabaseSync) {
    withDb(undefined, (out, config) => {
      assert.match(out, /next start/);
      assert.equal(config, undefined);
    });
  }
  const out = execFileSync(process.execPath, [join(CCR, "ccr-enable-sanitizer.mjs")], {
    env: { ...process.env, CCR_CONFIG_DB: join(tmpdir(), "no-such-dir", "config.sqlite") },
    encoding: "utf8",
  });
  assert.match(out, /next start/);
});
