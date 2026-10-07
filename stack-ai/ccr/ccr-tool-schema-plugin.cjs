"use strict";
/**
 * Bastion: a CCR gateway plugin that runs the tool-schema sanitizer
 * (ccr-tool-schema-sanitizer.cjs) as a request transform.
 *
 * Why a plugin as well as the custom router: CCR applies plugin request
 * transforms to every upstream request after routing has settled, on the
 * provider-format body it is about to send. The custom router alone did not
 * protect requests routed by a Claude Code subagent tag: a general-purpose
 * subagent routed to DeepSeek by tag still reached the provider with
 * `Artifact`'s "^[^\\0]*$" pattern and got HTTP 400, while the same body sent
 * with the DeepSeek model id directly went through. Dropping that one pattern
 * on the tag-routed request was enough to fix it, so the sanitizing has to
 * happen at a stage every route passes.
 *
 * Registered by ccr-enable-plugins.mjs as a `plugins[]` entry with the
 * `trusted-code` and `gateway-request-transforms` permissions. It never
 * picks a model and never fails a request: a transform that throws is
 * logged by CCR and skipped.
 */

const { sanitizeRequest } = require("./ccr-tool-schema-sanitizer.cjs");

/** CCR's request transform: returns the cleaned body, or null when unchanged. */
function transform(input, context) {
  const body = input?.body;
  if (!body || !Array.isArray(body.tools) || body.tools.length === 0) {
    return null;
  }
  const before = JSON.stringify(body.tools);
  // input.body is CCR's own clone, so cleaning it in place is safe. The
  // routed model (the provider-side name) feeds CCR_DROP_TOOLS matching.
  sanitizeRequest({
    body,
    builtInSubagentModel: input.routedModel,
    log: context?.logger,
  });
  return JSON.stringify(body.tools) === before ? null : { body };
}

module.exports = {
  async setup(ctx) {
    ctx.registerGatewayRequestTransform({ id: "tool-schema-sanitizer", transform });
    ctx.logger?.info?.("tool-schema sanitizer request transform registered");
  },
};
module.exports.transform = transform;
