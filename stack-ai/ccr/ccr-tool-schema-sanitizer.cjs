"use strict";
/**
 * Bastion: tool-schema rewriting so every upstream provider accepts Claude
 * Code's tools. A library: ccr-tool-schema-plugin.cjs applies it to each
 * routed request inside CCR's core gateway.
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
 *    those tools when the routed target (model and provider name) contains
 *    the text before `=` (case-insensitive). Off when unset.
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

/** A tool's name, in the Anthropic or the OpenAI shape. */
function nameOf(tool) {
  return tool?.name ?? tool?.function?.name;
}

/** CCR_DROP_TOOLS as [[targetNeedle, Set(toolNames)], ...]. */
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

/**
 * The tools to send to `target`: the ones CCR_DROP_TOOLS names for it left
 * out, every other one's schema cleaned in place. `log.info(line, key)` is
 * told about each change (the caller decides how often to repeat it).
 */
function sanitizeTools(tools, { target = "", log, env = process.env } = {}) {
  if (!Array.isArray(tools) || tools.length === 0) {
    return tools;
  }
  const drop = toolsToDrop(target, parseDropTools(env.CCR_DROP_TOOLS));
  const kept = drop.size > 0 ? tools.filter((tool) => !drop.has(nameOf(tool))) : tools;
  if (kept.length !== tools.length) {
    log?.info?.(`dropped ${[...drop].join(", ")} for ${target}`, `drop:${target}`);
  }
  for (const tool of kept) {
    const removed = sanitizeSchema(schemaOf(tool));
    if (removed > 0) {
      log?.info?.(`removed ${removed} unportable pattern(s)/keyword(s) from ${nameOf(tool)}`, `pattern:${nameOf(tool)}`);
    }
  }
  return kept;
}

module.exports = { sanitizeTools, sanitizeSchema, isUnportablePattern };
