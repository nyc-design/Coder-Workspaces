#!/usr/bin/env bash
# Offline integration tests: only scratch copies and isolated homes are modified.
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
readonly fixture_root="$(mktemp -d)"
trap 'rm -rf "$fixture_root"' EXIT

mkdir -p "$fixture_root/prompts" "$fixture_root/image-skills/bundled"
printf 'Base prompt\n' > "$fixture_root/prompts/00-base.txt"
printf 'Image prompt\n' > "$fixture_root/prompts/20-image.txt"
printf 'Base prompt\n\nImage prompt\n' > "$fixture_root/expected-prompt"
printf 'Bundled skill\n' > "$fixture_root/image-skills/bundled/SKILL.md"

# Rewrite baked-in inputs in scratch copies, never in the source or live paths.
sed "s|/usr/local/share/workspace-prompts|$fixture_root/prompts|g" \
  "$repo_root/workspace-images/base-dev/init.d/11-agent-prompts.sh" \
  > "$fixture_root/prompts.sh"
sed -e "s|/usr/local/share/workspace-skills.d|$fixture_root/image-skills|g" \
  -e "s|/usr/local/share/workspace-skills-install.d|$fixture_root/no-install-lists|g" \
  "$repo_root/workspace-images/base-dev/init.d/13-agent-skills.sh" \
  > "$fixture_root/skills.sh"

for scenario in fresh preserved legacy; do
  home="$fixture_root/$scenario"
  mkdir -p "$home/.qwen"
  if [[ "$scenario" == preserved ]]; then
    printf 'User prompt\n' > "$home/.qwen/QWEN.md"
    mkdir -p "$home/.qwen/skills/bundled"
    printf 'User skill\n' > "$home/.qwen/skills/bundled/SKILL.md"
  elif [[ "$scenario" == legacy ]]; then
    ln -s "$home/missing-prompt" "$home/.qwen/QWEN.md"
    ln -s "$home/.agents/skills" "$home/.qwen/skills"
  fi

  for run in 1 2; do
    env HOME="$home" BASH_ENV=/dev/null bash "$fixture_root/prompts.sh" > "$fixture_root/prompts.log" 2>&1 || {
      cat "$fixture_root/prompts.log"; exit 1;
    }
    env HOME="$home" BASH_ENV=/dev/null bash "$fixture_root/skills.sh" > "$fixture_root/skills.log" 2>&1 || {
      cat "$fixture_root/skills.log"; exit 1;
    }
    cmp "$fixture_root/expected-prompt" "$home/.coder/AGENTS.md"
    cmp "$fixture_root/image-skills/bundled/SKILL.md" "$home/.agents/skills/bundled/SKILL.md"
    for provider in .claude/CLAUDE.md .codex/AGENTS.md .gemini/GEMINI.md .qwen/QWEN.md; do
      if [[ "$scenario" == preserved && "$provider" == .qwen/QWEN.md ]]; then
        [[ ! -L "$home/$provider" ]]
        [[ "$(cat "$home/$provider")" == 'User prompt' ]]
      else
        [[ "$(readlink "$home/$provider")" == "$home/.coder/AGENTS.md" ]]
        cmp "$fixture_root/expected-prompt" "$home/$provider"
      fi
    done
    for provider in .claude .codex .gemini .qwen .coder; do
      [[ -d "$home/$provider/skills" && ! -L "$home/$provider/skills" ]]
      if [[ "$scenario" == preserved && "$provider" == .qwen ]]; then
        [[ ! -L "$home/$provider/skills/bundled" ]]
        [[ "$(cat "$home/$provider/skills/bundled/SKILL.md")" == 'User skill' ]]
      else
        [[ "$(readlink "$home/$provider/skills/bundled")" == "$home/.agents/skills/bundled" ]]
      fi
    done

    if [[ "$run" == 1 ]]; then
      # Reruns must remove only stale canonical links, preserving user entries.
      ln -s "$home/.agents/skills/removed" "$home/.qwen/skills/stale"
      ln -s "$home/unrelated-missing" "$home/.qwen/skills/external"
      printf 'Keep regular file\n' > "$home/.qwen/skills/notes"
      # Also exercise a regular-file collision with an incoming bundled skill.
      mkdir -p "$home/.agents/skills/notes"
      printf 'Canonical notes\n' > "$home/.agents/skills/notes/SKILL.md"
      # A bad existing link for a current skill must be refreshed on rerun.
      ln -s "$home/unrelated-missing" "$home/.qwen/skills/notes-link"
      mkdir -p "$home/.agents/skills/notes-link"
      printf 'Canonical link\n' > "$home/.agents/skills/notes-link/SKILL.md"
    else
      [[ ! -e "$home/.qwen/skills/stale" && ! -L "$home/.qwen/skills/stale" ]]
      [[ "$(readlink "$home/.qwen/skills/external")" == "$home/unrelated-missing" ]]
      [[ ! -L "$home/.qwen/skills/notes" ]]
      [[ "$(cat "$home/.qwen/skills/notes")" == 'Keep regular file' ]]
      [[ "$(readlink "$home/.qwen/skills/notes-link")" == "$home/.agents/skills/notes-link" ]]
      [[ -f "$home/.qwen/skills/notes-link/SKILL.md" ]]
    fi
  done
  printf 'PASS: %s prompt/skills publishing and rerun\n' "$scenario"
done

printf 'All agent tools init tests passed.\n'
