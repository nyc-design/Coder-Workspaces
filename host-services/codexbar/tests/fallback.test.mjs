import test from 'node:test';
import assert from 'node:assert/strict';
import {createClaudeFallback} from '../claude-fallback.mjs';

const RATE_LIMITED = 'Claude OAuth usage endpoint is rate limited by Anthropic right now. Wait a few minutes, then click Refresh.';
const good = {id: 'claude', name: 'Claude', windows: [{label: 'Session', usedPercent: 11}], error: null, display: {accentColor: 'a'}};
const failed = message => ({id: 'claude', name: 'Claude', windows: [], error: {code: 1, message}, display: {accentColor: 'b'}});
const snap = (...providers) => ({generatedAt: 'x', providers});
const codex = {id: 'codex', windows: [], error: {message: RATE_LIMITED}};

test('rate-limited Claude card shows the last good reading with its age', () => {
  let now = 0;
  const fallback = createClaudeFallback({now: () => now});
  assert.deepEqual(fallback(snap(good, codex)), snap(good, codex));
  now = 4 * 60_000;
  const [claude, other] = fallback(snap(failed(RATE_LIMITED), codex)).providers;
  assert.deepEqual(claude.windows, good.windows);
  assert.equal(claude.error, null);
  assert.equal(claude.display.accentColor, 'b');
  assert.deepEqual(claude.status, {level: 'warning', label: 'rate limited · showing 4m old data'});
  assert.deepEqual(other, codex, 'other providers are never masked');
});

test('fallback fails open: no reading, stale reading, or a different error', () => {
  let now = 0;
  const fallback = createClaudeFallback({now: () => now});
  const limited = snap(failed(RATE_LIMITED));
  assert.deepEqual(fallback(limited), limited);
  fallback(snap(good));
  const auth = snap(failed('Claude OAuth request unauthorized. Run `claude` to re-authenticate.'));
  assert.deepEqual(fallback(auth), auth);
  now = 31 * 60_000;
  assert.deepEqual(fallback(limited), limited);
  assert.deepEqual(fallback({unexpected: true}), {unexpected: true});
});
