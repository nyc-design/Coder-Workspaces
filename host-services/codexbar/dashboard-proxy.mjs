import http from 'node:http';
import {timingSafeEqual} from 'node:crypto';

// Change presentation only. Keep the built-in ID for refresh and routing.
export function presentAlibaba(snapshot) {
  if (!Array.isArray(snapshot.providers)) throw new Error('Unexpected snapshot');
  return {...snapshot, providers: snapshot.providers.map(provider => {
    if (provider.id !== 'llmproxy') return provider;
    return {...provider, name: 'Alibaba Token Plan',
      identity: {...provider.identity, plan: 'Personal · Monthly'},
      windows: (provider.windows ?? []).filter(window =>
        window.kind === 'session' && window.label === 'Quota'),
    };
  })};
}

export function createDashboardProxy(upstreamPort = 8082, token = process.env.CODEXBAR_DASHBOARD_TOKEN) {
  if (!token) throw new Error('Dashboard token required');
  const server = http.createServer((req, res) => {
    const path = req.url.split('?')[0];
    // Loopback CodexBar bypasses its bearer gate; enforce it at the public boundary.
    if (path === '/usage' || path === '/cost' || path.startsWith('/dashboard/')) {
      const actual = Buffer.from(req.headers.authorization ?? '');
      const expected = Buffer.from(`Bearer ${token}`);
      if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) {
        res.writeHead(401, {'content-type': 'application/json', 'cache-control': 'no-store'})
          .end('{"error":"unauthorized"}');
        return;
      }
    }
    const upstream = http.request({hostname: '127.0.0.1', port: upstreamPort,
      method: req.method, path: req.url, headers: {...req.headers, 'accept-encoding': 'identity'}}, incoming => {
      const snapshot = req.method === 'GET' &&
        req.url.split('?')[0] === '/dashboard/v1/snapshot' && incoming.statusCode === 200;
      if (!snapshot) {
        res.writeHead(incoming.statusCode, incoming.headers);
        incoming.pipe(res);
        incoming.on('error', () => res.destroy());
        return;
      }
      const chunks = [];
      let size = 0;
      incoming.on('data', chunk => {
        size += chunk.length;
        if (size > 4 * 1024 * 1024) { incoming.destroy(); fail(); }
        else chunks.push(chunk);
      });
      incoming.on('error', fail);
      incoming.on('end', () => {
        if (res.destroyed || res.writableEnded) return;
        try {
          const body = JSON.stringify(presentAlibaba(JSON.parse(Buffer.concat(chunks).toString('utf8'))));
          const headers = {...incoming.headers, 'content-type': 'application/json',
            'content-length': Buffer.byteLength(body), 'cache-control': 'no-store'};
          for (const key of ['transfer-encoding', 'content-encoding', 'etag', 'last-modified']) delete headers[key];
          res.writeHead(200, headers).end(body);
        } catch { fail(); }
      });
    });
    function fail() {
      if (res.destroyed || res.writableEnded) return;
      if (res.headersSent) { res.destroy(); return; }
      res.writeHead(502, {'content-type': 'application/json', 'cache-control': 'no-store'})
        .end('{"error":"Dashboard upstream unavailable"}');
    }
    upstream.setTimeout(90000, () => upstream.destroy());
    upstream.on('error', fail);
    req.on('aborted', () => upstream.destroy());
    res.on('close', () => upstream.destroy());
    req.pipe(upstream);
  });
  server.stop = () => { server.closeAllConnections(); server.close(); };
  return server;
}
