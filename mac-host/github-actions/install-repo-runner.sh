#!/bin/zsh
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTROL_SOURCE="$SCRIPT_DIR/../coder-mac-control"
CONTROL_BIN="$HOME/.local/bin/coder-mac-control"

if [[ $# -ne 1 ]]; then
  echo "usage: $0 OWNER/REPO" >&2
  exit 2
fi

REPO="$1"
if [[ "$REPO" != */* ]]; then
  echo "repository must be in OWNER/REPO form" >&2
  exit 2
fi

command -v gh >/dev/null || {
  echo "GitHub CLI (gh) is required." >&2
  exit 1
}
gh auth status >/dev/null

ARCH="$(uname -m)"
if [[ "$ARCH" != "arm64" ]]; then
  echo "This installer currently targets Apple Silicon (arm64); got $ARCH." >&2
  exit 1
fi

RUNNER_TAG="$(gh api repos/actions/runner/releases/latest --jq '.tag_name')"
RUNNER_VERSION="${RUNNER_TAG#v}"
ASSET="actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
DOWNLOAD_URL="https://github.com/actions/runner/releases/download/${RUNNER_TAG}/${ASSET}"
SLUG="${REPO//\//-}"
RUNNER_DIR="$HOME/actions-runners/$SLUG"
RUNNER_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname)-${REPO##*/}"
LABELS="swift-ci,xcode,visionos"

mkdir -p "$RUNNER_DIR" "$HOME/.local/bin"
cp "$CONTROL_SOURCE" "$CONTROL_BIN"
chmod 700 "$CONTROL_BIN"
cd "$RUNNER_DIR"

if [[ -f .runner ]]; then
  echo "Runner already configured at $RUNNER_DIR" >&2
  echo "Remove it with ./config.sh remove before re-running this installer." >&2
  exit 1
fi

TMP_ARCHIVE="$(mktemp -t actions-runner).tar.gz"
trap 'rm -f "$TMP_ARCHIVE"' EXIT
curl -fL "$DOWNLOAD_URL" -o "$TMP_ARCHIVE"
tar xzf "$TMP_ARCHIVE"

REG_TOKEN="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq '.token')"

./config.sh \
  --unattended \
  --url "https://github.com/$REPO" \
  --token "$REG_TOKEN" \
  --name "$RUNNER_NAME" \
  --labels "$LABELS" \
  --work _work

./svc.sh install

# A prior controller invocation may have persisted this launchd label as
# disabled. Resolve the generated service label from GitHub's .service file,
# re-enable it, then start the runner.
if [[ -f .service ]]; then
  SERVICE_PLIST="$(cat .service)"
  SERVICE_LABEL="$(basename "$SERVICE_PLIST" .plist)"
  launchctl enable "gui/$(id -u)/$SERVICE_LABEL" >/dev/null 2>&1 || true
fi
./svc.sh start

cat <<EOF
Self-hosted GitHub Actions runner installed for $REPO.

Directory: $RUNNER_DIR
Runner:    $RUNNER_NAME
Labels:    self-hosted, macOS, ARM64, $LABELS

Persistent controls for ALL configured runners:
  $CONTROL_BIN github on
  $CONTROL_BIN github off
  $CONTROL_BIN github toggle
  $CONTROL_BIN github status

Service status for this runner:
  cd "$RUNNER_DIR" && ./svc.sh status

Run this installer once for each repository that should be able to dispatch Xcode CI to this Mac. Personal GitHub accounts do not have organization-level runners shared across all repositories.
EOF
