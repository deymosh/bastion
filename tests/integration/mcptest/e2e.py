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
            await session.initialize()
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
            ok(f"tools/list: {len(names)} unique namespaced tools across {len(NAMESPACES)} namespaces")

            r = await session.call_tool("time_get_current_time", {"timezone": "Europe/Madrid"})
            if r.is_error or "Europe/Madrid" not in r.content[0].text:
                die("time_get_current_time", r.content[0].text[:120])
            ok("time namespace answers with the configured timezone")

            r = await session.call_tool("searxng_web_search", {"query": "model context protocol"})
            if r.is_error or len(r.content[0].text) < 200:
                die("searxng_web_search", r.content[0].text[:120])
            ok("searxng namespace searches the internal SearXNG instance")

            entity = {"name": "E2ECheck", "entityType": "test", "observations": ["integration run"]}
            await session.call_tool("memory_create_entities", {"entities": [entity]})
            r = await session.call_tool("memory_read_graph", {})
            if r.is_error or "E2ECheck" not in r.content[0].text:
                die("memory create+read round-trip", r.content[0].text[:120])
            ok("memory namespace round-trips and persists")

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
