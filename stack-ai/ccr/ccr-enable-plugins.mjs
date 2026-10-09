#!/usr/bin/env node
/**
 * Bastion: wire the bundled CCR plugins into CCR's configuration, before CCR
 * starts. Both are CCR plugins that hand themselves to CCR's core gateway as
 * module plugins (`registerCoreGatewayPlugin`), so CCR keeps serving from its
 * single gateway runtime:
 *  - bastion-tool-schema-sanitizer (ccr-tool-schema-plugin.cjs), a request
 *    transform that rewrites tool schemas some providers reject;
 *  - bastion-claude-oauth-refresh (ccr-oauth-refresh-plugin.cjs), which
 *    refreshes the Claude Code OAuth login with the `claude` CLI on a 401.
 *
 * CCR keeps its configuration in SQLite (config.sqlite, table app_config,
 * row "default", a JSON document; CCR's own entrypoint edits it the same
 * way). A UI save writes back the whole document it loaded, so what is set
 * here survives later edits in the UI.
 *
 * Each start reconciles:
 *  - a missing entry is added;
 *  - an entry with this id that loads our module gets the permissions and
 *    surfaces it needs now (an image upgrade can change them); `enabled` is
 *    the operator's and is kept;
 *  - an entry with this id that loads another module is the operator's
 *    choice, left alone and logged;
 *  - CUSTOM_ROUTER_PATH pointing at our sanitizer is removed: earlier images
 *    ran the sanitizer as a custom router too, which the core-gateway
 *    transform makes redundant. Any other router is the operator's and stays.
 * A fresh install (no configuration yet) is left alone: CCR writes it on its
 * first start, and the next start sets everything.
 *
 * Never fatal: CCR always starts, with or without these plugins.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";

const TAG = "[ccr-enable-plugins]";
const LIB = "/usr/local/lib/ccr";
// Where earlier images pointed CUSTOM_ROUTER_PATH.
const LEGACY_ROUTER = `${LIB}/ccr-tool-schema-sanitizer.cjs`;

// The minimum CCR requires to load a local module and register a core-gateway
// plugin from it; the gateway surface is the only one either plugin uses.
const PERMISSIONS = ["trusted-code", "core-gateway-plugins"];
const SURFACES = { apps: false, gateway: true, provider: false };
const PLUGINS = [
  {
    id: "bastion-tool-schema-sanitizer",
    label: "tool-schema sanitizer plugin",
    module: process.env.CCR_SANITIZER_PLUGIN_PATH ?? `${LIB}/ccr-tool-schema-plugin.cjs`,
  },
  {
    id: "bastion-claude-oauth-refresh",
    label: "OAuth refresh plugin",
    module: process.env.CCR_OAUTH_REFRESH_PLUGIN_PATH ?? `${LIB}/ccr-oauth-refresh-plugin.cjs`,
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
      let changed = removeLegacyRouter(config);
      for (const plugin of PLUGINS) {
        changed = reconcilePlugin(config, plugin) || changed;
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

/** Drops CUSTOM_ROUTER_PATH when it is our old sanitizer router. Returns whether it changed. */
function removeLegacyRouter(config) {
  if (typeof config.CUSTOM_ROUTER_PATH !== "string" || config.CUSTOM_ROUTER_PATH.trim() !== LEGACY_ROUTER) {
    return false;
  }
  config.CUSTOM_ROUTER_PATH = "";
  console.log(`${TAG} removed CUSTOM_ROUTER_PATH=${LEGACY_ROUTER}; the sanitizer now runs in the core gateway`);
  return true;
}

const sameList = (a, b) => Array.isArray(a) && a.length === b.length && a.every((item) => b.includes(item));
const sameSurfaces = (a) => Object.entries(SURFACES).every(([key, value]) => a?.[key] === value);

/** Adds or updates one plugin entry (see the header). Returns whether it changed. */
function reconcilePlugin(config, { id, label, module }) {
  const plugins = Array.isArray(config.plugins) ? config.plugins : [];
  const existing = plugins.find((plugin) => plugin?.id === id);
  if (!existing) {
    config.plugins = [...plugins, { id, enabled: true, module, surfaces: { ...SURFACES }, permissions: [...PERMISSIONS] }];
    console.log(`${TAG} enabled ${label}: ${module}`);
    return true;
  }
  if (existing.module !== module) {
    console.log(`${TAG} plugin ${id} loads ${existing.module}, not ${module}; leaving it`);
    return false;
  }
  const state = existing.enabled === false ? "disabled by the operator" : "enabled";
  if (sameList(existing.permissions, PERMISSIONS) && sameSurfaces(existing.surfaces)) {
    console.log(`${TAG} ${label} already set up (${state})`);
    return false;
  }
  existing.permissions = [...PERMISSIONS];
  existing.surfaces = { ...SURFACES };
  console.log(`${TAG} updated ${label} permissions (${state})`);
  return true;
}

try {
  await main();
} catch (error) {
  console.log(`${TAG} skipped: ${error?.message ?? error}`);
}
