"""End-to-end exercise of the Bastion MCP gateway.

Runs inside the throwaway test project's client container against
http://mcp-gateway:8811/mcp using the official MCP SDK (an independent
implementation, not fastmcp). Exits non-zero on the first failed assertion;
prints one line per check. The bearer token is passed as argv[1].
"""

import asyncio
import sys

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import create_mcp_http_client, streamable_http_client

URL = "http://mcp-gateway:8811"
MCP_URL = URL + "/mcp"
NAMESPACES = ("searxng", "context7", "memory", "time")

# Tools the gateway must NOT serve: searxng/memory tools dropped by the trim
# transforms.
FORBIDDEN = (
    "searxng_instance_info",
    "searxng_search_suggestions",
    "memory_view_note",
    "memory_list_workspaces",
    "memory_search",
    "memory_fetch",
)

# Tools that must stay served: dropping one of these hides real capability.
REQUIRED = (
    "memory_delete_project",
    "memory_schema_validate",
    "memory_schema_infer",
    "memory_schema_diff",
    "memory_basic_memory_diagnostics",
)

checks = 0


def ok(label):
    global checks
    checks += 1
    print(f"  ok   {label}")


def die(label, detail=""):
    print(f"  FAIL {label} {detail}")
    sys.exit(1)


async def auth_and_health(token):
    body = '{"jsonrpc":"2.0","method":"tools/list","id":1}'
    headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    r = httpx.post(MCP_URL, content=body, headers=headers, timeout=10)
    (ok("missing token -> 401") if r.status_code == 401 else die("missing token", f"got {r.status_code}"))
    if r.headers.get("www-authenticate", "").lower() != "bearer":
        die("401 carries WWW-Authenticate: Bearer", r.headers.get("www-authenticate"))
    ok("401 carries WWW-Authenticate: Bearer")
    r = httpx.post(MCP_URL + "?token=" + token, content=body, headers=headers, timeout=10)
    (ok("token in query param rejected") if r.status_code == 401 else die("query-param token", f"got {r.status_code}"))
    r = httpx.get(URL + "/healthz", timeout=10)
    if r.status_code != 200:
        die("healthz without token", f"got {r.status_code}")
    if "token" in r.text.lower() or "secret" in r.text.lower():
        die("healthz body leaks credential-ish strings", r.text[:120])
    ok("healthz open and exposes no credential material")


async def mcp_session(token):
    http_client = create_mcp_http_client(headers={"Authorization": f"Bearer {token}"})
    async with streamable_http_client(MCP_URL, http_client=http_client) as streams:
        read, write, *rest = streams
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            if "searxng_web_url_read" not in (init.instructions or ""):
                die("initialize carries the gateway instructions", repr(init.instructions)[:120])
            ok("initialize carries the gateway instructions")
            tools = (await session.list_tools()).tools
            names = [t.name for t in tools]
            if len(names) != len(set(names)):
                die("tool names are unique", str(names))
            bad = [n for n in names if not n.startswith(NAMESPACES)]
            if bad:
                die("every tool is namespaced", str(bad))
            per_ns = {ns: [n for n in names if n.startswith(ns + "_")] for ns in NAMESPACES}
            empty = [ns for ns, v in per_ns.items() if not v]
            if empty:
                die("every namespace exposes tools", str(empty))
            served = [n for n in FORBIDDEN if n in names]
            if served:
                die("trimmed/unconfigured tools are not served", str(served))
            missing = [n for n in REQUIRED if n not in names]
            if missing:
                die("useful tools stay served", str(missing))
            by_name = {t.name: t for t in tools}
            leaked = [
                n for n in ("memory_write_note", "memory_edit_note", "memory_create_memory_project", "memory_delete_project")
                if "workspace" in by_name[n].input_schema.get("properties", {})
            ]
            if leaked:
                die("cloud-only workspace arg is hidden", str(leaked))
            leaked = [n for n in names if n.startswith("memory_") and "project_id" in by_name[n].input_schema.get("properties", {})]
            if leaked:
                die("cloud-only project_id arg is hidden", str(leaked))
            if "project_path" in by_name["memory_create_memory_project"].input_schema.get("properties", {}):
                die("create_memory_project takes no path")
            ok(f"tools/list: {len(names)} unique namespaced tools across {len(NAMESPACES)} namespaces, trims hold")

            r = await session.call_tool("time_get_current_time", {"timezone": "Europe/Madrid"})
            if r.is_error or "Europe/Madrid" not in r.content[0].text:
                die("time_get_current_time", r.content[0].text[:120])
            ok("time namespace answers with the configured timezone")

            r = await session.call_tool("searxng_web_search", {"query": "model context protocol"})
            if r.is_error or len(r.content[0].text) < 200:
                die("searxng_web_search", r.content[0].text[:120])
            ok("searxng namespace searches the internal SearXNG instance")

            # memory: per-project knowledge base. Create a project, write a
            # note into it, find it again with a paginated search.
            r = await session.call_tool("memory_create_memory_project", {"project_name": "e2e"})
            if r.is_error or "/data/memory/projects/e2e" not in r.content[0].text:
                die("a new project lands under the project root", r.content[0].text[:200])
            ok("memory projects are created under /data/memory/projects")
            await session.call_tool(
                "memory_write_note",
                {
                    "title": "E2E check note",
                    "directory": "",
                    "content": "integration run marker",
                    "project": "e2e",
                },
            )
            r = await session.call_tool(
                "memory_search_notes",
                {"query": "marker", "project": "e2e", "page": 1, "page_size": 5},
            )
            if r.is_error or "E2E check note" not in r.content[0].text:
                die("memory project+write+search round-trip", r.content[0].text[:120])
            ok("memory namespace round-trips per-project with paginated search")

            r = await session.call_tool(
                "context7_resolve-library-id", {"libraryName": "react", "query": "hooks"}
            )
            if r.is_error or "Available Libraries" not in r.content[0].text:
                die("context7_resolve-library-id", r.content[0].text[:120])
            ok("context7 namespace reaches the context7 API")


async def main():
    token = sys.argv[1]
    await auth_and_health(token)
    await mcp_session(token)
    print(f"  all {checks} checks passed")


asyncio.run(main())
