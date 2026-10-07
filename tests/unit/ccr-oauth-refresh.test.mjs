/**
 * Tests for stack-ai/ccr/ccr-oauth-refresh-plugin.cjs, the CCR plugin whose
 * core-gateway provider hook refreshes the Claude Code OAuth login with the
 * `claude` CLI when an upstream request was answered 401.
 *
 * The CLI is a stub (CCR_CLAUDE_CLI) that behaves like the real one: it
 * rotates the stored tokens only when the stored access token looks expired,
 * and records how it was invoked.
 */
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { chmodSync, existsSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const PLUGIN_FILE = resolve(here, "../../stack-ai/ccr/ccr-oauth-refresh-plugin.cjs");
const plugin = createRequire(import.meta.url)(PLUGIN_FILE);

const FAKE_CLI = `#!/usr/bin/env node
const fs = require("fs");
const dir = process.env.CLAUDE_CONFIG_DIR;
const file = dir + "/.credentials.json";
fs.appendFileSync(dir + "/calls.log", JSON.stringify({
  argv: process.argv.slice(2),
  leaked: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN"]
    .filter((name) => name in process.env),
}) + "\\n");
const mode = process.env.FAKE_CLAUDE_MODE || "rotate";
setTimeout(() => {
  const creds = JSON.parse(fs.readFileSync(file, "utf8"));
  if (mode === "rotate" && creds.claudeAiOauth.expiresAt <= Date.now()) {
    creds.claudeAiOauth.accessToken = "sk-ant-oat01-new";
    creds.claudeAiOauth.refreshToken = "sk-ant-ort01-new";
    creds.claudeAiOauth.expiresAt = Date.now() + 8 * 3600 * 1000;
    fs.writeFileSync(file, JSON.stringify(creds));
  }
  console.error("There's an issue with the selected model");
  process.exit(1);
}, Number(process.env.FAKE_CLAUDE_DELAY_MS || 0));
`;

let dir;

function credentials(overrides = {}) {
  return {
    claudeAiOauth: {
      accessToken: "sk-ant-oat01-old",
      refreshToken: "sk-ant-ort01-old",
      expiresAt: Date.now() + 3600 * 1000,
      scopes: ["user:inference"],
      subscriptionType: "pro",
      ...overrides,
    },
    organizationUuid: "11111111-1111-1111-1111-111111111111",
  };
}

const stored = () => JSON.parse(readFileSync(join(dir, ".credentials.json"), "utf8"));
const calls = () => existsSync(join(dir, "calls.log"))
  ? readFileSync(join(dir, "calls.log"), "utf8").trim().split("\n").map((line) => JSON.parse(line))
  : [];

/** A core-gateway authenticate input, as the 401 retry builds it. */
function retryInput({ provider = "Claude Code API", retry = true } = {}) {
  return {
    forceCodexOauthRefreshOnce: retry,
    targetProviderName: provider,
    config: {
      providerPlugins: [
        { key: "ccr-local-agent-claude-code-api-claude-code-oauth", providerName: "Claude Code API" },
        { key: "ccr-local-agent-kimi-kimi-cli-oauth", providerName: "Kimi" },
      ],
    },
    upstreamRequest: {
      url: "https://api.anthropic.com/v1/messages",
      headers: { Authorization: "Bearer sk-ant-oat01-old", "content-type": "application/json" },
    },
  };
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "ccr-oauth-refresh-"));
  writeFileSync(join(dir, ".credentials.json"), JSON.stringify(credentials()));
  const cli = join(dir, "claude");
  writeFileSync(cli, FAKE_CLI);
  chmodSync(cli, 0o755);
  process.env.CLAUDE_CONFIG_DIR = dir;
  process.env.CCR_CLAUDE_CLI = cli;
  process.env.ANTHROPIC_BASE_URL = "http://127.0.0.1:3456";
  process.env.CLAUDE_CODE_OAUTH_TOKEN = "must-not-reach-the-cli";
  delete process.env.CCR_TOKEN_REFRESH;
  delete process.env.FAKE_CLAUDE_MODE;
  delete process.env.FAKE_CLAUDE_DELAY_MS;
  Object.assign(plugin._state, { inflight: null, lastSuccessAt: 0, lastFailureAt: 0 });
});

test("a 401 retry for the Claude Code provider refreshes through the CLI", async () => {
  const result = await plugin.authenticate(retryInput());
  assert.equal(result.ok, true);
  assert.equal(result.value.headers.authorization, "Bearer sk-ant-oat01-new");
  assert.equal(result.value.headers.Authorization, undefined, "the stale header is replaced, not duplicated");
  assert.equal(result.value.headers["content-type"], "application/json");
  assert.equal(result.value.url, "https://api.anthropic.com/v1/messages");

  const [call, ...more] = calls();
  assert.equal(more.length, 0, "one CLI run");
  assert.equal(call.argv[0], "-p");
  assert.equal(call.argv[call.argv.indexOf("--model") + 1], "bastion-oauth-refresh-only",
    "a model that does not exist, so no inference is spent");
  assert.ok(call.argv.includes("--no-session-persistence"));
  assert.deepEqual(call.leaked, [], "the CLI sees no env credentials or base URL");

  const after = stored();
  assert.equal(after.claudeAiOauth.refreshToken, "sk-ant-ort01-new");
  assert.equal(after.claudeAiOauth.subscriptionType, "pro", "unmanaged keys survive");
  assert.equal(after.organizationUuid, "11111111-1111-1111-1111-111111111111");
});

test("the token CCR compiled into its gateway config is switched in place", async () => {
  // The gateway applies these entries' header after this hook, on every
  // request: left stale, they would put the old token back on the retry.
  const input = retryInput();
  input.config.providerPlugins[0].auth = { headers: { Authorization: "Bearer sk-ant-oat01-old" }, strict: true };
  input.config.providerPlugins[1].auth = { headers: { authorization: "Bearer kimi-token" } };
  await plugin.authenticate(input);
  assert.deepEqual(input.config.providerPlugins[0].auth.headers, { authorization: "Bearer sk-ant-oat01-new" });
  assert.equal(input.config.providerPlugins[0].auth.strict, true);
  assert.deepEqual(input.config.providerPlugins[1].auth.headers, { authorization: "Bearer kimi-token" },
    "other providers' entries are untouched");
});

test("the 401 is authoritative: a token that has not expired locally is refreshed too", async () => {
  // The default fixture expires in an hour; the stub only rotates an expired
  // token, so this passes only if the plugin marks the token expired first.
  const result = await plugin.authenticate(retryInput());
  assert.equal(result.value.headers.authorization, "Bearer sk-ant-oat01-new");
  if (process.platform !== "win32") {
    assert.equal(statSync(join(dir, ".credentials.json")).mode & 0o777, 0o600);
  }
});

test("ordinary requests, other providers and CCR_TOKEN_REFRESH=0 are passed through", async () => {
  const first = retryInput({ retry: false });
  assert.equal((await plugin.authenticate(first)).value, first.upstreamRequest);
  const kimi = retryInput({ provider: "Kimi" });
  assert.equal((await plugin.authenticate(kimi)).value, kimi.upstreamRequest);
  const apiKey = retryInput({ provider: "Anthropic API key" });
  assert.equal((await plugin.authenticate(apiKey)).value, apiKey.upstreamRequest);
  process.env.CCR_TOKEN_REFRESH = "0";
  const off = retryInput();
  assert.equal((await plugin.authenticate(off)).value, off.upstreamRequest);
  assert.equal(calls().length, 0, "the CLI never ran");
  assert.equal(stored().claudeAiOauth.accessToken, "sk-ant-oat01-old");
});

test("concurrent 401s share one CLI run, and a refresh is reused for a while", async () => {
  process.env.FAKE_CLAUDE_DELAY_MS = "300";
  const results = await Promise.all([1, 2, 3].map(() => plugin.authenticate(retryInput())));
  for (const result of results) {
    assert.equal(result.value.headers.authorization, "Bearer sk-ant-oat01-new");
  }
  const late = await plugin.authenticate(retryInput());
  assert.equal(late.value.headers.authorization, "Bearer sk-ant-oat01-new");
  assert.equal(calls().length, 1);
});

test("a failed refresh leaves the request as it was, and backs off", async () => {
  process.env.FAKE_CLAUDE_MODE = "fail";
  const input = retryInput();
  assert.equal((await plugin.authenticate(input)).value, input.upstreamRequest);
  await plugin.authenticate(retryInput());
  assert.equal(calls().length, 1, "no second CLI run inside the backoff window");
  assert.equal(stored().claudeAiOauth.refreshToken, "sk-ant-ort01-old");
});

test("no OAuth login, or a dead refresh token, never runs the CLI", async () => {
  writeFileSync(join(dir, ".credentials.json"), JSON.stringify({ primaryApiKey: "sk-ant-api-x" }));
  const input = retryInput();
  assert.equal((await plugin.authenticate(input)).value, input.upstreamRequest);
  writeFileSync(join(dir, ".credentials.json"),
    JSON.stringify(credentials({ refreshTokenExpiresAt: Date.now() - 1000 })));
  assert.equal((await plugin.authenticate(input)).value, input.upstreamRequest);
  assert.equal(calls().length, 0);
});

test("a missing CLI is a failed refresh, not a failed request", async () => {
  process.env.CCR_CLAUDE_CLI = join(dir, "no-such-claude");
  const input = retryInput();
  assert.equal((await plugin.authenticate(input)).value, input.upstreamRequest);
});

test("setup hands this file to the core gateway; the hook is fail-open", async () => {
  const registered = [];
  await plugin.setup({ registerCoreGatewayPlugin: (entry) => registered.push(entry) });
  assert.deepEqual(registered, [{ key: "bastion-claude-oauth-refresh", enabled: true, modulePath: PLUGIN_FILE }]);

  // The core gateway imports the module and needs a named createGatewayPlugin.
  const imported = await import(`${new URL(`file://${PLUGIN_FILE.replace(/\\/g, "/")}`).href}`);
  assert.equal(typeof imported.createGatewayPlugin, "function");
  const [hook] = imported.createGatewayPlugin().providerHooks;
  assert.equal(hook.key, "bastion-claude-oauth-refresh");
  assert.equal(hook.execution.failureMode, "fail_open");
  assert.ok(hook.execution.timeoutMs > 60_000, "the hook outlives the CLI's own timeout");
});
