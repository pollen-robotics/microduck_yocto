#!/bin/sh
# Test tests/cukinia/ports.sh against fake /proc/net tables: a wrong loopback rule
# would silently pass an exposed port.
#
#   sh scripts/test-ports.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
script=$here/../tests/cukinia/ports.sh
w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
fails=0
hdr="  sl  local_address rem_address   st"

# table <file> <"local state" ...>
table() {
	f=$1; shift
	echo "$hdr" > "$w/$f"
	for row in "$@"; do echo "   0: ${row% *} 00000000:0000 ${row#* }" >> "$w/$f"; done
}
# expect <description> <0|1> [text the output must contain]
expect() {
	out=$(PROC_NET=$w FSTAB=$w/fstab sh "$script" 2>&1) && rc=0 || rc=1
	if [ "$rc" = "$2" ] && case "$out" in *"${3:-}"*) true ;; *) false ;; esac; then
		echo "ok   $1"
	else
		echo "FAIL $1: rc=$rc, $out"; fails=$((fails + 1))
	fi
}

echo "/dev/root / auto defaults 1 1" > "$w/fstab" # the dev image

# Allowed ports, and every loopback form, which must not count.
table tcp "00000000:0016 0A" "0100007F:1F90 0A" "0100007F:20FB 0A"
table tcp6 "00000000000000000000000001000000:0277 0A" "0000000000000000FFFF00000100007F:1388 0A"
table udp "00000000:0043 07" "00000000:9C40 07"
table udp6
expect "allowed and loopback only" 0 "off loopback: tcp:22 udp:67"

table tcp "00000000:0016 0A" "00000000:115C 01"
expect "a connection is not a listener" 0

table tcp "00000000:0016 0A" "00000000:115C 0A"
expect "unexpected IPv4 listener" 1 "not on the list: tcp:4444"

table tcp "00000000:0016 0A"
table tcp6 "00000000000000000000000000000000:115C 0A"
expect "unexpected IPv6 listener" 1 "not on the list: tcp:4444"

table tcp6
table udp "00000000:0035 07"
expect "unexpected UDP service" 1 "not on the list: udp:53"

# The update page: allowed off loopback on the dev image, not on the shipping one.
table udp
table tcp "00000000:1F9A 0A"
expect "dev image: 8090 on the LAN" 0
echo "/dev/root / auto ro 1 1" > "$w/fstab"
expect "shipping image: 8090 on the LAN" 1 "not on the list: tcp:8090"

[ "$fails" -eq 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
