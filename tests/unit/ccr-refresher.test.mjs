/*
 * Tests for stack-ai/ccr-token-refresher.mjs
 *
 *   node --test tests/ccr-refresher.test.mjs
 *
 * The refresher is a long-running loop, so each test spawns it as a child with
 * a fast interval, a mock token endpoint, and an isolated CLAUDE_CONFIG_DIR,
 * lets it run one or two ticks, then kills it and inspects stdout + the file.
 */
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REFRESHER = resolve(dirname(fileURLToPath(import.meta.url)), "../../stack-ai/ccr-token-refresher.mjs");

function mockEndpoint(handler) {
  const srv = createServer((req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => handler(req, body, res));
  });
  return new Promise((r) => srv.listen(0, "127.0.0.1", () => r({ srv, url: `http://127.0.0.1:${srv.address().port}/v1/oauth/token` })));
}

async function runRefresher({ credentials, tokenUrl, ms = 2500, env = {} }) {
  const dir = mkdtempSync(join(tmpdir(), "ccr-refresh-"));
  const credFile = join(dir, ".credentials.json");
  if (credentials !== undefined) writeFileSync(credFile, typeof credentials === "string" ? credentials : JSON.stringify(credentials));
  const child = spawn(process.execPath, [REFRESHER], {
    env: { ...process.env, CLAUDE_CONFIG_DIR: dir, CCR_REFRESH_INTERVAL: "1", CCR_OAUTH_TOKEN_URL: tokenUrl || "http://127.0.0.1:1/none", ...env },
  });
  let out = "";
  child.stdout.on("data", (d) => (out += d));
  child.stderr.on("data", (d) => (out += d));
  await new Promise((r) => setTimeout(r, ms));
  child.kill("SIGKILL");
  let after = null;
  if (existsSync(credFile)) {
    const raw = readFileSync(credFile, "utf8");
    try { after = JSON.parse(raw); } catch { after = raw; }
  }
  rmSync(dir, { recursive: true, force: true });
  return { out, after };
}

test("no credentials file -> idle, no crash, no file created", async () => {
  const { out, after } = await runRefresher({ credentials: undefined });
  assert.match(out, /idle/i);
  assert.equal(after, null);
  assert.doesNotMatch(out, /unexpected error|TypeError|ReferenceError/);
});

test("malformed JSON credentials -> idle (no 60s hot loop), file untouched", async () => {
  const { out, after } = await runRefresher({ credentials: "{ not json", ms: 3500 });
  assert.match(out, /not valid JSON/i);
  assert.doesNotMatch(out, /refreshing|refreshed OK|token endpoint/i, "no refresh attempt");
  // interval is 1s; a "transient" would re-log every retry. "idle" logs once.
  assert.equal((out.match(/not valid JSON/g) || []).length, 1, "logged once, not looping");
  assert.equal(after, "{ not json");
});

test("API-key style file (no claudeAiOauth) -> idle, file untouched", async () => {
  const original = { apiKey: "sk-ant-api03-xxx" };
  const { out, after } = await runRefresher({ credentials: original });
  assert.match(out, /nothing to refresh|idle/i);
  assert.deepEqual(after, original);
});

test("OAuth token not near expiry -> no request, file untouched", async () => {
  let hits = 0;
  const { srv, url } = await mockEndpoint((_r, _b, res) => { hits++; res.end("{}"); });
  const creds = { claudeAiOauth: { accessToken: "A", refreshToken: "R", expiresAt: Date.now() + 6 * 3600_000 } };
  const { after } = await runRefresher({ credentials: creds, tokenUrl: url });
  srv.close();
  assert.equal(hits, 0, "must not call the token endpoint when far from expiry");
  assert.equal(after.claudeAiOauth.accessToken, "A");
});

test("expired OAuth token -> refreshes, rotates both tokens, advances expiry, keeps other keys", async () => {
  const { srv, url } = await mockEndpoint((req, body, res) => {
    const p = new URLSearchParams(body);
    assert.equal(p.get("grant_type"), "refresh_token");
    assert.ok(p.get("client_id"));
    assert.equal(p.get("refresh_token"), "sk-ant-ort01-OLD");
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ access_token: "sk-ant-oat01-NEW", refresh_token: "sk-ant-ort01-NEW", expires_in: 36000 }));
  });
  const creds = {
    claudeAiOauth: { accessToken: "sk-ant-oat01-OLD", refreshToken: "sk-ant-ort01-OLD", expiresAt: 1, scopes: ["user:inference"], subscriptionType: "pro" },
    unrelated: "keep-me",
  };
  const { out, after } = await runRefresher({ credentials: creds, tokenUrl: url });
  srv.close();
  assert.match(out, /refreshed OK/i);
  assert.equal(after.claudeAiOauth.accessToken, "sk-ant-oat01-NEW");
  assert.equal(after.claudeAiOauth.refreshToken, "sk-ant-ort01-NEW");
  assert.ok(after.claudeAiOauth.expiresAt > Date.now() + 30_000_000);
  assert.deepEqual(after.claudeAiOauth.scopes, ["user:inference"]);
  assert.equal(after.claudeAiOauth.subscriptionType, "pro");
  assert.equal(after.unrelated, "keep-me");
});

test("invalid_grant -> logged, file NOT clobbered", async () => {
  const { srv, url } = await mockEndpoint((_r, _b, res) => {
    res.writeHead(400, { "content-type": "application/json" });
    res.end(JSON.stringify({ error: "invalid_grant" }));
  });
  const creds = { claudeAiOauth: { accessToken: "OLD", refreshToken: "DEAD", expiresAt: 1 } };
  const { out, after } = await runRefresher({ credentials: creds, tokenUrl: url });
  srv.close();
  assert.match(out, /invalid_grant/i);
  assert.equal(after.claudeAiOauth.accessToken, "OLD", "must not overwrite creds on a dead refresh token");
});

test("5xx from endpoint -> transient, file untouched, keeps running", async () => {
  const { srv, url } = await mockEndpoint((_r, _b, res) => { res.writeHead(503); res.end("nope"); });
  const creds = { claudeAiOauth: { accessToken: "OLD", refreshToken: "R", expiresAt: 1 } };
  const { out, after } = await runRefresher({ credentials: creds, tokenUrl: url, ms: 3000 });
  srv.close();
  assert.match(out, /HTTP 503|transient/i);
  assert.equal(after.claudeAiOauth.accessToken, "OLD");
});
