import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {colorProviders} from '../theme.mjs';
import {presentAlibaba, createDashboardProxy} from '../dashboard-proxy.mjs';

const fixture = {generatedAt: 'unchanged', providers: [
  {id: 'codex', name: 'Codex', windows: [{label: 'Weekly'}]},
  {id: 'llmproxy', name: 'LLM Proxy', identity: {plan: 'Quota-stats', accountEmail: null},
    stale: true, error: {message: 'original failure'}, updatedAt: 'unchanged',
    windows: [{kind: 'session', label: 'Quota', usedPercent: 7.5, resetAt: 'unchanged'},
      {kind: 'weekly', label: 'Requests'}, {kind: 'tertiary', label: 'Sonnet'}, {kind: 'alibaba', label: 'alibaba'}]},
]};

test('only Alibaba presentation changes; quota, errors, staleness and other providers survive', () => {
  const original = structuredClone(fixture);
  const result = presentAlibaba(fixture);
  assert.deepEqual(fixture, original);
  assert.deepEqual(result.providers[0], fixture.providers[0]);
  const row = result.providers[1];
  assert.equal(row.name, 'Alibaba Token Plan');
  assert.equal(row.identity.plan, 'Personal · Monthly');
  assert.equal(row.id, 'llmproxy');
  assert.deepEqual(row.windows, [fixture.providers[1].windows[0]]);
  assert.deepEqual(row.error, fixture.providers[1].error);
  assert.equal(row.stale, true);
  assert.equal(row.updatedAt, 'unchanged');
  assert.deepEqual(presentAlibaba({providers: [{id: 'llmproxy', error: {message:'offline'}}]}).providers[0].windows, []);
});

test('proxy preserves bearer gate, assets and raw APIs, transforms only successful snapshots', async t => {
  const upstream = http.createServer((req, res) => {
    if (req.headers.host !== `127.0.0.1:${upstream.address().port}`) {
      res.writeHead(403).end('forbidden host'); return;
    }
    if (req.url === '/') { res.setHeader('content-type', 'text/html'); res.end('<html><head><title>CodexBar Dashboard</title></head><body><h1>CodexBar</h1><script>/* retained */</script></body></html>'); return; }
    if (req.url === '/asset') { res.end('asset'); return; }
    if (req.headers.authorization !== 'Bearer test') { res.writeHead(401).end('unauthorized'); return; }
    if (req.url === '/usage') { res.end('raw usage'); return; }
    if (req.url === '/dashboard/v1/snapshot?bad') { res.end('invalid'); return; }
    const body = JSON.stringify(fixture);
    res.writeHead(200, {'content-type':'application/json', etag:'old', 'content-length':Buffer.byteLength(body)}).end(body);
  });
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const proxy = createDashboardProxy(upstream.address().port, 'test');
  await new Promise(resolve => proxy.listen(0, '127.0.0.1', resolve));
  t.after(() => {proxy.stop(); upstream.closeAllConnections(); upstream.close();});
  const base = `http://127.0.0.1:${proxy.address().port}`;
  const page = await fetch(base+'/', {headers: {host: 'usage.tapiavala.com'}});
  assert(page.headers.get('content-type').includes('text/html'));
  const html = await page.text();
  assert(html.includes('Tapiavala AI Usage'));
  assert(html.includes('<script>/* retained */</script>'));
  assert.equal((await fetch(base+'/dashboard/v1/snapshot')).status, 401);
  assert.equal(await (await fetch(base+'/asset', {headers: {host: 'usage.tapiavala.com'}})).text(), 'asset');
  const headers = {authorization:'Bearer test', host: 'usage.tapiavala.com'};
  assert.equal(await (await fetch(base+'/usage', {headers})).text(), 'raw usage');
  const response = await fetch(base+'/dashboard/v1/snapshot?provider=llmproxy', {headers});
  assert.equal(response.headers.get('etag'), null);
  assert.deepEqual(await response.json(), colorProviders(presentAlibaba(fixture)));
  assert.equal((await fetch(base+'/dashboard/v1/snapshot?bad', {headers})).status, 502);
});
