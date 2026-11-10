// Keeps the host-shared Claude Code OAuth token fresh so the dashboard never
// waits for someone to run `claude` in a workspace.
//
// CodexBar never refreshes Claude-CLI-owned credentials itself; it delegates to
// the `claude` CLI, and only for interactive (macOS) refreshes. So when the
// ~8h access token lapses, the Claude row errors until any Claude Code process
// touches the shared dir. This loop runs that CLI shortly before expiry. Claude
// Code refreshes under its own lock in the config dir, which is the same
// coordination workspace sessions use, so rotation can't race them.
import {spawn} from 'node:child_process';
import {readFile, mkdir} from 'node:fs/promises';
import {join} from 'node:path';

const MINUTE = 60_000;

// Returns 'missing' | 'relogin' | 'fresh' | 'due'. Never exposes token values.
export function tokenState(raw, now = Date.now(), marginMs = 4 * MINUTE) {
  let oauth;
  try { oauth = JSON.parse(raw)?.claudeAiOauth; } catch { return 'missing'; }
  if (!oauth?.refreshToken || typeof oauth.expiresAt !== 'number') return 'missing';
  if (typeof oauth.refreshTokenExpiresAt === 'number' && oauth.refreshTokenExpiresAt <= now) return 'relogin';
  return oauth.expiresAt - now > marginMs ? 'fresh' : 'due';
}

// Minimal headless call: no tools, MCP, hooks or saved session. Claude Code
// refreshes an expiring token before sending it.
export const CLAUDE_ARGS = ['-p', 'ok', '--model', 'haiku', '--tools', '', '--strict-mcp-config',
  '--setting-sources', 'project', '--no-session-persistence'];

function runClaude({cwd, timeoutMs}) {
  // Default config dir (~/.claude = the shared mount) keeps ~/.claude.json
  // container-local instead of writing it into the shared credentials dir.
  const env = {...process.env};
  delete env.CLAUDE_CONFIG_DIR;
  return new Promise(resolve => {
    const child = spawn('claude', CLAUDE_ARGS, {cwd, env, stdio: 'ignore'});
    const timer = setTimeout(() => child.kill('SIGKILL'), timeoutMs);
    child.on('error', () => { clearTimeout(timer); resolve(-1); });
    child.on('exit', code => { clearTimeout(timer); resolve(code ?? -1); });
  });
}

export function startClaudeKeepalive({
  credentialsPath = join(process.env.HOME || '/home/codexbar', '.claude', '.credentials.json'),
  // Claude Code only refreshes inside its own ~5 minute expiry buffer, so the
  // margin must sit inside it or the call is spent without a refresh.
  intervalMs = 2 * MINUTE, marginMs = 4 * MINUTE, timeoutMs = 2 * MINUTE,
  run = runClaude, log = console, now = Date.now,
} = {}) {
  let busy = false, lastState;
  // Fixed cwd: Claude Code keys a per-project dir in the shared mount on cwd,
  // so a stable path keeps that to one entry.
  const cwd = join(process.env.HOME || '/home/codexbar', 'claude-keepalive');
  async function tick() {
    if (busy) return;
    busy = true;
    try {
      const raw = await readFile(credentialsPath, 'utf8').catch(() => '');
      const state = tokenState(raw, now(), marginMs);
      if (state !== lastState && state !== 'due') log.log(`claude-keepalive: token ${state}`);
      lastState = state;
      if (state !== 'due') return;
      await mkdir(cwd, {recursive: true});
      const code = await run({cwd, timeoutMs});
      const after = tokenState(await readFile(credentialsPath, 'utf8').catch(() => ''), now(), marginMs);
      log.log(`claude-keepalive: refresh ${after === 'fresh' ? 'ok' : `failed (exit ${code}, token ${after})`}`);
      lastState = after;
    } finally { busy = false; }
  }
  tick();
  const timer = setInterval(tick, intervalMs);
  timer.unref();
  return {stop: () => clearInterval(timer), tick};
}
