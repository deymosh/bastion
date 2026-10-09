/**
 * One /v1/messages request through the test CCR gateway, as Claude Code
 * would send it to the Claude Code provider. Prints "<status> <body>";
 * argv[2] = "stream" sends a streaming request (the body is the raw SSE),
 * "tools" sends Claude Code-like tools whose schemas some providers reject.
 */
const stream = process.argv[2] === "stream";
const tools = process.argv[2] !== "tools" ? undefined : [
  {
    name: "Artifact",
    input_schema: {
      type: "object",
      properties: {
        // Claude Code's own pattern: a backslash then 0, which RE2-style
        // engines reject.
        file_paths: { type: "array", items: { type: "string", pattern: String.raw`^[^\0]*$` } },
        asset_ids: { type: "array", items: { type: "string", pattern: "^[0-9a-f]{32}$" } },
        files: { type: "object", propertyNames: { maxLength: 512 } },
      },
    },
  },
  { name: "DropMe", input_schema: { type: "object" } },
  { name: "Read", input_schema: { type: "object" } },
];
const response = await fetch("http://127.0.0.1:3456/v1/messages", {
  method: "POST",
  headers: {
    "content-type": "application/json",
    "anthropic-version": "2023-06-01",
    "x-api-key": "ccrtest-gateway-key",
  },
  body: JSON.stringify({
    model: "Claude Code API,claude-sonnet-5",
    max_tokens: 16,
    stream,
    ...(tools ? { tools } : {}),
    messages: [{ role: "user", content: "hi" }],
  }),
});
console.log(response.status, (await response.text()).replace(/\s+/g, " ").slice(0, 4000));
