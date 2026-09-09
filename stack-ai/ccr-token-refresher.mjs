#!/usr/bin/env node
/*
 * Bastion CCR OAuth token refresher.
 *
 * Claude Code Router authenticates to Anthropic with the Claude Code OAuth
 * access token read from CLAUDE_CONFIG_DIR/.credentials.json. That token lives
 * ~a day. CCR (>= commit 561c2d8, in the pinned fork branch) re-reads the file
 * on every upstream request, so a rotated token is picked up with no restart --
 * but CCR never refreshes the Claude Code token itself. In this headless
 * container nothing else does either, so it 401s daily.
 *
 * This process watches the file and, shortly before expiry, exchanges the
 * refresh token for a new one via the standard OAuth2 refresh grant, then
 * writes the file back atomically. No signal to CCR is needed.
 *
 * Constants below were read from the bundled @anthropic-ai/claude-code binary
 * (CLIENT_ID and the platform.claude.com token endpoint). Re-verify with:
 *   grep -aoE 'CLIENT_ID:"[0-9a-f-]{36}"|https://[a-z.]+/v1/oauth/token' \
 *     /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
 *
 * Zero dependencies (Node 22 global fetch). No secrets are logged.
 */

import { readFile, writeFile, rename, stat } from "node:fs/promises";
import { dirname, join } from "node:path";

const CONFIG_DIR = process.env.CLAUDE_CONFIG_DIR || "/data/.claude";
const CRED_FILE = join(CONFIG_DIR, ".credentials.json");

const TOKEN_URL = process.env.CCR_OAUTH_TOKEN_URL || "https://platform.claude.com/v1/oauth/token";
const CLIENT_ID = process.env.CCR_OAUTH_CLIENT_ID || "9d1c250a-e61b-44d9-88ed-5944d1962f5e";

const INTERVAL_MS = intEnv("CCR_REFRESH_INTERVAL", 300) * 1000;   // how often to check
const SKEW_MS = intEnv("CCR_REFRESH_SKEW_MS", 30 * 60 * 1000);    // refresh this early
const MIN_RETRY_MS = 60 * 1000;                                   // after a transient failure

function intEnv(name, fallback) {
  const v = parseInt(process.env[name] ?? "", 10);
  return Number.isFinite(v) && v > 0 ? v : fallback;
}

function log(msg, extra) {
  const line = `[ccr-token-refresher] ${new Date().toISOString()} ${msg}`;
  if (extra) console.log(line, extra);
  else console.log(line);
}

async function writeCreds(data) {
  const tmp = CRED_FILE + ".tmp";
  await writeFile(tmp, JSON.stringify(data, null, 2) + "\n", { mode: 0o600 });
  await rename(tmp, CRED_FILE);
}

// Only log a repeating condition when it changes, so an idle refresher stays
// quiet (CCR may be running on a plain API key with no OAuth file at all).
let lastState = "";
function logOnce(state, msg) {
  if (state !== lastState) log(msg);
  lastState = state;
}

/**
 * @returns {"refreshed" | "not-due" | "idle" | "transient" | "dead"}
 *   idle = nothing to refresh (no file, or not an OAuth credentials file).
 *          Never an error - CCR keeps running regardless.
 */
async function tick() {
  let raw;
  try {
    raw = await readFile(CRED_FILE, "utf8");
  } catch (err) {
    if (err.code === "ENOENT") {
      logOnce("no-file", `no credentials file at ${CRED_FILE} yet - idle`);
      return "idle";
    }
    log("could not read credentials file", String(err.message || err));
    return "transient";
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch {
    logOnce("bad-json", "credentials file is not valid JSON - idle");
    return "transient";
  }

  const oauth = data && typeof data === "object" ? data.claudeAiOauth : null;
  if (!oauth || !oauth.accessToken) {
    logOnce("not-oauth", "credentials file has no claudeAiOauth token - nothing to refresh, idle");
    return "idle";
  }
  if (!oauth.refreshToken) {
    logOnce("no-refresh", "OAuth access token present but no refreshToken - re-run `claude` login to enable auto-refresh");
    return "idle";
  }

  const expiresAt = Number(oauth.expiresAt) || 0;
  const msLeft = expiresAt - Date.now();
  if (msLeft > SKEW_MS) {
    lastState = "ok";
    return "not-due";
  }

  log(`refreshing (expires in ${Math.round(msLeft / 1000)}s)`);

  let resp;
  try {
    resp = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "refresh_token",
        client_id: CLIENT_ID,
        refresh_token: oauth.refreshToken,
      }),
    });
  } catch (err) {
    log("network error contacting token endpoint", String(err.message || err));
    return "transient";
  }

  if (!resp.ok) {
    const bodyText = await resp.text().catch(() => "");
    let oauthError = "";
    try {
      oauthError = JSON.parse(bodyText).error || "";
    } catch { /* non-JSON body */ }
    if (resp.status === 400 && oauthError === "invalid_grant") {
      log("refresh token rejected (invalid_grant) - manual `claude` login required");
      return "dead";
    }
    log(`token endpoint returned HTTP ${resp.status}${oauthError ? " " + oauthError : ""}`);
    return "transient";
  }

  let body;
  try {
    body = await resp.json();
  } catch {
    log("token endpoint 200 but body was not JSON");
    return "transient";
  }
  if (!body.access_token) {
    log("token endpoint 200 but no access_token in response");
    return "transient";
  }

  const expiresInMs = (Number(body.expires_in) || 36000) * 1000;
  data.claudeAiOauth = {
    ...oauth,
    accessToken: body.access_token,
    refreshToken: body.refresh_token || oauth.refreshToken,
    expiresAt: Date.now() + expiresInMs,
  };

  try {
    await writeCreds(data);
  } catch (err) {
    log("refreshed but could not write credentials file back", String(err.message || err));
    return "transient";
  }

  log(`refreshed OK, next expiry ${new Date(data.claudeAiOauth.expiresAt).toISOString()}`);
  return "refreshed";
}

async function main() {
  log(`starting; file=${CRED_FILE} interval=${INTERVAL_MS / 1000}s skew=${SKEW_MS / 1000}s endpoint=${TOKEN_URL}`);
  await stat(dirname(CRED_FILE)).catch(() => {});

  for (;;) {
    let wait = INTERVAL_MS;
    try {
      const result = await tick();
      if (result === "transient") wait = MIN_RETRY_MS;
      // "idle" / "dead": just re-check at the normal interval. CCR runs fine
      // without us; an operator may add or fix credentials at any time.
    } catch (err) {
      log("unexpected error in tick()", String(err.stack || err));
      wait = MIN_RETRY_MS;
    }
    await new Promise((r) => setTimeout(r, wait));
  }
}

main();
