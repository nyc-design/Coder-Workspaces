#!/usr/bin/env bash
# 12-new-project.sh
#
# When the workspace was created with `is_existing_project = "new"`, the
# project-workspace template points envbuilder at a Project-Scaffolds
# scaffold/<type> branch. Envbuilder clones it, which leaves a .git/
# directory tied to nyc-design/Project-Scaffolds. The user wants a clean
# repo they own, so on first start we drop that .git/, reinit, and make
# a single "Initial commit from <type> scaffold" commit.
#
# A sentinel file prevents this from running again after the user has
# started doing real git work in the project.

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

sentinel="${project_dir}/.coder/new-project-initialized"
if [[ -f "${sentinel}" ]]; then
    exit 0
fi

cd "${project_dir}"

echo "[12-new-project] reinitializing git for ${project_type} scaffold at ${project_dir}"

rm -rf .git
git init -q -b main
git add -A
# GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL / GIT_COMMITTER_* come from the
# coder agent env, set in project-workspace/main.tf.
git commit -q -m "Initial commit from ${project_type} scaffold"

mkdir -p "${project_dir}/.coder"
touch "${sentinel}"
