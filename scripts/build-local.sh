#!/bin/sh
# Build on this machine, with kas-container.
#
#   scripts/build-local.sh                                    # default target
#   scripts/build-local.sh shell -c 'bitbake microduck-daemon'
#   KAS_FILES=kas/microduck.yml:kas/beta.yml scripts/build-local.sh   # the beta board
#
# Paths come from kas/local.env if it exists (git-ignored; README.md "Build"
# has the three lines it needs), else from the environment.
#
# Exists so the kas-container invocation lives in one place. Composing it inline
# over ssh needs three levels of quoting (ssh '...', sh -c "...", --runtime-args
# "...") and silently truncates when one is wrong -- which produced a build that
# wrote a zero-byte log and never started a container.
#
# --ssh-agent forwards the auth socket for the private microduck_daemon fetch, and
# validates an agent is actually reachable, so over ssh connect with `ssh -A`.
# Set KAS_SSH_DIR to a directory holding a known_hosts with github.com in it.
set -eu

cd "$(dirname "$0")/.."
[ -f kas/local.env ] && . kas/local.env

CMD=${1:-build}
KAS_FILES=${KAS_FILES:-kas/microduck.yml}
[ $# -gt 0 ] && shift

kas-container --ssh-agent "$CMD" "$KAS_FILES" "$@"
