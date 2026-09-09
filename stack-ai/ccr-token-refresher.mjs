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

async function readCreds() {
  const raw = await readFile(CRED_FILE, "utf8");
  const data = JSON.parse(raw);
  if (!data || typeof data !== "object" || !data.claudeAiOauth) {
    throw new Error("no claudeAiOauth object in credentials file");
  }
  return data;
}

async function writeCreds(data) {
  const tmp = CRED_FILE + ".tmp";
  await writeFile(tmp, JSON.stringify(data, null, 2) + "\n", { mode: 0o600 });
  await rename(tmp, CRED_FILE);
}

/**
 * @returns {"refreshed" | "not-due" | "transient" | "dead"}
 */
async function tick() {
  let data;
  try {
    data = await readCreds();
  } catch (err) {
    // File missing / not yet written by an interactive login: not our problem
    // to create, just wait for it.
    if (err.code === "ENOENT") {
      log("credentials file not present yet, waiting");
      return "transient";
    }
    log("could not read credentials file", String(err.message || err));
    return "transient";
  }

  const oauth = data.claudeAiOauth;
  const expiresAt = Number(oauth.expiresAt) || 0;
  const msLeft = expiresAt - Date.now();

  if (msLeft > SKEW_MS) {
    return "not-due";
  }
  if (!oauth.refreshToken) {
    log("token near expiry but no refreshToken present - manual `claude` login required");
    return "dead";
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
  // Make sure the directory exists so ENOENT below is specifically the file.
  await stat(dirname(CRED_FILE)).catch(() => {});

  for (;;) {
    let wait = INTERVAL_MS;
    try {
      const result = await tick();
      if (result === "transient") wait = MIN_RETRY_MS;
      // "dead": keep looping at the normal interval; an operator may re-login
      // at any time and we should pick the new refresh token up.
    } catch (err) {
      log("unexpected error in tick()", String(err.stack || err));
      wait = MIN_RETRY_MS;
    }
    await new Promise((r) => setTimeout(r, wait));
  }
}

main();
