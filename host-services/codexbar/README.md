# CodexBar host dashboard

Stock CodexBar 0.84.0 on Node 22 Alpine, with the pinned Bailian 2.0.0 CLI.
The existing multi-arch GHCR workflow builds from the repository root. No new
npm dependencies or Swift compilation are required.

## Monthly Alibaba usage

CodexBar's native **Alibaba Token Plan** provider handles international
Personal subscriptions, including monthly-only quotas (upstream v0.66.0+). It is
configured in `config.json` as `alibabatokenplan` with `source: cli` and
`region: intl-personal`, so CodexBar runs
`bl console call --api zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage`
with the shared `.bailian` console session. A monthly-only plan uses the primary
usage bar with its real reset time. See upstream
[alibaba-token-plan.md](https://github.com/steipete/CodexBar/blob/v0.84.0/docs/alibaba-token-plan.md).

```text
Browser → Traefik → presentation proxy :8080 → CodexBar 127.0.0.1:8082
                     ├─ Codex/Claude: existing OAuth credential mounts
                     └─ Alibaba Token Plan → bl → Alibaba console usage endpoint
```

The explicit `cli` source never falls back to browser cookies (macOS-only
anyway). An expired console session shows as a provider error asking you to
sign in with `bl`; run `bl auth login --console` in any workspace.

This replaces the earlier loopback LLM Proxy bridge and Bailian preload hook,
which existed only because CodexBar 0.64 rejected monthly-only responses.

### Dashboard presentation

A Node HTTP proxy listens publicly on 8080; stock CodexBar listens only on
127.0.0.1:8082. The proxy enforces the existing dashboard bearer token for data
routes (loopback CodexBar bypasses its own auth gate). Static assets and health
remain accessible as before.

Only successful `/dashboard/v1/snapshot` responses are adapted, and only with
provider accent colours and the Codex reset-credit summary below. Percentages,
reset timestamps, error/staleness fields, names and provider IDs are unchanged.
Raw `/usage` and `/cost` responses are not rewritten. Invalid snapshots fail with
a generic 502; buffers are bounded.

### Tapiavala branding

The public homepage is branded **Tapiavala AI Usage** with a locally generated
SVG T/spark mark and favicon, no third-party assets or fonts. A scoped stylesheet
keeps the stock responsive grid and JavaScript behavior while adding charcoal
surfaces, teal/neon-green header, logo and control accents, rounded cards, focus states and reduced-motion
support. Dark grey is the default, independent of the device preference. A visible header
button switches between light and dark, persists the selection locally, and applies
it before page paint. Storage restrictions do not prevent toggling. Codex bars are teal,
Claude warm amber, and Alibaba lime; warning/error indicators remain semantic.
The upstream version retains a small “Powered by CodexBar” attribution.

HTML rewriting is limited to fixed branding strings and an appended stylesheet;
upstream scripts, token storage, refresh, authentication forms and chart logic are
unchanged. The public Host header is rewritten to the internal loopback authority
before forwarding so CodexBar does not reject the deployment hostname.

### Codex manual reset credits

The Codex card now includes a display-only **Manual resets** section. Available
credits can be expanded to show every expiration in local date/time order, with
non-expiring credits last. Redeemed and expired credits are excluded. There are
no redemption controls and no changes to the normal usage-window reset labels.

The proxy reads stock CodexBar's `/usage?provider=codex` on loopback only when a
snapshot includes Codex. Reads are coalesced and cached for 60 seconds, bounded
to five seconds and 2 MiB, and reuse CodexBar's own provider machinery/cache.
Only counts, expiration dates and an observation timestamp reach the browser;
credit IDs and account details are not added. Missing, malformed or older-than-
three-minute data displays **Unavailable**, never a fabricated zero. Multiple raw
Codex accounts or grouped account cards are conservatively left unavailable rather
than assigning credits to the wrong account. A genuine empty inventory displays
**0 available**. Claude remains unchanged.

## Deploy

1. Keep `CODEXBAR_DASHBOARD_TOKEN` in the host `.env` and the existing Codex,
   Claude, Bailian and cache mounts in `docker-compose.snippet.yml`. The Claude
   mount must be read-write for the token keepalive below.
2. Pull the published image and recreate: `docker compose pull codexbar` then
   `docker compose up -d codexbar`.
3. Authenticate `bl` from a workspace if necessary (`bl auth login --console`).
   Its shared `.bailian` session is reused; no browser cookie or additional host
   secret is required.
4. Open the existing AI Usage app. Expect the native **Alibaba Token Plan** card
   with a monthly bar. `CODEXBAR_ALIBABA_REGION` is not used; remove it if present.

Do not mount host credentials into another service. The image healthcheck probes
the public listener, not provider availability. SIGTERM/SIGINT stop the
CodexBar process group; a forced shutdown follows after three seconds if necessary.

## Validation

`node --test host-services/codexbar/tests/*.test.mjs` runs offline regression
tests for auth, routing, branding, colours, reset credits, the Claude
rate-limit fallback and the Claude keepalive. Existing agent-tools CI runs these
on AMD64 and ARM64; the publishing workflow runs them before its build too.

## Claude usage rate limits

Anthropic rate limits the Claude OAuth usage endpoint per account, and that
budget is shared with every Claude Code session on the same login. A burst of
about ten requests in a minute returns 429 for a couple of minutes, and CodexBar
then backs off for five. `claude-fallback.mjs` keeps the last good Claude card
in memory and serves it during that window, with a `rate limited · showing Nm
old data` status chip. Readings older than 30 minutes, and every other error
(expired login included), are passed through unchanged.

## Claude token keepalive

CodexBar never refreshes Claude Code-owned OAuth credentials on Linux; it waits
for a `claude` process to do it. Without help, the Claude row errors once the
~8h access token lapses, until someone runs `claude` in a workspace.
`claude-keepalive.mjs` (started by `serve.mjs`) checks the shared
`.credentials.json` every 2 minutes. Within 4 minutes of expiry it runs one
minimal headless Claude Code call (`haiku`, no tools/MCP/hooks/session), which
refreshes the token under Claude Code's own lock — the same coordination used
by workspace sessions. Logs show only `token fresh|missing|relogin` and
`refresh ok|failed`, never token values. An expired refresh token
(`relogin`) still needs `claude` login in a workspace. Disable with
`CLAUDE_KEEPALIVE=0`.
