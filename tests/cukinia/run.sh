#!/bin/sh
# On the board, as root (board-test.sh): cukinia's JUnit report plus what
# the HTML report shows, in ./out. Exits with cukinia's status.
here=$(cd "$(dirname "$0")" && pwd)
out=$here/out
mkdir -p "$out"

export MICRODUCK_TEST_ARTIFACTS="$out"
"$here/cukinia" -f junitxml -o "$out/report.xml" "$here/cukinia.conf"
rc=$?

robotctl health > "$out/health.txt" 2>&1
for unit in $(systemctl --failed --no-legend --plain | awk '{ print $1 }'); do
	echo "### $unit"
	journalctl -b -u "$unit" --no-pager -n 15
	echo
done > "$out/failed-units.txt" 2>&1
{
	tr -d '\0' < /proc/device-tree/model; echo
	grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
	uname -r
} > "$out/board.txt" 2>&1

# board-test.sh fetches and removes this as the ssh user.
[ -z "${SUDO_USER:-}" ] || chown -R "$SUDO_USER" "$here"
exit $rc
