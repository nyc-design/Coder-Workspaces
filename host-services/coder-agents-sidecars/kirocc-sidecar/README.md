# kirocc sidecar

Tiny Go proxy ([d-kuro/kirocc](https://github.com/d-kuro/kirocc)) that exposes
the Anthropic Messages API at `127.0.0.1:9090` backed by a Kiro Builder ID
OAuth token. The dispatcher routes any request whose `model` starts with
`kiro/` here (after stripping the prefix).

## Bootstrap

kirocc has no built-in login flow — it reads tokens from the SQLite database
that the official `kiro` CLI writes (`~/.local/share/kiro-cli/data.sqlite3`).
On a machine that has `kiro` installed and signed in:

```bash
kiro auth login
docker cp ~/.local/share/kiro-cli/data.sqlite3 \
  coder-agents-sidecars:/data/auth/kirocc/data.sqlite3
docker exec coder-agents-sidecars chmod 600 /data/auth/kirocc/data.sqlite3
docker restart coder-agents-sidecars
```

The DB lives on the `coder-agents-sidecars-auth` named volume, so the copy is
a one-time step that survives image rebuilds.

## Auth

- **Inbound:** `kirocc -api-key` enforces the shared bearer that the
  dispatcher forwards (same `SIDECAR_SHARED_API_KEY` used elsewhere).
- **Upstream:** OAuth handled internally by kirocc; rotates via the same
  refresh flow as the `kiro` CLI.

## Versioning

Pinned in the Dockerfile via `ARG KIROCC_VERSION=v0.1.0` and downloaded from
`https://github.com/d-kuro/kirocc/releases`.
