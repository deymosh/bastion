#!/usr/bin/env node
/**
 * Bastion: wire the bundled tool-schema sanitizer into CCR, before CCR
 * starts, in two places:
 *  - CUSTOM_ROUTER_PATH -> ccr-tool-schema-sanitizer.cjs (the original hook);
 *  - a `plugins[]` entry for ccr-tool-schema-plugin.cjs, a gateway request
 *    transform. CCR applies those to every upstream request after routing,
 *    including requests routed by a Claude Code subagent tag, which the
 *    custom router did not protect in practice.
 *
 * CCR keeps its configuration in SQLite (config.sqlite, table app_config,
 * row "default", a JSON document) and its UI has no field for
 * CUSTOM_ROUTER_PATH; it saves back the whole document it loaded, so a value
 * set here survives later edits in the UI.
 *
 * Leaves the configuration alone when:
 *  - there is none yet (a fresh install): CCR writes it on first start, and
 *    the next container start sets the path;
 *  - CUSTOM_ROUTER_PATH already names another router: the operator's own
 *    choice wins (it is logged, so the sanitizer's absence is not silent);
 *  - a plugin with the same id already exists (pointing elsewhere, or
 *    disabled by the operator): also left as it is, and logged.
 *
 * Never fatal: CCR always starts, with or without the sanitizer.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";

const TAG = "[ccr-enable-sanitizer]";
const SANITIZER = process.env.CCR_SANITIZER_PATH ?? "/usr/local/lib/ccr/ccr-tool-schema-sanitizer.cjs";
const PLUGIN = process.env.CCR_SANITIZER_PLUGIN_PATH ?? "/usr/local/lib/ccr/ccr-tool-schema-plugin.cjs";
const PLUGIN_ID = "bastion-tool-schema-sanitizer";
const DB_FILE = process.env.CCR_CONFIG_DB ?? join(process.env.HOME ?? "/data", ".claude-code-router", "config.sqlite");

function main() {
  if (!existsSync(DB_FILE)) {
    console.log(`${TAG} no CCR configuration yet; the sanitizer is set on the next start`);
    return;
  }
  // Loaded only when there is a database to open, so an older Node without
  // node:sqlite fails here, inside the try, and CCR still starts.
  return import("node:sqlite").then(({ DatabaseSync }) => {
    const db = new DatabaseSync(DB_FILE);
    try {
      const row = db.prepare("SELECT value_json FROM app_config WHERE key = 'default'").get();
      if (!row) {
        console.log(`${TAG} no CCR configuration yet; the sanitizer is set on the next start`);
        return;
      }
      const config = JSON.parse(row.value_json);
      const changedRouter = enableCustomRouter(config);
      const changedPlugin = enablePlugin(config);
      if (changedRouter || changedPlugin) {
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
    console.log(`${TAG} already enabled`);
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

/**
 * Adds the request-transform plugin entry unless one with its id exists.
 * Returns whether it changed. The two permissions are the minimum CCR
 * requires to load a local module and register a request transform.
 */
function enablePlugin(config) {
  const plugins = Array.isArray(config.plugins) ? config.plugins : [];
  const existing = plugins.find((plugin) => plugin?.id === PLUGIN_ID);
  if (existing) {
    const ours = existing.module === PLUGIN && existing.enabled !== false;
    console.log(ours
      ? `${TAG} request-transform plugin already enabled`
      : `${TAG} plugin ${PLUGIN_ID} was changed by the operator; leaving it`);
    return false;
  }
  config.plugins = [
    ...plugins,
    {
      id: PLUGIN_ID,
      enabled: true,
      module: PLUGIN,
      surfaces: { apps: false, gateway: true, provider: false },
      permissions: ["trusted-code", "gateway-request-transforms"],
    },
  ];
  console.log(`${TAG} enabled request-transform plugin: ${PLUGIN}`);
  return true;
}

try {
  await main();
} catch (error) {
  console.log(`${TAG} skipped: ${error?.message ?? error}`);
}
