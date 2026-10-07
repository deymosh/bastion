#!/usr/bin/env node
/**
 * Bastion: wire the bundled CCR extensions into CCR's configuration, before
 * CCR starts:
 *  - CUSTOM_ROUTER_PATH -> ccr-tool-schema-sanitizer.cjs (the original hook);
 *  - a `plugins[]` entry for ccr-tool-schema-plugin.cjs, a gateway request
 *    transform. CCR applies those to every upstream request after routing,
 *    including requests routed by a Claude Code subagent tag, which the
 *    custom router did not protect in practice;
 *  - a `plugins[]` entry for ccr-oauth-refresh-plugin.cjs, which hands CCR's
 *    core gateway a provider hook that refreshes the Claude Code OAuth login
 *    with the `claude` CLI when Anthropic answers 401.
 *
 * CCR keeps its configuration in SQLite (config.sqlite, table app_config,
 * row "default", a JSON document) and its UI has no field for
 * CUSTOM_ROUTER_PATH; it saves back the whole document it loaded, so values
 * set here survive later edits in the UI.
 *
 * Leaves the configuration alone when:
 *  - there is none yet (a fresh install): CCR writes it on first start, and
 *    the next container start sets everything;
 *  - CUSTOM_ROUTER_PATH already names another router: the operator's own
 *    choice wins (it is logged, so the sanitizer's absence is not silent);
 *  - a plugin with one of these ids already exists (pointing elsewhere, or
 *    disabled by the operator): also left as it is, and logged.
 *
 * Never fatal: CCR always starts, with or without these extensions.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";

const TAG = "[ccr-enable-plugins]";
const LIB = "/usr/local/lib/ccr";
const SANITIZER = process.env.CCR_SANITIZER_PATH ?? `${LIB}/ccr-tool-schema-sanitizer.cjs`;

// The permissions are the minimum CCR requires for each: loading a local
// module, plus registering a request transform / a core-gateway plugin.
const PLUGINS = [
  {
    id: "bastion-tool-schema-sanitizer",
    label: "request-transform plugin",
    module: process.env.CCR_SANITIZER_PLUGIN_PATH ?? `${LIB}/ccr-tool-schema-plugin.cjs`,
    permissions: ["trusted-code", "gateway-request-transforms"],
  },
  {
    id: "bastion-claude-oauth-refresh",
    label: "OAuth refresh plugin",
    module: process.env.CCR_OAUTH_REFRESH_PLUGIN_PATH ?? `${LIB}/ccr-oauth-refresh-plugin.cjs`,
    permissions: ["trusted-code", "core-gateway-plugins"],
  },
];

// Resolved like CCR's own entrypoint does (HOME=$CCR_DATA_DIR, default /data),
// not from this process's HOME: the wrapper runs this step through gosu, which
// resets HOME to the run user's passwd home, so HOME pointed at a directory
// with no CCR configuration and the step never enabled anything.
const DB_FILE = process.env.CCR_CONFIG_DB
  ?? join(process.env.CCR_DATA_DIR || "/data", ".claude-code-router", "config.sqlite");

function main() {
  if (!existsSync(DB_FILE)) {
    console.log(`${TAG} no CCR configuration yet; the plugins are set on the next start`);
    return;
  }
  // Loaded only when there is a database to open, so an older Node without
  // node:sqlite fails here, inside the try, and CCR still starts.
  return import("node:sqlite").then(({ DatabaseSync }) => {
    const db = new DatabaseSync(DB_FILE);
    try {
      const row = db.prepare("SELECT value_json FROM app_config WHERE key = 'default'").get();
      if (!row) {
        console.log(`${TAG} no CCR configuration yet; the plugins are set on the next start`);
        return;
      }
      const config = JSON.parse(row.value_json);
      let changed = enableCustomRouter(config);
      for (const plugin of PLUGINS) {
        changed = enablePlugin(config, plugin) || changed;
      }
      if (changed) {
        db.prepare("UPDATE app_config SET value_json = ?, updated_at = ? WHERE key = 'default'")
          .run(JSON.stringify(config), new Date().toISOString());
      }
    } finally {
      db.close();
    }
  });
}

/** Sets CUSTOM_ROUTER_PATH unless another router is configured. Returns whether it changed. */
function enableCustomRouter(config) {
  const current = typeof config.CUSTOM_ROUTER_PATH === "string" ? config.CUSTOM_ROUTER_PATH.trim() : "";
  if (current === SANITIZER) {
    console.log(`${TAG} custom router already enabled`);
    return false;
  }
  if (current) {
    console.log(`${TAG} CUSTOM_ROUTER_PATH is ${current}; leaving it (the tool-schema sanitizer is off)`);
    return false;
  }
  config.CUSTOM_ROUTER_PATH = SANITIZER;
  console.log(`${TAG} enabled: CUSTOM_ROUTER_PATH=${SANITIZER}`);
  return true;
}

/** Adds a plugin entry unless one with its id exists. Returns whether it changed. */
function enablePlugin(config, { id, label, module, permissions }) {
  const plugins = Array.isArray(config.plugins) ? config.plugins : [];
  const existing = plugins.find((plugin) => plugin?.id === id);
  if (existing) {
    const ours = existing.module === module && existing.enabled !== false;
    console.log(ours
      ? `${TAG} ${label} already enabled`
      : `${TAG} plugin ${id} was changed by the operator; leaving it`);
    return false;
  }
  config.plugins = [
    ...plugins,
    {
      id,
      enabled: true,
      module,
      surfaces: { apps: false, gateway: true, provider: false },
      permissions,
    },
  ];
  console.log(`${TAG} enabled ${label}: ${module}`);
  return true;
}

try {
  await main();
} catch (error) {
  console.log(`${TAG} skipped: ${error?.message ?? error}`);
}
