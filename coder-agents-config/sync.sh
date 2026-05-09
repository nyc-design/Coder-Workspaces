#!/usr/bin/env bash
# sync.sh — apply this directory's YAML files against a running Coder
# deployment via the experimental Coder Agents config API. Idempotent: items
# in YAML are POSTed if missing (matched by stable key) or PATCHed by UUID if
# already present. Items only present in Coder (not in YAML) are left alone.
#
# Required env:
#   CODER_URL              base URL of the Coder deployment
#   CODER_SESSION_TOKEN    admin session token (Owner role)
#   SIDECAR_SHARED_API_KEY shared secret for the host-services sidecars
#   CONTEXT7_API_KEY       Context7 API key
#   GITHUB_PAT             GitHub PAT for the github MCP server
#
# Tooling: requires bash, curl, jq, yq (mikefarah/yq v4+), envsubst.
# All four are available on github-hosted runners by default.
#
# Stable keys per resource:
#   providers       provider field (anthropic | openai | google | …)
#   models          (provider, model) tuple
#   mcp servers     slug field

set -euo pipefail

CONFIG_DIR="${1:-coder-agents-config}"
: "${CODER_URL:?CODER_URL must be set}"
: "${CODER_SESSION_TOKEN:?CODER_SESSION_TOKEN must be set}"

AUTH_HEADER="Coder-Session-Token: ${CODER_SESSION_TOKEN}"

# expand_yaml — substitute ${VAR} placeholders, then convert YAML to JSON.
# We only expand vars that are in env to avoid eating literal `${...}`.
expand_yaml() {
  envsubst < "$1" | yq -o=json '.'
}

# coder_get / coder_post / coder_patch — thin curl wrappers with the auth
# header pre-set. All return the response body on stdout, fail-fast on HTTP
# error (curl --fail-with-body so we still see error JSON).
coder_get()   { curl -sS --fail-with-body -H "$AUTH_HEADER" "${CODER_URL}$1"; }
coder_post()  { curl -sS --fail-with-body -X POST  -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d "$2" "${CODER_URL}$1"; }
coder_patch() { curl -sS --fail-with-body -X PATCH -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d "$2" "${CODER_URL}$1"; }

# ───────── PROVIDERS ────────────────────────────────────────────────────────
sync_providers() {
  local file="$CONFIG_DIR/providers.yaml"
  [ -f "$file" ] || { echo "no providers.yaml, skipping"; return; }

  echo "==> syncing providers from $file"
  local desired current
  desired="$(expand_yaml "$file")"
  current="$(coder_get '/api/experimental/chats/providers')"

  echo "$desired" | jq -c '.providers[]' | while read -r p; do
    local provider existing_id
    provider="$(jq -r '.provider' <<< "$p")"
    # Only DB-backed entries have a non-Nil UUID — stub entries from
    # SupportedProviders/EnvPreset have id="" or id="00000000-...". Filter.
    existing_id="$(jq -r --arg n "$provider" \
      '.[] | select(.provider == $n and .id != "" and .id != "00000000-0000-0000-0000-000000000000") | .id' \
      <<< "$current" | head -n1)"

    if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
      echo "    PATCH $provider ($existing_id)"
      coder_patch "/api/experimental/chats/providers/$existing_id" "$p" >/dev/null
    else
      echo "    POST  $provider (new)"
      coder_post "/api/experimental/chats/providers" "$p" >/dev/null
    fi
  done
}

# ───────── MODELS ───────────────────────────────────────────────────────────
sync_models() {
  local file="$CONFIG_DIR/models.yaml"
  [ -f "$file" ] || { echo "no models.yaml, skipping"; return; }

  echo "==> syncing model configs from $file"
  local desired current
  desired="$(expand_yaml "$file")"
  current="$(coder_get '/api/experimental/chats/model-configs')"

  echo "$desired" | jq -c '.models[]' | while read -r m; do
    local provider model existing_id
    provider="$(jq -r '.provider' <<< "$m")"
    model="$(jq -r '.model' <<< "$m")"
    existing_id="$(jq -r --arg p "$provider" --arg m "$model" \
      '.[] | select(.provider == $p and .model == $m) | .id' \
      <<< "$current" | head -n1)"

    if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
      echo "    PATCH $provider/$model ($existing_id)"
      coder_patch "/api/experimental/chats/model-configs/$existing_id" "$m" >/dev/null
    else
      echo "    POST  $provider/$model (new)"
      coder_post "/api/experimental/chats/model-configs" "$m" >/dev/null
    fi
  done
}

# ───────── MCP SERVERS ──────────────────────────────────────────────────────
sync_mcp_servers() {
  local file="$CONFIG_DIR/mcp-servers.yaml"
  [ -f "$file" ] || { echo "no mcp-servers.yaml, skipping"; return; }

  echo "==> syncing MCP servers from $file"
  local desired current
  desired="$(expand_yaml "$file")"
  current="$(coder_get '/api/experimental/mcp/servers')"

  echo "$desired" | jq -c '.mcp_servers[]' | while read -r s; do
    local slug existing_id
    slug="$(jq -r '.slug' <<< "$s")"
    existing_id="$(jq -r --arg s "$slug" \
      '.[] | select(.slug == $s) | .id' \
      <<< "$current" | head -n1)"

    if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
      echo "    PATCH $slug ($existing_id)"
      coder_patch "/api/experimental/mcp/servers/$existing_id" "$s" >/dev/null
    else
      echo "    POST  $slug (new)"
      coder_post "/api/experimental/mcp/servers" "$s" >/dev/null
    fi
  done
}

# ───────── SYSTEM PROMPT ────────────────────────────────────────────────────
sync_system_prompt() {
  local file="$CONFIG_DIR/system-prompt.txt"
  [ -f "$file" ] || { echo "no system-prompt.txt, skipping"; return; }

  echo "==> syncing system prompt from $file"
  local body
  body="$(jq -n --rawfile p "$file" '{system_prompt: $p}')"
  curl -sS --fail-with-body -X PUT \
    -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
    -d "$body" \
    "${CODER_URL}/api/experimental/chats/config/system-prompt" >/dev/null
  echo "    PUT system prompt ($(wc -c < "$file") bytes)"
}

# Order matters: providers must exist before models reference them.
sync_providers
sync_models
sync_mcp_servers
sync_system_prompt
echo "==> done"
