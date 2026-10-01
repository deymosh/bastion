#!/usr/bin/env node
/**
 * Bastion: point CCR's CUSTOM_ROUTER_PATH at the bundled tool-schema
 * sanitizer (ccr-tool-schema-sanitizer.cjs), once, before CCR starts.
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
 *    choice wins (it is logged, so the sanitizer's absence is not silent).
 *
 * Never fatal: CCR always starts, with or without the sanitizer.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";

const TAG = "[ccr-enable-sanitizer]";
const SANITIZER = process.env.CCR_SANITIZER_PATH ?? "/usr/local/lib/ccr/ccr-tool-schema-sanitizer.cjs";
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
      const current = typeof config.CUSTOM_ROUTER_PATH === "string" ? config.CUSTOM_ROUTER_PATH.trim() : "";
      if (current === SANITIZER) {
        console.log(`${TAG} already enabled`);
        return;
      }
      if (current) {
        console.log(`${TAG} CUSTOM_ROUTER_PATH is ${current}; leaving it (the tool-schema sanitizer is off)`);
        return;
      }
      config.CUSTOM_ROUTER_PATH = SANITIZER;
      db.prepare("UPDATE app_config SET value_json = ?, updated_at = ? WHERE key = 'default'")
        .run(JSON.stringify(config), new Date().toISOString());
      console.log(`${TAG} enabled: CUSTOM_ROUTER_PATH=${SANITIZER}`);
    } finally {
      db.close();
    }
  });
}

try {
  await main();
} catch (error) {
  console.log(`${TAG} skipped: ${error?.message ?? error}`);
}
