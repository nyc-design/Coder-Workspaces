#!/bin/sh
# Remove superseded versions of the workspace image from the Docker host.
#
# Runs on the provisioner (terraform local-exec), which talks to the same
# Docker daemon that runs the workspaces. Workspaces run images by digest, so
# every new build of ":latest" would otherwise leave the previous one behind.
#
#   IMAGE_REPO  repository without tag or digest, e.g. ghcr.io/org/base-dev
#   IMAGE_KEEP  the reference this workspace runs: <repo>@sha256:<digest>
#
# Every other tag or digest of IMAGE_REPO is removed, without force: Docker
# refuses to delete an image a container still uses, so a workspace running an
# older version keeps it until it restarts, and a later start cleans it up.
#
# Best-effort by design: needs only sh, curl, grep and sed (no jq on the Coder
# server image), and always exits 0 so cleanup can never fail a workspace start.
# PRUNE_DRY_RUN=1 logs what would be removed.

log() { echo "[image-prune] $*"; }

repo="${IMAGE_REPO:-}"
keep="${IMAGE_KEEP:-}"
if [ -z "$repo" ] || [ -z "$keep" ]; then
  log "IMAGE_REPO / IMAGE_KEEP not set; nothing to do"
  exit 0
fi
command -v curl >/dev/null 2>&1 || { log "curl not available; skipping"; exit 0; }

case "${DOCKER_HOST:-}" in
  "")        sock=/var/run/docker.sock ;;
  unix://*)  sock="${DOCKER_HOST#unix://}" ;;
  *)         log "DOCKER_HOST is not a unix socket; skipping"; exit 0 ;;
esac
[ -S "$sock" ] || { log "no Docker socket at $sock; skipping"; exit 0; }

api() { curl -sS --max-time 30 --unix-socket "$sock" "$@"; }

# Literal repo -> regex (dots and the like must not act as wildcards).
repo_re="$(printf '%s' "$repo" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"

images="$(api "http://docker/images/json" 2>/dev/null)" || { log "could not list images; skipping"; exit 0; }

# Every reference to this repository on the host: "<repo>:<tag>" and
# "<repo>@sha256:<digest>". Tags cannot contain '/', so "<repo>/child:tag" of a
# nested repository does not match.
refs="$(printf '%s' "$images" \
  | grep -oE "\"${repo_re}(:[A-Za-z0-9_][A-Za-z0-9_.-]*|@sha256:[0-9a-f]{64})\"" \
  | tr -d '"' | sort -u)"

removed=0; kept=0
for ref in $refs; do
  [ "$ref" = "$keep" ] && continue

  # A tag can point at the very image this workspace runs (the same build,
  # pulled by tag earlier). Removing its last tag would delete the image.
  info="$(api "http://docker/images/${ref}/json" 2>/dev/null)" || continue
  case "$info" in *"\"$keep\""*) continue ;; esac

  if [ "${PRUNE_DRY_RUN:-0}" = "1" ]; then
    log "would remove $ref"
    continue
  fi

  code="$(api -o /dev/null -w '%{http_code}' -X DELETE "http://docker/images/${ref}" 2>/dev/null)"
  case "$code" in
    200) removed=$((removed + 1)); log "removed $ref" ;;
    404) ;;  # went away with another reference to the same image
    409) kept=$((kept + 1)); log "kept $ref (in use by a container)" ;;
    *)   log "could not remove $ref (HTTP ${code:-none})" ;;
  esac
done

log "$repo: removed $removed, kept $kept in use"
exit 0
