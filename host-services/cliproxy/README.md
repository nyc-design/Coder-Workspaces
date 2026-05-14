# cliproxy

[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) built from
upstream release with our config baked in. Single Go process serves
**Codex (ChatGPT Plus/Pro OAuth)** and **Gemini (personal Google OAuth)**
on `127.0.0.1:8317` inside the container.

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

## Endpoints

| Path                                          | Provider             |
|-----------------------------------------------|----------------------|
| `POST /v1/responses`                          | Codex (ChatGPT)      |
| `POST /v1beta/models/{model}:generateContent` | Gemini native        |
| `POST /v1internal:streamGenerateContent`      | Cloud Code Assist    |
| `GET  /v1beta/models`                         | Model list (Gemini)  |
| `GET  /health`                                | Liveness             |

## Auth bootstrap

Both OAuth flows are driven by the `cli-proxy-api` CLI itself, baked into
the image. From your laptop, with the container running:

```bash
# Codex (ChatGPT Plus/Pro)
docker exec -it cliproxy cli-proxy-api --auth-dir /data/auth/cliproxy --login codex

# Gemini (personal Google)
docker exec -it cliproxy cli-proxy-api --auth-dir /data/auth/cliproxy --login gemini

docker restart cliproxy
```

Credentials land in the `cliproxy-auth` named volume and survive container
restarts and image upgrades. Run only the providers you need — missing
auth = 401s for that provider only; the other keeps working.

### Refresh

- **Codex**: refresh works for ~30 days idle before the refresh token rots.
  Re-run `--login codex` when you start seeing 401s.
- **Gemini**: refresh tokens are long-lived (months to years) provided
  they're used at least every 6 months. CLIProxyAPI handles refresh
  transparently.

## Local API key

CLIProxyAPI requires a local API key on every request so the sidecar isn't
an open relay if anything else lands on the docker network. The
entrypoint substitutes `CLIPROXY_API_KEY` from the env var into the baked
config at startup, so the key can rotate without rebuilding the image.
Generate with `openssl rand -hex 32` and set it in the host `.env`.

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

## Versions

| Build arg                | Default     | Notes |
|--------------------------|-------------|-------|
| `CLI_PROXY_API_VERSION`  | `v6.10.9`   | Bump in PR; watchtower rolls the image |
