/**
 * Tests for stack-ai/ccr/ccr-oauth-refresh-plugin.cjs, the CCR plugin that
 * refreshes the Claude Code OAuth login with the `claude` CLI only when
 * Anthropic answers 401: from a core-gateway provider hook for inference, and
 * from a fetch wrapper in CCR's process for the account-usage request.
 *
 * The CLI is a stub (CCR_CLAUDE_CLI) that behaves like the real one: it
 * rotates the stored tokens only when the stored access token looks expired,
 * and records how it was invoked.
 */
import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
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
  cwdEntries: fs.readdirSync(process.cwd()).length,
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
  console.error(mode === "rotate"
    ? "There's an issue with the selected model"
    : "Failed to authenticate: OAuth session expired and could not be refreshed");
  process.exit(1);
}, Number(process.env.FAKE_CLAUDE_DELAY_MS || 0));
`;

let dir;
let logs = [];
const originalLog = console.log;
console.log = (...args) => { logs.push(args.join(" ")); };
const logged = (pattern) => logs.some((line) => pattern.test(line));

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
  plugin._state.inflight = null;
  logs = [];
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
  assert.equal(call.argv[call.argv.indexOf("--setting-sources") + 1], "project",
    "CCR's user settings (base URL pointing at CCR, apiKeyHelper) are ignored");
  assert.equal(call.cwdEntries, 0, "run from an empty directory: no project settings either");
  assert.deepEqual(call.leaked, [], "the CLI sees no env credentials or base URL");

  const after = stored();
  assert.equal(after.claudeAiOauth.refreshToken, "sk-ant-ort01-new");
  assert.equal(after.claudeAiOauth.subscriptionType, "pro", "unmanaged keys survive");
  assert.equal(after.organizationUuid, "11111111-1111-1111-1111-111111111111");
  assert.ok(logged(/refreshed; access token valid until \S+Z/));
});

test("CCR v3.1.2+ keeps the OAuth bindings inside its auth plugin's config; they are found there too", async () => {
  const input = retryInput({ provider: "claude-code-api::anthropic_messages" });
  input.config = {
    providerPlugins: [],
    plugins: [
      { key: "ccr-router", config: {} },
      {
        key: "ccr-local-agent-auth-provider-hooks",
        config: {
          providerPlugins: [{
            key: "ccr-local-agent-claude-code-api-claude-code-oauth-internal",
            providerName: "claude-code-api::anthropic_messages",
          }],
        },
      },
    ],
  };
  const result = await plugin.authenticate(input);
  assert.equal(result.value.headers.authorization, "Bearer sk-ant-oat01-new");
});

test("a refresh token close to expiry is reported after a refresh", async () => {
  writeFileSync(join(dir, ".credentials.json"),
    JSON.stringify(credentials({ refreshTokenExpiresAt: Date.now() + 24 * 3600 * 1000 })));
  await plugin.authenticate(retryInput());
  assert.ok(logged(/refresh token until \S+Z - it expires soon; LOGIN NEEDED/));
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
  assert.ok(logged(/401 right after a refresh; retrying with the refreshed token/), "the reuse is logged, not silent");
});

test("a failed refresh leaves the request as it was, says a login is needed, and backs off", async () => {
  process.env.FAKE_CLAUDE_MODE = "fail";
  const input = retryInput();
  assert.equal((await plugin.authenticate(input)).value, input.upstreamRequest);
  assert.ok(logged(/refresh token was rejected \(claude CLI: Failed to authenticate: OAuth session expired and could not be refreshed\)\. LOGIN NEEDED/));
  await plugin.authenticate(retryInput());
  assert.equal(calls().length, 1, "no second CLI run inside the backoff window");
  assert.equal(stored().claudeAiOauth.refreshToken, "sk-ant-ort01-old");
});

test("no OAuth login, or a dead refresh token, never runs the CLI", async () => {
  writeFileSync(join(dir, ".credentials.json"), JSON.stringify({ primaryApiKey: "sk-ant-api-x" }));
  const input = retryInput();
  assert.equal((await plugin.authenticate(input)).value, input.upstreamRequest);
  assert.ok(logged(/holds no OAuth login\. LOGIN NEEDED/));
  writeFileSync(join(dir, ".credentials.json"),
    JSON.stringify(credentials({ refreshTokenExpiresAt: Date.now() - 1000 })));
  assert.equal((await plugin.authenticate(input)).value, input.upstreamRequest);
  assert.ok(logged(/refresh token expired at \S+Z\. LOGIN NEEDED/));
  assert.equal(calls().length, 0);
});

test("a missing CLI is a failed refresh, not a failed request", async () => {
  process.env.CCR_CLAUDE_CLI = join(dir, "no-such-claude");
  const input = retryInput();
  assert.equal((await plugin.authenticate(input)).value, input.upstreamRequest);
  assert.ok(logged(/refresh failed \(claude CLI: could not start the claude CLI: .*\); retrying on the next 401/));
});

const USAGE_URL = "https://api.anthropic.com/api/oauth/usage";
const usageInit = (token = "sk-ant-oat01-old") => ({
  headers: { authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" },
});

/** Installs a fake global fetch, wraps it, and returns what it was asked. */
function fakeFetch(answer) {
  const seen = [];
  const before = globalThis.fetch;
  globalThis.fetch = async (input, init) => {
    seen.push({ url: String(input), authorization: new Headers(init?.headers).get("authorization") });
    return new Response("{}", { status: answer(input, init) });
  };
  const unwrap = plugin.wrapFetch();
  return { seen, restore: () => { unwrap(); globalThis.fetch = before; } };
}

test("an account-usage 401 is refreshed and that request sent once more", async () => {
  const fetched = fakeFetch((input, init) =>
    (new Headers(init?.headers).get("authorization") === "Bearer sk-ant-oat01-new" ? 200 : 401));
  try {
    const response = await globalThis.fetch(USAGE_URL, usageInit());
    assert.equal(response.status, 200);
    assert.deepEqual(fetched.seen.map((call) => call.authorization),
      ["Bearer sk-ant-oat01-old", "Bearer sk-ant-oat01-new"]);
    assert.equal(calls().length, 1);
    assert.ok(logged(/account usage 401: refreshing the Claude Code login/));
  } finally {
    fetched.restore();
  }
});

test("other responses, other URLs and a failed refresh pass through untouched", async () => {
  process.env.FAKE_CLAUDE_MODE = "fail";
  const fetched = fakeFetch((input) => (String(input).includes("/v1/") ? 401 : 200));
  try {
    assert.equal((await globalThis.fetch(USAGE_URL, usageInit())).status, 200, "a 200 is not a refresh");
    assert.equal((await globalThis.fetch("https://api.anthropic.com/v1/models", usageInit())).status, 401,
      "only the usage endpoint is retried");
    assert.equal(calls().length, 0);
  } finally {
    fetched.restore();
  }
  const failing = fakeFetch(() => 401);
  try {
    const response = await globalThis.fetch(USAGE_URL, usageInit());
    assert.equal(response.status, 401, "the original 401 comes back when no token could be had");
    assert.equal(failing.seen.length, 1, "no retry without a new token");
  } finally {
    failing.restore();
  }
});

test("wrapping twice never stacks wrappers, and unwrapping restores fetch", () => {
  const before = globalThis.fetch;
  const unwrapFirst = plugin.wrapFetch();
  unwrapFirst();
  assert.equal(globalThis.fetch, before);
  const unwrapA = plugin.wrapFetch();
  const unwrapB = plugin.wrapFetch();
  unwrapB();
  assert.equal(globalThis.fetch, before, "the second wrap wrapped the original, not the first wrapper");
  unwrapA();
  assert.equal(globalThis.fetch, before);
});

test("a refresh made by the other process is reused, not repeated", async () => {
  // CCR's process and the core gateway share the credentials file: a fresh
  // refresh recorded by either one is reused by the other on its next 401.
  writeFileSync(join(dir, ".credentials.json"), JSON.stringify(credentials({ accessToken: "sk-ant-oat01-other" })));
  writeFileSync(join(dir, ".credentials.json.bastion-refresh.json"), JSON.stringify({ refreshedAt: Date.now() }));
  const result = await plugin.authenticate(retryInput());
  assert.equal(result.value.headers.authorization, "Bearer sk-ant-oat01-other");
  assert.equal(calls().length, 0);
});

test("a refresh running in the other process is waited for, then reused", async () => {
  const lock = join(dir, ".credentials.json.bastion-refresh.lock");
  writeFileSync(lock, "4242");
  setTimeout(() => {
    writeFileSync(join(dir, ".credentials.json"), JSON.stringify(credentials({ accessToken: "sk-ant-oat01-other" })));
    writeFileSync(join(dir, ".credentials.json.bastion-refresh.json"), JSON.stringify({ refreshedAt: Date.now() }));
    rmSync(lock);
  }, 300);
  const result = await plugin.authenticate(retryInput());
  assert.equal(result.value.headers.authorization, "Bearer sk-ant-oat01-other");
  assert.equal(calls().length, 0, "the CLI ran once, in the other process");
  assert.equal(existsSync(lock), false);
});

test("a lock left by a dead process is taken over", async () => {
  const lock = join(dir, ".credentials.json.bastion-refresh.lock");
  writeFileSync(lock, "4242");
  const old = (Date.now() - 10 * 60_000) / 1000;
  utimesSync(lock, old, old);
  const result = await plugin.authenticate(retryInput());
  assert.equal(result.value.headers.authorization, "Bearer sk-ant-oat01-new");
  assert.equal(existsSync(lock), false, "released after the refresh");
});

test("setup hands this file to the core gateway and wraps fetch until stopped; the hook is fail-open", async () => {
  const registered = [];
  const logger = { info: (line) => logs.push(`info ${line}`), warn: (line) => logs.push(`warn ${line}`) };
  const before = globalThis.fetch;
  const registration = await plugin.setup({ logger, registerCoreGatewayPlugin: (entry) => registered.push(entry) });
  assert.deepEqual(registered, [{ key: "bastion-claude-oauth-refresh", enabled: true, modulePath: PLUGIN_FILE }]);
  assert.notEqual(globalThis.fetch, before, "fetch is wrapped while the plugin runs");
  assert.equal(typeof registration.stop, "function", "CCR re-runs setup on reload: the fetch wrap must come off");
  registration.stop();
  assert.equal(globalThis.fetch, before);
  assert.ok(logged(/^info \[bastion-claude-oauth-refresh\] on-demand refresh registered with the core gateway/),
    "CCR's side logs through the logger CCR provides");

  // The core gateway imports the module and needs a named createGatewayPlugin.
  const imported = await import(`${new URL(`file://${PLUGIN_FILE.replace(/\\/g, "/")}`).href}`);
  assert.equal(typeof imported.createGatewayPlugin, "function");
  const module = imported.createGatewayPlugin();
  const [hook] = module.providerHooks;
  // The gateway rejects a manifest that names a capability the module does
  // not return.
  assert.equal(imported.manifest.name, "bastion-claude-oauth-refresh");
  assert.ok(imported.manifest.description.length > 0);
  for (const capability of imported.manifest.capabilities) {
    assert.ok(Array.isArray(module[capability]) && module[capability].length > 0, capability);
  }
  assert.equal(hook.key, "bastion-claude-oauth-refresh");
  assert.equal(hook.execution.failureMode, "fail_open");
  assert.ok(hook.execution.timeoutMs > 60_000, "the hook outlives the CLI's own timeout");
});

test.after?.(() => { console.log = originalLog; });
