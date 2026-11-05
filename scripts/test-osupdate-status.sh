#!/bin/sh
# Test that microduck-osupdate's `status` still answers while RAUC does not.
#
# Why this exists: RAUC refuses `rauc status` while it installs, `status` died on
# that under set -e and printed nothing, and the page polling it mid-update said
# "Robot unreachable (JSON.parse: unexpected end of data)". Seen on a Zero 3W
# installing 1.1.0+20261105181236.
#
#   sh scripts/test-osupdate-status.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../meta-microduck/recipes-microduck/microduck-osupdate/files/microduck-osupdate
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
mkdir -p "$w/bin" "$w/state"
fails=0

# A RAUC that answers, then one mid-install.
good='{"compatible":"microduck-zero3","booted":"A","slots":[{"rootfs.0":{"bootname":"A","state":"booted","boot_status":"good","slot_status":{"bundle":{"build":"20261105165207"}}}},{"rootfs.1":{"bootname":"B","state":"inactive","boot_status":"good","slot_status":{"bundle":{"build":"20261105090625"}}}}]}'
rauc_answers() { printf '#!/bin/sh\ncat <<"EOF"\n%s\nEOF\n' "$good" > "$w/bin/rauc"; chmod +x "$w/bin/rauc"; }
rauc_busy() {
	printf '#!/bin/sh\necho "Already processing a different method" >&2\nexit 1\n' > "$w/bin/rauc"
	chmod +x "$w/bin/rauc"
}
status() { PATH="$w/bin:$PATH" MICRODUCK_OSUPDATE_STATE=$w/state sh "$script" status 2>/dev/null || true; }
expect() {  # description, text the output must contain
	out=$(status)
	case $out in
	*"$2"*) echo "ok   $1" ;;
	*) echo "FAIL $1: wanted '$2' in: $(printf '%s' "$out" | head -c 200)"; fails=1 ;;
	esac
}

echo installing > "$w/state/phase"
rauc_busy
expect "busy RAUC, nothing cached: still answers, with the phase" '"phase":"installing"'
rauc_answers
expect "RAUC answers" '"installed_build":"20261105165207"'
rauc_busy
expect "busy RAUC: the last answer's slots stand in" '"installed_build":"20261105165207"'
exit $fails
