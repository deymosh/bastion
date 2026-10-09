#!/usr/bin/env python3
"""Bastion MCP gateway.

Aggregates the stack-ai MCP servers - searxng, context7, memory, time -
each running as a local stdio child process, behind a single Streamable
HTTP endpoint protected by one Bearer token. Remote agents connect to /mcp on
the published port; the children are plain executables baked into this image
at build time (exact-pinned versions), so nothing is fetched at runtime.

The aggregation itself is FastMCP's proxy/composition feature: one
create_proxy(Client(StdioTransport)) per child, mounted under a namespace, so
every tool the gateway serves is named <namespace>_<tool> and collisions
between children are impossible.

Context budget is a first-class concern: every tool's name, description and
input schema lands in the connecting model's context, so each child is mounted
through a ToolTransform that (a) disables tools that duplicate a served one,
cannot work on this install, or give a model nothing to act on, (b) rewrites upstream descriptions that are needlessly verbose,
and (c) hides arguments that only power-user callers would ever send. The
served surface is the trimmed one - upstream tool sets can grow without
silently growing the gateway's footprint.

Configuration comes from the environment as non-secret values and secret-file
PATHS only. Secret values are read from files at startup - never env vars:

  MCP_TOKEN_FILE              Bearer token file (required; the gateway refuses
                              to start without one, fail closed).
  MCP_CONTEXT7_API_KEY_FILE   optional Context7 API key (empty file = keyless,
                              which context7 serves at lower rate limits).
  MCP_SEARXNG_URL             default http://searxng:8080 (in-network alias).
  MCP_BM_CONFIG_DIR           basic-memory config/db/projects (data dir).
  MCP_HOST / MCP_PORT         listen address, default 0.0.0.0 / 8811.
  TIMEZONE                    --local-timezone for the time server (bastion.conf).
"""

import hmac
import json
import os
import shutil
import sys

import uvicorn
from fastmcp import Client, FastMCP
from fastmcp.client.transports import StdioTransport
from fastmcp.server import create_proxy
from fastmcp.server.providers.fastmcp_provider import FastMCPProvider
from fastmcp.server.transforms import ToolTransform
from fastmcp.tools.tool_transform import ArgTransformConfig, ToolTransformConfig
from starlette.middleware import Middleware
from starlette.responses import JSONResponse
from starlette.routing import Route

DATA_DIR = os.environ.get("MCP_DATA_DIR", "/data")
BM_CONFIG_DIR = os.environ.get("MCP_BM_CONFIG_DIR", f"{DATA_DIR}/memory")


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


def disabled(*names: str) -> dict[str, ToolTransformConfig]:
    """Transform set that removes tools from the served surface."""
    return {name: ToolTransformConfig(enabled=False) for name in names}


# --- searxng ---------------------------------------------------------------

# instance_info and search_suggestions never earn their context slot: one
# reports SearXNG engine configuration, the other autocompletes queries a
# model does not need autocompleted. web_search is renamed (mcp-searxng
# prefixes its tools with "searxng_" upstream, and the namespace re-applies
# the prefix) and kept lean: the hidden args are engine plumbing a caller
# almost never wants, and each costs schema tokens forever.
SEARXNG_TRANSFORMS = {
    **disabled("searxng_instance_info", "searxng_search_suggestions"),
    "searxng_web_search": ToolTransformConfig(
        name="web_search",
        arguments={
            arg: ArgTransformConfig(hide=True)
            for arg in ("response_format", "result_detail", "min_score", "categories", "engines", "safesearch")
        },
    ),
    # maxLength/section cover the read-a-page use case; the rest is slicing
    # machinery the model can express with those two.
    "web_url_read": ToolTransformConfig(
        arguments={arg: ArgTransformConfig(hide=True) for arg in ("startChar", "paragraphRange", "readHeadings")}
    ),
}

# --- context7 --------------------------------------------------------------

# Upstream ships a ~500-token description that mostly restates examples and
# internal scoring. The override keeps the contract (name in -> candidates
# with trust scores out) in a fraction of the tokens.
CONTEXT7_TRANSFORMS = {
    "resolve-library-id": ToolTransformConfig(
        description=(
            "Resolve a natural-language product/framework/library name to a Context7 "
            "library ID (e.g. 'react' -> '/facebook/react'). Returns candidate "
            "libraries with trust scores and their IDs; pass the best ID to "
            "context7_query-docs."
        )
    ),
}

# --- memory (basic-memory) -------------------------------------------------

# Every memory project lives in its own directory under this root, on the
# data volume. basic-memory enforces it when BASIC_MEMORY_PROJECT_ROOT is set
# (passed to the child below): create_memory_project then ignores the
# caller's path and creates <root>/<permalink of the name>, so an agent cannot
# scatter a knowledge base anywhere else in the container.
BM_PROJECT_ROOT = os.path.join(BM_CONFIG_DIR, "projects")

# basic-memory serves 21 tools. Only the ones that add nothing a served tool
# does not already do are dropped:
#  - search / fetch: the ChatGPT-connector pair, duplicates of search_notes
#    and read_content;
#  - view_note: read_note plus an instruction to render it as an artifact;
#  - list_workspaces: cloud workspaces only; this install is local, so it can
#    only answer with an error.
MEMORY_DISABLED = disabled("search", "fetch", "view_note", "list_workspaces")


# Cloud-workspace plumbing, hidden on every tool that carries it. `workspace`
# routes a call to a cloud workspace, which a local install rejects outright;
# `project_id` disambiguates one project name living in several workspaces,
# which cannot happen here (names are unique), and its upstream description
# costs ~75 tokens on each of 13 tools. Hiding an arg only drops it from the
# schema: the call still reaches basic-memory with the arg's own default.
# The verbose upstream `project` descriptions (several cite cloud workspaces)
# are replaced by one short line.
MEMORY_WORKSPACE_TOOLS = {"write_note", "edit_note", "create_memory_project", "delete_project"}
MEMORY_PROJECT_TOOLS = {
    "build_context", "delete_note", "edit_note", "list_directory", "move_note", "read_content",
    "read_note", "recent_activity", "search_notes", "write_note",
    "schema_validate", "schema_infer", "schema_diff",
}
MEMORY_PROJECT_ARG = ArgTransformConfig(
    description="Project name (from list_memory_projects); omit for the default project."
)

# Tool-level overrides on top of the cloud trims.
MEMORY_OVERRIDES: dict[str, dict] = {
    # project_path is required upstream but ignored under the project root,
    # so it is hidden with a placeholder value and the description says where
    # the project really goes.
    "create_memory_project": {
        "description": (
            "Create a new memory project. Its directory is always "
            f"{BM_PROJECT_ROOT}/<project_name> on the node's data volume; no other "
            "location is possible. Optionally make it the default project."
        ),
        "arguments": {"project_path": ArgTransformConfig(hide=True, default="")},
    },
    # Upstream explains how project_id disambiguates cloud workspaces, which
    # this install has none of.
    "list_memory_projects": {"description": "List all memory projects with their status."},
    # Upstream repeats the timeframe examples its `timeframe` arg already lists.
    "recent_activity": {"description": "Get recent activity for a project or across all projects."},
    # The upstream description is a 230-token essay about memory:// URIs; the
    # mechanism matters, the essay does not.
    "build_context": {
        "description": (
            "Build context from a memory:// URI (e.g. memory://bastion/project-notes) "
            "to continue a previous conversation thread with its linked notes."
        )
    },
}


def memory_transforms() -> dict[str, ToolTransformConfig]:
    transforms = dict(MEMORY_DISABLED)
    for tool in MEMORY_WORKSPACE_TOOLS | MEMORY_PROJECT_TOOLS | MEMORY_OVERRIDES.keys():
        override = MEMORY_OVERRIDES.get(tool, {})
        arguments = dict(override.get("arguments", {}))
        if tool in MEMORY_WORKSPACE_TOOLS:
            arguments["workspace"] = ArgTransformConfig(hide=True)
        if tool in MEMORY_PROJECT_TOOLS:
            arguments["project_id"] = ArgTransformConfig(hide=True)
            arguments["project"] = MEMORY_PROJECT_ARG
        fields = {key: value for key, value in override.items() if key != "arguments"}
        transforms[tool] = ToolTransformConfig(arguments=arguments, **fields)
    return transforms


MEMORY_TRANSFORMS = memory_transforms()

def build_backends() -> list[tuple[str, StdioTransport, dict[str, ToolTransformConfig] | None]]:
    context7_key = read_secret_file("MCP_CONTEXT7_API_KEY_FILE", "/run/secrets/context7_api_key")
    context7_env = {"CONTEXT7_API_KEY": context7_key} if context7_key else {}

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
            SEARXNG_TRANSFORMS,
        ),
        # Up-to-date library/API docs from context7.com.
        ("context7", child_transport("context7-mcp", [], context7_env), CONTEXT7_TRANSFORMS),
        # Per-project knowledge base: markdown notes + SQLite index + semantic
        # search. Config, database and projects live in the data dir.
        (
            "memory",
            child_transport(
                "/opt/basic-memory-venv/bin/basic-memory",
                ["mcp"],
                {"BASIC_MEMORY_CONFIG_DIR": BM_CONFIG_DIR, "BASIC_MEMORY_PROJECT_ROOT": BM_PROJECT_ROOT},
            ),
            MEMORY_TRANSFORMS,
        ),
        # Time and timezone conversion, pinned to the host's bastion.conf TZ.
        (
            "time",
            child_transport(
                "/opt/time-venv/bin/python",
                ["-m", "mcp_server_time", "--local-timezone", os.environ.get("TIMEZONE", "UTC")],
            ),
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


# Server-level instructions: MCP clients surface these to the model once per
# session (Claude Code puts them in the system prompt), so they carry the
# cross-namespace guidance no single upstream tool description can - including
# the served names, since upstream descriptions still cite unprefixed ones
# (mcp-searxng's search tool points at `web_url_read`).
INSTRUCTIONS = """\
Bastion node tools, namespaced <namespace>_<tool>:
- searxng: private metasearch. searxng_web_search finds pages; read a result's full text with searxng_web_url_read.
- context7: current library/framework docs. Call context7_resolve-library-id first, then context7_query-docs with the returned ID. Prefer it over web search for API questions.
- memory: per-project knowledge base of markdown notes. List projects with memory_list_memory_projects (create one with memory_create_memory_project; the node places it, you only name it), then memory_search_notes to find and memory_write_note to store. Durable facts only, never secrets.
- time: current time and timezone conversion; defaults to the node's local timezone.
"""


def mount_child(
    gateway: FastMCP,
    name: str,
    transport: StdioTransport,
    transforms: dict[str, ToolTransformConfig] | None = None,
) -> None:
    """Mount one child under its namespace, optionally trimmed.

    FastMCP's own mount() accepts tool_names only as a rename map - it cannot
    disable a tool, rewrite a description, or hide an argument - so this walks
    the same internal path (provider + ToolTransform + add_provider) with the
    full transform config, renames included as ToolTransformConfig(name=...).
    One persistent Client per child: connected lazily on first use and reused
    across requests (a crashed child is reconnected on the next call, and only
    its own tools fail in the meantime).
    """
    proxy = create_proxy(Client(transport), name=name)
    provider = FastMCPProvider(proxy)
    if transforms:
        provider = provider.wrap_transform(ToolTransform(transforms))
    gateway.add_provider(provider, namespace=name)


def warn_projects_outside_root(bm_config: str) -> None:
    """Name every registered project that lives outside BM_PROJECT_ROOT.

    basic-memory enforces the root only when a project is created, so a
    project registered before the root existed keeps working where it is.
    Logged at startup so an operator can unregister it (memory_delete_project
    keeps its files) and recreate it under the root.
    """
    try:
        with open(bm_config, encoding="utf-8") as handle:
            projects = json.load(handle).get("projects", {})
    except (OSError, ValueError, AttributeError):
        return
    root = os.path.realpath(BM_PROJECT_ROOT)
    for name, entry in projects.items():
        path = entry.get("path") if isinstance(entry, dict) else None
        if isinstance(path, str) and os.path.commonpath([root, os.path.realpath(path)]) != root:
            print(
                f"mcp-gateway: memory project {name!r} is outside {BM_PROJECT_ROOT} ({path}); "
                "new projects can only be created under the root",
                file=sys.stderr,
            )


def seed_volumes() -> None:
    """Create first-run basic-memory state on the data volume, idempotently.

    Nothing here touches the network: the embedding model was baked into the
    image at build time and is copied into place. Without the config seed
    basic-memory would create its default project under /root (outside the
    volume, lost on recreate) and phone home daily for update checks.
    """
    bm_config = os.path.join(BM_CONFIG_DIR, "config.json")
    if not os.path.exists(bm_config):
        projects = os.path.join(BM_CONFIG_DIR, "projects", "main")
        os.makedirs(projects, exist_ok=True)
        with open(bm_config, "w", encoding="utf-8") as handle:
            handle.write(
                '{"env":"dev","projects":{"main":{"path":"%s","mode":"local"}},"default_project":"main",'
                '"auto_update":false}' % projects.replace("\\", "/")
            )

    warn_projects_outside_root(bm_config)

    fastembed_dst = os.path.join(BM_CONFIG_DIR, "fastembed_cache")
    if not os.path.exists(fastembed_dst) and os.path.isdir("/opt/fastembed-seed"):
        shutil.copytree("/opt/fastembed-seed", fastembed_dst)


def build_app(token: str):
    gateway = FastMCP(name="bastion-mcp", instructions=INSTRUCTIONS)
    namespaces = []
    for name, transport, transforms in build_backends():
        mount_child(gateway, name, transport, transforms)
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
    seed_volumes()
    app = build_app(token)
    uvicorn.run(
        app,
        host=os.environ.get("MCP_HOST", "0.0.0.0"),
        port=int(os.environ.get("MCP_PORT", "8811")),
        log_level="info",
    )


if __name__ == "__main__":
    main()
