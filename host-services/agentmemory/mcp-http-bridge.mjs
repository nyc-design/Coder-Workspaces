#!/usr/bin/env node
// MCP streamable_http bridge for agentmemory.
//
// Upstream agentmemory exposes its MCP capabilities as custom REST endpoints
// (/agentmemory/mcp/{tools,call,resources,resources/read,prompts,prompts/get})
// and a stdio MCP shim (@agentmemory/mcp). It does NOT speak the streamable_http
// MCP wire protocol natively, which is what Coder Agents (chatd) needs.
//
// This bridge is a thin JSON-RPC <-> REST translator: it implements the MCP
// streamable_http transport on 0.0.0.0:3114 and forwards each method to the
// matching REST endpoint on http://127.0.0.1:3111 (same container, same
// network namespace).
//
// Methods handled:
//   initialize                     → static response (no upstream call)
//   notifications/initialized      → ack
//   tools/list                     → GET  /agentmemory/mcp/tools
//   tools/call                     → POST /agentmemory/mcp/call    {name, arguments}
//   resources/list                 → GET  /agentmemory/mcp/resources
//   resources/read                 → POST /agentmemory/mcp/resources/read   {uri}
//   prompts/list                   → GET  /agentmemory/mcp/prompts
//   prompts/get                    → POST /agentmemory/mcp/prompts/get      {name, arguments}
//
// Auth: the inbound Authorization header is forwarded verbatim to every upstream
// REST call. When AGENTMEMORY_SECRET is set on the upstream agentmemory process,
// its middleware::api-auth validates `Authorization: Bearer <secret>` via
// timingSafeCompare. The bridge does no auth itself; it is purely a translator.
//
// Streamable HTTP transport per spec rev 2025-03-26: a single POST to /mcp
// returns either application/json (single response) or text/event-stream
// (server-streamed responses). We only ever return single responses since
// agentmemory's tools complete synchronously.

import { createServer } from "node:http";

const UPSTREAM = process.env.AGENTMEMORY_URL || "http://127.0.0.1:3111";
const PORT = Number(process.env.MCP_BRIDGE_PORT || 3114);
const HOST = process.env.MCP_BRIDGE_HOST || "0.0.0.0";

const SERVER_INFO = {
  name: "agentmemory-bridge",
  version: "0.1.0",
  protocolVersion: "2024-11-05",
};

function log(...args) {
  process.stderr.write(`[mcp-http-bridge] ${args.join(" ")}\n`);
}

async function upstream(path, init = {}, authHeader) {
  const headers = { "content-type": "application/json", ...(init.headers || {}) };
  if (authHeader) headers.authorization = authHeader;
  const res = await fetch(`${UPSTREAM}${path}`, { ...init, headers });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    const err = new Error(`upstream ${path} ${res.status}: ${body.slice(0, 200)}`);
    err.status = res.status;
    throw err;
  }
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

async function dispatch(method, params, authHeader) {
  switch (method) {
    case "initialize":
      return {
        protocolVersion: SERVER_INFO.protocolVersion,
        capabilities: {
          tools: { listChanged: false },
          resources: { listChanged: false, subscribe: false },
          prompts: { listChanged: false },
        },
        serverInfo: { name: SERVER_INFO.name, version: SERVER_INFO.version },
      };

    case "notifications/initialized":
    case "notifications/cancelled":
      return null;

    case "ping":
      return {};

    case "tools/list": {
      const r = await upstream("/agentmemory/mcp/tools", { method: "GET" }, authHeader);
      return { tools: Array.isArray(r?.tools) ? r.tools : [] };
    }

    case "tools/call": {
      const r = await upstream("/agentmemory/mcp/call", {
        method: "POST",
        body: JSON.stringify({
          name: params?.name,
          arguments: params?.arguments || {},
        }),
      }, authHeader);
      if (r && Array.isArray(r.content)) return { content: r.content, isError: !!r.isError };
      return { content: [{ type: "text", text: JSON.stringify(r) }] };
    }

    case "resources/list": {
      const r = await upstream("/agentmemory/mcp/resources", { method: "GET" }, authHeader);
      return { resources: Array.isArray(r?.resources) ? r.resources : [] };
    }

    case "resources/read": {
      const r = await upstream("/agentmemory/mcp/resources/read", {
        method: "POST",
        body: JSON.stringify({ uri: params?.uri }),
      }, authHeader);
      return { contents: Array.isArray(r?.contents) ? r.contents : [] };
    }

    case "prompts/list": {
      const r = await upstream("/agentmemory/mcp/prompts", { method: "GET" }, authHeader);
      return { prompts: Array.isArray(r?.prompts) ? r.prompts : [] };
    }

    case "prompts/get": {
      const r = await upstream("/agentmemory/mcp/prompts/get", {
        method: "POST",
        body: JSON.stringify({
          name: params?.name,
          arguments: params?.arguments || {},
        }),
      }, authHeader);
      return r;
    }

    default:
      throw Object.assign(new Error(`Method not found: ${method}`), { code: -32601 });
  }
}

function isNotification(req) {
  return req.id === undefined || req.id === null;
}

async function handleMessage(req, authHeader) {
  if (!req || typeof req !== "object" || req.jsonrpc !== "2.0" || typeof req.method !== "string") {
    return {
      jsonrpc: "2.0",
      id: typeof req?.id === "string" || typeof req?.id === "number" ? req.id : null,
      error: { code: -32600, message: "Invalid Request" },
    };
  }
  try {
    const result = await dispatch(req.method, req.params || {}, authHeader);
    if (isNotification(req)) return null;
    return { jsonrpc: "2.0", id: req.id, result };
  } catch (err) {
    if (isNotification(req)) {
      log(`notification handler error for ${req.method}: ${err?.message || err}`);
      return null;
    }
    const code = err?.code || (err?.status === 401 ? -32001 : -32603);
    return {
      jsonrpc: "2.0",
      id: req.id,
      error: { code, message: err?.message || String(err) },
    };
  }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);

  if (url.pathname === "/health" && req.method === "GET") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ status: "ok", upstream: UPSTREAM }));
    return;
  }

  if (url.pathname !== "/mcp") {
    res.writeHead(404).end();
    return;
  }

  if (req.method === "GET") {
    // Streamable HTTP optional GET for server-initiated streams. We don't push.
    res.writeHead(405, { allow: "POST" }).end();
    return;
  }

  if (req.method !== "POST") {
    res.writeHead(405, { allow: "POST" }).end();
    return;
  }

  let body = "";
  req.setEncoding("utf8");
  req.on("data", (chunk) => {
    body += chunk;
    if (body.length > 5 * 1024 * 1024) {
      res.writeHead(413).end();
      req.destroy();
    }
  });
  const authHeader = req.headers.authorization || req.headers.Authorization;
  req.on("end", async () => {
    let parsed;
    try {
      parsed = JSON.parse(body);
    } catch {
      res.writeHead(400, { "content-type": "application/json" });
      res.end(JSON.stringify({ jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } }));
      return;
    }
    const messages = Array.isArray(parsed) ? parsed : [parsed];
    const responses = (await Promise.all(messages.map((m) => handleMessage(m, authHeader)))).filter(Boolean);
    if (responses.length === 0) {
      res.writeHead(202).end();
      return;
    }
    const payload = Array.isArray(parsed) ? responses : responses[0];
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify(payload));
  });
});

server.listen(PORT, HOST, () => {
  log(`listening on ${HOST}:${PORT}, upstream ${UPSTREAM}`);
});

for (const sig of ["SIGTERM", "SIGINT"]) {
  process.on(sig, () => {
    log(`received ${sig}, shutting down`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
