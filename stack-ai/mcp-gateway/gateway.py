#!/usr/bin/env python3
"""Bastion MCP gateway.

Aggregates the stack-ai MCP servers - searxng, context7, memory, time - each
running as a local stdio child process, behind a single Streamable HTTP
endpoint protected by one Bearer token. Remote agents connect to /mcp on the
published port; the children are plain executables baked into this image at
build time (exact-pinned versions), so nothing is fetched at runtime.

The aggregation itself is FastMCP's proxy/composition feature: one
create_proxy(Client(StdioTransport)) per child, mounted under a namespace, so
every tool the gateway serves is named <namespace>_<tool> and collisions
between children are impossible.

Configuration comes from the environment as non-secret values and secret-file
PATHS only. Secret values are read from files at startup - never env vars:

  MCP_TOKEN_FILE              Bearer token file (required; the gateway refuses
                              to start without one, fail closed).
  MCP_CONTEXT7_API_KEY_FILE   optional Context7 API key (empty file = keyless,
                              which context7 serves at lower rate limits).
  MCP_SEARXNG_URL             default http://searxng:8080 (in-network alias).
  MCP_MEMORY_FILE_PATH        default /data/memory.json (named volume).
  MCP_HOST / MCP_PORT         listen address, default 0.0.0.0 / 8811.
  TIMEZONE                    --local-timezone for the time server (bastion.conf).
"""

import hmac
import os
import sys

import uvicorn
from fastmcp import Client, FastMCP
from fastmcp.client.transports import StdioTransport
from fastmcp.server import create_proxy
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.routing import Route


def read_secret_file(env_var: str, default_path: str) -> str:
    """Read a mounted secret file. The env var carries the PATH, not the value."""
    path = os.environ.get(env_var, default_path)
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def child_transport(command: str, args: list[str], extra_env: dict[str, str] | None = None) -> StdioTransport:
    """Stdio transport for an MCP child.

    The child gets this container's environment plus its own extras: npm/PyPI
    servers expect a normal PATH/HOME, and passing the merged dict explicitly
    keeps us independent of how the MCP SDK merges (or replaces) inherited env.
    """
    return StdioTransport(command, args, env={**os.environ, **(extra_env or {})})


def build_backends() -> list[tuple[str, StdioTransport, dict[str, str] | None]]:
    context7_key = read_secret_file("MCP_CONTEXT7_API_KEY_FILE", "/run/secrets/context7_api_key")
    context7_env = {"CONTEXT7_API_KEY": context7_key} if context7_key else {}

    # Time server: lives in its own virtualenv (see Dockerfile.mcp-gateway) -
    # it pins mcp 1.x while the gateway's fastmcp needs mcp 2.x.
    time_python = os.environ.get("MCP_TIME_PYTHON", "/opt/time-venv/bin/python")
    if not os.path.exists(time_python):
        sys.exit(f"mcp-gateway: time-server interpreter not found: {time_python}")

    # mcp-searxng already prefixes its own tools with "searxng_" upstream
    # (searxng_web_search, ...); strip that so the namespace re-applies it
    # exactly once (searxng_web_search instead of searxng_searxng_web_search).
    searxng_renames = {
        "searxng_web_search": "web_search",
        "searxng_search_suggestions": "search_suggestions",
        "searxng_instance_info": "instance_info",
    }

    return [
        # SearXNG metasearch. JSON output is enabled in the instance's
        # settings.yml; without it every query answers 403.
        (
            "searxng",
            child_transport(
                "mcp-searxng",
                [],
                {"SEARXNG_URL": os.environ.get("MCP_SEARXNG_URL", "http://searxng:8080")},
            ),
            searxng_renames,
        ),
        # Up-to-date library/API docs from context7.com.
        ("context7", child_transport("context7-mcp", [], context7_env), None),
        # Persistent knowledge graph; the file lives on the named volume.
        (
            "memory",
            child_transport(
                "mcp-server-memory",
                [],
                {"MEMORY_FILE_PATH": os.environ.get("MCP_MEMORY_FILE_PATH", "/data/memory.json")},
            ),
            None,
        ),
        # Time and timezone conversion, pinned to the host's bastion.conf TZ.
        (
            "time",
            child_transport(time_python, ["-m", "mcp_server_time", "--local-timezone", os.environ.get("TIMEZONE", "UTC")]),
            None,
        ),
    ]


class BearerAuthMiddleware:
    """Reject every request that does not carry the expected Bearer token.

    Pure ASGI so it wraps the FastMCP Starlette app unchanged. /healthz stays
    open (Docker's healthcheck has no token); everything else answers 401 with
    WWW-Authenticate. Comparison is constant-time so response timing cannot
    recover the token byte by byte.
    """

    def __init__(self, app, token: str, exempt: tuple[str, ...] = ("/healthz",)) -> None:
        self.app = app
        self.expected = token.encode()
        self.exempt = exempt

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] == "http" and scope["path"] not in self.exempt:
            headers = {key.lower(): value for key, value in scope.get("headers", [])}
            scheme, _, credential = headers.get(b"authorization", b"").partition(b" ")
            authorized = scheme.lower() == b"bearer" and hmac.compare_digest(credential, self.expected)
            if not authorized:
                response = JSONResponse(
                    {"error": "unauthorized: missing or invalid bearer token"},
                    status_code=401,
                    headers={"WWW-Authenticate": "Bearer"},
                )
                await response(scope, receive, send)
                return
        await self.app(scope, receive, send)


def build_app(token: str):
    gateway = FastMCP(name="bastion-mcp")
    namespaces = []
    for name, transport, renames in build_backends():
        # One persistent Client per child: connected lazily on first use and
        # reused across requests (a crashed child is reconnected on the next
        # call, and only its own tools fail in the meantime).
        proxy = create_proxy(Client(transport), name=name)
        gateway.mount(proxy, namespace=name, tool_names=renames)
        namespaces.append(name)

    app = gateway.http_app(
        path="/mcp",
        stateless_http=True,
        middleware=[Middleware(BearerAuthMiddleware, token=token)],
    )

    async def healthz(request):  # pragma: no cover - trivial
        return JSONResponse({"status": "ok", "namespaces": namespaces})

    app.router.routes.append(Route("/healthz", healthz, methods=["GET"]))
    return app


def main() -> None:
    token = read_secret_file("MCP_TOKEN_FILE", "/run/secrets/mcp_gateway_token")
    if not token:
        # Fail closed: an unauthenticated MCP endpoint on the LAN is worse
        # than no endpoint.
        sys.exit(
            "mcp-gateway: no bearer token - set MCP_GATEWAY_TOKEN in "
            "bastion.conf so the secret file is created, then retry"
        )
    app = build_app(token)
    uvicorn.run(
        app,
        host=os.environ.get("MCP_HOST", "0.0.0.0"),
        port=int(os.environ.get("MCP_PORT", "8811")),
        log_level="info",
    )


if __name__ == "__main__":
    main()
