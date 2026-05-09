# cliproxy-sidecar

Single [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) process
serving **both Codex (ChatGPT Plus/Pro OAuth)** and **Gemini (personal Google
OAuth)** from one Go binary. Listens on `127.0.0.1:8317` inside the container;
Headroom dispatches by request path.

| Coder Agents provider | Path Headroom routes here | Backed by upstream |
|---|---|---|
| OpenAI | `POST /v1/responses` | `chatgpt.com/backend-api/codex/responses` |
| Google | `POST /v1beta/models/{model}:generateContent` | `generativelanguage.googleapis.com` |
| Google (alt) | `POST /v1internal:streamGenerateContent` | Cloud Code Assist (gemini-cli shape) |

## Why one process for both

CLIProxyAPI is actively maintained (near-daily commits) and natively supports
both OAuth flows. Consolidating into one process saves a service, an extra
~30MB of container memory, and one set of credential-management ergonomics.
The downside is shared lifecycle — restarting affects both providers — which
is acceptable for a single-user setup.

(Earlier versions of this PR used codex-bridge for Codex separately; we swapped
to CLIProxyAPI for both freshness and consolidation.)

## Auth bootstrap

Both OAuth flows are driven by the `cli-proxy-api` CLI itself, baked into the
image. Run from your laptop:

```bash
# Codex (ChatGPT Plus/Pro)
docker exec -it coder-agents-sidecars cli-proxy-api \
  --auth-dir /data/auth/cliproxy --login codex
# → prints a URL, browser, paste code back

# Gemini (personal Google)
docker exec -it coder-agents-sidecars cli-proxy-api \
  --auth-dir /data/auth/cliproxy --login gemini

docker restart coder-agents-sidecars
```

You can run just one if you only want one provider — CLIProxyAPI auto-detects
which credentials exist and serves whichever endpoints have valid auth. Missing
auth = 401s for that provider only; the other keeps working.

Both credential sets land in `/data/auth/cliproxy/` on the
`coder-agents-sidecars-auth` named volume, so they survive container restarts
and image upgrades.

### Refresh

- **Codex**: refresh works for ~30 days idle before the refresh token rots.
  Re-run `--login codex` when you start seeing 401s.
- **Gemini**: refresh tokens are long-lived (months to years) provided they're
  used at least every 6 months. CLIProxyAPI handles refresh transparently.

## Local API key

CLIProxyAPI requires a local API key on every request so the sidecar isn't an
open relay if someone else ends up on the container network. The image
substitutes `SIDECAR_SHARED_API_KEY` into the baked config at startup —
same value Coder Agents sends in the OpenAI and Google providers' API key
fields. Vendor never sees it.

## Multi-account

Drop multiple credential files into `/data/auth/cliproxy/` (re-run `--login`
under a different account) and CLIProxyAPI will round-robin between accounts of
the same provider. Useful for higher aggregate rate limits — but mind each
account's ToS on personal-use restrictions.

## Subscription notes

- **ChatGPT Plus/Pro Codex** has tight weekly caps (~300 messages/week
  historically) and account-tied auth not amenable to multi-tenancy.
  Single-user only.
- **Gemini Advanced** is the most generous of the three subscriptions in this
  stack — but still personal-use per Google's ToS.

## Endpoints exposed (verifiable via curl through Headroom)

```bash
# Codex — should hit upstream and return a Responses API stream
curl -i http://localhost:8787/v1/responses \
  -H "Authorization: Bearer $SIDECAR_SHARED_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-5-codex","input":"hello"}'

# Gemini native
curl -i 'http://localhost:8787/v1beta/models/gemini-2.5-flash:generateContent' \
  -H "x-goog-api-key: $SIDECAR_SHARED_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"contents":[{"parts":[{"text":"hello"}]}]}'

# Models list
curl -fsS http://localhost:8787/v1beta/models \
  -H "x-goog-api-key: $SIDECAR_SHARED_API_KEY"
```
