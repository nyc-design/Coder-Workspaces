#!/usr/bin/env bash
# git-clone pre_clone_script.
#
# A fresh home volume starts as a copy of the image's home, whose ~/.gitconfig
# uses the `store` credential helper. Left in place, the clone would save the
# external-auth token it authenticates with to ~/.git-credentials. With no
# helper, git asks the agent (GIT_ASKPASS) and keeps nothing. 03-git.sh sets up
# the real helper during init, so this only matters for the clone itself.
if [ ! -e "$HOME/.git-credentials" ] && git config --global --get-all credential.helper 2> /dev/null | grep -q '^store'; then
  git config --global --unset-all credential.helper || true
fi
