---
name: ccr-oauth
description: Use when working on CCR (Claude Code Router) auth in stack-ai — the Claude OAuth credentials file, why the token expires in the headless container, the on-demand refresh plugin (ccr-oauth-refresh-plugin.cjs) that has the official claude CLI refresh the login on a 401 (inference via the core gateway's provider hooks, account usage via a fetch wrapper in CCR's process), and debugging 401s from CCR. Read before touching Dockerfile.ccr, the entrypoint wrapper, ccr-enable-plugins.mjs, or the refresh plugin.
---

# CCR Claude OAuth model

## Core principle

CCR authenticates its "Claude Code API" provider to `api.anthropic.com` with
the Claude Code OAuth **access token** from
`$CLAUDE_CONFIG_DIR/.credentials.json` (`/data/.claude`, set in the compose
file). The token is short-lived (hours). CCR never refreshes it for this
provider. Bastion refreshes it **only on demand**: when Anthropic answers
`401`, a bundled CCR plugin has the **official `claude` CLI** refresh the login,
and the request is retried with the new token. No timer, no background
process, no polling, no hand-rolled OAuth request - a refresh is always a
reaction to a 401 (the maintainer's explicit choice; do not add a proactive
or expiry-driven refresh).

## When to use this skill

- Editing `stack-ai/ccr/ccr-oauth-refresh-plugin.cjs`,
  `stack-ai/ccr/ccr-enable-plugins.mjs`, `stack-ai/ccr/ccr-entrypoint-wrapper.sh`
  or `stack-ai/ccr/Dockerfile.ccr`.
- CCR returns 401 / "please run /login".
- Bumping `CCR_REF` or the bundled `claude` CLI (both can move the internals
  below; `tests/integration/ccr-oauth-refresh.sh` is the check).

## 1. The credentials file

```json
{
  "claudeAiOauth": {
    "accessToken":  "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt":    1788998262097,          // epoch MILLISECONDS
    "refreshTokenExpiresAt": 1791253716097, // may be absent
    "scopes": ["user:inference", "..."],
    "subscriptionType": "pro",
    "rateLimitTier": "default_claude_ai"
  },
  "organizationUuid": "..."                 // sibling of claudeAiOauth
}
```

Written by an interactive `./bastion exec ccr -- claude` login. Live secret:
never commit it, never log its contents. The plugin rewrites only
`claudeAiOauth.expiresAt` (atomically, tmp + rename, mode 600); the CLI then
rewrites the token pair itself and keeps every other key.

## 2. Where the 401 is caught

Two CCR paths use the token, in two processes, and the plugin covers both.

**Inference: the core gateway.** CCR runs its data plane in a separate
supervised process, the **core gateway** (npm `@the-next-ai/ai-gateway`),
configured from JSON that CCR compiles at gateway start. A CCR plugin reaches
it with `ctx.registerCoreGatewayPlugin({ key, enabled, modulePath })` (needs
the `core-gateway-plugins` permission and the `gateway` surface); the gateway
then `import()`s that module, reads its `manifest` export (name, description,
`capabilities` - validated: naming a capability the module does not return
fails the load) and calls its `createGatewayPlugin()`.

- On **any** upstream `401`, the gateway rebuilds the request once through
  every provider hook's `authenticate` with `forceCodexOauthRefreshOnce: true`
  and retries it. That flag is the hook's trigger. (Upstream non-OK
  responses never reach `responseHooks` / `streamHooks`.)
- The hook input has no provider kind. The Claude Code OAuth providers are
  found through CCR's provider-plugin entries, keys
  `ccr-local-agent-<slug>-claude-code-oauth[-internal]`, whose `providerName`s
  (public and `…::anthropic_messages`) are matched against
  `targetProviderName`. **Where those entries live moved in CCR v3.1.2**: up
  to v3.1.1 they are the gateway config's top-level `providerPlugins`; from
  v3.1.2 that list is empty and they sit in
  `plugins[key=ccr-local-agent-auth-provider-hooks].config.providerPlugins`.
  The plugin reads both. If a CCR bump moves them again, the hook silently
  matches nothing - the integration test's "exactly one refresh" check catches
  it.
- Applying the token: from v3.1.2 CCR strips any compiled `authorization`
  from those entries (`withoutStaticLocalOauthAuth`), and its live hook
  `ccr-local-agent-auth-provider-hooks`, which runs after ours, re-reads the
  credentials file per request. So the refreshed file is enough; the plugin
  also sets the header on the retried request it returns.

**Account usage: CCR's own process.** For a Claude Code OAuth provider CCR
fetches `GET https://api.anthropic.com/api/oauth/usage` (shown in its UI) with
the token from the file, through `fetchWithSystemProxy`, which calls the
**global `fetch`, looked up per call**. A 401 there is a plain error: no
retry, no hook, no event. So `setup` wraps `globalThis.fetch`: a 401 from that
exact endpoint gets the same refresh, and that one request is sent again with
the new token; every other response is returned untouched, and without a new
token the original 401 is returned. CCR re-runs `setup` on every config change
after calling the previous registration's `stop`, which unwraps fetch (the
wrapper also never wraps itself).

## 3. How the CLI is made to refresh (verified against CLI 2.1.x)

1. Mark the stored access token expired (`expiresAt` in the past). The CLI only
   refreshes a token it believes has expired, and a 401 is authoritative.
2. Run `claude -p ok --model bastion-oauth-refresh-only --max-turns 1
   --no-session-persistence --setting-sources project` from an empty temp
   dir, with `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_BASE_URL`
   and `CLAUDE_CODE_OAUTH_TOKEN` stripped from its env. `--setting-sources
   project` is load-bearing: CCR writes `/data/.claude/settings.json` with
   `env.ANTHROPIC_BASE_URL=http://127.0.0.1:3456` and an `apiKeyHelper`, so
   without it the CLI's call goes into CCR itself (a catch-all route could
   spend inference or loop back into the hook). The
   CLI refreshes (`POST platform.claude.com/v1/oauth/token`), validates the
   profile, persists the rotated pair, releases its lock, then calls
   `/v1/messages` for the nonexistent model and gets `404 not_found_error`. No
   inference is spent. The exit status is non-zero by design; success = the
   stored access token changed.

Do **not** use:
- `claude auth status`: it starts a refresh in the background and exits
  before it completes, leaving `$CLAUDE_CONFIG_DIR/.oauth_refresh.lock` held.
  The next CLI then fails with "another Claude Code process is refreshing it
  or exited mid-refresh" until the lock goes stale.
- `--bare`: it ignores the OAuth login ("Not logged in").

Concurrency and backoff, across both processes: concurrent 401s in one
process share one refresh; across processes a lock file
(`.credentials.json.bastion-refresh.lock`, stale after 75 s) lets only one CLI
run at a time, and the second process then reuses its result. The last
success/failure time is shared in `.credentials.json.bastion-refresh.json`:
a 401 within 30 s of a successful refresh reuses the fresh token (this spans
restarts too), and after a failed refresh the CLI is not rerun for 60 s. The
hook is `failureMode: "fail_open"` with a 135 s timeout (lock wait + the CLI,
killed at 60 s): a failed refresh lets the original 401 reach the client,
never a worse error. `CCR_TOKEN_REFRESH=0` (read at runtime) disables both
paths.

## 4. Registration

`ccr-entrypoint-wrapper.sh` runs `ccr-enable-plugins.mjs` (as the run user)
before CCR starts. It edits CCR's config (SQLite `config.sqlite`, table
`app_config`, row `default`) to add two `plugins[]` entries,
`bastion-tool-schema-sanitizer` and `bastion-claude-oauth-refresh`, both with
`trusted-code` + `core-gateway-plugins` and only the `gateway` surface: both
hand themselves to the core gateway as module plugins. Never use a CCR-side
`registerGatewayRequestTransform` (or gateway routes): either makes CCR put
its compatibility server in front of the core gateway
(`singleGatewayRuntimeBlockers` in CCR's gateway-service.ts). Our entries get
their permissions/surfaces reconciled on each start, keeping the operator's
`enabled`; an entry pointing at another module is left alone. A fresh install gets them on its second start (CCR writes the
config on the first). Also note: on a fresh install with **no provider**, CCR
does not start its gateway ("No available models"), so `/health` (proxied by
nginx) fails until a provider exists. That is upstream behaviour, not a
Bastion fault.

## 5. Lifetimes and logging

Observed: access token ~8 h. Refresh token ~9-10 days after the write that
issued it (`refreshTokenExpiresAt`; two real logins measured 8.9 and 10.0
days). Whether a refresh extends it is not established. So a node whose CCR
sees no 401 for longer than that may need an interactive login. Every line
needing an operator contains `LOGIN NEEDED`.

## 6. Debugging a CCR 401

1. `./bastion logs ccr | grep bastion-claude-oauth-refresh`:
   - `upstream 401: refreshing …` (inference) or `account usage 401: refreshing …` (CCR's usage fetch) then `refreshed; access token valid until …, refresh token until …`: working
     (`- it expires soon; LOGIN NEEDED …` appended when under two days remain).
   - `refresh failed: the refresh token was rejected (claude CLI: Failed to authenticate: OAuth session expired and could not be refreshed). LOGIN NEEDED …`:
     revoked/expired login; log in again with `./bastion exec ccr -- claude`.
   - `upstream 401 and the refresh token expired at … LOGIN NEEDED`: same, caught without running the CLI.
   - `refresh failed (claude CLI: …); retrying on the next 401 after a minute`: transient or unknown; read the CLI line.
   - `… holds no OAuth login. LOGIN NEEDED`: no `claudeAiOauth` in the file.
   - `401 right after a refresh; retrying with the refreshed token`: a request raced the refresh (in either process); harmless unless it repeats.
   - no line at all: the plugin is not registered (check
     `./bastion logs ccr | grep ccr-enable-plugins`), `CCR_TOKEN_REFRESH=0`, or
     a CCR bump moved the provider-plugin entries (section 2).
2. `./bastion exec ccr -- ls -la /data/.claude`: a long-lived
   `.oauth_refresh.lock` (the CLI's) or `.credentials.json.bastion-refresh.lock`
   (the plugin's) means a process died mid-refresh; both clear when stale.
3. Is the token actually expired?
   `./bastion exec ccr -- node -e "const c=require('/data/.claude/.credentials.json').claudeAiOauth; console.log(new Date(c.expiresAt))"`

## Tests

- `tests/unit/ccr-oauth-refresh.test.mjs`: hook, fetch-wrapper and
  cross-process logic with a stub CLI (both CCR config shapes).
- `tests/integration/ccr-oauth-refresh.sh`: the real image + official CLI
  against a fake Anthropic (both hostnames, throwaway CA): stale token → 401 →
  refresh → 200, then reuse, streaming, restart, and revoked-login fail-open.
  Run it after any `CCR_REF` or CLI bump. It does not drive the account-usage
  path (CCR only fetches usage for its UI); that path is unit-tested.

## When NOT to apply

- The CodeDeck+ bridge's own Claude auth: that uses the
  `CLAUDE_CODE_OAUTH_TOKEN` compose secret, a different mechanism.

## Related

- [../stack-compose/SKILL.md](../stack-compose/SKILL.md)
