import http from 'node:http';
import {spawn} from 'node:child_process';
import {timingSafeEqual} from 'node:crypto';
import {fileURLToPath} from 'node:url';

export function quotaResponse(data, now = Date.now()) {
  if (!Number.isFinite(data.ratio) || data.ratio < 0 || data.ratio > 1 ||
      !Number.isSafeInteger(data.reset) || data.reset <= now || data.reset > now + 62 * 86400000) {
    throw new Error('Invalid or expired monthly usage');
  }
  return {providers: {alibaba: {quota_groups: [{name: 'Monthly',
    remaining_percent: (1 - data.ratio) * 100,
    reset_time: new Date(data.reset).toISOString()}]}}};
}

export function fetchMonthly(signal) {
  return new Promise((resolve, reject) => {
    const child = spawn('bl', ['usage', 'token-plan', '--console-region', 'ap-southeast-1',
      '--console-site', 'international', '--output', 'json'], {
      env: {...process.env, NODE_OPTIONS: `--require=${fileURLToPath(new URL('./bailian-monthly.cjs', import.meta.url))}`,
        DO_NOT_TRACK: '1'},
      stdio: ['ignore', 'ignore', 'ignore', 'pipe'], detached: true,
    });
    let output = '';
    let failed = false;
    const stop = () => { try { process.kill(-child.pid, 'SIGKILL'); } catch {} };
    signal?.addEventListener('abort', stop, {once: true});
    if (signal?.aborted) stop();
    const timer = setTimeout(() => { failed = true; stop(); }, 20000);
    child.stdio[3].on('data', chunk => {
      output += chunk;
      if (output.length > 1024) { failed = true; stop(); }
    });
    child.on('error', () => { clearTimeout(timer); reject(new Error('Bailian unavailable')); });
    child.on('close', code => {
      clearTimeout(timer);
      signal?.removeEventListener('abort', stop);
      try {
        if (failed || code !== 0) throw new Error();
        const data = JSON.parse(output);
        quotaResponse(data);
        resolve(data);
      } catch { reject(new Error('Monthly usage unavailable; check Bailian console login')); }
    });
  });
}

export function createBridge(token, fetcher = fetchMonthly) {
  if (!token) throw new Error('Bridge token required');
  let cached;
  let expires = 0;
  let pending;
  const controller = new AbortController();
  const server = http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('Content-Type', 'application/json');
    if (req.method === 'GET' && req.url === '/health') { res.end('{"status":"ok"}'); return; }
    const supplied = Buffer.from(req.headers.authorization ?? '');
    const expected = Buffer.from(`Bearer ${token}`);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
      res.writeHead(401).end('{"error":"unauthorized"}'); return;
    }
    if (req.method !== 'GET' || req.url !== '/v1/quota-stats') {
      res.writeHead(404).end('{"error":"not found"}'); return;
    }
    try {
      if (!cached || Date.now() >= expires || cached.reset <= Date.now()) {
        pending ??= fetcher(controller.signal).then(data => {
          quotaResponse(data); cached = data; expires = Date.now() + 60000;
        }).finally(() => { pending = undefined; });
        await pending;
      }
      res.end(JSON.stringify(quotaResponse(cached)));
    } catch {
      res.writeHead(503).end('{"error":"Monthly usage unavailable; check Bailian console login"}');
    }
  });
  server.stop = () => { controller.abort(); server.closeAllConnections(); server.close(); };
  return server;
}
