#!/usr/bin/env bash
# The showme and highlight commands, run against stand-ins for the two editor
# extensions: a stdio MCP bridge for ShowMe and an HTTP MCP server for Code
# Walkthrough. Both stand-ins answer a tool call with the call they received.
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly SHOWME="$repo_root/workspace-images/base-dev/scripts/showme"
readonly HIGHLIGHT="$repo_root/workspace-images/base-dev/scripts/highlight"
readonly T="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

fail=0
chk() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }

# ---------------------------------------------------------------------------
# showme
# ---------------------------------------------------------------------------
cat > "$T/fake-bridge.js" <<'EOF'
const readline = require("readline");
const reply = (id, result) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n");
readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  if (message.method === "initialize") reply(message.id, { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "fake" } });
  if (message.method === "tools/list") reply(message.id, { tools: [{ name: "annotate", description: "Points at code. More detail here.", inputSchema: { type: "object", properties: { items: {} } } }] });
  if (message.method === "tools/call") {
    const refused = message.params.name === "refused_tool";
    reply(message.id, { isError: refused, content: [{ type: "text", text: refused ? "ShowMe is off" : JSON.stringify(message.params) }] });
  }
});
EOF

echo "===== showme ====="
export SHOWME_BRIDGE="$T/fake-bridge.js"
chk "showme: lists tools, one line each"  '[ "$(node "$SHOWME" tools)" = "annotate: Points at code." ]'
chk "showme: prints one tool schema"      'node "$SHOWME" tools annotate | grep -q "\"items\""'
chk "showme: unknown tool name fails"     '! node "$SHOWME" tools missing 2>/dev/null'
chk "showme: passes JSON arguments"       '[ "$(node "$SHOWME" annotate "{\"reveal\":true}")" = "{\"name\":\"annotate\",\"arguments\":{\"reveal\":true}}" ]'
chk "showme: reads arguments from stdin"  '[ "$(echo "{\"mode\":\"clear\"}" | node "$SHOWME" annotate -)" = "{\"name\":\"annotate\",\"arguments\":{\"mode\":\"clear\"}}" ]'
chk "showme: no arguments means {}"       '[ "$(node "$SHOWME" list_workspaces)" = "{\"name\":\"list_workspaces\",\"arguments\":{}}" ]'
refused_out="$(node "$SHOWME" refused_tool 2>&1)" && refused_rc=0 || refused_rc=$?
chk "showme: a refused call exits 1"      '[ "$refused_rc" -eq 1 ] && [ "$refused_out" = "showme: ShowMe is off" ]'
chk "showme: invalid JSON is reported"    'grep -q "not valid JSON" <<< "$(node "$SHOWME" annotate "not json" 2>&1 || true)"'

# Without the override the bridge is found in an editor's extensions folder,
# newest version first.
unset SHOWME_BRIDGE
for version in 0.1.9 0.1.10; do
  mkdir -p "$T/home/.vscode-extensions/code-server/zvxbase.vscode-showme-$version-universal/bridge"
  sed "s/name: \"fake\"/name: \"fake-$version\"/; s/Points at code\./From $version./" "$T/fake-bridge.js" \
    > "$T/home/.vscode-extensions/code-server/zvxbase.vscode-showme-$version-universal/bridge/index.js"
done
chk "showme: finds the newest installed bridge" '[ "$(HOME="$T/home" node "$SHOWME" tools)" = "annotate: From 0.1.10." ]'
chk "showme: says so when not installed"  'grep -q "not installed" <<< "$(HOME="$T/empty-home" node "$SHOWME" tools 2>&1 || true)"'

# ---------------------------------------------------------------------------
# highlight
# ---------------------------------------------------------------------------
cat > "$T/fake-server.js" <<'EOF'
const http = require("http");
const fs = require("fs");
const server = http.createServer((request, response) => {
  let body = "";
  request.on("data", (chunk) => { body += chunk; });
  request.on("end", () => {
    const message = JSON.parse(body);
    fs.appendFileSync(process.argv[3], JSON.stringify(message.params) + "\n");
    const result = { content: [{ type: "text", text: `ok ${message.params.name}` }] };
    // Answer as a one-event SSE stream, as the real server can.
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end(`event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n\n`);
  });
});
server.listen(0, "127.0.0.1", () => fs.writeFileSync(process.argv[2], String(server.address().port)));
EOF

echo "===== highlight ====="
node "$T/fake-server.js" "$T/port" "$T/calls" & server_pid=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
export WALKTHROUGH_MCP_PORT="$(cat "$T/port")"
last_call() { tail -n "${1:-1}" "$T/calls" | head -n 1; }

cd "$T"
chk "highlight: one line"                 '[ "$(node "$HIGHLIGHT" notes.txt 7)" = "ok highlight_range" ] && [ "$(last_call)" = "{\"name\":\"highlight_range\",\"arguments\":{\"uri\":\"file://$T/notes.txt\",\"startLine\":7,\"endLine\":7,\"scroll\":true}}" ]'
node "$HIGHLIGHT" notes.txt 3 9 --note "the loop" --status "2 of 5" > /dev/null
chk "highlight: range with a note"        '[ "$(last_call 2)" = "{\"name\":\"highlight_range\",\"arguments\":{\"uri\":\"file://$T/notes.txt\",\"startLine\":3,\"endLine\":9,\"scroll\":true,\"note\":\"the loop\"}}" ]'
chk "highlight: status is set"            '[ "$(last_call)" = "{\"name\":\"set_status\",\"arguments\":{\"message\":\"2 of 5\"}}" ]'
chk "highlight: clear"                    '[ "$(node "$HIGHLIGHT" clear)" = "cleared" ] && [ "$(last_call 2)" = "{\"name\":\"clear_highlights\",\"arguments\":{}}" ]'
chk "highlight: symbols"                  'node "$HIGHLIGHT" symbols notes.txt > /dev/null && [ "$(last_call)" = "{\"name\":\"get_document_symbols\",\"arguments\":{\"uri\":\"file://$T/notes.txt\"}}" ]'
chk "highlight: where asks three things"  '[ "$(node "$HIGHLIGHT" where | wc -l)" -eq 3 ]'
chk "highlight: bad line number fails"    '! node "$HIGHLIGHT" notes.txt seven 2>/dev/null'
chk "highlight: symbols needs a file"     '! node "$HIGHLIGHT" symbols 2>/dev/null'
kill "$server_pid" 2>/dev/null || true; server_pid=""
chk "highlight: no server is reported"    'grep -q "No Code Walkthrough server" <<< "$(node "$HIGHLIGHT" notes.txt 1 2>&1 || true)"'

exit $fail
