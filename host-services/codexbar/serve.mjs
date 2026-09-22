import {spawn} from 'node:child_process';
import {randomBytes} from 'node:crypto';
import {createBridge} from './monthly-bridge.mjs';
import {createDashboardProxy} from './dashboard-proxy.mjs';

const token = randomBytes(32).toString('hex');
const bridge = createBridge(token);
const dashboard = createDashboardProxy();
let child;
let stopping = false;
function shutdown(code) {
  if (stopping) return;
  stopping = true;
  process.exitCode = code;
  bridge.stop();
  dashboard.stop();
  if (child?.pid) { try { process.kill(-child.pid, 'SIGTERM'); } catch {} }
  setTimeout(() => {
    if (child?.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
    process.exit(code);
  }, 3000);
  if (!child?.pid) process.exit(code);
}
dashboard.on('error', () => { console.error('Dashboard listener failed'); shutdown(1); });
bridge.on('error', () => { console.error('Monthly bridge listener failed'); shutdown(1); });
bridge.listen(8081, '127.0.0.1', () => {
  dashboard.listen(8080, '0.0.0.0');
  child = spawn('codexbar', ['serve', '--host', '127.0.0.1', '--port', '8082',
    '--allow-plain-http', '--identity', 'redacted', ...process.argv.slice(2)], {
    env: {...process.env, LLM_PROXY_BASE_URL: 'http://127.0.0.1:8081', LLM_PROXY_API_KEY: token},
    detached: true, stdio: 'inherit',
  });
  child.on('error', () => shutdown(1));
  child.on('exit', code => { shutdown(code || 1); });
});
process.on('SIGTERM', () => shutdown(0));
process.on('SIGINT', () => shutdown(0));
