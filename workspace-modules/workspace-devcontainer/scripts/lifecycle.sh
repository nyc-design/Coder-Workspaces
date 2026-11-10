# Devcontainer lifecycle commands, run the way envbuilder ran them: in order,
# from the project folder, on every workspace start (the container is new each
# time). A failing command is reported and the remaining ones are skipped, but
# workspace startup carries on.
#
# Head of the agent startup script. The calls are appended by main.tf with
# base64 arguments, so no command text is ever re-quoted by Terraform. Kept to
# what dash accepts: the agent runs it with the image user's shell.

devcontainer_lifecycle_failed=""

# Shows what the entrypoint's clone did (its output is otherwise only in the
# container log), then moves into the project folder.
devcontainer_enter() {
  [ ! -s /tmp/workspace-clone.log ] || cat /tmp/workspace-clone.log
  cd "$(printf '%s' "$1" | base64 -d)" 2> /dev/null || true
}

devcontainer_notice() {
  printf '=== %s\n' "$(printf '%s' "$1" | base64 -d)"
}

run_lifecycle_command() {
  local hook="$1" command log pid rc
  command="$(printf '%s' "$2" | base64 -d)"

  if [ -n "$devcontainer_lifecycle_failed" ]; then
    printf '=== Skipping %s because %s failed: %s\n' "$hook" "$devcontainer_lifecycle_failed" "$command"
    return 0
  fi

  printf '=== Running %s: %s\n' "$hook" "$command"
  log="$(mktemp)"
  # The command writes to a file and tail relays it. A command that leaves a
  # daemon behind (a postStartCommand starting a server) would otherwise keep
  # this script's stdout pipe open, and workspace startup would never finish.
  sh -c "$command" > "$log" 2>&1 < /dev/null &
  pid=$!
  tail --pid="$pid" -s 0.2 -n +1 -f "$log" 2> /dev/null || true
  rc=0
  wait "$pid" || rc=$?
  rm -f "$log"

  if [ "$rc" -ne 0 ]; then
    printf '=== %s failed (exit %s). Skipping the remaining lifecycle commands; workspace startup continues.\n' "$hook" "$rc"
    devcontainer_lifecycle_failed="$hook"
  fi
}
