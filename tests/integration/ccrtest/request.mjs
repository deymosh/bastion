/**
 * One /v1/messages request through the test CCR gateway, as Claude Code
 * would send it to the Claude Code provider. Prints "<status> <body>";
 * argv[2] = "stream" sends a streaming request (the body is the raw SSE).
 */
const stream = process.argv[2] === "stream";
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
    messages: [{ role: "user", content: "hi" }],
  }),
});
console.log(response.status, (await response.text()).replace(/\s+/g, " ").slice(0, 4000));
