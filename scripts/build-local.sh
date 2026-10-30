#!/bin/sh
# Build on this machine, with kas-container.
#
#   scripts/build-local.sh                                    # default target
#   scripts/build-local.sh shell -c 'bitbake microduck-daemon'
#   scripts/build-local.sh shell -c 'bitbake -c update_crates microduck-daemon'
#   DAEMON_VERSION=0.16.1 scripts/build-local.sh              # not the newest daemon
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

# The daemon release (README.md, "Which daemon the image seeds"), passed as -e
# in --runtime-args because kas-container forwards no environment of its own
# beyond its fixed list, so an exported variable never reaches kas inside the
# container.
daemon=$(scripts/daemon-release.sh "${DAEMON_VERSION:-latest}")
# The bundle's RAUC version, the newest OS release, travels the same way.
daemon="$daemon
MICRODUCK_OS_VERSION=$(scripts/os-release.sh)"
daemon_env=$(printf '%s\n' "$daemon" | sed 's/^/-e /' | tr '\n' ' ')

kas() {
	kas-container \
		--ssh-agent \
		--runtime-args "$daemon_env" \
		"$@"
}

# The crate list follows the release's Cargo.lock. Regenerating it rewrites the
# tracked microduck-daemon-crates.inc in this checkout; that diff is the
# release's, not a mistake.
if [ "$CMD" = build ]; then
	kas shell "$KAS_FILES" -c "bitbake -c update_crates microduck-daemon"
fi
kas "$CMD" "$KAS_FILES" "$@"
