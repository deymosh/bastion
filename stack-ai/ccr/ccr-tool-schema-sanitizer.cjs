"use strict";
/**
 * Bastion: a CCR custom router (CUSTOM_ROUTER_PATH) that never picks a model.
 * It rewrites the tool schemas of every request so each upstream accepts
 * them, then returns undefined, so CCR's own routing (rules, subagent tags,
 * the default) decides the model exactly as if it were not there.
 *
 * Why a custom router and not a routing rule: CCR calls the custom router for
 * every request, before any policy. A routing rule runs only when no earlier
 * policy matched: a Claude Code subagent tagged with a target model is routed
 * before the rules, so a rule never sees it; and a rule that matches stops
 * the rules after it.
 *
 * What it fixes:
 *  - A `pattern` only a backtracking engine understands: a digit escape
 *    (`\0`, `\1`...), a lookaround (`(?=`, `(?!`, `(?<=`, `(?<!`), an atomic
 *    group (`(?>`) or a named backreference (`\k<`). JavaScript and PCRE
 *    accept them, but linear-time engines (RE2, Rust's regex) reject them,
 *    and a provider that compiles tool schemas then refuses the whole
 *    request: DeepSeek answers HTTP 400 to Claude Code's `Artifact` tool
 *    ("^[^\\0]*$") and `ArtifactData` tool (`collection`/`doc_id` start with
 *    "(?!\\.\\.?...)").
 *  - The JSON Schema 2020-12 keywords `prefixItems` and `propertyNames`,
 *    which strict schema compilers also reject (`ArtifactData`'s `where`
 *    tuples, `Artifact`'s `files` map).
 *    Dropping either loses nothing: they only steer the model, and Claude
 *    Code validates each tool call against its own schema anyway.
 *  - Optionally, tools a provider cannot take at all, by model:
 *    CCR_DROP_TOOLS="deepseek=Artifact,ArtifactData;gemini=Monitor" drops
 *    those tools when the target model's name contains the text before `=`
 *    (case-insensitive). Off when unset.
 *
 * Fail-open: CCR catches and logs anything thrown here and routes as usual.
 */

/**
 * Not itself escaped, and then: a backslash before a digit or `k<`, or an
 * opening group of the lookaround or atomic kind.
 */
const BACKTRACKING_ONLY = /(?:^|[^\\])(?:\\\\)*(?:\\(?:[0-9]|k<)|\((?:\?[=!>]|\?<[=!]))/;

/** Schema keywords some upstream schema compiler rejects. */
const UNPORTABLE_KEYWORDS = ["prefixItems", "propertyNames"];

/** Keywords whose value maps names to schemas, not keywords to values. */
const SCHEMA_MAPS = new Set(["properties", "patternProperties", "$defs", "definitions", "dependentSchemas"]);

/** Patterns some upstream regex engine rejects. */
function isUnportablePattern(pattern) {
  return BACKTRACKING_ONLY.test(pattern);
}

/**
 * Remove every unportable `pattern` and keyword under `schema`, in place.
 * Returns how many were removed.
 */
function sanitizeSchema(schema) {
  let removed = 0;
  const walk = (node) => {
    if (Array.isArray(node)) {
      node.forEach(walk);
      return;
    }
    if (!node || typeof node !== "object") {
      return;
    }
    if (typeof node.pattern === "string" && isUnportablePattern(node.pattern)) {
      delete node.pattern;
      removed += 1;
    }
    for (const keyword of UNPORTABLE_KEYWORDS) {
      if (keyword in node) {
        delete node[keyword];
        removed += 1;
      }
    }
    for (const [key, value] of Object.entries(node)) {
      if (SCHEMA_MAPS.has(key) && value && typeof value === "object" && !Array.isArray(value)) {
        // A property named "pattern" or "prefixItems" is a schema to clean,
        // never a keyword to drop.
        Object.values(value).forEach(walk);
      } else if (key !== "pattern") {
        walk(value);
      }
    }
  };
  walk(schema);
  return removed;
}

/** A tool's input schema, in the Anthropic or the OpenAI shape. */
function schemaOf(tool) {
  return tool?.input_schema ?? tool?.parameters ?? tool?.function?.parameters;
}

/**
 * The text of a CCR client model id, whose hex tail (`...-h<hex>`) encodes
 * the "Provider/model" it stands for; any other id as it is.
 */
function decodeModel(value) {
  if (typeof value !== "string") {
    return "";
  }
  const match = value.match(/-h([0-9a-fA-F]{16,})(?:\[1m\])?\s*$/);
  if (!match || match[1].length % 2 !== 0) {
    return value;
  }
  return `${value} ${Buffer.from(match[1], "hex").toString("utf8")}`;
}

/** CCR_DROP_TOOLS as [[modelNeedle, Set(toolNames)], ...]. */
function parseDropTools(raw) {
  if (!raw) {
    return [];
  }
  return raw
    .split(";")
    .map((entry) => entry.split("="))
    .filter(([needle, tools]) => needle?.trim() && tools?.trim())
    .map(([needle, tools]) => [
      needle.trim().toLowerCase(),
      new Set(tools.split(",").map((t) => t.trim()).filter(Boolean)),
    ]);
}

/** The tool names to drop for a request routed to `target`. */
function toolsToDrop(target, rules) {
  const lower = target.toLowerCase();
  const names = new Set();
  for (const [needle, tools] of rules) {
    if (lower.includes(needle)) {
      tools.forEach((t) => names.add(t));
    }
  }
  return names;
}

const reported = new Set();

/** Log a change once per process, so a long session does not flood the log. */
function reportOnce(log, key, message) {
  if (!reported.has(key)) {
    reported.add(key);
    log?.info?.(`[tool-schema-sanitizer] ${message}`);
  }
}

/** Sanitize `request.body.tools` in place. Exported for the tests. */
function sanitizeRequest(request, env = process.env) {
  const tools = request?.body?.tools;
  if (!Array.isArray(tools) || tools.length === 0) {
    return;
  }
  const log = request.log;
  // The subagent's tagged target if any (CCR has already taken the tag out
  // of the prompt), else the model the client asked for.
  const target = decodeModel(request.builtInSubagentModel || request.body.model);
  const drop = toolsToDrop(target, parseDropTools(env.CCR_DROP_TOOLS));
  if (drop.size > 0) {
    const kept = tools.filter((tool) => !drop.has(tool?.name));
    if (kept.length !== tools.length) {
      request.body.tools = kept;
      reportOnce(log, `drop:${target}`, `dropped ${[...drop].join(", ")} for ${target}`);
    }
  }
  for (const tool of request.body.tools) {
    const removed = sanitizeSchema(schemaOf(tool));
    if (removed > 0) {
      reportOnce(log, `pattern:${tool.name}`, `removed ${removed} unportable pattern(s)/keyword(s) from ${tool.name}`);
    }
  }
}

async function toolSchemaSanitizer(request) {
  sanitizeRequest(request);
  return undefined;
}

module.exports = toolSchemaSanitizer;
module.exports.sanitizeRequest = sanitizeRequest;
module.exports.sanitizeSchema = sanitizeSchema;
module.exports.isUnportablePattern = isUnportablePattern;
module.exports.decodeModel = decodeModel;
