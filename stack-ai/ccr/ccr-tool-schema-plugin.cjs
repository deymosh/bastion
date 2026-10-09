"use strict";
/**
 * Bastion: rewrite the tool schemas of every upstream request so each
 * provider accepts them (see ccr-tool-schema-sanitizer.cjs for what is
 * removed and why), as a request transform inside CCR's core gateway.
 *
 * Where it runs: the core gateway (the ai-gateway process CCR supervises)
 * applies `beforeUpstream` request transforms once per upstream attempt,
 * after routing has settled - CCR's own router, including Claude Code
 * subagent-tag routing, runs earlier, in the `beforeRouting` stage - and
 * hands them the routed model and both forms of the request:
 *  - `requestBody`, the client's body, which a passthrough route (e.g.
 *    Anthropic Messages in, Anthropic Messages out) sends as it is;
 *  - `standardRequest`, the gateway's normalized request, from which a
 *    converting route builds the provider's body.
 * The transform cleans the tools in both, in place, and returns nothing, so
 * the gateway keeps its own choice between the two paths.
 *
 * Why the core gateway and not a CCR-side request transform
 * (`registerGatewayRequestTransform`): any CCR-side transform makes CCR put
 * its own compatibility server in front of the core gateway, proxying every
 * request through one more process. A core-gateway transform keeps CCR on
 * its single gateway runtime and still sees every route.
 *
 * One file, two loaders, like ccr-oauth-refresh-plugin.cjs:
 *  - CCR loads it as a plugin (registered by ccr-enable-plugins.mjs with the
 *    `trusted-code` and `core-gateway-plugins` permissions); `setup` hands
 *    this same file to the core gateway as a module plugin;
 *  - the core gateway imports it, reads `manifest`, and calls
 *    `createGatewayPlugin`.
 *
 * Never fails a request: the transform is fail-open, so one that throws is
 * skipped and the request goes out as it came in.
 */

const { sanitizeTools } = require("./ccr-tool-schema-sanitizer.cjs");

const KEY = "bastion-tool-schema-sanitizer";

/**
 * Read by the core gateway when it imports this module: shown in its plugin
 * catalog. `capabilities` is validated against what createGatewayPlugin
 * returns; a name it does not return fails the load.
 */
const manifest = {
  name: KEY,
  description:
    "Removes tool-schema regexes and JSON Schema keywords some providers reject, and drops the tools "
    + "CCR_DROP_TOOLS names for a routed model; fail-open.",
  capabilities: ["requestTransforms"],
};

// The gateway hands its plugins no logger: each change is logged to stdout
// once per process, so a long session does not flood the log.
const reported = new Set();
const log = {
  info(line, key = line) {
    if (reported.has(key)) return;
    reported.add(key);
    console.log(`[${KEY}] ${line}`);
  },
};

/**
 * The core gateway's `beforeUpstream` request transform. The drop rules
 * match against the routed model and the target provider's name, so a rule
 * can name either ("deepseek" matches model deepseek-v4 or a provider
 * called "DeepSeek").
 */
function transform(input) {
  const target = [input?.model, input?.targetProviderConfig?.name].filter(Boolean).join(" ");
  for (const request of [input?.requestBody, input?.standardRequest]) {
    if (request && typeof request === "object" && Array.isArray(request.tools)) {
      request.tools = sanitizeTools(request.tools, { target, log });
    }
  }
}

function createGatewayPlugin() {
  return {
    requestTransforms: [
      {
        key: KEY,
        stage: "beforeUpstream",
        execution: { failureMode: "fail_open" },
        transform,
      },
    ],
  };
}

module.exports = {
  /** CCR plugin entry point: hands this file to the core gateway. */
  async setup(ctx) {
    ctx.registerCoreGatewayPlugin({ key: KEY, enabled: true, modulePath: __filename });
    ctx.logger?.info?.(`[${KEY}] tool-schema sanitizer registered with the core gateway`);
  },
  createGatewayPlugin,
  manifest,
};
// Named exports spelled out, so the core gateway's ESM import() finds them.
module.exports.createGatewayPlugin = createGatewayPlugin;
module.exports.manifest = manifest;
module.exports.transform = transform;
