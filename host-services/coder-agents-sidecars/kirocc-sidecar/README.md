# kirocc sidecar

Tiny Go proxy ([d-kuro/kirocc](https://github.com/d-kuro/kirocc)) that exposes
the Anthropic Messages API at `127.0.0.1:9090` backed by a Kiro Builder ID
OAuth token. The dispatcher routes any request whose `model` starts with
`kiro/` here (after stripping the prefix).

## Bootstrap

kirocc itself has no login flow — it reads tokens from a SQLite database that
the upstream Amazon Q / Kiro CLI writes. The image ships that CLI as `q`
(static musl build, multi-arch, ~100 MB), so a one-shot login from inside the
container is enough; no host-side install or `docker cp` of a pre-auth'd
SQLite required:

```bash
docker exec -it coder-agents-sidecars kiro-auth-login
# → "Open this URL: https://view.awsapps.com/start/#/device?user_code=...."
# → paste the code in any browser, complete sign-in, then return here
docker restart coder-agents-sidecars
```

This is symmetric with the CLIProxyAPI `--login codex|gemini|claude` flow
used for the other sidecars. Tokens land in `/data/auth/kirocc/data.sqlite3`
on the named volume, so they survive image rebuilds. Re-running
`kiro-auth-login` (account swap, forced re-auth) overwrites the existing DB.

The wrapper sets `XDG_DATA_HOME=/data/auth` and symlinks
`/data/auth/amazon-q → /data/auth/kirocc` so the upstream CLI's writes (which
default to `$XDG_DATA_HOME/amazon-q/data.sqlite3`) land in the path kirocc
reads. Subsequent refresh-token rotations stay in the same physical file —
kirocc uses the same fig_auth code path as the CLI.

## Auth

- **Inbound:** `kirocc -api-key` enforces the shared bearer that the
  dispatcher forwards (same `SIDECAR_SHARED_API_KEY` used elsewhere).
- **Upstream:** OAuth handled internally by kirocc; refresh tokens auto-rotate
  using the same flow as the Kiro CLI.

## Versioning

- **kirocc** — pinned in the Dockerfile via `ARG KIROCC_VERSION=v0.1.0`,
  downloaded from <https://github.com/d-kuro/kirocc/releases>.
- **Amazon Q / Kiro CLI** — fetched from
  `https://desktop-release.q.us-east-1.amazonaws.com/latest/q-${arch}-linux-musl.zip`.
  The static musl build avoids the GUI library deps that the branded
  `kiro-cli.deb` pulls in (`libayatana-appindicator3-1`, `libwebkit2gtk-4.1-0`,
  `libgtk-3-0`) and works on `arm64`, which the branded `.deb` doesn't ship
  yet. Same fig_auth SQLite schema as the branded CLI; kirocc reads it
  transparently.
