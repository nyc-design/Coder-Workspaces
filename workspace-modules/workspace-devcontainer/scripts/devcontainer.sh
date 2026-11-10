# Container entrypoint, after clone.sh and before the agent init script: apply
# the checked-out .devcontainer/devcontainer.json.
#
# Everything except the image is read here, from the checkout, as envbuilder
# did (the image has to be known before the container exists, so main.tf reads
# that one field from GitHub). This:
#   - exports containerEnv and remoteEnv, so the agent and everything it
#     starts inherit them. remoteEnv wins; CODER_* names are never overridden.
#   - writes the lifecycle commands to /tmp/workspace-devcontainer.lifecycle as
#     "<hook> <base64 command>" lines, which lifecycle.sh runs from the agent's
#     startup script.
# Problems are reported in the clone log and never stop the workspace.
rm -f /tmp/workspace-devcontainer.env /tmp/workspace-devcontainer.lifecycle
if [ -n "${WORKSPACE_CLONE_DIR:-}" ]; then
  {
    if [ ! -f "$WORKSPACE_CLONE_DIR/.devcontainer/devcontainer.json" ]; then
      echo "=== No .devcontainer/devcontainer.json in $WORKSPACE_CLONE_DIR; the workspace runs the template's default image."
    elif ! command -v python3 > /dev/null 2>&1; then
      echo "=== python3 is not installed in this image; devcontainer.json environment and lifecycle commands were skipped."
    else
      python3 - "$WORKSPACE_CLONE_DIR" << 'DEVCONTAINER_PY'
import base64, json, os, re, shlex, sys

folder = sys.argv[1]


def note(message):
    print("=== " + message)


with open(os.path.join(folder, ".devcontainer", "devcontainer.json"), encoding="utf-8-sig") as f:
    text = f.read()

# JSONC -> JSON: drop comments, then trailing commas. Strings are matched first
# so that "//" and "/*" inside them (URLs, globs) are left alone.
STRING = r'"(?:\\.|[^"\\])*"'
text = re.sub(STRING + r"|//[^\n]*|/\*.*?\*/", lambda m: m[0] if m[0][0] == '"' else " ", text, flags=re.S)
text = re.sub(STRING + r"|,(\s*[}\]])", lambda m: m[0] if m[0][0] == '"' else m[1], text)
try:
    spec = json.loads(text)
    if not isinstance(spec, dict):
        raise ValueError("not a JSON object")
except ValueError as err:
    note(f"devcontainer.json could not be parsed ({err}); its environment and lifecycle commands were skipped.")
    sys.exit(0)

if not spec.get("image"):
    note('devcontainer.json has no "image" (Dockerfile builds and features are not supported); the workspace runs the template\'s default image.')

# ── Environment ──────────────────────────────────────────────────────────────
basename = os.path.basename(folder.rstrip("/"))
KNOWN = {
    "containerWorkspaceFolder": folder,
    "localWorkspaceFolder": folder,
    "containerWorkspaceFolderBasename": basename,
    "localWorkspaceFolderBasename": basename,
}


def resolve(value):
    """Substitute ${...}; raises KeyError for a variable this cannot know."""

    def substitute(match):
        kind, _, rest = match[1].partition(":")
        if kind in ("containerEnv", "localEnv", "env") and rest:
            name, _, default = rest.partition(":")
            return os.environ.get(name, default)
        return KNOWN[match[1]]

    return re.sub(r"\$\{([^}]*)\}", substitute, value)


env, skipped = {}, set()
for section in ("containerEnv", "remoteEnv"):
    declared = spec.get(section)
    for name, value in declared.items() if isinstance(declared, dict) else ():
        env.pop(name, None)
        if value is None:
            continue
        try:
            if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", name) or name.startswith("CODER_"):
                raise KeyError(name)
            env[name] = resolve(value if isinstance(value, str) else json.dumps(value))
        except KeyError:
            skipped.add(name)
skipped -= set(env)

with open("/tmp/workspace-devcontainer.env", "w") as f:
    for name, value in env.items():
        f.write(f"export {name}={shlex.quote(value)}\n")
if skipped:
    note("Skipped devcontainer environment variables that are reserved or use an unsupported ${...} variable: " + ", ".join(sorted(skipped)) + ".")


# ── Lifecycle commands ───────────────────────────────────────────────────────
def command_lines(value):
    """A command is a string (run by sh), an argv array, or an object of named
    commands, which run in name order rather than in parallel."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [shlex.join(str(arg) for arg in value)]
    if isinstance(value, dict):
        return [line for name in sorted(value) for line in command_lines(value[name])]
    return []


with open("/tmp/workspace-devcontainer.lifecycle", "w") as f:
    for hook in ("onCreateCommand", "updateContentCommand", "postCreateCommand", "postStartCommand"):
        for command in command_lines(spec.get(hook)):
            if command.strip():
                f.write(f"{hook} {base64.b64encode(command.encode()).decode()}\n")
DEVCONTAINER_PY
    fi
  } 2>&1 | tee -a /tmp/workspace-clone.log
  # shellcheck disable=SC1091
  [ ! -f /tmp/workspace-devcontainer.env ] || . /tmp/workspace-devcontainer.env
fi
unset WORKSPACE_CLONE_URL WORKSPACE_CLONE_REF WORKSPACE_CLONE_DIR WORKSPACE_CLONE_TOKEN
