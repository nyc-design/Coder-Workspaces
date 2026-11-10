#!/usr/bin/env bash
# Curate editor extension directories from the shared OpenVSX cache.
#
# 25-extensions-install.sh installs manifest-declared extensions into the
# host-bound shared cache (~/.vscode-extensions/shared). This script runs after
# that install step and:
#
#   1. PROMOTE: if a per-editor dir has a REAL (non-symlink) extension dir
#      whose id is in the active manifest set, move it into the shared cache
#      and replace it with a symlink. This is how code-server UI updates
#      ("Update" button / auto-update) get reconciled: the UI installs into the
#      per-editor dir, we move it into shared/ on next start so other editors
#      and other workspaces see it too, and 25-extensions-install.sh's manifest
#      pin (if any) will re-assert the pinned version on the next start.
#
#   2. SYNC: for each id in the active manifest set, resolve exactly ONE
#      active version from the shared cache -- the manifest-pinned version if
#      a pin exists and is present, otherwise the highest version number
#      that the editor's VS Code version can run (`engines.vscode`) -- and
#      symlink only that version into each per-editor dir (code-server,
#      vscode-web, vscode-server, cursor-server). Editors differ in VS Code
#      version, so they can resolve different versions of one id. vscode-web's
#      dir also links the Marketplace-only extensions from its host-bound
#      store (~/.vscode-extensions/vscode-web). Any other symlinks for the
#      same id are removed so the editor has a single candidate and the active
#      version is deterministic. Stale symlinks (manifest dropped, or target
#      gone) are pruned. Real (non-symlink, non-manifest) entries -- e.g.
#      user-installed extensions -- are never touched.
#
#   3. RECONCILE: bring each editor's own registry (`extensions.json` and
#      `.obsolete` in its extensions dir) in line with the symlinks SYNC just
#      made. The editors trust that registry and do not rescan the directory,
#      so without this a repointed id keeps an entry for the version that is
#      gone ("Invalid extensions detected") while the version now linked is
#      unknown to the editor, which flags it obsolete and removes the link.
#
#   4. LEASE: write shared/_leases/<owner>--<workspace> listing every versioned
#      dir this workspace activated (in shared/ and vscode-web/). Leases live
#      inside the host-bound cache, so every workspace on the VM can read every
#      other workspace's lease. 31-extensions-prune.sh only deletes versions
#      that no fresh lease references and that are not the newest for their
#      id. A background refresher re-touches the lease every few hours so a
#      long-running workspace never looks abandoned.

set -euo pipefail

MANIFEST_DIR="${MANIFEST_DIR:-/usr/local/share/workspace-extensions.d}"
WORKSPACES_ROOT="${WORKSPACES_ROOT:-/workspaces}"
SHARED_EXTENSIONS_DIR="${SHARED_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/shared}"
CODE_SERVER_EXTENSIONS_DIR="${CODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/code-server}"
# Host-bound store of Marketplace-only extensions, shared by every workspace.
VSCODE_WEB_EXTENSIONS_DIR="${VSCODE_WEB_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web}"
# The dir vscode-web actually runs on: per-workspace, symlinks only. It used to
# run on the store itself, where every workspace rewrote the same symlinks and
# the same extensions.json.
VSCODE_WEB_EDITOR_EXTENSIONS_DIR="${VSCODE_WEB_EDITOR_EXTENSIONS_DIR:-/home/coder/.vscode-extensions/vscode-web-editor}"
VSCODE_SERVER_EXTENSIONS_DIR="${VSCODE_SERVER_EXTENSIONS_DIR:-/home/coder/.vscode-server/extensions}"
CURSOR_SERVER_EXTENSIONS_DIR="${CURSOR_SERVER_EXTENSIONS_DIR:-/home/coder/.cursor-server/extensions}"
LEASES_DIR="${EXTENSIONS_LEASES_DIR:-$SHARED_EXTENSIONS_DIR/_leases}"
LEASE_REFRESH_INTERVAL="${EXTENSIONS_LEASE_REFRESH_INTERVAL:-6h}"
LEASE_REFRESH_PIDFILE="${EXTENSIONS_LEASE_REFRESH_PIDFILE:-/tmp/extensions-lease-refresh.pid}"
# Written only after a fully successful run. 31-extensions-prune.sh refuses to
# delete anything unless it finds this marker, so a crashed or partial activate
# can never license a prune against a cache whose leases were not refreshed.
ACTIVATE_OK_MARKER="${EXTENSIONS_ACTIVATE_OK_MARKER:-/tmp/extensions-activate.ok}"

log() { printf '[extensions-activate] %s\n' "$*"; }

# The marker is removed up front: if anything below fails, it stays absent and
# the pruner stands down.
rm -f "$ACTIVATE_OK_MARKER"

# ---------------------------------------------------------------------------
# Name parsing. Versioned dirs look like `<publisher>.<name>-<ver>[-<arch>]`,
# e.g. `eamodio.gitlens-2026.7.180533-universal` or
# `anthropic.claude-code-2.1.269-linux-arm64`.
# ---------------------------------------------------------------------------

# Strip trailing -<ver>[-<arch>] to get the extension id.
ext_id() {
  printf '%s' "$1" | sed -E 's/-[0-9][0-9A-Za-z.+-]*(-[a-z0-9_]+(-[a-z0-9_]+)?)?$//'
}

# Extract the version number only (no arch suffix).
ext_version() {
  local name="$1" id
  id="$(ext_id "$name")"
  [ "$id" = "$name" ] && { printf ''; return 0; }
  printf '%s' "${name#"$id"-}" | sed -E 's/^([0-9][0-9A-Za-z.+]*)(-.*)?$/\1/'
}

# ---------------------------------------------------------------------------
# Manifest collection: ids (lowercased) and pins.
# ---------------------------------------------------------------------------

declare -A manifest_set=()
declare -A manifest_pin=()

add_manifest_id() {
  local spec="$1" id ver
  [ -n "$spec" ] || return 0
  if [[ "$spec" == *"@"* ]]; then
    id="${spec%@*}"; ver="${spec#*@}"
  else
    id="$spec"; ver=""
  fi
  manifest_set["${id,,}"]=1
  [ -n "$ver" ] && manifest_pin["${id,,}"]="$ver"
  return 0
}

collect_project_extensions() {
  local manifest="$1"
  FILE="$manifest" node <<'NODE'
const fs = require('fs');
const path = require('path');
const file = process.env.FILE;
let text;
try { text = fs.readFileSync(file, 'utf8'); } catch (e) { process.exit(0); }

function stripJsonc(input) {
  let output = '';
  let inString = false, escaped = false, lineComment = false, blockComment = false;
  for (let i = 0; i < input.length; i += 1) {
    const ch = input[i], next = input[i + 1];
    if (lineComment) { if (ch === '\n') { lineComment = false; output += ch; } continue; }
    if (blockComment) {
      if (ch === '*' && next === '/') { blockComment = false; i += 1; }
      else if (ch === '\n') output += ch;
      continue;
    }
    if (inString) {
      output += ch;
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; output += ch; continue; }
    if (ch === '/' && next === '/') { lineComment = true; i += 1; continue; }
    if (ch === '/' && next === '*') { blockComment = true; i += 1; continue; }
    output += ch;
  }

  let result = '';
  inString = false; escaped = false;
  for (let i = 0; i < output.length; i += 1) {
    const ch = output[i];
    if (inString) {
      result += ch;
      if (escaped) escaped = false;
      else if (ch === '\\') escaped = true;
      else if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; result += ch; continue; }
    if (ch === ',') {
      let next = i + 1;
      while (/\s/.test(output[next] ?? '')) next += 1;
      if (output[next] === '}' || output[next] === ']') continue;
    }
    result += ch;
  }
  return result;
}

let data;
try { data = JSON.parse(stripJsonc(text)); } catch (e) { process.exit(0); }
const base = path.basename(file);
let ids = [];
if (base === 'devcontainer.json') {
  ids = data?.customizations?.vscode?.extensions ?? [];
} else if (base === 'extensions.json') {
  ids = data?.recommendations ?? [];
}
for (const id of ids) {
  if (typeof id === 'string' && id.trim()) {
    process.stdout.write(id.trim() + '\n');
  }
}
NODE
}

# ---------------------------------------------------------------------------
# Editor VS Code versions, for `engines.vscode` checks. Empty means unknown,
# which disables the check for that editor. Each can be overridden (including
# to empty) with EXTENSIONS_<EDITOR>_VSCODE_VERSION.
# ---------------------------------------------------------------------------
highest_package_version() {
  local f v best=""
  for f in "$@"; do
    [ -f "$f" ] || continue
    v="$(jq -r '.version // empty' "$f" 2>/dev/null || true)"
    [ -n "$v" ] || continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best" "$v" | sort -V | tail -n1)" = "$v" ]; then best="$v"; fi
  done
  printf '%s' "$best"
}

shopt -s nullglob
CODE_SERVER_VSCODE_VERSION="${EXTENSIONS_CODE_SERVER_VSCODE_VERSION-$(highest_package_version /opt/code-server/lib/code-server-*/lib/vscode/package.json /opt/code-server/lib/vscode/package.json)}"
VSCODE_WEB_VSCODE_VERSION="${EXTENSIONS_VSCODE_WEB_VSCODE_VERSION-$(highest_package_version /opt/vscode-web/package.json)}"
# VS Code Desktop downloads one server per client version; the newest is the
# client in use. Unknown until the first connection.
vscode_server_root="$(dirname "$VSCODE_SERVER_EXTENSIONS_DIR")"
VSCODE_SERVER_VSCODE_VERSION="${EXTENSIONS_VSCODE_SERVER_VSCODE_VERSION-$(highest_package_version "$vscode_server_root"/cli/servers/*/server/package.json "$vscode_server_root"/bin/*/package.json)}"
CURSOR_SERVER_VSCODE_VERSION="${EXTENSIONS_CURSOR_SERVER_VSCODE_VERSION-}"

# engine_ok <editor version> <engines.vscode range>: can the editor run it?
# Mirrors VS Code's rule for the ranges extensions use (`^1.2.3`, `>=1.2.3`,
# `1.2.x`, `*`): the editor must be at least the stated version. Unknown
# editor version or an unparsable range counts as compatible.
engine_ok() {
  local have="${1%%-*}" want
  [ -n "$have" ] || return 0
  want="$(printf '%s' "$2" | sed -nE 's/^[^0-9]*([0-9]+)\.([0-9]+|x)(\.([0-9]+|x))?.*$/\1.\2.\4/p' | sed -E 's/x/0/g; s/\.$/.0/')"
  [ -n "$want" ] || return 0
  [ "$(printf '%s\n%s\n' "$want" "$have" | sort -V | tail -n1)" = "$have" ]
}

# ---------------------------------------------------------------------------
# Version resolution. For a given id, pick the single dir in <store> that
# should be active: the pinned version if present, else the highest version
# the editor can run, else (none compatible) the highest version.
# Prints the basename, or nothing if the id has no dirs in <store>.
# ---------------------------------------------------------------------------
resolve_active() {
  local store="$1" id_lc="$2" editor_ver="${3:-}" pin="${manifest_pin[$id_lc]:-}"
  local ok="" ok_ver=""
  shopt -s nullglob nocaseglob
  local candidates=("$store"/"${id_lc}"-[0-9]*/)
  shopt -u nocaseglob
  [ "${#candidates[@]}" -gt 0 ] || return 0

  local c name id best="" best_ver=""
  for c in "${candidates[@]}"; do
    c="${c%/}"
    name="$(basename "$c")"
    id="$(ext_id "$name")"
    # Guard against prefix collisions (e.g. foo.bar vs foo.bar-baz).
    [ "${id,,}" = "$id_lc" ] || continue
    local ver
    ver="$(ext_version "$name")"
    [ -n "$ver" ] || continue
    if [ -n "$pin" ] && [ "$ver" = "$pin" ]; then
      printf '%s' "$name"
      return 0
    fi
    if [ -z "$best" ]; then
      best="$name"; best_ver="$ver"
    elif [ "$ver" != "$best_ver" ] && [ "$(printf '%s\n%s\n' "$best_ver" "$ver" | sort -V | tail -n1)" = "$ver" ]; then
      best="$name"; best_ver="$ver"
    fi
    [ -n "$editor_ver" ] || continue
    engine_ok "$editor_ver" "$(jq -r '.engines.vscode // empty' "$c/package.json" 2>/dev/null || true)" || continue
    if [ -z "$ok" ]; then
      ok="$name"; ok_ver="$ver"
    elif [ "$ver" != "$ok_ver" ] && [ "$(printf '%s\n%s\n' "$ok_ver" "$ver" | sort -V | tail -n1)" = "$ver" ]; then
      ok="$name"; ok_ver="$ver"
    fi
  done
  [ -n "$ok" ] && best="$ok"
  [ -n "$best" ] && printf '%s' "$best"
  return 0
}

# ---------------------------------------------------------------------------
# PROMOTE
# ---------------------------------------------------------------------------
promote_real_to_shared() {
  local target_dir="$1"
  [ -d "$target_dir" ] || return 0
  shopt -s nullglob
  local promoted=0 dropped=0 bytes=0
  for entry in "$target_dir"/*/; do
    entry="${entry%/}"
    [ -L "$entry" ] && continue
    local name id
    name="$(basename "$entry")"
    id="$(ext_id "$name")"
    if [ -z "$id" ] || [ "$id" = "$name" ]; then continue; fi
    [ -z "${manifest_set[${id,,}]:-}" ] && continue

    local sz
    sz="$(du -sk -- "$entry" 2>/dev/null | cut -f1 || echo 0)"
    bytes=$((bytes + sz))
    local dest="$SHARED_EXTENSIONS_DIR/$name"
    if [ -e "$dest" ]; then
      # Shared cache already has this exact version (from a manifest install
      # or a promote in another workspace). Drop the local copy; SYNC will
      # symlink it if it's the active version.
      rm -rf -- "$entry"
      dropped=$((dropped + 1))
    else
      mv -- "$entry" "$dest"
      promoted=$((promoted + 1))
      log "promoted $(basename "$target_dir")/$name -> shared/"
    fi
  done
  if [ $((promoted + dropped)) -gt 0 ]; then
    log "$(basename "$target_dir"): reconciled $((promoted + dropped)) UI-installed real dir(s) ($((bytes / 1024)) MB; promoted $promoted, dropped $dropped duplicates)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# SYNC
# ---------------------------------------------------------------------------
declare -a lease_lines=()

# sync_editor_dir <editor_name> <target_dir> <do_promote> <vscode_version> [extra_store]
#   do_promote:     "1" to promote real dirs back into the shared cache. "0"
#                   for vscode-web: it installs from the Marketplace, and those
#                   builds are not put in the OpenVSX cache behind its back.
#   vscode_version: the editor's VS Code version, or empty if unknown.
#   extra_store:    a second store whose every id is linked as well, taking
#                   precedence over the shared cache (vscode-web's own store).
sync_editor_dir() {
  local editor_name="$1"
  local target_dir="$2"
  local do_promote="$3"
  local editor_ver="${4:-}"
  local extra_store="${5:-}"
  mkdir -p "$target_dir" "$SHARED_EXTENSIONS_DIR"

  if [ "$do_promote" = "1" ]; then
    promote_real_to_shared "$target_dir"
  fi

  shopt -s nullglob
  declare -A want_ids=()
  if [ "${#manifest_set[@]}" -gt 0 ]; then
    local k
    for k in "${!manifest_set[@]}"; do want_ids["$k"]=1; done
  else
    # Fail-open: no manifest available. Mirror every id in the shared cache
    # rather than hiding every extension (still one version per id).
    local src name id
    for src in "$SHARED_EXTENSIONS_DIR"/*/; do
      src="${src%/}"; name="$(basename "$src")"
      case "$name" in _*) continue ;; esac
      id="$(ext_id "$name")"
      if [ -z "$id" ] || [ "$id" = "$name" ]; then continue; fi
      want_ids["${id,,}"]=1
    done
    log "$editor_name: no manifest set found; mirroring shared cache ids"
  fi

  # Which versioned name is active per id in this editor dir.
  declare -A active_name=()
  declare -A active_store=()
  local id_lc active
  for id_lc in "${!want_ids[@]}"; do
    active="$(resolve_active "$SHARED_EXTENSIONS_DIR" "$id_lc" "$editor_ver")"
    [ -n "$active" ] && active_name["$id_lc"]="$active"
  done
  if [ -n "$extra_store" ] && [ -d "$extra_store" ]; then
    local xsrc xname xid
    for xsrc in "$extra_store"/*/; do
      xsrc="${xsrc%/}"
      [ -L "$xsrc" ] && continue
      xname="$(basename "$xsrc")"
      case "$xname" in _*|.*) continue ;; esac
      xid="$(ext_id "$xname")"
      if [ -z "$xid" ] || [ "$xid" = "$xname" ]; then continue; fi
      id_lc="${xid,,}"
      [ -n "${active_store[$id_lc]:-}" ] && continue
      active="$(resolve_active "$extra_store" "$id_lc" "$editor_ver")"
      [ -n "$active" ] || continue
      want_ids["$id_lc"]=1
      active_name["$id_lc"]="$active"
      active_store["$id_lc"]="$extra_store"
    done
  fi

  # Pass 1: drop symlinks that are stale (manifest dropped, target gone) or
  # point at a non-active version of a wanted id.
  local pruned=0 entry name id
  for entry in "$target_dir"/*; do
    [ -L "$entry" ] || continue
    name="$(basename "$entry")"
    id="$(ext_id "$name")"
    id_lc="${id,,}"
    if [ -z "${want_ids[$id_lc]:-}" ] || [ ! -e "$entry" ] || [ "${active_name[$id_lc]:-}" != "$name" ]; then
      rm -f -- "$entry"
      pruned=$((pruned + 1))
    fi
  done

  # Pass 2: link the active version of each wanted id.
  local linked=0 link src
  for id_lc in "${!active_name[@]}"; do
    name="${active_name[$id_lc]}"
    src="${active_store[$id_lc]:-$SHARED_EXTENSIONS_DIR}/$name"
    link="$target_dir/$name"
    if [ -L "$link" ] || [ ! -e "$link" ]; then
      ln -snf "$src" "$link"
      linked=$((linked + 1))
    fi
    if [ -n "${active_store[$id_lc]:-}" ]; then
      lease_lines+=("vscode-web/$name")
    else
      lease_lines+=("shared/$name")
    fi
  done

  log "$editor_name: synced (active ids: ${#active_name[@]}, linked/repointed: $linked, removed symlinks: $pruned)"

  local active_tsv=""
  for id_lc in "${!active_name[@]}"; do
    name="${active_name[$id_lc]}"
    active_tsv+="$id_lc"$'\t'"$name"$'\t'"$(ext_version "$name")"$'\n'
  done
  reconcile_registry "$editor_name" "$target_dir" "$active_tsv"
}

# ---------------------------------------------------------------------------
# RECONCILE
# ---------------------------------------------------------------------------
# reconcile_registry <editor_name> <target_dir> <active_tsv>
#   active_tsv: one "<id_lc>\t<versioned name>\t<version>" line per active id.
# Best-effort: a failure here is logged and never fails activation.
reconcile_registry() {
  local editor_name="$1" target_dir="$2" active_tsv="$3" out
  command -v node >/dev/null 2>&1 || return 0
  if out="$(DIR="$target_dir" ACTIVE="$active_tsv" INSTALL_REGISTRIES="$SHARED_EXTENSIONS_DIR/extensions.json:$VSCODE_WEB_EXTENSIONS_DIR/extensions.json" node <<'NODE' 2>&1
const fs = require('fs');
const path = require('path');
const dir = process.env.DIR;
const active = (process.env.ACTIVE || '').split('\n').filter(Boolean).map((l) => {
  const [id, name, ver] = l.split('\t');
  return { id, name, ver };
});

const readJson = (file) => {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (e) { return undefined; }
};
const writeJson = (file, data) => {
  const tmp = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(data));
  fs.renameSync(tmp, file);
};
const entryPath = (e) => (e && e.relativeLocation
  ? path.join(dir, e.relativeLocation)
  : (e && e.location && (e.location.path || e.location.fsPath)) || '');
const entryId = (e) => String((e && e.identifier && e.identifier.id) || '').toLowerCase();

// .obsolete: an active version must never be flagged for removal.
const obsoleteFile = path.join(dir, '.obsolete');
const obsolete = readJson(obsoleteFile);
let unflagged = 0;
if (obsolete && typeof obsolete === 'object' && !Array.isArray(obsolete)) {
  const keep = new Set();
  for (const a of active) { keep.add(a.name.toLowerCase()); keep.add(`${a.id}-${a.ver}`.toLowerCase()); }
  for (const key of Object.keys(obsolete)) {
    if (keep.has(key.toLowerCase())) { delete obsolete[key]; unflagged += 1; }
  }
  if (unflagged) writeJson(obsoleteFile, obsolete);
}

// extensions.json: absent means the editor has not built its registry yet and
// will scan the directory itself; unparsable is left for the editor to handle.
const registryFile = path.join(dir, 'extensions.json');
let entries = fs.existsSync(registryFile) ? readJson(registryFile) : undefined;
let added = 0, dropped = 0;
if (Array.isArray(entries)) {
  // The install step's own registries (shared cache, vscode-web store).
  const sharedByName = new Map();
  for (const file of (process.env.INSTALL_REGISTRIES || '').split(':').filter(Boolean)) {
    const installed = readJson(file);
    if (!Array.isArray(installed)) continue;
    for (const e of installed) if (e && e.relativeLocation) sharedByName.set(e.relativeLocation.toLowerCase(), e);
  }

  const missing = entries.filter((e) => !fs.existsSync(entryPath(e)));
  entries = entries.filter((e) => fs.existsSync(entryPath(e)));
  dropped = missing.length;

  for (const a of active) {
    const loc = path.join(dir, a.name);
    if (!fs.existsSync(loc)) continue;
    if (entries.some((e) => entryPath(e) === loc)) continue;
    // Metadata: the install step's record for this exact version if there is
    // one, else what this editor knew about the version it had before.
    const exact = sharedByName.get(a.name.toLowerCase());
    const template = exact || missing.find((e) => entryId(e) === a.id) || {};
    const pkg = readJson(path.join(loc, 'package.json')) || {};
    const platform = a.name.slice(`${a.id}-${a.ver}`.length).replace(/^-/, '');
    // pinned:false -- the install step records `id@version` installs as
    // pinned, which would switch off the editor's own updates for this id.
    const metadata = { ...(template.metadata || {}), installedTimestamp: Date.now(), pinned: false };
    delete metadata.size;
    if (platform) metadata.targetPlatform = platform;
    else if (!exact) metadata.targetPlatform = 'undefined';
    entries.push({
      identifier: template.identifier
        || { id: pkg.publisher && pkg.name ? `${pkg.publisher}.${pkg.name}` : a.id },
      version: typeof pkg.version === 'string' ? pkg.version : a.ver,
      location: { $mid: 1, path: loc, scheme: 'file' },
      relativeLocation: a.name,
      metadata,
    });
    added += 1;
  }
  if (added || dropped) writeJson(registryFile, entries);
}

if (added || dropped || unflagged) {
  console.log(`registry reconciled (entries added: ${added}, stale entries dropped: ${dropped}, obsolete flags cleared: ${unflagged})`);
}
NODE
  )"; then
    [ -n "$out" ] && log "$editor_name: $out"
  else
    log "$editor_name: WARN registry reconcile failed: $out"
  fi
  return 0
}

# vscode-web is its own host-bound store: Marketplace-only extensions
# (vscode_web_only) are real dirs there. Record the active version of each
# so the pruner keeps it.
lease_vscode_web_real_dirs() {
  [ -d "$VSCODE_WEB_EXTENSIONS_DIR" ] || return 0
  shopt -s nullglob
  declare -A seen=()
  local entry name id id_lc active
  for entry in "$VSCODE_WEB_EXTENSIONS_DIR"/*/; do
    entry="${entry%/}"
    [ -L "$entry" ] && continue
    name="$(basename "$entry")"
    case "$name" in _*) continue ;; esac
    id="$(ext_id "$name")"
    if [ -z "$id" ] || [ "$id" = "$name" ]; then continue; fi
    id_lc="${id,,}"
    [ -n "${seen[$id_lc]:-}" ] && continue
    seen["$id_lc"]=1
    active="$(resolve_active "$VSCODE_WEB_EXTENSIONS_DIR" "$id_lc")"
    [ -n "$active" ] && lease_lines+=("vscode-web/$active")
  done
}

# ---------------------------------------------------------------------------
# LEASE
# ---------------------------------------------------------------------------
lease_name() {
  local owner="${CODER_WORKSPACE_OWNER_NAME:-}" ws="${CODER_WORKSPACE_NAME:-}"
  [ -n "$ws" ] || ws="$(hostname 2>/dev/null || echo unknown)"
  local n="${owner:+$owner--}$ws"
  printf '%s' "$n" | tr -c 'A-Za-z0-9._-' '_'
}

write_lease() {
  mkdir -p "$LEASES_DIR"
  LEASE_PATH="$LEASES_DIR/$(lease_name)"
  local tmp
  tmp="$(mktemp "$LEASES_DIR/.tmp.XXXXXX")"
  if [ "${#lease_lines[@]}" -gt 0 ]; then
    printf '%s\n' "${lease_lines[@]}" | sort -u > "$tmp"
  else
    : > "$tmp"
  fi
  mv -f -- "$tmp" "$LEASE_PATH"
  log "lease written: $LEASE_PATH ($(wc -l < "$LEASE_PATH") entries)"
}

start_lease_refresher() {
  local lease="$1"
  if [ -f "$LEASE_REFRESH_PIDFILE" ] && kill -0 "$(cat "$LEASE_REFRESH_PIDFILE" 2>/dev/null)" 2>/dev/null; then
    return 0
  fi
  nohup setsid bash -c '
    lease="$1"; interval="$2"
    while :; do
      sleep "$interval"
      [ -f "$lease" ] || exit 0
      touch -c "$lease" 2>/dev/null || true
    done
  ' _ "$lease" "$LEASE_REFRESH_INTERVAL" > /dev/null 2>&1 &
  printf '%s' "$!" > "$LEASE_REFRESH_PIDFILE"
  log "lease refresher started (pid $!, every $LEASE_REFRESH_INTERVAL)"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# Tier 1 + Tier 2 manifests baked into the image.
if [ -d "$MANIFEST_DIR" ] && command -v jq >/dev/null 2>&1; then
  shopt -s nullglob
  for manifest in "$MANIFEST_DIR"/*.json; do
    while IFS= read -r ext; do
      add_manifest_id "$ext"
    done < <(jq -r '((.shared // []) + (.shared_marketplace // []) + (.vscode_web_only // []))[]' "$manifest" 2>/dev/null || true)
  done
fi

# Tier 3 project manifests.
if [ -d "$WORKSPACES_ROOT" ] && command -v node >/dev/null 2>&1; then
  shopt -s nullglob
  for project in "$WORKSPACES_ROOT"/*/; do
    project="${project%/}"
    name="$(basename "$project")"
    case "$name" in .*) continue ;; esac

    for manifest in "$project/.devcontainer/devcontainer.json" "$project/.vscode/extensions.json"; do
      [ -f "$manifest" ] || continue
      while IFS= read -r ext; do
        add_manifest_id "$ext"
      done < <(collect_project_extensions "$manifest")
    done
  done
fi

log "manifest extension IDs: ${#manifest_set[@]} (pinned: ${#manifest_pin[@]})"

log "editor VS Code versions: code-server=${CODE_SERVER_VSCODE_VERSION:-unknown} vscode-web=${VSCODE_WEB_VSCODE_VERSION:-unknown} vscode-server=${VSCODE_SERVER_VSCODE_VERSION:-unknown} cursor-server=${CURSOR_SERVER_VSCODE_VERSION:-unknown}"

sync_editor_dir "code-server"    "$CODE_SERVER_EXTENSIONS_DIR"       1 "$CODE_SERVER_VSCODE_VERSION"
sync_editor_dir "vscode-web"     "$VSCODE_WEB_EDITOR_EXTENSIONS_DIR" 0 "$VSCODE_WEB_VSCODE_VERSION" "$VSCODE_WEB_EXTENSIONS_DIR"
sync_editor_dir "vscode-server"  "$VSCODE_SERVER_EXTENSIONS_DIR"     1 "$VSCODE_SERVER_VSCODE_VERSION"
sync_editor_dir "cursor-server"  "$CURSOR_SERVER_EXTENSIONS_DIR"     1 "$CURSOR_SERVER_VSCODE_VERSION"
lease_vscode_web_real_dirs

LEASE_PATH=""
write_lease
start_lease_refresher "$LEASE_PATH"

printf '%s\n' "$LEASE_PATH" > "$ACTIVATE_OK_MARKER"
log "activate completed; prune is cleared to run"
