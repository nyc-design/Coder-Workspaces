import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {tokenState, startClaudeKeepalive} from '../claude-keepalive.mjs';

const now = 1_000_000_000_000;
const creds = (expiresAt, extra = {}) =>
  JSON.stringify({claudeAiOauth: {accessToken: 'a', refreshToken: 'r', expiresAt, ...extra}});

test('token state classification', () => {
  assert.equal(tokenState('', now), 'missing');
  assert.equal(tokenState('{bad', now), 'missing');
  assert.equal(tokenState(JSON.stringify({claudeAiOauth: {expiresAt: now}}), now), 'missing');
  assert.equal(tokenState(creds(now + 3_600_000), now), 'fresh');
  assert.equal(tokenState(creds(now + 60_000), now), 'due');
  assert.equal(tokenState(creds(now - 60_000), now), 'due');
  assert.equal(tokenState(creds(now - 1, {refreshTokenExpiresAt: now - 1}), now), 'relogin');
});

async function harness(initial, onRun) {
  const dir = await mkdtemp(join(tmpdir(), 'kt-'));
  const path = join(dir, '.credentials.json');
  await writeFile(path, initial);
  const logs = [];
  let runs = 0;
  const k = startClaudeKeepalive({
    credentialsPath: path, now: () => now, log: {log: m => logs.push(m)},
    run: async () => { runs++; await onRun?.(path); return 0; },
  });
  k.stop();
  await new Promise(r => setTimeout(r, 50));
  return {runs: () => runs, logs, tick: k.tick};
}

test('runs claude only when due, and reports success without secrets', async () => {
  const fresh = await harness(creds(now + 3_600_000));
  assert.equal(fresh.runs(), 0);
  const due = await harness(creds(now + 60_000), p => writeFile(p, creds(now + 8 * 3_600_000)));
  assert.equal(due.runs(), 1);
  assert(due.logs.includes('claude-keepalive: refresh ok'));
  assert(!due.logs.join().includes('"r"'));
});

test('failed refresh and relogin are logged, relogin never spawns claude', async () => {
  const failed = await harness(creds(now - 1));
  assert.equal(failed.runs(), 1);
  assert.match(failed.logs.at(-1), /refresh failed/);
  const relogin = await harness(creds(now - 1, {refreshTokenExpiresAt: now - 1}));
  assert.equal(relogin.runs(), 0);
  assert(relogin.logs.includes('claude-keepalive: token relogin'));
});
