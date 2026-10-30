#!/bin/sh
# The newest OS release, which dev and candidate builds are versioned after.
#
#   scripts/os-release.sh        # prints e.g. 1.0.1
#
# Read from origin's microduck-os-v<X.Y.Z> tags, the ones promote-os.yml makes,
# so a release is picked up by the next build with nothing to bump by hand.
# 0.0.0 before the first release. Fails if origin cannot be reached: a build
# should not quietly publish under a version it guessed.
set -eu

cd "$(dirname "$0")/.."

tags=$(git ls-remote --tags --refs origin 'microduck-os-v*') || {
	echo "$0: cannot list origin's tags" >&2
	exit 1
}
version=$(printf '%s\n' "$tags" | sed -n 's|.*refs/tags/microduck-os-v\([0-9]*\.[0-9]*\.[0-9]*\)$|\1|p' \
	| sort -V | tail -n 1)
echo "${version:-0.0.0}"
