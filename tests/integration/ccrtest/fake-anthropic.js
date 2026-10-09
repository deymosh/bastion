/**
 * Stand-in for api.anthropic.com and platform.claude.com in the CCR OAuth
 * refresh integration test (tests/integration/ccr-oauth-refresh.sh).
 *
 * The ccr container resolves both hostnames here (extra_hosts) and trusts the
 * throwaway CA via NODE_EXTRA_CA_CERTS, so CCR's own upstream calls and the
 * claude CLI's refresh both land on this server. Token model:
 *  - only the access token minted by the latest refresh is accepted; the
 *    seeded one is answered 401, as an expired token would be;
 *  - POST /v1/oauth/token rotates both tokens when given the current refresh
 *    token, else 400 invalid_grant;
 *  - the CLI's own API calls get just enough to complete a refresh (a valid
 *    profile, a 404 for its nonexistent model).
 * A plain-HTTP control port (8080) exposes counters and a "revoke" switch.
 */
"use strict";
const http = require("node:http");
const https = require("node:https");
const fs = require("node:fs");

const state = {
  refreshToken: "sk-ant-ort01-fake-0",
  accessToken: null, // nothing valid until the first refresh
  generation: 0,
  revoked: false,
  oauthPosts: 0,
  messages200: 0,
  messages401: 0,
  // Fake bearer tokens seen on /v1/messages, in order (prefix stripped).
  bearers: [],
  // Calls the claude CLI made for the refresh plugin's nonexistent model.
  cliProbes: 0,
  // The tools of the last /v1/messages request that carried any, as received.
  lastTools: null,
};

function json(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function message(model) {
  return {
    id: "msg_bastion_test",
    type: "message",
    role: "assistant",
    model,
    content: [{ type: "text", text: "bastion-refresh-ok" }],
    stop_reason: "end_turn",
    stop_sequence: null,
    usage: { input_tokens: 1, output_tokens: 1 },
  };
}

function streamMessage(res, model) {
  const send = (event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
  res.writeHead(200, { "content-type": "text/event-stream" });
  const full = message(model);
  send("message_start", { type: "message_start", message: { ...full, content: [], stop_reason: null } });
  send("content_block_start", { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } });
  send("content_block_delta", { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: "bastion-refresh-ok" } });
  send("content_block_stop", { type: "content_block_stop", index: 0 });
  send("message_delta", { type: "message_delta", delta: { stop_reason: "end_turn", stop_sequence: null }, usage: { output_tokens: 1 } });
  send("message_stop", { type: "message_stop" });
  res.end();
}

function handle(req, res, body) {
  const path = req.url.split("?")[0];
  const bearer = (req.headers.authorization || "").replace(/^Bearer\s+/i, "");

  if (path === "/v1/oauth/token") {
    state.oauthPosts += 1;
    let refresh = "";
    try { refresh = JSON.parse(body).refresh_token; } catch { refresh = new URLSearchParams(body).get("refresh_token"); }
    if (state.revoked || refresh !== state.refreshToken) {
      return json(res, 400, { error: "invalid_grant", error_description: "Refresh token not found or invalid" });
    }
    state.generation += 1;
    state.accessToken = `sk-ant-oat01-fake-${state.generation}`;
    state.refreshToken = `sk-ant-ort01-fake-${state.generation}`;
    return json(res, 200, {
      access_token: state.accessToken,
      refresh_token: state.refreshToken,
      expires_in: 28800,
      token_type: "Bearer",
      scope: "user:inference user:profile user:sessions:claude_code user:mcp_servers user:file_upload",
    });
  }

  if (path === "/api/oauth/profile") {
    return json(res, 200, {
      account: { uuid: "22222222-2222-2222-2222-222222222222", email: "test@example.invalid", email_address: "test@example.invalid" },
      organization: { uuid: "11111111-1111-1111-1111-111111111111", organization_type: "claude_pro" },
    });
  }

  if (path.startsWith("/v1/messages")) {
    let request = {};
    try { request = JSON.parse(body); } catch { /* empty body */ }
    if (request.model === "bastion-oauth-refresh-only") {
      // The refresh plugin's CLI must reach Anthropic directly, never via CCR.
      state.cliProbes += 1;
      return json(res, 404, { type: "error", error: { type: "not_found_error", message: `model: ${request.model}` } });
    }
    state.bearers.push(bearer.replace(/^sk-ant-oat01-/, ""));
    if (Array.isArray(request.tools)) state.lastTools = request.tools;
    if (state.revoked || !state.accessToken || bearer !== state.accessToken) {
      state.messages401 += 1;
      return json(res, 401, { type: "error", error: { type: "authentication_error", message: "OAuth token has expired." } });
    }
    state.messages200 += 1;
    return request.stream ? streamMessage(res, request.model) : json(res, 200, message(request.model));
  }

  if (path === "/v1/models") return json(res, 200, { data: [], has_more: false });
  return json(res, 200, {});
}

const tls = https.createServer({ key: fs.readFileSync("/certs/srv.key"), cert: fs.readFileSync("/certs/srv.pem") }, (req, res) => {
  let body = "";
  req.on("data", (chunk) => { body += chunk; });
  req.on("end", () => handle(req, res, body));
});
tls.listen(443);

http.createServer((req, res) => {
  if (req.url === "/control/revoke") state.revoked = true;
  json(res, 200, state);
}).listen(8080);

console.log("fake-anthropic listening on 443 (TLS) and 8080 (control)");
