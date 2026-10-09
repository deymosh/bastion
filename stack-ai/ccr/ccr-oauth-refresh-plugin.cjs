"use strict";
/**
 * Bastion: refresh CCR's Claude Code OAuth login on demand, when Anthropic
 * answers HTTP 401, using the official `claude` CLI.
 *
 * CCR authenticates its "Claude Code" provider with the access token in
 * $CLAUDE_CONFIG_DIR/.credentials.json and re-reads that file on every use,
 * but never refreshes it; the token expires within a day. Two CCR paths read
 * it, in two processes, and only one of them retries a 401 on its own:
 *  - inference goes through CCR's core gateway (the ai-gateway process CCR
 *    supervises), which retries any upstream 401 exactly once, rebuilding the
 *    request through every provider hook's `authenticate` with
 *    `forceCodexOauthRefreshOnce: true`;
 *  - the provider's account usage (GET api.anthropic.com/api/oauth/usage,
 *    shown in CCR's UI) is fetched by CCR's own process, which treats a 401
 *    as a plain error: no retry, no provider hook.
 * So this file works in both, and acts only on a 401 - there is no timer,
 * no polling and no background process:
 *  - in the core gateway, a provider hook acts only on the 401 retry, and
 *    only for providers bound to CCR's Claude Code OAuth login: it has the
 *    CLI refresh the login, then puts the new token on the retried request
 *    (CCR's own auth hook, which runs after this one, re-reads the same
 *    refreshed file). Every other request is passed through untouched;
 *  - in CCR's process, the global fetch (which CCR's usage fetch looks up on
 *    each call) is wrapped: a 401 from the usage endpoint gets the same
 *    refresh, and that one request is sent again with the new token. Every
 *    other response is returned untouched.
 * The two can race, so a refresh holds a lock file next to the credentials
 * and records when it last succeeded or failed in a small state file there:
 * whichever process comes second reuses the fresh token instead of running
 * the CLI again (which would also rotate the refresh token for nothing).
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
 *  - the CLI must talk to Anthropic directly. CCR writes the config dir's
 *    settings.json so that Claude Code in this container routes through CCR
 *    (ANTHROPIC_BASE_URL, an apiKeyHelper); obeyed here, the CLI's model call
 *    would land on CCR, where a catch-all route could spend inference or
 *    route back into this very hook. `--setting-sources project`, run from an
 *    empty directory, drops those user settings; the login itself lives in
 *    .credentials.json and is still used.
 * Success is judged by the stored access token having changed, not by the
 * CLI's exit status (non-zero by design here).
 *
 * One file, two loaders:
 *  - CCR loads it as a plugin (registered by ccr-enable-plugins.mjs with the
 *    `trusted-code` and `core-gateway-plugins` permissions); `setup` hands
 *    this same file to the core gateway as a module plugin, wraps fetch, and
 *    returns a `stop` that unwraps it (CCR re-runs `setup` on every
 *    configuration change);
 *  - the core gateway imports it, reads `manifest`, and calls
 *    `createGatewayPlugin`.
 *
 * Never makes a request worse: the hook is fail-open, so a refresh that fails
 * or times out leaves the original 401 to reach the client, and the usage
 * path then returns the original 401 response. Set CCR_TOKEN_REFRESH=0 to
 * turn both paths off.
 */

const { spawn } = require("node:child_process");
const { mkdtempSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } = require("node:fs");
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
// A lock older than any CLI run belongs to a process that died holding it.
const LOCK_STALE_MS = REFRESH_TIMEOUT_MS + 15_000;
// Warn ahead of time when the refresh token itself is about to run out: past
// that point only an interactive login brings the provider back.
const REFRESH_TOKEN_WARN_MS = 2 * 24 * 3600 * 1000;
// What the CLI prints when the refresh token is rejected (revoked/expired).
const LOGIN_NEEDED_OUTPUT = /could not be refreshed|invalid_grant|not logged in|please run \/login|session expired/i;
// Every log line that needs an operator carries this marker, so it is easy
// to grep for or alert on.
const LOGIN_NEEDED = `LOGIN NEEDED: run \`./bastion exec ccr -- claude\` and log in again`;
// Anything that would make the CLI use other credentials than the login file.
const STRIPPED_ENV = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN"];

/**
 * Read by the core gateway when it imports this module: shown in its plugin
 * catalog (GET /manager/plugins/catalog). `capabilities` is validated against
 * what createGatewayPlugin returns; a name it does not return fails the load.
 */
const manifest = {
  name: KEY,
  description:
    "Refreshes CCR's Claude Code OAuth login with the claude CLI when Anthropic answers 401, "
    + "then retries the request once with the new token; fail-open.",
  capabilities: ["providerHooks"],
};

// Per process: one refresh at a time, and where log lines go. The gateway
// hands its plugins no logger, so that side logs to stdout; `setup` switches
// CCR's side to the logger CCR provides.
const state = { inflight: null };
const log = { info: (line) => console.log(line), warn: (line) => console.log(line) };

function enabled() {
  return (process.env.CCR_TOKEN_REFRESH ?? "1") !== "0";
}

/** Same resolution as CCR and the CLI: $CLAUDE_CONFIG_DIR, else ~/.claude. */
function credentialsFile() {
  const dir = process.env.CLAUDE_CONFIG_DIR || join(homedir(), ".claude");
  return join(dir, ".credentials.json");
}

const lockFile = () => `${credentialsFile()}.bastion-refresh.lock`;
const stateFile = () => `${credentialsFile()}.bastion-refresh.json`;

function readJson(file) {
  try {
    return JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return undefined;
  }
}

const readCredentials = () => readJson(credentialsFile());

function oauthOf(credentials) {
  const oauth = credentials?.claudeAiOauth;
  return oauth && typeof oauth === "object" ? oauth : undefined;
}

/** Atomic rewrite (tmp + rename, mode 600) so no reader sees a torn file. */
function writeAtomic(file, value) {
  const tmp = `${file}.${process.pid}.tmp`;
  writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 });
  renameSync(tmp, file);
}

/** When a refresh last succeeded / failed, in any process. */
function sharedState() {
  const value = readJson(stateFile());
  return {
    refreshedAt: Number(value?.refreshedAt) || 0,
    failedAt: Number(value?.failedAt) || 0,
  };
}

function recordOutcome(outcome) {
  try {
    writeAtomic(stateFile(), { ...sharedState(), [outcome]: Date.now() });
  } catch {
    // Only costs a duplicate refresh later; never worth failing over.
  }
}

/**
 * Runs `fn` holding the cross-process refresh lock. Waits for a holder to
 * finish (its result is then in the files `fn` reads), and takes over a lock
 * left by a process that died. A config dir the lock cannot be created in is
 * not a reason to skip the refresh: `fn` then runs unlocked.
 */
async function withRefreshLock(fn) {
  const deadline = Date.now() + LOCK_STALE_MS;
  for (;;) {
    try {
      writeFileSync(lockFile(), String(process.pid), { flag: "wx", mode: 0o600 });
      break;
    } catch (error) {
      if (error?.code !== "EEXIST") return fn();
      let age = 0;
      try {
        age = Date.now() - statSync(lockFile()).mtimeMs;
      } catch {
        continue; // released between the two calls
      }
      if (age > LOCK_STALE_MS) {
        rmSync(lockFile(), { force: true });
        continue;
      }
      if (Date.now() > deadline) return undefined;
      await new Promise((resolve) => setTimeout(resolve, 250));
    }
  }
  try {
    return await fn();
  } finally {
    rmSync(lockFile(), { force: true });
  }
}

/**
 * CCR's provider-plugin entries, wherever its version keeps them in the
 * gateway config: top-level `providerPlugins` up to CCR v3.1.1; from v3.1.2
 * on, the private config of the gateway plugin that applies the login
 * (`plugins[].config.providerPlugins`, key ccr-local-agent-auth-provider-hooks),
 * with the top-level list left empty.
 */
function providerPluginEntries(config) {
  const lists = [config?.providerPlugins];
  for (const plugin of Array.isArray(config?.plugins) ? config.plugins : []) {
    lists.push(plugin?.config?.providerPlugins);
  }
  return lists.flatMap((list) => (Array.isArray(list) ? list : []));
}

/** Provider names CCR bound to its Claude Code OAuth login. */
function claudeCodeOauthProviderNames(config) {
  const names = new Set();
  for (const plugin of providerPluginEntries(config)) {
    const key = typeof plugin?.key === "string" ? plugin.key.toLowerCase() : "";
    if (key.startsWith("ccr-local-agent-") && key.includes("claude-code-oauth")
      && typeof plugin.providerName === "string") {
      names.add(plugin.providerName.toLowerCase());
    }
  }
  return names;
}

/**
 * The hook input carries no provider kind, and CCR names these providers
 * freely, so the Claude Code OAuth ones are found the way CCR binds them:
 * through its `ccr-local-agent-*-claude-code-oauth*` provider-plugin entries.
 */
function isClaudeCodeOauthTarget(input) {
  const target = input?.targetProviderName ?? input?.targetProviderConfig?.name;
  return typeof target === "string" && claudeCodeOauthProviderNames(input.config).has(target.toLowerCase());
}

/** Runs the CLI once; resolves with its last output line (never token material). */
function runClaudeCli() {
  const env = { ...process.env, DISABLE_AUTOUPDATER: "1" };
  for (const name of STRIPPED_ENV) delete env[name];
  // An empty working directory, so `--setting-sources project` finds no
  // project settings either.
  const cwd = mkdtempSync(join(tmpdir(), "bastion-oauth-refresh-"));
  const cleanup = () => rmSync(cwd, { recursive: true, force: true });
  return new Promise((resolve) => {
    let output = "";
    let child;
    try {
      child = spawn(process.env.CCR_CLAUDE_CLI || "claude",
        ["-p", "ok", "--model", REFRESH_MODEL, "--max-turns", "1", "--no-session-persistence",
          "--setting-sources", "project"],
        { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      cleanup();
      resolve(`could not start the claude CLI: ${error?.message ?? error}`);
      return;
    }
    const collect = (chunk) => { output = (output + chunk).slice(-2000); };
    child.stdout.on("data", collect);
    child.stderr.on("data", collect);
    const timer = setTimeout(() => child.kill("SIGKILL"), REFRESH_TIMEOUT_MS);
    child.on("error", (error) => { clearTimeout(timer); cleanup(); resolve(`could not start the claude CLI: ${error.message}`); });
    child.on("close", () => {
      clearTimeout(timer);
      cleanup();
      const lines = output.trim().split("\n").filter(Boolean);
      resolve((lines[lines.length - 1] ?? "").slice(0, 300));
    });
  });
}

const iso = (ms) => (typeof ms === "number" ? new Date(ms).toISOString() : "unknown");

/** One line after a successful refresh: both expiries, plus a warning when due. */
function logRefreshed(oauth) {
  let line = `${TAG} refreshed; access token valid until ${iso(oauth.expiresAt)}`;
  if (typeof oauth.refreshTokenExpiresAt === "number") {
    line += `, refresh token until ${iso(oauth.refreshTokenExpiresAt)}`;
    if (oauth.refreshTokenExpiresAt - Date.now() < REFRESH_TOKEN_WARN_MS) {
      log.warn(`${line} - it expires soon; ${LOGIN_NEEDED} before then`);
      return;
    }
  }
  log.info(line);
}

/**
 * The refresh itself, run after a 401 (`source` names who saw it, for the
 * log). Reuses a refresh another request or process just made, honours the
 * failure backoff, and runs the CLI at most once at a time across processes.
 * Returns the access token to use, or undefined when there is no usable
 * OAuth login.
 */
async function refreshLogin(source) {
  const before = oauthOf(readCredentials());
  if (!before?.refreshToken) {
    log.warn(`${TAG} ${source} 401, but ${credentialsFile()} holds no OAuth login. ${LOGIN_NEEDED}`);
    return undefined;
  }
  const now = Date.now();
  const shared = sharedState();
  if (now - shared.refreshedAt < FRESH_WINDOW_MS) {
    // Usually a request that raced the refresh with the old token. If the
    // new token is itself rejected, the next 401 after the window runs the
    // CLI again and reports why.
    log.info(`${TAG} ${source} 401 right after a refresh; retrying with the refreshed token`);
    return before.accessToken;
  }
  if (now - shared.failedAt < FAILURE_BACKOFF_MS) return undefined;
  if (typeof before.refreshTokenExpiresAt === "number" && before.refreshTokenExpiresAt <= now) {
    recordOutcome("failedAt");
    log.warn(`${TAG} ${source} 401 and the refresh token expired at ${iso(before.refreshTokenExpiresAt)}. ${LOGIN_NEEDED}`);
    return undefined;
  }

  return withRefreshLock(async () => {
    // Another process may have refreshed while this one waited for the lock.
    const credentials = readCredentials();
    const current = oauthOf(credentials);
    if (!current?.refreshToken) return undefined;
    const latest = sharedState();
    if (current.accessToken !== before.accessToken && latest.refreshedAt > shared.refreshedAt) {
      return current.accessToken;
    }
    // ... or tried and failed: one failed CLI run per backoff window is enough.
    if (latest.failedAt > shared.failedAt) return undefined;

    log.info(`${TAG} ${source} 401: refreshing the Claude Code login with the claude CLI`);
    writeAtomic(credentialsFile(), { ...credentials, claudeAiOauth: { ...current, expiresAt: Date.now() - 60_000 } });
    const lastLine = await runClaudeCli();

    const after = oauthOf(readCredentials());
    if (after?.accessToken && after.accessToken !== current.accessToken) {
      recordOutcome("refreshedAt");
      logRefreshed(after);
      return after.accessToken;
    }
    recordOutcome("failedAt");
    log.warn(LOGIN_NEEDED_OUTPUT.test(lastLine)
      ? `${TAG} refresh failed: the refresh token was rejected (claude CLI: ${lastLine}). ${LOGIN_NEEDED}`
      : `${TAG} refresh failed (claude CLI: ${lastLine || "no output"}); retrying on the next 401 after a minute. If it persists, ${LOGIN_NEEDED}`);
    return undefined;
  });
}

/** Concurrent callers in one process share a single refresh. */
function refreshOnce(source) {
  if (!state.inflight) {
    state.inflight = refreshLogin(source).finally(() => { state.inflight = null; });
  }
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
  const token = await refreshOnce("upstream");
  if (!token) return unchanged;
  return {
    ok: true,
    value: { ...input.upstreamRequest, headers: withAuthorization(input.upstreamRequest?.headers, token) },
  };
}

// The account-usage endpoint CCR's own process fetches for a Claude Code
// OAuth provider (shown in CCR's UI), with the token from the login file.
const USAGE_HOST = "api.anthropic.com";
const USAGE_PATH = "/api/oauth/usage";
// Marks the wrapper, so a re-run `setup` never wraps a wrapper.
const ORIGINAL_FETCH = Symbol.for(`${KEY}.originalFetch`);

function isUsageRequest(input, init) {
  if (typeof input !== "string" && !(input instanceof URL)) return false;
  let url;
  try {
    url = new URL(String(input));
  } catch {
    return false;
  }
  return url.hostname === USAGE_HOST && url.pathname === USAGE_PATH
    && new Headers(init?.headers).has("authorization");
}

/**
 * Wraps CCR's process-wide fetch so a 401 from the account-usage endpoint
 * gets the same on-demand refresh as an inference 401: refresh through the
 * CLI, then send that one request again with the new token. CCR's usage
 * fetch looks the global fetch up on each call, and treats a 401 as a plain
 * error with no retry and no hook of its own. Every other request, and any
 * usage request when the refresh does not produce a token, gets the original
 * response untouched. Returns the function that unwraps it again.
 */
function wrapFetch() {
  const current = globalThis.fetch;
  if (typeof current !== "function") return () => {};
  const original = current[ORIGINAL_FETCH] ?? current;
  const wrapped = async function bastionUsageRefreshFetch(input, init) {
    const response = await original(input, init);
    if (response.status !== 401 || !enabled() || !isUsageRequest(input, init)) return response;
    let token;
    try {
      token = await refreshOnce("account usage");
    } catch (error) {
      log.warn(`${TAG} refresh after an account-usage 401 failed: ${error?.message ?? error}`);
    }
    if (!token) return response;
    const headers = new Headers(init?.headers);
    headers.set("authorization", `Bearer ${token}`);
    return original(input, { ...init, headers });
  };
  wrapped[ORIGINAL_FETCH] = original;
  globalThis.fetch = wrapped;
  return () => {
    if (globalThis.fetch === wrapped) globalThis.fetch = original;
  };
}

function createGatewayPlugin() {
  return {
    providerHooks: [
      {
        key: KEY,
        // Fail-open: a refresh that throws or overruns is skipped, and the
        // retry goes out with whatever token CCR's own hook reads. The budget
        // covers waiting for another process's CLI run, then running our own.
        execution: { timeoutMs: LOCK_STALE_MS + REFRESH_TIMEOUT_MS, failureMode: "fail_open" },
        authenticate,
      },
    ],
  };
}

module.exports = {
  /**
   * CCR plugin entry point, in CCR's own process: hands this file to the core
   * gateway (inference 401s) and wraps fetch (account-usage 401s). CCR
   * re-runs `setup` on every configuration change and calls the returned
   * `stop` first, which unwraps fetch again.
   */
  async setup(ctx) {
    const logger = ctx?.logger;
    if (typeof logger?.info === "function") log.info = (line) => logger.info(line);
    if (typeof logger?.warn === "function") log.warn = (line) => logger.warn(line);
    ctx.registerCoreGatewayPlugin({ key: KEY, enabled: true, modulePath: __filename });
    const unwrap = wrapFetch();
    log.info(`${TAG} on-demand refresh registered with the core gateway and for account-usage requests`);
    return { stop: unwrap };
  },
  createGatewayPlugin,
  manifest,
};
// Named exports spelled out, so the core gateway's ESM import() finds them.
module.exports.createGatewayPlugin = createGatewayPlugin;
module.exports.manifest = manifest;
module.exports.authenticate = authenticate;
module.exports.wrapFetch = wrapFetch;
module.exports._state = state;
