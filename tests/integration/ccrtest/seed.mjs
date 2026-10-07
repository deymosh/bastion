/**
 * Seeds the test ccr container (run inside it, as the CCR user, after CCR's
 * first start has written its configuration):
 *  - a gateway key for the test client;
 *  - a "Claude Code API" provider bound to CCR's Claude Code OAuth login, in
 *    the shape CCR's UI saves after importing the local Claude Code login;
 *  - an OAuth credentials file whose access token the fake server rejects
 *    (as an expired one would be) and whose refresh token it accepts.
 * Fake tokens only.
 */
import { DatabaseSync } from "node:sqlite";
import { mkdirSync, writeFileSync } from "node:fs";

const PROVIDER = "Claude Code API";
const STALE = "sk-ant-oat01-fake-0";

const db = new DatabaseSync("/data/.claude-code-router/config.sqlite");
const row = db.prepare("SELECT value_json FROM app_config WHERE key = 'default'").get();
const config = JSON.parse(row.value_json);
// The key the test client presents to CCR's own gateway (not an upstream one).
config.APIKEY = "ccrtest-gateway-key";

config.Providers = [
  ...(config.Providers ?? []).filter((provider) => provider.name !== PROVIDER),
  {
    id: "claude-code-api",
    name: PROVIDER,
    type: "anthropic_messages",
    api_base_url: "https://api.anthropic.com",
    api_key: "ccr-local-agent-login",
    capabilities: [{
      baseUrl: "https://api.anthropic.com",
      endpoint: "https://api.anthropic.com/v1/messages",
      source: "detected",
      type: "anthropic_messages",
    }],
    models: ["claude-sonnet-5"],
  },
];
const oauthPlugin = (suffix, providerName) => ({
  auth: {
    headers: { authorization: `Bearer ${STALE}`, "anthropic-beta": "oauth-2025-04-20" },
    removeHeaders: ["x-api-key"],
    strict: true,
  },
  key: `ccr-local-agent-claude-code-api-${suffix}`,
  providerName,
});
config.providerPlugins = [
  oauthPlugin("claude-code-oauth", PROVIDER),
  oauthPlugin("claude-code-oauth-internal", "claude-code-api::anthropic_messages"),
];
db.prepare("UPDATE app_config SET value_json = ?, updated_at = ? WHERE key = 'default'")
  .run(JSON.stringify(config), new Date().toISOString());
db.close();

mkdirSync("/data/.claude", { recursive: true });
writeFileSync("/data/.claude/.credentials.json", JSON.stringify({
  claudeAiOauth: {
    accessToken: STALE,
    refreshToken: "sk-ant-ort01-fake-0",
    // Not expired as far as anyone local can tell: the 401 alone must drive
    // the refresh.
    expiresAt: Date.now() + 3600 * 1000,
    scopes: ["user:inference", "user:profile"],
    subscriptionType: "pro",
    rateLimitTier: "default_claude_ai",
  },
  organizationUuid: "11111111-1111-1111-1111-111111111111",
}), { mode: 0o600 });
console.log("seeded provider + credentials");
