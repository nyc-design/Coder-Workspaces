import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import {addResetSummary} from '../reset-credits.mjs';
import {colorProviders} from '../theme.mjs';
import {createDashboardProxy} from '../dashboard-proxy.mjs';

const fixture = {generatedAt: 'unchanged', providers: [
  {id: 'codex', name: 'Codex', windows: [{label: 'Weekly'}]},
  {id: 'alibabatokenplan', name: 'Alibaba Token Plan', stale: true, error: {message: 'original failure'},
    windows: [{kind: 'session', label: 'Monthly', usedPercent: 7.5, resetAt: 'unchanged'}]},
]};

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
  const response = await fetch(base+'/dashboard/v1/snapshot?provider=alibabatokenplan', {headers});
  assert.equal(response.headers.get('etag'), null);
  const snapshot = await response.json();
  assert.deepEqual(snapshot, addResetSummary(colorProviders(fixture), {state:'unavailable'}));
  // Native Alibaba rows pass through untouched apart from the accent colour.
  assert.deepEqual({...snapshot.providers[1], display: undefined}, {...fixture.providers[1], display: undefined});
  assert.equal((await fetch(base+'/dashboard/v1/snapshot?bad', {headers})).status, 502);
});
