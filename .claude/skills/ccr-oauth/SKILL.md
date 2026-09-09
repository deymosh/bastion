---
name: ccr-oauth
description: Use when working on CCR (Claude Code Router) auth in stack-ai — the Claude OAuth credentials file, why the token expires in the headless container, the in-container refresher (ccr-token-refresher.mjs), the OAuth refresh request shape, and debugging 401s from CCR. Read before touching Dockerfile.ccr, the entrypoint wrapper, or the refresher.
---

# CCR Claude OAuth model

## Core principle

CCR authenticates to `api.anthropic.com` with the Claude Code OAuth
**access token**, read from a credentials file on disk. That token is
short-lived (~a day). CCR (>= commit `561c2d8`, which the pinned fork branch
`fix/log-body.worker.js` includes) **re-reads the file on every upstream
request**, so a rotated token is picked up with **no gateway restart** — but CCR
itself never refreshes it for the Claude-Code provider path (unlike its Grok /
Kimi paths). In a headless container nothing rotates the file, so it 401s daily.
Bastion fixes this with a tiny refresher process started alongside CCR.

## When to use this skill

- Editing `stack-ai/Dockerfile.ccr`, `stack-ai/ccr-entrypoint-wrapper.sh`, or
  `stack-ai/ccr-token-refresher.mjs`.
- CCR returns 401 / "please run /login" after working for a while.
- Changing `CLAUDE_CONFIG_DIR` or the CCR data volume.

## 1. The credentials file

`CLAUDE_CONFIG_DIR=/data/.claude` (set in `Dockerfile.ccr`), so the file is
`/data/.claude/.credentials.json`, persisted via `./data/ccr:/data`. Shape:

```json
{
  "claudeAiOauth": {
    "accessToken":  "sk-ant-oat01-...",
    "refreshToken": "sk-ant-ort01-...",
    "expiresAt":    1788899895278,        // epoch MILLISECONDS
    "scopes":       ["user:inference", "user:profile"],
    "subscriptionType": "pro"
  }
}
```

It is written initially by an interactive `claude` login (the `claude` CLI is
baked into the image). It holds **live secrets** — never commit it, never log its
contents.

## 2. The refresh request

Standard OAuth2 refresh, no auth header:

```
POST https://claude.ai/v1/oauth/token
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token
client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e
refresh_token=<current refreshToken>
```

Response (200): `{ "access_token", "refresh_token", "expires_in" }` — the refresh
token **rotates**, so the new one must be written back. `expires_in` is seconds
(~36000). Compute `expiresAt = Date.now() + expires_in*1000`.

**Verify the endpoint + `client_id` against the baked-in CLI** rather than
trusting these constants blindly:
`grep -rhoE '(client_id|oauth/token|[0-9a-f-]{36})' /usr/local/lib/node_modules/@anthropic-ai/claude-code/ | sort -u`.

Error handling:
- `4xx` with `invalid_grant` → the refresh token is dead; an operator must
  `claude` login again. Log loudly, keep looping (don't crash).
- `429` / `5xx` / network → transient; back off and retry.

## 3. How the refresher runs

`stack-ai/ccr-entrypoint-wrapper.sh` is the image `ENTRYPOINT`. It backgrounds
`node /usr/local/bin/ccr-token-refresher.mjs` (when `CCR_TOKEN_REFRESH=1` and the
credentials file exists), then `exec`s the upstream `ccr-entrypoint`. The
refresher loops every `CCR_REFRESH_INTERVAL` (default 300s): read the file, and
if `Date.now() >= expiresAt - CCR_REFRESH_SKEW_MS` (default 30 min) do the POST
and write the file back **atomically** (`.credentials.json.tmp` + `rename`, mode
`600`), preserving any keys it doesn't manage. No restart, no signal to CCR — the
per-request re-read picks it up.

Zero dependencies: the runtime image has Node 22 with global `fetch`.

## 4. Debugging a CCR 401

1. `docker exec ccr node -e "const c=require('/data/.claude/.credentials.json').claudeAiOauth; console.log(new Date(c.expiresAt), Date.now()<c.expiresAt)"`
   — is the token actually expired?
2. `docker logs ccr | grep -i refresh` — did the refresher run / fail?
3. If `invalid_grant` in the logs → refresh token revoked; re-login:
   `docker exec -it ccr claude` (interactive) or re-run the login flow, then
   restart is unnecessary but harmless.
4. Confirm `CCR_TOKEN_REFRESH=1` is set (`docker exec ccr env | grep CCR_`).

## Quick reference

| Symptom | Cause | Fix |
|---|---|---|
| 401 after ~1 day, was fine before | refresher not running / disabled | set `CCR_TOKEN_REFRESH=1`, check `docker logs` |
| refresher logs `invalid_grant` | refresh token revoked/expired | operator re-login with `claude` |
| token refreshes but CCR still 401 | CCR older than `561c2d8` (no per-request re-read) | rebuild from a fork branch that includes it |
| refresher logs 429 repeatedly | rate-limited on the token endpoint | increase `CCR_REFRESH_INTERVAL`; it backs off already |

## When NOT to apply

- The CodeDeck+ bridge's own Claude auth — that uses the
  `CLAUDE_CODE_OAUTH_TOKEN` compose secret, a different mechanism.

## Related

- [../stack-compose/SKILL.md](../stack-compose/SKILL.md)
- Issue context: `musistudio/claude-code-router` #1628, PR #1705, commit `561c2d8`.
