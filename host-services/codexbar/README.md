# CodexBar host dashboard

Stock CodexBar 0.64.0 on Node 22 Alpine, with the pinned Bailian 2.0.0 CLI.
The existing multi-arch GHCR workflow builds from the repository root. No new
npm dependencies or Swift compilation are required.

## Monthly Alibaba usage

Alibaba international Personal subscriptions can return only
`per1MonthPercentage` and `per1MonthResetTime`. Bailian drops those fields;
CodexBar's native Alibaba parser also rejects monthly-only responses.

The service uses the existing **LLM Proxy** provider instead:

```text
Browser → Traefik → presentation proxy :8080 → CodexBar 127.0.0.1:8082
                     ├─ Codex/Claude: existing OAuth credential mounts
                     └─ LLM Proxy → bearer-authenticated 127.0.0.1:8081
                                      └─ bl → Alibaba console usage endpoint
```

`serve.mjs` supervises CodexBar and the loopback HTTP bridge in one container.
It generates a fresh private bridge token on startup. This is independent of
`CODEXBAR_DASHBOARD_TOKEN`; neither token is written into the config file.

`monthly-bridge.mjs` launches `bl usage token-plan` with the existing `.bailian`
session and explicit international/Singapore flags. A process-local Node preload
(`bailian-monthly.cjs`) observes only the successful, known console response before
Bailian filters it. Only the two numeric monthly fields pass through a private FD;
raw responses, credentials, and CLI stdout/stderr never enter bridge responses or
logs. No installed Bailian files are patched. This hook is deliberately tied to the
pinned CLI and response envelope: incompatible changes fail closed.

Fetches are bounded to 20 seconds, coalesced, and cached for 60 seconds. Missing,
invalid, expired, or out-of-range monthly values return 503, not fabricated zero
usage. The quota percentage must be a fraction in [0,1] and the millisecond reset
must be in the future, at most 62 days away. The real reset timestamp is preserved;
no weekly mapping or made-up credit totals are used. CodexBar has its own cache and
may display previously successful data as stale during failures.

### Dashboard presentation

A Node HTTP proxy listens publicly on 8080; stock CodexBar listens only on
127.0.0.1:8082. The proxy enforces the existing dashboard bearer token for data
routes (loopback CodexBar bypasses its own auth gate). Static assets and health
remain accessible as before.

Only successful `/dashboard/v1/snapshot` responses are adapted: the `llmproxy`
card is named **Alibaba Token Plan**, its plan subtitle is **Personal · Monthly**,
and only its real **Quota** window remains. Default Requests/Sonnet/provider rows
are hidden. Percentages, reset timestamps, error/staleness fields, provider IDs,
and all other providers remain unchanged. Raw `/usage` and `/cost` responses are
not rewritten. Invalid snapshots fail with a generic 502; buffers are bounded.
The built-in provider itself has no custom title setting; this is a scoped web
presentation override, not a rename of the native CLI provider.

### Tapiavala branding

The public homepage is branded **Tapiavala AI Usage** with a locally generated
SVG T/spark mark and favicon, no third-party assets or fonts. A scoped stylesheet
keeps the stock responsive grid and JavaScript behavior while adding charcoal
surfaces, teal/neon-green accents, rounded cards, focus states and reduced-motion
support. Light/dark themes follow the device preference. Codex bars are teal,
Claude warm amber, and Alibaba lime; warning/error indicators remain semantic.
The upstream version retains a small “Powered by CodexBar” attribution.

HTML rewriting is limited to fixed branding strings and an appended stylesheet;
upstream scripts, token storage, refresh, authentication forms and chart logic are
unchanged. The public Host header is rewritten to the internal loopback authority
before forwarding so CodexBar does not reject the deployment hostname.

## Deploy

1. Keep `CODEXBAR_DASHBOARD_TOKEN` in the host `.env` and the existing Codex,
   Claude, Bailian and cache mounts in `docker-compose.snippet.yml`.
2. Pull the published image and recreate: `docker compose pull codexbar` then
   `docker compose up -d codexbar`.
3. Authenticate `bl` from a workspace if necessary. Its shared `.bailian` session
   is reused; no browser cookie or additional host secret is required.
4. Open the existing AI Usage app. Expect **Alibaba Token Plan / Personal · Monthly**, with only the
   Quota bar. `CODEXBAR_ALIBABA_REGION` is no longer used; remove it if present.

Do not expose port 8081 or mount host credentials into another service. The image
healthcheck probes both listeners, not Alibaba availability. SIGTERM/SIGINT close
the bridge, terminate active Bailian requests, and stop the CodexBar process group;
a forced shutdown follows after three seconds if necessary.

## Validation

`node --test host-services/codexbar/tests/*.test.mjs` runs offline regression
tests for monthly normalization, auth, routing, cache/single-flight behavior,
private errors, and response extraction. Existing agent-tools CI runs these on
AMD64 and ARM64; the publishing workflow runs them before its build too.

Local ARM64 checks: Docker build; synthetic 25%-used quota through the real stock
CodexBar `/usage` and `/dashboard/v1/snapshot` (75% remaining, reset preserved);
live workspace Bailian session yields valid monthly fields without logging values.
Public bearer gating and presentation were tested with the stock binary after
adding the proxy. Host deployment and a real browser render remain to be checked after rollout.
