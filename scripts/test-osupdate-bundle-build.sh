#!/bin/sh
# Test microduck-osupdate's bundle_build against fixed `rauc info --output-format=shell`
# output: apply refuses a bundle unless this returns the manifest's BUILD, so it
# must return the signed build and nothing else.
#
#   sh scripts/test-osupdate-bundle-build.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../meta-microduck/recipes-microduck/microduck-osupdate/files/microduck-osupdate
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Just the function, out of the script, which otherwise wants a board.
sed -n '/^bundle_build() {/,/^}/p' "$script" > "$tmp/fn"
[ -s "$tmp/fn" ] || { echo "bundle_build not found in $script"; exit 1; }
. "$tmp/fn"
STATE=$tmp
PATH=$tmp:$PATH

# A fake rauc printing $2 on stdout and exiting $1.
fake() {
	printf '#!/bin/sh\ncat <<'"'"'EOF'"'"'\n%s\nEOF\nexit %s\n' "$2" "$1" > "$tmp/rauc"
	chmod +x "$tmp/rauc"
}
fails=0
expect() {  # wanted-build  description  exit  rauc-output
	fake "$3" "$4"
	got=$(bundle_build bundle.raucb)
	if [ "$got" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2: '$got', wanted '$1'"; fails=1; fi
}

# The shape promote-os.yml reads from rauc info on a runner.
expect 20261110093000 "a verified bundle" 0 "RAUC_MF_COMPATIBLE='microduck-zero3'
RAUC_MF_VERSION='1.2.0+20261110093000'
RAUC_MF_BUILD='20261110093000'
RAUC_MF_DESCRIPTION='microduck'"
expect 20261110093000 "unquoted" 0 "RAUC_MF_BUILD=20261110093000"
expect "" "no build in the manifest" 0 "RAUC_MF_COMPATIBLE='microduck-zero3'"
expect "" "a build that is not 14 digits" 0 "RAUC_MF_BUILD='2026'"
expect "" "a build with something after it" 0 "RAUC_MF_BUILD='20261110093000'; reboot"
expect "" "not the build line itself" 0 "RAUC_MF_DESCRIPTION='RAUC_MF_BUILD=20261110093000'"
expect "" "rauc will not verify it" 1 ""
exit $fails
