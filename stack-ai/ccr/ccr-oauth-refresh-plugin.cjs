"use strict";
/**
 * Bastion: refresh the Claude Code OAuth login on demand, when Anthropic
 * answers a CCR request with HTTP 401, using the official `claude` CLI.
 *
 * CCR authenticates its "Claude Code" provider with the access token in
 * $CLAUDE_CONFIG_DIR/.credentials.json and re-reads that file on every
 * upstream request, but never refreshes it; the token expires within a day.
 *
 * Where the 401 is caught: CCR's core gateway (the ai-gateway process CCR
 * supervises) retries any upstream 401 exactly once, rebuilding the request
 * through every provider hook's `authenticate` with
 * `forceCodexOauthRefreshOnce: true`. This file's provider hook acts only on
 * that retry, and only for providers bound to CCR's Claude Code OAuth
 * login: it has the `claude` CLI refresh the login, then puts the new token
 * on the retried request. CCR's own auth hook, which runs after this one,
 * re-reads the same refreshed file. Every other request is passed through
 * untouched, so there is no polling and no background process.
 *
 * How the CLI is made to refresh:
 *  - the stored access token is first marked expired (the 401 is
 *    authoritative; the CLI only refreshes a token it believes has expired),
 *    rewriting the file atomically with every other key untouched;
 *  - then `claude -p` runs with a model name that does not exist. The CLI
 *    refreshes and persists the login before its first API call, and that
 *    call is answered 404 not_found_error, so no inference is spent.
 *    (`claude auth status` is NOT used: it starts a refresh and exits before
 *    it completes, leaving the CLI's refresh lock held, which then blocks the
 *    next refresh.)
 * Success is judged by the stored access token having changed, not by the
 * CLI's exit status (non-zero by design here).
 *
 * One file, two loaders:
 *  - CCR loads it as a plugin (registered by ccr-enable-plugins.mjs with the
 *    `trusted-code` and `core-gateway-plugins` permissions); `setup` hands
 *    this same file to the core gateway as a module plugin;
 *  - the core gateway imports it and calls `createGatewayPlugin`.
 *
 * Never makes a request worse: the hook is fail-open, so a refresh that fails
 * or times out leaves the original 401 to reach the client. Set
 * CCR_TOKEN_REFRESH=0 to turn it off.
 */

const { spawn } = require("node:child_process");
const { readFileSync, renameSync, writeFileSync } = require("node:fs");
const { homedir, tmpdir } = require("node:os");
const { join } = require("node:path");

const KEY = "bastion-claude-oauth-refresh";
const TAG = `[${KEY}]`;
// Not a real model: the CLI's only API call after refreshing is a 404.
const REFRESH_MODEL = "bastion-oauth-refresh-only";
const REFRESH_TIMEOUT_MS = 60_000;
// A 401 that lands right after a successful refresh raced it with the old
// token: reuse the fresh one instead of refreshing again.
const FRESH_WINDOW_MS = 30_000;
// After a failed refresh (revoked login, network), do not rerun the CLI on
// every request; one attempt per window is enough until an operator logs in.
const FAILURE_BACKOFF_MS = 60_000;
// Anything that would make the CLI use other credentials than the login file.
const STRIPPED_ENV = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN"];

const state = { inflight: null, lastSuccessAt: 0, lastFailureAt: 0 };

function enabled() {
  return (process.env.CCR_TOKEN_REFRESH ?? "1") !== "0";
}

/** Same resolution as CCR and the CLI: $CLAUDE_CONFIG_DIR, else ~/.claude. */
function credentialsFile() {
  const dir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
  return join(dir, ".credentials.json");
}

function readCredentials() {
  try {
    return JSON.parse(readFileSync(credentialsFile(), "utf8"));
  } catch {
    return undefined;
  }
}

function oauthOf(credentials) {
  const oauth = credentials?.claudeAiOauth;
  return oauth && typeof oauth === "object" ? oauth : undefined;
}

/** Atomic rewrite (tmp + rename, mode 600) so CCR never reads a torn file. */
function writeCredentials(credentials) {
  const file = credentialsFile();
  const tmp = `${file}.bastion-refresh.tmp`;
  writeFileSync(tmp, JSON.stringify(credentials), { mode: 0o600 });
  renameSync(tmp, file);
}

/** CCR's provider-plugin entries for its Claude Code OAuth login (gateway config). */
function claudeCodeOauthEntries(config) {
  return (Array.isArray(config?.providerPlugins) ? config.providerPlugins : []).filter((plugin) => {
    const key = typeof plugin?.key === "string" ? plugin.key.toLowerCase() : "";
    return key.startsWith("ccr-local-agent-") && key.includes("claude-code-oauth");
  });
}

/** Provider names CCR bound to its Claude Code OAuth login. */
function claudeCodeOauthProviderNames(config) {
  const names = new Set();
  for (const plugin of claudeCodeOauthEntries(config)) {
    if (typeof plugin.providerName === "string") names.add(plugin.providerName.toLowerCase());
  }
  return names;
}

/**
 * CCR compiles the access token it finds at gateway start into these
 * entries' `auth.headers.authorization`, and the gateway applies that header
 * after this hook, on every request - so a refreshed file alone would leave
 * the retry, and everything after it, on the stale token until CCR next
 * recompiles its gateway config. The gateway reads the header from these
 * same live objects each time, so updating it in place switches every later
 * request (this retry included) to the new token. A recompile reads the file
 * again, so the two never disagree for long.
 */
function updateCompiledAuthorization(config, token) {
  for (const plugin of claudeCodeOauthEntries(config)) {
    const headers = plugin.auth?.headers;
    if (!headers || typeof headers !== "object") continue;
    for (const name of Object.keys(headers)) {
      if (name.toLowerCase() === "authorization") delete headers[name];
    }
    headers.authorization = `Bearer ${token}`;
  }
}

function isClaudeCodeOauthTarget(input) {
  const target = input?.targetProviderName ?? input?.targetProviderConfig?.name;
  return typeof target === "string" && claudeCodeOauthProviderNames(input.config).has(target.toLowerCase());
}

/** Runs the CLI once; resolves with its last output line (never token material). */
function runClaudeCli() {
  const env = { ...process.env, DISABLE_AUTOUPDATER: "1" };
  for (const name of STRIPPED_ENV) delete env[name];
  return new Promise((resolve) => {
    let output = "";
    let child;
    try {
      child = spawn(process.env.CCR_CLAUDE_CLI || "claude",
        ["-p", "ok", "--model", REFRESH_MODEL, "--max-turns", "1", "--no-session-persistence"],
        { cwd: tmpdir(), env, stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      resolve(`could not start the claude CLI: ${error?.message ?? error}`);
      return;
    }
    const collect = (chunk) => { output = (output + chunk).slice(-2000); };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    const timer = setTimeout(() => child.kill("SIGKILL"), REFRESH_TIMEOUT_MS);
    child.on("error", (error) => { clearTimeout(timer); resolve(`could not start the claude CLI: ${error.message}`); });
    child.on("close", () => {
      clearTimeout(timer);
      const lines = output.trim().split("\n").filter(Boolean);
      resolve((lines[lines.length - 1] ?? "").slice(0, 300));
    });
  });
}

/**
 * Refreshes the login unless a recent refresh already did, or a recent one
 * failed. Concurrent 401s share one CLI run. Returns the access token to use,
 * or undefined when there is no usable OAuth login.
 */
function refreshOnDemand() {
  if (state.inflight) return state.inflight;
  state.inflight = (async () => {
    const now = Date.now();
    const credentials = readCredentials();
    const before = oauthOf(credentials);
    if (!before?.refreshToken) {
      console.log(`${TAG} upstream 401, but ${credentialsFile()} holds no OAuth login; log in with \`claude\``);
      return undefined;
    }
    if (now - state.lastSuccessAt < FRESH_WINDOW_MS) return before.accessToken;
    if (now - state.lastFailureAt < FAILURE_BACKOFF_MS) return undefined;
    if (typeof before.refreshTokenExpiresAt === "number" && before.refreshTokenExpiresAt <= now) {
      state.lastFailureAt = now;
      console.log(`${TAG} upstream 401 and the refresh token has expired; log in again with \`claude\``);
      return undefined;
    }

    console.log(`${TAG} upstream 401: refreshing the Claude Code login with the claude CLI`);
    writeCredentials({ ...credentials, claudeAiOauth: { ...before, expiresAt: now - 60_000 } });
    const lastLine = await runClaudeCli();

    const after = oauthOf(readCredentials());
    if (after?.accessToken && after.accessToken !== before.accessToken) {
      state.lastSuccessAt = Date.now();
      const expires = typeof after.expiresAt === "number" ? new Date(after.expiresAt).toISOString() : "unknown";
      console.log(`${TAG} refreshed; the new access token expires at ${expires}`);
      return after.accessToken;
    }
    state.lastFailureAt = Date.now();
    console.log(`${TAG} refresh failed (${lastLine || "no output"}); if this persists, log in again with \`claude\``);
    return undefined;
  })().finally(() => { state.inflight = null; });
  return state.inflight;
}

function withAuthorization(headers, token) {
  const next = {};
  for (const [name, value] of Object.entries(headers ?? {})) {
    if (name.toLowerCase() !== "authorization") next[name] = value;
  }
  next.authorization = `Bearer ${token}`;
  return next;
}

/** The core gateway's provider `authenticate` hook. */
async function authenticate(input) {
  const unchanged = { ok: true, value: input.upstreamRequest };
  if (!input?.forceCodexOauthRefreshOnce || !enabled() || !isClaudeCodeOauthTarget(input)) {
    return unchanged;
  }
  const token = await refreshOnDemand();
  if (!token) return unchanged;
  updateCompiledAuthorization(input.config, token);
  return {
    ok: true,
    value: { ...input.upstreamRequest, headers: withAuthorization(input.upstreamRequest?.headers, token) },
  };
}

function createGatewayPlugin() {
  return {
    providerHooks: [
      {
        key: KEY,
        // Fail-open: a refresh that throws or overruns is skipped, and the
        // retry goes out with whatever token CCR's own hook reads.
        execution: { timeoutMs: REFRESH_TIMEOUT_MS + 10_000, failureMode: "fail_open" },
        authenticate,
      },
    ],
  };
}

module.exports = {
  /** CCR plugin entry point: hands this file to the core gateway. */
  async setup(ctx) {
    ctx.registerCoreGatewayPlugin({ key: KEY, enabled: true, modulePath: __filename });
    ctx.logger?.info?.("on-demand Claude Code OAuth refresh registered with the core gateway");
  },
  createGatewayPlugin,
};
module.exports.createGatewayPlugin = createGatewayPlugin;
module.exports.authenticate = authenticate;
module.exports._state = state;
