#!/usr/bin/env bash
# Reap unused extension versions from the host-bound caches
# (~/.vscode-extensions/shared and ~/.vscode-extensions/vscode-web).
#
# Runs after 30-extensions-activate.sh has written this workspace's lease.
# Both cache dirs are shared by every workspace on the VM, so this script is
# enforcing a host-wide rule using host-wide information: leases from EVERY
# workspace are read, not just this one's.
#
# A versioned dir `<id>-<ver>-<arch>` is deleted only when ALL of these hold:
#
#   - it is not the highest version present for <id> in that store
#     (the newest version is always kept, leased or not);
#   - it is not pinned by any manifest baked into this image;
#   - no fresh lease in shared/_leases/ references it.
#
# A lease is fresh when its mtime is younger than EXTENSIONS_LEASE_STALE_DAYS
# (default 45). Running workspaces re-touch their lease on a timer (see 30), so
# only stopped-and-forgotten or deleted workspaces go stale. Stale leases are
# removed. A workspace whose lease was reaped simply re-downloads whatever it
# needs on its next start (25 installs pinned versions if absent; unpinned ids
# just pick up the current newest).
#
# There is no time-based aging of extension versions themselves: a version
# lives as long as someone leases it or it is the newest, and dies otherwise.
#
# Set EXTENSIONS_PRUNE=0 to disable, EXTENSIONS_PRUNE_DRY_RUN=1 to log only.

set -euo pipefail

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
SHARED_EXTENSIONS_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
VSCODE_WEB_EXTENSIONS_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"
LEASES_DIR="${EXTENSIONS_LEASES_DIR:-$SHARED_EXTENSIONS_DIR/_leases}"
LEASE_STALE_DAYS="${EXTENSIONS_LEASE_STALE_DAYS:-45}"
PRUNE_ENABLED="${EXTENSIONS_PRUNE:-1}"
DRY_RUN="${EXTENSIONS_PRUNE_DRY_RUN:-0}"

log() { printf '[extensions-prune] %s\n' "$*"; }

if [ "$PRUNE_ENABLED" != "1" ]; then
  log "disabled (EXTENSIONS_PRUNE=$PRUNE_ENABLED)"
  exit 0
fi

ext_id() {
  printf '%s' "$1" | sed -E 's/-[0-9][0-9A-Za-z.+-]*(-[a-z0-9_]+(-[a-z0-9_]+)?)?$//'
}

ext_version() {
  local name="$1" id
  id="$(ext_id "$name")"
  [ "$id" = "$name" ] && { printf ''; return 0; }
  printf '%s' "${name#"$id"-}" | sed -E 's/^([0-9][0-9A-Za-z.+]*)(-.*)?$/\1/'
}

# ---------------------------------------------------------------------------
# Protection sets
# ---------------------------------------------------------------------------
declare -A pinned=()     # "<id_lc>@<ver>" -> 1
declare -A leased=()     # "<store>/<name_lc>" -> "lease1 lease2 ..."

if [ -d "$MANIFEST_DIR" ] && command -v jq >/dev/null 2>&1; then
  shopt -s nullglob
  for manifest in "$MANIFEST_DIR"/*.json; do
    while IFS= read -r spec; do
      [[ "$spec" == *"@"* ]] || continue
      id="${spec%@*}"; ver="${spec#*@}"
      pinned["${id,,}@$ver"]=1
    done < <(jq -r '((.shared // []) + (.shared_marketplace // []) + (.vscode_web_only // []))[]' "$manifest" 2>/dev/null || true)
  done
fi

read_leases() {
  [ -d "$LEASES_DIR" ] || { log "no leases dir at $LEASES_DIR; nothing is protected beyond newest+pinned"; return 0; }
  local cutoff now fresh=0 stale=0
  now="$(date +%s)"
  cutoff=$((now - LEASE_STALE_DAYS * 86400))
  shopt -s nullglob
  local lease m name line
  for lease in "$LEASES_DIR"/*; do
    [ -f "$lease" ] || continue
    name="$(basename "$lease")"
    case "$name" in .*) continue ;; esac
    m="$(stat -c '%Y' "$lease" 2>/dev/null || echo 0)"
    if [ "$m" -lt "$cutoff" ]; then
      stale=$((stale + 1))
      if [ "$DRY_RUN" = "1" ]; then
        log "would remove stale lease $name (last refreshed $(( (now - m) / 86400 ))d ago)"
      else
        rm -f -- "$lease"
        log "removed stale lease $name (last refreshed $(( (now - m) / 86400 ))d ago)"
      fi
      continue
    fi
    fresh=$((fresh + 1))
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      line="${line,,}"
      leased["$line"]="${leased[$line]:-}${leased[$line]:+ }$name"
    done < "$lease"
  done
  log "leases: $fresh fresh, $stale stale (stale after ${LEASE_STALE_DAYS}d)"
}

# ---------------------------------------------------------------------------
# Prune one store. <label> is the prefix used in lease lines ("shared" or
# "vscode-web").
# ---------------------------------------------------------------------------
prune_store() {
  local label="$1" store="$2"
  [ -d "$store" ] || return 0
  shopt -s nullglob

  # Group versioned dirs by id, tracking the highest version per id.
  declare -A newest_name=()
  declare -A newest_ver=()
  declare -a entries=()
  local entry name id id_lc ver
  for entry in "$store"/*/; do
    entry="${entry%/}"
    [ -L "$entry" ] && continue
    name="$(basename "$entry")"
    case "$name" in _*|.*) continue ;; esac
    id="$(ext_id "$name")"
    if [ -z "$id" ] || [ "$id" = "$name" ]; then continue; fi
    ver="$(ext_version "$name")"
    [ -n "$ver" ] || continue
    id_lc="${id,,}"
    entries+=("$name")
    if [ -z "${newest_name[$id_lc]:-}" ]; then
      newest_name["$id_lc"]="$name"; newest_ver["$id_lc"]="$ver"
    elif [ "$ver" != "${newest_ver[$id_lc]}" ] && [ "$(printf '%s\n%s\n' "${newest_ver[$id_lc]}" "$ver" | sort -V | tail -n1)" = "$ver" ]; then
      newest_name["$id_lc"]="$name"; newest_ver["$id_lc"]="$ver"
    fi
  done

  local removed=0 kept=0 freed_kb=0 sz
  for name in "${entries[@]}"; do
    id="$(ext_id "$name")"; id_lc="${id,,}"; ver="$(ext_version "$name")"
    if [ "$name" = "${newest_name[$id_lc]}" ]; then
      continue
    fi
    if [ -n "${pinned[$id_lc@$ver]:-}" ]; then
      kept=$((kept + 1))
      log "keep $label/$name (pinned by image manifest)"
      continue
    fi
    local key="$label/${name,,}"
    if [ -n "${leased[$key]:-}" ]; then
      kept=$((kept + 1))
      log "keep $label/$name (leased by: ${leased[$key]})"
      continue
    fi
    sz="$(du -sk -- "$store/$name" 2>/dev/null | cut -f1 || echo 0)"
    freed_kb=$((freed_kb + sz))
    removed=$((removed + 1))
    if [ "$DRY_RUN" = "1" ]; then
      log "would remove $label/$name ($((sz / 1024)) MB; newest is ${newest_name[$id_lc]})"
    else
      rm -rf -- "$store/$name"
      log "removed $label/$name ($((sz / 1024)) MB; newest is ${newest_name[$id_lc]})"
    fi
  done
  log "$label: ${#entries[@]} versioned dirs, removed $removed ($((freed_kb / 1024)) MB), kept $kept older versions (pinned/leased)"
}

read_leases
prune_store "shared"     "$SHARED_EXTENSIONS_DIR"
prune_store "vscode-web" "$VSCODE_WEB_EXTENSIONS_DIR"
log "done"
