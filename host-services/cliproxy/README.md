# cliproxy

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) built from
upstream release with our config baked in. Single Go process serves
**Codex (ChatGPT Plus/Pro OAuth)**, **Gemini (personal Google OAuth)**,
and **Claude Code (Anthropic OAuth)** on `127.0.0.1:8317` inside the
container.

Published to GHCR by `.github/workflows/build-cliproxy.yaml`:

```
ghcr.io/nyc-design/cliproxy:latest
ghcr.io/nyc-design/cliproxy:sha-<commit>
```

Multi-arch (`linux/amd64` + `linux/arm64`).

## Why bundle?

Upstream doesn't publish a Docker image — they ship Go binaries on the
GitHub Releases page. Bundling the binary + our config into one image
means the bare VM only needs the compose snippet, and watchtower handles
upstream version bumps the same way it handles upstream image bumps.

## Role in the topology

cliproxy is **internal-only** in our stack. Only OmniRoute reaches it —
no Traefik labels, no public URL. Public traffic flows:

```
client → headroom → omniroute → cliproxy → chatgpt.com / generativelanguage.googleapis.com / api.anthropic.com
```

OmniRoute registers cliproxy in three ways:

- For Claude Code: `anthropic-compatible-cc-cliproxy-claude` provider
  with `baseUrl=http://cliproxy:8317/v1` — handles `/v1/messages` as an
  alternate/fallback Claude route alongside meridian.
- For Codex: `openai-compatible-cliproxy-resp` provider with
  `baseUrl=http://cliproxy:8317/v1` and `apiType=responses` — handles
  `/v1/responses` requests.
- For Gemini: built-in `cliproxyapi` upstream-proxy mode on the
  `gemini` provider (`PUT /api/upstream-proxy/gemini {mode: "cliproxyapi"}`),
  which OmniRoute wires to cliproxy's port 8317 — see OmniRoute
  `src/lib/db/upstreamProxy.ts:36`.

The internal-only posture is also defense-in-depth: the OAuth
credentials in `/data/auth/cliproxy` stay on the docker network and
never face an inbound public path.

## Endpoints (from inside the docker network)

| Path                                          | Provider             |
|-----------------------------------------------|----------------------|
| `POST /v1/messages`                           | Claude Code          |
| `POST /v1/messages/count_tokens`              | Claude Code          |
| `POST /v1/responses`                          | Codex (ChatGPT)      |
| `POST /v1beta/models/{model}:generateContent` | Gemini native        |
| `POST /v1internal:streamGenerateContent`      | Cloud Code Assist    |
| `GET  /v1/models`                             | Model list (OpenAI/Claude shape) |
| `GET  /v1beta/models`                         | Model list (Gemini)  |
| `GET  /healthz`                               | Liveness             |

Reach via `http://cliproxy:8317` from any other container on the same
docker network.

## Auth bootstrap

All OAuth flows are driven by the `cli-proxy-api` CLI itself, baked into
the image. Pass `--config /run/cliproxy/config.yaml`; the auth directory
is read from that config (`auth-dir: /data/auth/cliproxy`). Do **not** pass
`--auth-dir` — CLIProxyAPI v6.10.9 does not expose that flag.

From your laptop, with the container running:

```bash
# Codex (ChatGPT Plus/Pro)
docker exec -it cliproxy cli-proxy-api \
  --config /run/cliproxy/config.yaml \
  --codex-login

# Gemini (personal Google)
docker exec -it cliproxy cli-proxy-api \
  --config /run/cliproxy/config.yaml \
  --login

# Claude Code (Anthropic)
docker exec -it cliproxy cli-proxy-api \
  --config /run/cliproxy/config.yaml \
  --claude-login

docker restart cliproxy
```

Credentials land in the `cliproxy-auth` named volume and survive container
restarts and image upgrades. Run only the providers you need — missing
auth = 401s for that provider only; the others keep working.

### Refresh

- **Codex**: refresh works for ~30 days idle before the refresh token rots.
  Re-run `--login codex` when you start seeing 401s.
- **Gemini**: refresh tokens are long-lived (months to years) provided
  they're used at least every 6 months. CLIProxyAPI handles refresh
  transparently.
- **Claude Code**: refresh behavior follows Anthropic's Claude Code OAuth
  session rules. Re-run `--claude-login` if cliproxy starts returning 401s
  on `/v1/messages`.

## Local API key

CLIProxyAPI requires a local API key on every request so the sidecar isn't
an open relay if anything else lands on the docker network. The
entrypoint substitutes `CLIPROXY_API_KEY` from the env var into the baked
config at startup, so the key can rotate without rebuilding the image.
Generate with `openssl rand -hex 32` and set it in the host `.env`.
**Use the same value when registering cliproxy as a provider in the
OmniRoute dashboard** so OmniRoute can authenticate inbound calls.

## Multi-account

Drop multiple credential files into `/data/auth/cliproxy/` (re-run
`--login` under a different account) and CLIProxyAPI round-robins between
accounts of the same provider. Useful for higher aggregate rate limits —
but mind each account's ToS on personal-use restrictions.

## Subscription notes

- **ChatGPT Plus/Pro Codex** has tight weekly caps (~300 messages/week
  historically) and account-tied auth not amenable to multi-tenancy.
  Single-user only.
- **Gemini Advanced** is the most generous of the supported subscriptions —
  but still personal-use per Google's ToS.
- **Claude Pro/Max via Claude Code** is available here as an alternate route
  to meridian. Keep each account single-user; do not use one subscription
  token as a shared team backend.

## Versions

| Build arg                | Default     | Notes |
|--------------------------|-------------|-------|
| `CLI_PROXY_API_VERSION`  | `v6.10.9`   | Bump in PR; watchtower rolls the image |
