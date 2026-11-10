# Container entrypoint, after fix-ownership.sh and before the agent init script
# that main.tf appends: clone the project if its folder is empty.
#
# Cloning here, not from the agent, keeps the order envbuilder had: the
# repository exists before the agent connects, so the agent's startup script,
# the editor and anything opening the project folder can rely on it.
#
# A failed clone never stops the workspace. The agent still starts, the
# startup script shows this log, and the next start tries again because the
# folder is still empty.
#
# Settings arrive as WORKSPACE_CLONE_* container env (see main.tf). The token is
# handed to git by an inline credential helper, so it is not written to
# ~/.git-credentials or .git/config, and the image's own helper is not used.
if [ -n "${WORKSPACE_CLONE_URL:-}" ] && [ -n "${WORKSPACE_CLONE_DIR:-}" ]; then
  {
    mkdir -p "$WORKSPACE_CLONE_DIR"
    if [ -n "$(ls -A "$WORKSPACE_CLONE_DIR" 2> /dev/null)" ]; then
      echo "=== $WORKSPACE_CLONE_DIR already has content; not cloning."
    elif ! command -v git > /dev/null 2>&1; then
      echo "=== Clone failed: git is not installed in this image. The workspace starts without the project."
    else
      echo "=== Cloning $WORKSPACE_CLONE_URL${WORKSPACE_CLONE_REF:+ (branch $WORKSPACE_CLONE_REF)} into $WORKSPACE_CLONE_DIR"
      # shellcheck disable=SC2016  # expanded by git's shell, not this one
      if GIT_TERMINAL_PROMPT=0 git \
        -c credential.helper= \
        -c 'credential.helper=!f() { test "$1" = get && printf "username=x-access-token\npassword=%s\n" "$WORKSPACE_CLONE_TOKEN"; }; f' \
        clone ${WORKSPACE_CLONE_REF:+--branch "$WORKSPACE_CLONE_REF"} -- "$WORKSPACE_CLONE_URL" "$WORKSPACE_CLONE_DIR"; then
        echo "=== Clone finished."
      else
        echo "=== Clone failed. The workspace starts without the project; check the repository name and GitHub access, then restart to retry."
      fi
    fi
  } 2>&1 | tee /tmp/workspace-clone.log
fi
unset WORKSPACE_CLONE_URL WORKSPACE_CLONE_REF WORKSPACE_CLONE_DIR WORKSPACE_CLONE_TOKEN
