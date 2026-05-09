# gemini-sidecar

Google `generativelanguage` API-shaped HTTP front-end backed by
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), configured for
Gemini CLI OAuth only.

Coder Agents' Google provider points at this sidecar (via Headroom) instead of
`generativelanguage.googleapis.com`. Native shape — no protocol translation needed.

## Why CLIProxyAPI here vs codex-bridge / Meridian

It's the only mature OSS proxy that exposes the **native** `/v1beta/models/{model}:generateContent`
shape (and the Cloud Code Assist `/v1internal:streamGenerateContent` shape) backed
by Gemini CLI OAuth. nettee/gemini-cli-proxy and similar only expose OpenAI-compat,
which would force a translation layer.

## Auth bootstrap

Gemini CLI OAuth uses Google's standard 3-legged flow. Bootstrap on the host once,
then mount the credentials.

### One-time login

On the host, install `cli-proxy-api` (or run via Docker):

```bash
docker run --rm -it -v "${PWD}/auth:/data/auth" eceasy/cli-proxy-api:latest \
  --auth-dir /data/auth --login gemini
# → prints a URL, open it in browser, paste the redirect code back
```

This writes one or more `gemini-*.json` files into `./auth/` (or whatever you
mounted). The compose stack mounts `${GEMINI_SIDECAR_AUTH_DIR}` (default
`./gemini-sidecar/auth`) into `/data/auth`.

### Refresh

Google refresh tokens are long-lived (months to years) provided they're used at
least every 6 months. CLIProxyAPI handles refresh transparently. Re-login only
when the file goes stale.

## Endpoints

- `POST /v1beta/models/{model}:generateContent` — native Gemini API (non-streaming)
- `POST /v1beta/models/{model}:streamGenerateContent` — streaming SSE
- `POST /v1internal:streamGenerateContent` — Cloud Code Assist shape (gemini-cli)
- `GET  /v1beta/models` — model list
- `GET  /healthz` — liveness

## Local API key

CLIProxyAPI requires a local API key on every request (so the sidecar isn't an
open relay if someone else ends up on the network). Set `CLIPROXY_API_KEY` in
`.env` — the value is also used by Headroom and Coder Agents when configuring the
Google provider's API key field. Anything you supply works; Google never sees it.

## Multi-account

Drop multiple `gemini-*.json` credential files into `auth-dir` and CLIProxyAPI will
round-robin between them. Useful for hitting higher aggregate rate limits without
violating any single account's ToS.
