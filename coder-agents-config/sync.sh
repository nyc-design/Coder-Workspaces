#!/usr/bin/env bash
# sync.sh — apply this directory's YAML files against a running Coder
# deployment via the experimental Coder Agents config API.
#
# Modes:
#   push (default)  Apply YAML → Coder. See per-resource semantics below.
#   pull            Inverse: dump current Coder admin state → YAML files
#                   in the config dir. Useful for bootstrapping or refreshing
#                   from values you've tuned in the UI.
#
# Per-resource sync semantics on push:
#   providers       additive   (POST if missing, PATCH if exists; never delete)
#   models          declarative (POST/PATCH desired; DELETE any model not in YAML)
#   mcp servers     additive   (POST if missing, PATCH if exists; never delete)
#   system prompt   PUT singleton
#
# Required env:
#   CODER_URL              base URL of the Coder deployment
#   CODER_SESSION_TOKEN    admin session token (Owner role)
#   LLM_GATEWAY_API_KEY client-facing OmniRoute/Headroom gateway key (push only)
#   CONTEXT7_API_KEY       Context7 API key (push only)
#   GITHUB_PAT             GitHub PAT for the github MCP server (push only)
#
# Tooling: bash, curl, jq, yq (mikefarah/yq v4+), envsubst.
# All four are available on github-hosted runners by default.
#
# Stable keys per resource:
#   providers       provider field (anthropic | openai | google | …)
#   models          (provider, model) tuple
#   mcp servers     slug field

set -euo pipefail

MODE="push"
CONFIG_DIR="coder-agents-config"

# Accept either ordering: `sync.sh <dir>`, `sync.sh <mode>`, or
# `sync.sh <mode> <dir>`. Bare arg is treated as dir for backwards compat.
case "${1:-}" in
  push|pull) MODE="$1"; CONFIG_DIR="${2:-$CONFIG_DIR}" ;;
  "")        : ;;
  *)         CONFIG_DIR="$1" ;;
esac

: "${CODER_URL:?CODER_URL must be set}"
: "${CODER_SESSION_TOKEN:?CODER_SESSION_TOKEN must be set}"

AUTH_HEADER="Coder-Session-Token: ${CODER_SESSION_TOKEN}"

expand_yaml() { envsubst < "$1" | yq -o=json '.'; }

# Wrappers: print response body on HTTP error so 4xx/5xx aren't opaque.
_curl() {
  local method="$1" path="$2" data="${3-}"
  local out status
  if [ -n "$data" ]; then
    out="$(curl -sS -w $'\n%{http_code}' -X "$method" -H "$AUTH_HEADER" -H 'Content-Type: application/json' -d "$data" "${CODER_URL}${path}")"
  else
    out="$(curl -sS -w $'\n%{http_code}' -X "$method" -H "$AUTH_HEADER" "${CODER_URL}${path}")"
  fi
  status="${out##*$'\n'}"
  body="${out%$'\n'*}"
  if [ "$status" -ge 400 ]; then
    echo "    HTTP $status on $method $path" >&2
    echo "    request:  $(printf '%s' "$data" | head -c 500)" >&2
    echo "    response: $(printf '%s' "$body" | head -c 1000)" >&2
    return 22
  fi
  printf '%s' "$body"
}
coder_get()    { _curl GET    "$1"; }
coder_post()   { _curl POST   "$1" "$2"; }
coder_patch()  { _curl PATCH  "$1" "$2"; }
coder_delete() { _curl DELETE "$1"; }

# ───────── PROVIDERS (additive) ─────────────────────────────────────────────
push_providers() {
  local file="$CONFIG_DIR/providers.yaml"
  [ -f "$file" ] || { echo "no providers.yaml, skipping"; return; }

  echo "==> syncing providers from $file"
  local desired current
  desired="$(expand_yaml "$file")"
  current="$(coder_get '/api/experimental/chats/providers')"

  echo "$desired" | jq -c '.providers[]' | while read -r p; do
    local provider existing_id
    provider="$(jq -r '.provider' <<< "$p")"
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

# ───────── MODELS (declarative) ─────────────────────────────────────────────
# Sync flow:
#   1. POST/PATCH every model in YAML
#   2. After step 1 succeeds, DELETE any model in Coder whose (provider, model)
#      is NOT in YAML. Order matters — we need everything in YAML in place
#      first, in case one of those needs to become the new default before we
#      can delete the old one.
push_models() {
  local file="$CONFIG_DIR/models.yaml"
  [ -f "$file" ] || { echo "no models.yaml, skipping"; return; }

  echo "==> syncing model configs from $file (declarative)"
  local desired current
  desired="$(expand_yaml "$file")"
  current="$(coder_get '/api/experimental/chats/model-configs')"

  # Phase 1: apply desired (POST or PATCH)
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

  # Phase 2: delete anything in Coder but not in desired
  current="$(coder_get '/api/experimental/chats/model-configs')"
  echo "$current" | jq -c '.[]' | while read -r m; do
    local provider model id in_desired
    provider="$(jq -r '.provider' <<< "$m")"
    model="$(jq -r '.model' <<< "$m")"
    id="$(jq -r '.id' <<< "$m")"
    in_desired="$(echo "$desired" | jq --arg p "$provider" --arg m "$model" \
      'any(.models[]; .provider == $p and .model == $m)')"

    if [ "$in_desired" = "false" ]; then
      echo "    DELETE $provider/$model ($id) — not in YAML"
      coder_delete "/api/experimental/chats/model-configs/$id" >/dev/null
    fi
  done
}

# ───────── MCP SERVERS (additive) ───────────────────────────────────────────
push_mcp_servers() {
  local file="$CONFIG_DIR/mcp-servers.yaml"
  [ -f "$file" ] || { echo "no mcp-servers.yaml, skipping"; return; }

  echo "==> syncing MCP servers from $file"
  local desired current
  desired="$(expand_yaml "$file")"
  current="$(coder_get '/api/experimental/mcp/servers')"

  echo "$desired" | jq -c '.mcp_servers[]' | while read -r s; do
    local slug existing_id
    slug="$(jq -r '.slug' <<< "$s")"
    existing_id="$(jq -r --arg s "$slug" '.[] | select(.slug == $s) | .id' <<< "$current" | head -n1)"

    if [ -n "$existing_id" ] && [ "$existing_id" != "null" ]; then
      echo "    PATCH $slug ($existing_id)"
      coder_patch "/api/experimental/mcp/servers/$existing_id" "$s" >/dev/null
    else
      echo "    POST  $slug (new)"
      coder_post "/api/experimental/mcp/servers" "$s" >/dev/null
    fi
  done
}

# ───────── SYSTEM PROMPT (PUT singleton) ────────────────────────────────────
# system-prompt.txt may begin with optional YAML frontmatter (between two
# `---` delimiters) carrying toggle fields like include_default_system_prompt.
# When present, frontmatter is stripped from the body and merged into the
# PUT JSON. Default include_default_system_prompt=true if absent — without
# explicitly sending it the Coder admin toggle gets flipped off.
push_system_prompt() {
  local file="$CONFIG_DIR/system-prompt.txt"
  [ -f "$file" ] || { echo "no system-prompt.txt, skipping"; return; }

  echo "==> syncing system prompt from $file"

  local frontmatter body include_default
  if [ "$(head -n1 "$file")" = "---" ]; then
    frontmatter="$(awk 'NR==1 && $0=="---" {fm=1; next} fm==1 && $0=="---" {fm=2; next} fm==1' "$file")"
    body="$(awk 'NR==1 && $0=="---" {fm=1; next} fm==1 && $0=="---" {fm=2; next} fm==2' "$file")"
    include_default="$(printf '%s' "$frontmatter" | yq -r '.include_default_system_prompt // true')"
  else
    body="$(cat "$file")"
    include_default="true"
  fi

  local req_body
  req_body="$(jq -n \
    --arg p "$body" \
    --argjson i "$include_default" \
    '{system_prompt: $p, include_default_system_prompt: $i}')"

  curl -sS --fail-with-body -X PUT \
    -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
    -d "$req_body" \
    "${CODER_URL}/api/experimental/chats/config/system-prompt" >/dev/null
  echo "    PUT system prompt ($(printf '%s' "$body" | wc -c) bytes, include_default_system_prompt=$include_default)"
}

# ───────── PLAN MODE INSTRUCTIONS (PUT singleton) ───────────────────────────
push_plan_mode_instructions() {
  local file="$CONFIG_DIR/plan-mode-instructions.txt"
  [ -f "$file" ] || { echo "no plan-mode-instructions.txt, skipping"; return; }

  echo "==> syncing plan mode instructions from $file"
  local body
  body="$(jq -n --rawfile p "$file" '{plan_mode_instructions: $p}')"
  curl -sS --fail-with-body -X PUT \
    -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
    -d "$body" \
    "${CODER_URL}/api/experimental/chats/config/plan-mode-instructions" >/dev/null
  echo "    PUT plan-mode-instructions ($(wc -c < "$file") bytes)"
}

# ───────── TEMPLATE ALLOWLIST (PUT singleton) ───────────────────────────────
# Coder Agents stores the allowlist as template UUIDs. We track template slugs
# in YAML for readability — resolve slug → UUID at sync time via the v2
# templates endpoint (slugs match the `name` field).
push_template_allowlist() {
  local file="$CONFIG_DIR/template-allowlist.yaml"
  [ -f "$file" ] || { echo "no template-allowlist.yaml, skipping"; return; }

  echo "==> syncing template allowlist from $file"
  local desired_slugs templates ids body slug
  desired_slugs="$(yq -o=json '.allowed_templates // []' "$file")"
  templates="$(coder_get '/api/v2/templates')"

  ids='[]'
  for slug in $(echo "$desired_slugs" | jq -r '.[]'); do
    local id
    id="$(jq -r --arg n "$slug" '.[] | select(.name == $n) | .id' <<< "$templates" | head -n1)"
    if [ -z "$id" ] || [ "$id" = "null" ]; then
      echo "    WARN  template slug '$slug' not found in deployment; skipping" >&2
      continue
    fi
    echo "    resolve $slug → $id"
    ids="$(echo "$ids" | jq --arg id "$id" '. + [$id]')"
  done

  body="$(jq -n --argjson ids "$ids" '{template_ids: $ids}')"
  curl -sS --fail-with-body -X PUT \
    -H "$AUTH_HEADER" -H 'Content-Type: application/json' \
    -d "$body" \
    "${CODER_URL}/api/experimental/chats/config/template-allowlist" >/dev/null
  echo "    PUT template-allowlist ($(echo "$ids" | jq 'length') templates)"
}

# ───────── PULL MODE ────────────────────────────────────────────────────────
# Dumps current Coder admin state to the YAML files. Useful for bootstrapping
# from existing UI configs or refreshing after manual edits in the admin UI.
#
# - providers.yaml: includes all DB-backed providers (skips stub entries)
# - models.yaml: every model config
# - mcp-servers.yaml: every MCP server
# - system-prompt.txt: current prompt content
#
# Secret values (api_key, custom_headers values) come back as `has_*: true`
# booleans only — actual values are never readable. Pull preserves any
# `${VAR}` placeholders already in your YAML by NOT replacing those fields
# when the GET response signals presence; if you want a clean dump, delete
# the YAML files first and re-run pull. Then re-add `${VAR}` references for
# secrets manually.
# prettify_yaml — yq's default emit packs list items with no separator
# between them. For the human-edited yaml files we want a blank line before
# each top-level list item (`^  - `) so blocks are easy to scan. The awk
# rule skips the first item and any item whose previous line is already
# blank or the parent map key (e.g. "models:").
prettify_yaml() {
  awk '
    /^  - / && NR > 1 && prev != "" && prev !~ /^[A-Za-z_]+:$/ { print "" }
    { print; prev = $0 }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

pull_all() {
  echo "==> pulling current admin state into $CONFIG_DIR/"

  # Providers — strip stub entries (id == Nil UUID), keep all DB rows
  echo "  providers.yaml"
  coder_get '/api/experimental/chats/providers' | \
    jq '{providers: [.[] | select(.id != "" and .id != "00000000-0000-0000-0000-000000000000")
                    | {provider, display_name, base_url,
                       api_key: (if .has_api_key then "${LLM_GATEWAY_API_KEY}" else null end),
                       enabled, central_api_key_enabled, allow_user_api_key,
                       allow_central_api_key_fallback}
                    | with_entries(select(.value != null))]}' | \
    yq -o=yaml -P '.' > "$CONFIG_DIR/providers.yaml.new"
  prettify_yaml "$CONFIG_DIR/providers.yaml.new"

  echo "  models.yaml"
  coder_get '/api/experimental/chats/model-configs' | \
    jq '{models: [.[] | {provider, model, display_name, enabled, is_default,
                         context_limit, compression_threshold, model_config}
                  | with_entries(select(.value != null))]}' | \
    yq -o=yaml -P '.' > "$CONFIG_DIR/models.yaml.new"
  prettify_yaml "$CONFIG_DIR/models.yaml.new"

  echo "  mcp-servers.yaml"
  coder_get '/api/experimental/mcp/servers' | \
    jq '{mcp_servers: [.[] | {slug, display_name, description, icon_url, transport, url,
                              auth_type, availability,
                              custom_headers: (if .has_custom_headers
                                               then {Authorization: "${...}"} else null end)}
                       | with_entries(select(.value != null))]}' | \
    yq -o=yaml -P '.' > "$CONFIG_DIR/mcp-servers.yaml.new"
  prettify_yaml "$CONFIG_DIR/mcp-servers.yaml.new"

  echo "  system-prompt.txt"
  coder_get '/api/experimental/chats/config/system-prompt' | \
    jq -r '.system_prompt' > "$CONFIG_DIR/system-prompt.txt.new"

  echo "  plan-mode-instructions.txt"
  coder_get '/api/experimental/chats/config/plan-mode-instructions' | \
    jq -r '.plan_mode_instructions' > "$CONFIG_DIR/plan-mode-instructions.txt.new"

  # Template allowlist — convert UUIDs back to slugs via v2 templates list
  # for readability (matching how the file is committed).
  echo "  template-allowlist.yaml"
  local allowlist templates slugs
  allowlist="$(coder_get '/api/experimental/chats/config/template-allowlist')"
  templates="$(coder_get '/api/v2/templates')"
  slugs="$(jq -n --argjson a "$allowlist" --argjson t "$templates" \
    '{allowed_templates: ($a.template_ids // []) | map(. as $id | ($t[] | select(.id == $id) | .name)) | sort}')"
  echo "$slugs" | yq -o=yaml -P '.' > "$CONFIG_DIR/template-allowlist.yaml.new"

  echo
  echo "Wrote *.new files alongside existing YAML. Diff and rename:"
  echo "  diff $CONFIG_DIR/providers.yaml{,.new}              && mv $CONFIG_DIR/providers.yaml{.new,}"
  echo "  diff $CONFIG_DIR/models.yaml{,.new}                 && mv $CONFIG_DIR/models.yaml{.new,}"
  echo "  diff $CONFIG_DIR/mcp-servers.yaml{,.new}            && mv $CONFIG_DIR/mcp-servers.yaml{.new,}"
  echo "  diff $CONFIG_DIR/template-allowlist.yaml{,.new}     && mv $CONFIG_DIR/template-allowlist.yaml{.new,}"
  echo "  diff $CONFIG_DIR/system-prompt.txt{,.new}           && mv $CONFIG_DIR/system-prompt.txt{.new,}"
  echo "  diff $CONFIG_DIR/plan-mode-instructions.txt{,.new}  && mv $CONFIG_DIR/plan-mode-instructions.txt{.new,}"
  echo
  echo "Heads up: secret fields come back as opaque placeholders. Restore"
  echo "your \${VAR} references in api_key / custom_headers before committing."
}

case "$MODE" in
  push)
    # Order matters: providers → models (with delete pass) → MCPs → prompts.
    # Coder rejects model creation if its provider isn't already configured.
    push_providers
    push_models
    push_mcp_servers
    push_system_prompt
    push_plan_mode_instructions
    push_template_allowlist
    echo "==> push done"
    ;;
  pull)
    pull_all
    ;;
esac
