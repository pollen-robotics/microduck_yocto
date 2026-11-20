#!/bin/sh
# Everything listening off loopback must be on the dev image's list (no ss or
# netstat on the image, so /proc/net). Measured on face-board-v1, 2026-11-19:
# 22 ssh, 8090 update page (LAN on dev only), 9443 duck-gateway, udp 67 the USB-C
# DHCP server, 68/546 DHCP clients. Client UDP ports (>= 32768) are skipped.
# PROC_NET is for scripts/test-ports.sh. Prints one line.
set -eu
ALLOWED="tcp:22 tcp:8090 tcp:9443 udp:67 udp:68 udp:546"
net=${PROC_NET:-/proc/net}

# "<proto> <hex addr>:<hex port>": TCP in LISTEN (0A), unconnected UDP (07).
listening() {
	for f in tcp tcp6; do awk -v p=tcp 'NR > 1 && $4 == "0A" { print p, $2 }' "$net/$f"; done
	for f in udp udp6; do awk -v p=udp 'NR > 1 && $4 == "07" { print p, $2 }' "$net/$f"; done
}

found=$(listening | awk '
	function hex(h,   i, n) { n = 0; for (i = 1; i <= length(h); i++) n = n * 16 + index("0123456789ABCDEF", toupper(substr(h, i, 1))) - 1; return n }
	{
		split($2, a, ":"); addr = a[1]; port = hex(a[2])
		# Loopback, as /proc prints it: 127/8 (little-endian), ::1, ::ffff:127.x
		if (length(addr) == 8 && substr(addr, 7, 2) == "7F") next
		if (addr == "00000000000000000000000001000000") next
		if (length(addr) == 32 && substr(addr, 17, 8) == "FFFF0000" && substr(addr, 31, 2) == "7F") next
		if ($1 == "udp" && port >= 32768) next
		print $1 ":" port
	}' | sort -u | tr '\n' ' ')

unexpected=
for s in $found; do
	case " $ALLOWED " in *" $s "*) ;; *) unexpected="$unexpected $s" ;; esac
done
echo "off loopback: ${found:-nothing}${unexpected:+; not on the list:$unexpected}"
[ -z "$unexpected" ]
