import test from 'node:test';
import assert from 'node:assert/strict';
import {createBridge, quotaResponse} from '../monthly-bridge.mjs';
import {mkdtempSync, writeFileSync, rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

test('monthly percentages and reset remain truthful, including zero and exhaustion', () => {
  for (const ratio of [0, 0.25, 1]) {
    const response = quotaResponse({ratio, reset: 2000}, 1000);
    const window = response.providers.alibaba.quota_groups[0];
    assert.equal(window.remaining_percent, (1 - ratio) * 100);
    assert.equal(window.reset_time, new Date(2000).toISOString());
  }
  for (const data of [{}, {ratio: -1, reset: 2000}, {ratio: 1.2, reset: 2000},
    {ratio: '0.2', reset: 2000}, {ratio: 0.2, reset: 999}, {ratio: 0.2, reset: 9e15}]) {
    assert.throws(() => quotaResponse(data, 1000));
  }
});

test('loopback auth, routing, single-flight cache and private errors', async t => {
  let calls = 0;
  const server = createBridge('test-secret', async () => {
    calls++;
    await new Promise(resolve => setTimeout(resolve, 10));
    return {ratio: 0.25, reset: Date.now() + 86400000};
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.stop());
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(base + '/health')).status, 200);
  assert.equal((await fetch(base + '/v1/quota-stats')).status, 401);
  const headers = {Authorization: 'Bearer test-secret'};
  assert.equal((await fetch(base + '/other', {headers})).status, 404);
  const results = await Promise.all(Array.from({length: 4}, () => fetch(base + '/v1/quota-stats', {headers})));
  assert(results.every(r => r.status === 200));
  assert.equal(calls, 1);
  assert.equal((await fetch(base + '/v1/quota-stats', {headers})).status, 200);
  assert.equal(calls, 1);
});

test('missing monthly data and upstream errors never become zero usage or leak details', async t => {
  const server = createBridge('test', async () => { throw new Error('secret-credential'); });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.stop());
  const r = await fetch(`http://127.0.0.1:${server.address().port}/v1/quota-stats`, {headers: {Authorization: 'Bearer test'}});
  assert.equal(r.status, 503);
  assert(!(await r.text()).includes('secret-credential'));
  assert.throws(() => createBridge(''));
});

test('Bailian hook extracts only monthly values from the exact successful endpoint', () => {
  const dir = mkdtempSync(join(tmpdir(), 'monthly-hook-'));
  try {
    const hook = fileURLToPath(new URL('../bailian-monthly.cjs', import.meta.url));
    const usage = {per1MonthPercentage: 0.25, per1MonthResetTime: 1234567890000, secret: 'never-copy'};
    for (const ok of [true, false]) {
      const script = `globalThis.fetch = async () => ({ok:true,clone(){return this},async json(){return ${JSON.stringify({successResponse: ok, data: {success: true, DataV2: {data: {success: true, data: usage}}}})}}}); require(${JSON.stringify(hook)}); fetch('https://example.test/cli/api.json?api=zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage');`;
      writeFileSync(join(dir, 'fixture.cjs'), script);
      const result = spawnSync(process.execPath, [join(dir, 'fixture.cjs')], {stdio: ['ignore', 'pipe', 'pipe', 'pipe']});
      assert.equal(result.status, 0);
      const output = result.output[3].toString();
      assert.equal(output, ok ? JSON.stringify({ratio: 0.25, reset: 1234567890000}) : '');
      assert(!output.includes('never-copy'));
    }
  } finally { rmSync(dir, {recursive: true, force: true}); }
});

test('bridge shutdown cancels an active quota fetch', async () => {
  let cancelled = false;
  let started;
  const ready = new Promise(resolve => { started = resolve; });
  const server = createBridge('test', signal => new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => { cancelled = true; reject(new Error('aborted')); }, {once: true});
    started();
  }));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const request = fetch(`http://127.0.0.1:${server.address().port}/v1/quota-stats`, {headers: {Authorization: 'Bearer test'}}).catch(() => null);
  await ready;
  server.stop();
  await request;
  assert.equal(cancelled, true);
});
