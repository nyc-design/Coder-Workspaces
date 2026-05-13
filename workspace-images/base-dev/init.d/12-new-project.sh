#!/usr/bin/env bash
# 12-new-project.sh
#
# When the workspace was created with `is_existing_project = "new"`, the
# project-workspace template points envbuilder at a Project-Scaffolds
# scaffold/<type> branch. Envbuilder clones it, which leaves a .git/
# directory tied to nyc-design/Project-Scaffolds. We drop that .git/,
# reinit, and make a single "Initial commit from <type> scaffold" commit
# so the user owns the history.
#
# Re-run safety: instead of a sentinel file, we use the existing `origin`
# URL as the state signal. Project-Scaffolds is never a legitimate
# `origin` for a real project, so if `origin` still points there, this
# workspace hasn't been reinit'd yet. After our `git init`, there is no
# `origin` at all (the user adds their own later), so subsequent boots
# fall through without touching anything.

set -euo pipefail

if [[ "${CODER_NEW_PROJECT:-}" != "true" ]]; then
    exit 0
fi

project_name="${CODER_PROJECT_NAME:-}"
project_type="${NEW_PROJECT_TYPE:-base}"
project_dir="/workspaces/${project_name}"

if [[ -z "${project_name}" ]]; then
    echo "[12-new-project] CODER_PROJECT_NAME unset, skipping"
    exit 0
fi
if [[ ! -d "${project_dir}" ]]; then
    echo "[12-new-project] ${project_dir} does not exist, skipping"
    exit 0
fi

current_origin="$(git -C "${project_dir}" remote get-url origin 2>/dev/null || true)"
case "${current_origin}" in
    *Project-Scaffolds*) ;;
    *) exit 0 ;;
esac

cd "${project_dir}"

echo "[12-new-project] reinitializing git for ${project_type} scaffold at ${project_dir}"

rm -rf .git
git init -q -b main
git add -A
# GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL / GIT_COMMITTER_* come from the
# coder agent env, set in project-workspace/main.tf.
git commit -q -m "Initial commit from ${project_type} scaffold"
