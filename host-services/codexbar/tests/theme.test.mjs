import test from 'node:test';
import assert from 'node:assert/strict';
import {brandDashboard, colorProviders} from '../theme.mjs';

test('local branding retains upstream scripts and functional markup', () => {
  const script = '<script>const key="codexbar-token";fetch("/dashboard/v1/snapshot")</script>';
  const page = '<html><head><title>CodexBar Dashboard</title><link rel="icon" href="data:,"></head><body><h1>CodexBar</h1><form id="token-form"></form>'+script+'</body></html>';
  const branded = brandDashboard(page);
  assert(branded.includes('<h1>Tapiavala AI Usage</h1>'));
  assert(branded.includes('<title>Tapiavala AI Usage</title>'));
  assert(branded.includes('data:image/svg+xml,'));
  assert(branded.includes('prefers-color-scheme:dark'));
  assert(branded.includes('prefers-reduced-motion'));
  assert(branded.includes(script));
  assert(branded.includes('<form id="token-form"></form>'));
  assert.throws(() => brandDashboard('<html>unexpected</html>'));
});

test('provider colors are distinct and do not alter quota or ordering metadata', () => {
  const input = {providers:['codex','claude','llmproxy','other'].map(id => ({id,display:{sortKey:3},windows:[{usedPercent:7.5}]}))};
  const before = structuredClone(input);
  const output = colorProviders(input);
  assert.deepEqual(input,before);
  assert.equal(new Set(output.providers.slice(0,3).map(p=>p.display.accentColor)).size,3);
  for (const p of output.providers) {assert.equal(p.display.sortKey,3);assert.equal(p.windows[0].usedPercent,7.5);}
  assert.deepEqual(output.providers[3],input.providers[3]);
});
